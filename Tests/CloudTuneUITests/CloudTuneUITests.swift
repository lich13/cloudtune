import CloudTuneCore
import CloudTuneUI
import Foundation
import Testing
#if os(macOS)
import AppKit
import WebKit
#endif

private func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PersistedRefreshCredential?
    private var simulatedSaveError: Error?

    init(_ initial: PersistedRefreshCredential? = nil, simulatedSaveError: Error? = nil) {
        self.stored = initial
        self.simulatedSaveError = simulatedSaveError
    }

    var current: PersistedRefreshCredential? {
        lock.withLock { stored }
    }

    func setSaveError(_ error: Error?) {
        lock.withLock { simulatedSaveError = error }
    }

    func readCredential() -> KeychainLoadResult {
        lock.withLock {
            if let stored { return .found(stored) }
            return .notFound
        }
    }

    func saveCredential(_ credential: PersistedRefreshCredential) throws {
        try lock.withLock {
            if let simulatedSaveError {
                throw simulatedSaveError
            }
            stored = credential
        }
    }

    func deleteCredential() {
        lock.withLock { stored = nil }
    }
}

@Suite("CloudTuneUI Draft Isolation & Offscreen Light/Dark Snapshot Verification")
struct CloudTuneUITests {
    @Test("Settings draft edits stay isolated from committedSettings across module switches and validate on commit")
    @MainActor
    func verifyDraftSettingsIsolation() async throws {
        let fixtureURL = repoRootURL().appendingPathComponent("contracts/representative-state.json")
        let fixture = try RepresentativeFixture.load(from: fixtureURL)
        let vm = CloudTuneViewModel.fixture(scene: .music, fixture: fixture)

        #expect(vm.committedSettings.cacheLimitMb == 2048)
        #expect(vm.committedSettings.downloadThreads == 8)

        // Invalid draft must NOT overwrite committedSettings and must survive tab switches
        vm.cacheLimitDraft = "128"
        vm.activeModule = .video
        vm.activeModule = .music
        #expect(vm.cacheLimitDraft == "128")
        #expect(vm.committedSettings.cacheLimitMb == 2048)

        let rejected = await vm.commitCacheLimitDraft()
        #expect(rejected == false)
        #expect(vm.settingsValidationError != nil)
        #expect(vm.statusMessage == vm.settingsValidationError)
        #expect(vm.committedSettings.cacheLimitMb == 2048)

        // Editing draft resets both settingsValidationError AND stale validation statusMessage immediately
        vm.cacheLimitDraft = "4096"
        vm.noteDraftEdited()
        #expect(vm.settingsValidationError == nil)
        #expect(vm.statusMessage == nil)

        let accepted = await vm.commitCacheLimitDraft()
        #expect(accepted == true)
        #expect(vm.committedSettings.cacheLimitMb == 4096)

        // Remote pause command must be idempotent (never start playing when already paused)
        vm.pauseIfPlaying()
        #expect(vm.isPlaying == false)
        vm.pauseIfPlaying()
        #expect(vm.isPlaying == false)

        // Unsupported local .ape codec failure must immediately stop playback and show guidance
        let apeTrack = TrackSummary(id: "ape-1", name: "Archive.ape", folderPath: "Lossless", sizeBytes: 1024)
        vm.isPlaying = true
        await vm.handlePlaybackPreparationFailure(
            track: apeTrack,
            error: CloudTuneError.unsupportedLocalMediaFormat("decode failed"),
            wasLoopback: false,
            resumeTime: 0
        )
        #expect(vm.isPlaying == false)
        #expect(vm.statusMessage?.contains(".ape") == true)
    }

    @Test("Anonymous loginName accounts keep isolated accountStorageKeys, preserve real subfolder export paths, and enforce retry cap")
    @MainActor
    func verifyAnonymousAccountIsolationSubfolderExportAndRetryCap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-vm-reg-\(UUID().uuidString)")
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-vm-exp-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: exportDir)
        }
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        actor DynamicMockTransport: CloudHTTPTransport {
            var sessionIndex = 0
            var failDownloadUrlCalls = false
            var downloadUrlCallCount = 0
            private var downloadUrlWaiters: [(id: UUID, target: Int, continuation: CheckedContinuation<Void, Never>)] = []

            func setSessionIndex(_ idx: Int) { sessionIndex = idx }
            func setFailDownloadUrl(_ fail: Bool) {
                failDownloadUrlCalls = fail
                downloadUrlCallCount = 0
            }
            func getDownloadUrlCalls() -> Int { downloadUrlCallCount }

            private func notifyDownloadUrlWaiters() {
                var remaining: [(id: UUID, target: Int, continuation: CheckedContinuation<Void, Never>)] = []
                for waiter in downloadUrlWaiters {
                    if downloadUrlCallCount >= waiter.target {
                        waiter.continuation.resume()
                    } else {
                        remaining.append(waiter)
                    }
                }
                downloadUrlWaiters = remaining
            }

            private func removeWaiter(id: UUID) {
                if let idx = downloadUrlWaiters.firstIndex(where: { $0.id == id }) {
                    let waiter = downloadUrlWaiters.remove(at: idx)
                    waiter.continuation.resume()
                }
            }

            func waitUntilDownloadUrlCalls(atLeast target: Int, timeout: Duration = .seconds(5)) async -> Bool {
                if downloadUrlCallCount >= target {
                    return true
                }
                let waiterID = UUID()
                var timeoutTask: Task<Void, Never>?
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if downloadUrlCallCount >= target {
                        continuation.resume()
                    } else {
                        downloadUrlWaiters.append((id: waiterID, target: target, continuation: continuation))
                        timeoutTask = Task {
                            try? await Task.sleep(for: timeout)
                            self.removeWaiter(id: waiterID)
                        }
                    }
                }
                timeoutTask?.cancel()
                return downloadUrlCallCount >= target
            }

            func send(_ request: URLRequest) async throws -> CloudHTTPResponse {
                let url = request.url!
                let path = url.path
                let query = url.query ?? ""
                if path.contains("getSessionForPC.action") {
                    // Omit loginName to exercise anonymous account key separation
                    let body = """
                    {"res_code":0,"accessToken":"at_\(sessionIndex)","refreshToken":"rt_unique_\(sessionIndex)","sessionKey":"sk_\(sessionIndex)","sessionSecret":"ss_\(sessionIndex)"}
                    """
                    return CloudHTTPResponse(statusCode: 200, body: Data(body.utf8), finalURL: url)
                }
                if path.contains("listFiles.action") {
                    if query.contains("folderId=cd1") {
                        let b = #"{"res_code":0,"fileListAO":{"count":1,"folderList":[],"fileList":[{"id":"f-cd1-01","name":"01. Track.flac","size":4}]}}"#
                        return CloudHTTPResponse(statusCode: 200, body: Data(b.utf8), finalURL: url)
                    }
                    if query.contains("folderId=cd2") {
                        let b = #"{"res_code":0,"fileListAO":{"count":1,"folderList":[],"fileList":[{"id":"f-cd2-01","name":"01. Track.flac","size":4}]}}"#
                        return CloudHTTPResponse(statusCode: 200, body: Data(b.utf8), finalURL: url)
                    }
                    let rootBody = #"{"res_code":0,"fileListAO":{"count":2,"folderList":[{"id":"cd1","name":"CD 1"},{"id":"cd2","name":"CD 2"}],"fileList":[]}}"#
                    return CloudHTTPResponse(statusCode: 200, body: Data(rootBody.utf8), finalURL: url)
                }
                if path.contains("getFileDownloadUrl.action") {
                    if query.contains("fileId=f-transient") {
                        downloadUrlCallCount += 1
                        notifyDownloadUrlWaiters()
                        if failDownloadUrlCalls {
                            throw URLError(.cannotFindHost)
                        }
                    }
                    return CloudHTTPResponse(statusCode: 200, body: Data(#"{"res_code":0,"fileDownloadUrl":"https://media.example.invalid/t.flac"}"#.utf8), finalURL: url)
                }
                return CloudHTTPResponse(statusCode: 200, body: Data("{}".utf8), finalURL: url)
            }

            func importCookies(_ cookies: [HTTPCookie]) async {}
            func clearCookies() async {}
        }

        let transport = DynamicMockTransport()
        let client = Cloud189Client(transport: transport)
        let store = try AccountScopedStore(rootDirectory: root)
        let isolatedKC = InMemoryKeychainBackend()
        let vm = CloudTuneViewModel(
            cloudClient: client,
            accountStore: store,
            keychainBackend: isolatedKC,
            enableLiveObservers: false
        )
        vm.retryBaseDelayMs = 5

        // 1) Two accounts that both omit loginName MUST NOT share storage bucket
        await transport.setSessionIndex(1)
        await vm.completeEmbeddedWebLogin(callbackURL: URL(string: "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=1")!, cookies: [])
        #expect(vm.accountName == "天翼云盘用户")
        let key1 = try #require(vm.accountStorageKey)
        #expect(key1 != "天翼云盘用户")
        try await store.saveLibrary([TrackSummary(id: "u1-song", name: "User1Only.flac", folderPath: "CD 1", sizeBytes: 100)], for: key1)

        await vm.logout()
        await transport.setSessionIndex(2)
        await vm.completeEmbeddedWebLogin(callbackURL: URL(string: "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=2")!, cookies: [])
        #expect(vm.accountName == "天翼云盘用户")
        let key2 = try #require(vm.accountStorageKey)
        #expect(key2 != key1)
        #expect(vm.tracks.isEmpty)

        // 2) Browsing into CD 1 and CD 2 preserves real folder names (never "当前目录")
        await vm.browseTo(folderId: "cd1", nextBreadcrumbs: [.root, BreadcrumbItem(id: "cd1", name: "CD 1")])
        #expect(vm.browser?.currentFolderName == "CD 1")
        #expect(vm.browser?.audioFiles.first?.folderPath == "CD 1")

        await vm.saveExportDirectoryBookmark(exportDir)
        await vm.enqueueCurrentFolderDownload(explicitDirectoryURL: exportDir)
        let cd1Subpath = vm.downloadTransfers.first?.path
        #expect(cd1Subpath == "CD 1/01. Track.flac")

        await vm.browseTo(folderId: "cd2", nextBreadcrumbs: [.root, BreadcrumbItem(id: "cd2", name: "CD 2")])
        #expect(vm.browser?.currentFolderName == "CD 2")
        await vm.enqueueCurrentFolderDownload(explicitDirectoryURL: exportDir)
        let allPaths = Set(vm.downloadTransfers.compactMap(\.path))
        #expect(allPaths.contains("CD 1/01. Track.flac"))
        #expect(allPaths.contains("CD 2/01. Track.flac"))

        // 3) Transient playback failure with resumeTime == 0 enforces maxRecoveryAttempts (1 initial + 6 retries = 7 total)
        await vm.updatePlaybackMode(.streamCache)
        await transport.setFailDownloadUrl(true)
        let smallTrack = TrackSummary(id: "f-transient", name: "Transient.mp3", folderPath: "CD 2", sizeBytes: 1024)
        await vm.playTrack(smallTrack)
        #expect(await transport.getDownloadUrlCalls() == 1 + PlaybackDecisionPolicy.maxRecoveryAttempts)
        #expect(vm.statusMessage?.contains("已停止自动重试") == true)

        // 4) Manual logout or opening video in-app during retry backoff cancels stale retry
        @MainActor
        func waitForRetryBackoffEntry() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while vm.statusMessage?.contains("正在重试") != true {
                guard ContinuousClock.now < deadline else {
                    break
                }
                await Task.yield()
                if vm.statusMessage?.contains("正在重试") != true {
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            #expect(vm.statusMessage?.contains("正在重试") == true)
        }

        vm.retryBaseDelayMs = 5_000
        await transport.setFailDownloadUrl(true)
        let videoInterruptTask = Task { @MainActor in
            await vm.playTrack(smallTrack)
        }
        #expect(await transport.waitUntilDownloadUrlCalls(atLeast: 1))
        try await waitForRetryBackoffEntry()
        await vm.openVideoInApp(TrackSummary(id: "vid-1", name: "Concert.mp4", folderPath: "CD 2", sizeBytes: 4096))
        await videoInterruptTask.value
        #expect(await transport.getDownloadUrlCalls() == 1)

        // Network DNS failure on .ape track MUST NOT misclassify as unsupported local codec
        await transport.setFailDownloadUrl(true)
        vm.retryBaseDelayMs = 2
        let apeNetworkTrack = TrackSummary(id: "f-transient", name: "Concert.ape", folderPath: "CD 2", sizeBytes: 1024)
        await vm.playTrack(apeNetworkTrack)
        #expect(await transport.getDownloadUrlCalls() == 1 + PlaybackDecisionPolicy.maxRecoveryAttempts)
        #expect(vm.statusMessage?.contains("已停止自动重试") == true)

        vm.retryBaseDelayMs = 5_000
        await transport.setFailDownloadUrl(true)
        let retryTask = Task { @MainActor in
            await vm.playTrack(smallTrack)
        }
        #expect(await transport.waitUntilDownloadUrlCalls(atLeast: 1))
        try await waitForRetryBackoffEntry()
        await vm.logout()
        await retryTask.value
        #expect(await transport.getDownloadUrlCalls() == 1)
        vm.retryBaseDelayMs = 5

        // 5) Bootstrap must NOT overwrite an existing native Keychain credential with legacy Tauri settings.json
        final class PreseededKeychain: KeychainBackend, @unchecked Sendable {
            var current: PersistedRefreshCredential?
            init(_ cred: PersistedRefreshCredential) { self.current = cred }
            func readCredential() -> KeychainLoadResult {
                if let current { return .found(current) }
                return .notFound
            }
            func saveCredential(_ credential: PersistedRefreshCredential) throws { current = credential }
            func deleteCredential() { current = nil }
        }
        let migRoot = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-boot-mig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: migRoot) }
        try FileManager.default.createDirectory(at: migRoot, withIntermediateDirectories: true)
        try Data(#"{"refreshToken":"rt_old_legacy","accountName":"old@example.invalid","cacheLimitMb":1024}"#.utf8)
            .write(to: migRoot.appendingPathComponent("settings.json"))
        let nativeCred = try #require(PersistedRefreshCredential(refreshToken: "rt_native_keep", accountName: "native@example.invalid"))
        let kc = PreseededKeychain(nativeCred)
        let migStore = try AccountScopedStore(rootDirectory: migRoot)
        let bootVM = CloudTuneViewModel(cloudClient: client, accountStore: migStore, keychainBackend: kc, enableLiveObservers: false)
        await bootVM.bootstrap()
        #expect(kc.current?.refreshToken != "rt_old_legacy")
    }

    @Test("Cloud/Video browser decoupling, activeTrack survival across folder navigation, checked settings write failure, and paired observer lifecycle")
    @MainActor
    func verifyDecoupledBrowsersActiveTrackSurvivalAndCheckedSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-vm-s1a-\(UUID().uuidString)")
        let suiteName = "com.gosu.cloudtune.test.\(UUID().uuidString)"
        let isolatedDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            isolatedDefaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        actor FolderMockTransport: CloudHTTPTransport {
            func send(_ request: URLRequest) async throws -> CloudHTTPResponse {
                let url = request.url!
                let path = url.path
                let query = url.query ?? ""
                if path.contains("getSessionForPC.action") {
                    let body = #"{"res_code":0,"loginName":"listener@example.invalid","accessToken":"at","refreshToken":"rt","sessionKey":"sk","sessionSecret":"ss"}"#
                    return CloudHTTPResponse(statusCode: 200, body: Data(body.utf8), finalURL: url)
                }
                if path.contains("listFiles.action") {
                    if query.contains("folderId=jazz") {
                        let b = #"{"res_code":0,"fileListAO":{"count":1,"folderList":[],"fileList":[{"id":"cloud-jazz-1","name":"Waltz.flac","size":2048}]}}"#
                        return CloudHTTPResponse(statusCode: 200, body: Data(b.utf8), finalURL: url)
                    }
                    if query.contains("folderId=concerts") {
                        let b = #"{"res_code":0,"fileListAO":{"count":1,"folderList":[],"fileList":[{"id":"vid-live-1","name":"Live4K.mp4","size":8192}]}}"#
                        return CloudHTTPResponse(statusCode: 200, body: Data(b.utf8), finalURL: url)
                    }
                    let b = #"{"res_code":0,"fileListAO":{"count":2,"folderList":[{"id":"jazz","name":"Jazz"},{"id":"concerts","name":"Concerts"}],"fileList":[]}}"#
                    return CloudHTTPResponse(statusCode: 200, body: Data(b.utf8), finalURL: url)
                }
                if path.contains("getFileDownloadUrl.action") {
                    let b = #"{"res_code":0,"fileDownloadUrl":"https://media.example.invalid/asset.bin"}"#
                    return CloudHTTPResponse(statusCode: 200, body: Data(b.utf8), finalURL: url)
                }
                return CloudHTTPResponse(statusCode: 200, body: Data("{}".utf8), finalURL: url)
            }
            func importCookies(_ cookies: [HTTPCookie]) async {}
            func clearCookies() async {}
        }

        let store = try AccountScopedStore(rootDirectory: root)
        let vmKeychain = InMemoryKeychainBackend()
        let vm = CloudTuneViewModel(
            cloudClient: Cloud189Client(transport: FolderMockTransport()),
            accountStore: store,
            keychainBackend: vmKeychain,
            userDefaults: isolatedDefaults,
            enableLiveObservers: true
        )
        defer { vm.teardownPlayerAndRemoteCommands() }
        #expect(vm.hasActivePlayerObservers == true)

        await vm.completeEmbeddedWebLogin(
            callbackURL: URL(string: "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=ok")!,
            cookies: []
        )
        #expect(vm.isAuthenticated == true)

        // 1) Browse cloudBrowser to Jazz, play ad-hoc cloud track (library `tracks` is empty!), then switch cloudBrowser to Concerts
        await vm.browseTo(scope: .cloud, folderId: "jazz", nextBreadcrumbs: [.root, BreadcrumbItem(id: "jazz", name: "Jazz")])
        await vm.browseTo(scope: .video, folderId: "concerts", nextBreadcrumbs: [.root, BreadcrumbItem(id: "concerts", name: "Concerts")])
        #expect(vm.cloudBrowser.payload?.currentFolderId == "jazz")
        #expect(vm.videoBrowser.payload?.currentFolderId == "concerts")

        let jazzTrack = try #require(vm.cloudBrowser.payload?.audioFiles.first)
        await vm.updatePlaybackMode(.streamCache)
        await vm.playTrack(jazzTrack)
        #expect(vm.currentTrack?.id == "cloud-jazz-1")

        // Navigating cloudBrowser away MUST NOT drop activeTrack / currentTrack
        await vm.browseTo(scope: .cloud, folderId: nil, nextBreadcrumbs: [.root])
        #expect(vm.cloudBrowser.payload?.audioFiles.isEmpty == true)
        #expect(vm.currentTrack?.id == "cloud-jazz-1")
        #expect(vm.videoBrowser.payload?.currentFolderId == "concerts")

        // 2) Uncached external video request NEVER returns raw https:// URL; sets pendingExternalVideoChoice with loopback proxy URL
        let concertVideo = try #require(vm.videoBrowser.payload?.videoFiles.first)
        let directURL = await vm.requestExternalVideoPlayback(concertVideo)
        #expect(directURL == nil)
        let choice = try #require(vm.pendingExternalVideoChoice)
        #expect(choice.video.id == "vid-live-1")
        #expect(choice.streamURL?.host == "127.0.0.1")

        // 2b) When streamServer is unavailable (enableLiveObservers: false), external video choice MUST NOT leak raw https:// URL
        let freshStore = try AccountScopedStore(rootDirectory: root.appendingPathComponent("fresh-acct"))
        let noProxyVM = CloudTuneViewModel(
            cloudClient: Cloud189Client(transport: FolderMockTransport()),
            accountStore: freshStore,
            keychainBackend: InMemoryKeychainBackend(),
            userDefaults: isolatedDefaults,
            enableLiveObservers: false
        )
        noProxyVM.appearancePreference = .dark
        await noProxyVM.completeEmbeddedWebLogin(
            callbackURL: URL(string: "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=noproxy")!,
            cookies: []
        )
        // Fresh account without settings.json preserves pre-login appearancePreference (.dark)
        // AND saveExportDirectoryBookmark persists .dark to settings.json instead of clobbering to .system
        #expect(noProxyVM.appearancePreference == .dark)
        #expect(noProxyVM.committedSettings.appearanceMode == .dark)
        let freshExportDir = root.appendingPathComponent("fresh-export-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: freshExportDir, withIntermediateDirectories: true)
        await noProxyVM.saveExportDirectoryBookmark(freshExportDir)
        let freshAccountKey = try #require(noProxyVM.accountStorageKey)
        let persistedFreshSettings = try #require(try await freshStore.loadSettingsIfPresent(for: freshAccountKey))
        #expect(persistedFreshSettings.appearanceMode == .dark)
        #expect(persistedFreshSettings.exportFolderDisplayName == "fresh-export-folder")
        let noProxyDirect = await noProxyVM.requestExternalVideoPlayback(concertVideo)
        #expect(noProxyDirect == nil)
        let noProxyChoice = try #require(noProxyVM.pendingExternalVideoChoice)
        #expect(noProxyChoice.streamURL == nil)

        // 2c) Dirty settings close guard blocks silent Cmd+W / window close while preserving draft
        noProxyVM.isShowingSettingsSheet = true
        noProxyVM.cacheLimitDraft = "4096"
        #expect(noProxyVM.canCloseSettingsSurface() == false)
        #expect(noProxyVM.isShowingSettingsSheet == true)
        #expect(noProxyVM.cacheLimitDraft == "4096")
        #expect(noProxyVM.settingsValidationError != nil)
        #expect(await noProxyVM.commitPendingSettingsDraftsIfNeeded() == true)
        #expect(noProxyVM.committedSettings.cacheLimitMb == 4096)
        #expect(noProxyVM.canCloseSettingsSurface() == true)
        #expect(noProxyVM.isShowingSettingsSheet == false)

        // 2d) External video request & download completing after logout() MUST NOT mutate pendingExternalVideoChoice, shareFileURL, or leave busyLabel stuck
        actor GatedVideoTransport: CloudHTTPTransport {
            private var enteredContinuation: CheckedContinuation<Void, Never>?
            private var releaseContinuation: CheckedContinuation<Void, Never>?
            private var hasEntered = false
            private var isReleased = false

            func resetGate() {
                hasEntered = false
                isReleased = false
                enteredContinuation = nil
                releaseContinuation = nil
            }

            func waitUntilEnteredDownloadURL() async {
                if hasEntered { return }
                await withCheckedContinuation { cont in
                    enteredContinuation = cont
                }
            }

            func releaseDownloadURL() {
                isReleased = true
                releaseContinuation?.resume()
                releaseContinuation = nil
            }

            func send(_ request: URLRequest) async throws -> CloudHTTPResponse {
                let url = request.url!
                if url.path.contains("getSessionForPC.action") {
                    let body = #"{"res_code":0,"loginName":"race@example.invalid","accessToken":"at","refreshToken":"rt","sessionKey":"sk","sessionSecret":"ss"}"#
                    return CloudHTTPResponse(statusCode: 200, body: Data(body.utf8), finalURL: url)
                }
                if url.path.contains("getFileDownloadUrl.action") {
                    hasEntered = true
                    enteredContinuation?.resume()
                    enteredContinuation = nil
                    if !isReleased {
                        await withCheckedContinuation { cont in
                            releaseContinuation = cont
                        }
                    }
                    let body = #"{"res_code":0,"fileDownloadUrl":"https://media.example.invalid/slow.mp4"}"#
                    return CloudHTTPResponse(statusCode: 200, body: Data(body.utf8), finalURL: url)
                }
                return CloudHTTPResponse(statusCode: 200, body: Data("{}".utf8), finalURL: url)
            }
            func importCookies(_ cookies: [HTTPCookie]) async {}
            func clearCookies() async {}
        }
        let gatedTransport = GatedVideoTransport()
        let raceVM = CloudTuneViewModel(
            cloudClient: Cloud189Client(transport: gatedTransport),
            accountStore: freshStore,
            keychainBackend: InMemoryKeychainBackend(),
            userDefaults: isolatedDefaults,
            enableLiveObservers: false
        )
        await raceVM.completeEmbeddedWebLogin(
            callbackURL: URL(string: "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=race")!,
            cookies: []
        )
        let inFlightExternalTask = Task { @MainActor in
            await raceVM.requestExternalVideoPlayback(concertVideo)
        }
        await gatedTransport.waitUntilEnteredDownloadURL()
        #expect(raceVM.busyLabel != nil)
        await raceVM.logout()
        #expect(raceVM.busyLabel == nil)
        await gatedTransport.releaseDownloadURL()
        let lateExternalResult = await inFlightExternalTask.value
        #expect(lateExternalResult == nil)
        #expect(raceVM.pendingExternalVideoChoice == nil)
        #expect(raceVM.shareFileURL == nil)
        #expect(raceVM.busyLabel == nil)

        // Also test downloadVideoAndPrepareLocalFile racing against logout()
        await gatedTransport.resetGate()
        await raceVM.completeEmbeddedWebLogin(
            callbackURL: URL(string: "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=race2")!,
            cookies: []
        )
        let smallUncachedVideo = TrackSummary(id: "vid-dl-race", name: "Clip.mp4", folderPath: "Videos", sizeBytes: 128)
        let inFlightDownloadVideoTask = Task { @MainActor in
            await raceVM.downloadVideoAndPrepareLocalFile(smallUncachedVideo)
        }
        await gatedTransport.waitUntilEnteredDownloadURL()
        #expect(raceVM.busyLabel != nil)
        await raceVM.logout()
        #expect(raceVM.busyLabel == nil)
        await gatedTransport.releaseDownloadURL()
        let lateDownloadResult = await inFlightDownloadVideoTask.value
        #expect(lateDownloadResult == nil)
        #expect(raceVM.shareFileURL == nil)
        #expect(raceVM.busyLabel == nil)
        #expect(raceVM.statusMessage == "已退出登录并清理当前会话")

        // 3) Logout tears down observers, closes sheets/modals, resets module, and re-login re-registers idempotently
        vm.isShowingSettingsSheet = true
        vm.isShowingWebLoginSheet = true
        vm.activeModule = .settings
        await vm.logout()
        #expect(vm.hasActivePlayerObservers == false)
        #expect(vm.isShowingSettingsSheet == false)
        #expect(vm.isShowingWebLoginSheet == false)
        #expect(vm.activeModule == .music)
        await vm.completeEmbeddedWebLogin(
            callbackURL: URL(string: "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=ok2")!,
            cookies: []
        )
        #expect(vm.hasActivePlayerObservers == true)

        // 4) Disk write failure on settings.json MUST NOT claim "已更新" or overwrite committedSettings, and MUST keep draft for retry
        let acctKey = try #require(vm.accountStorageKey)
        let acctPaths = try await store.paths(for: acctKey)
        try? FileManager.default.removeItem(at: acctPaths.settingsURL)
        try FileManager.default.createDirectory(at: acctPaths.settingsURL, withIntermediateDirectories: true)

        vm.cacheLimitDraft = "4096"
        let saved = await vm.commitCacheLimitDraft()
        #expect(saved == false)
        #expect(vm.committedSettings.cacheLimitMb == 1024)
        #expect(vm.cacheLimitDraft == "4096")
        #expect(vm.hasUnsavedSettingsDrafts == true)
        #expect(vm.statusMessage?.contains("保存设置失败") == true)
        #expect(TransferStatus(id: "d1", label: "a.flac", kind: "download", state: "running").localizedStateLabel == "传输中")
        #expect(TransferStatus(id: "d2", label: "a.flac", kind: "download", state: "paused").localizedStateLabel == "已暂停")

        #if os(macOS)
        // 5) MacShortcutFocusGuard blocks Spacebar playback shortcut when NSTextField or WKWebView is first responder
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let textField = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        let webView = WKWebView(frame: NSRect(x: 10, y: 50, width: 200, height: 100))
        container.addSubview(textField)
        container.addSubview(webView)
        win.contentView = container
        _ = win.makeFirstResponder(nil)
        #expect(MacShortcutFocusGuard.shouldAllowSingleKeyPlaybackShortcut(in: win) == true)
        _ = win.makeFirstResponder(textField)
        #expect(MacShortcutFocusGuard.shouldAllowSingleKeyPlaybackShortcut(in: win) == false)
        _ = win.makeFirstResponder(webView)
        #expect(MacShortcutFocusGuard.shouldAllowSingleKeyPlaybackShortcut(in: win) == false)
        #endif
    }

    @Test("Browser generation guard, simultaneous draft commit, concurrent settings mutation, login warning preservation, decoupled external video, and queue consumption")
    @MainActor
    func verifyBrowserGenerationSettingsAtomicityExternalVideoAndQueueConsumption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-vm-r14-\(UUID().uuidString)")
        let suiteName = "com.gosu.cloudtune.test.r14.\(UUID().uuidString)"
        let isolatedDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            isolatedDefaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let videoFixtureBytes = Data(repeating: 0x5A, count: 64)

        actor SequencedMockTransport: CloudHTTPTransport {
            private var slowFolderEntered: CheckedContinuation<Void, Never>?
            private var slowFolderRelease: CheckedContinuation<Void, Never>?
            private var hasEnteredSlowFolder = false
            private var isSlowFolderReleased = false
            private var videoUrlEntered: CheckedContinuation<Void, Never>?
            private var videoUrlRelease: CheckedContinuation<Void, Never>?
            private var hasEnteredVideoUrl = false
            private var isVideoUrlReleased = false
            private var authEntered: CheckedContinuation<Void, Never>?
            private var authRelease: CheckedContinuation<Void, Never>?
            private var gateNextAuth = false
            private var hasEnteredAuth = false
            private var downloadUrlCount = 0

            func enableAuthGate() {
                gateNextAuth = true
                hasEnteredAuth = false
                authEntered = nil
                authRelease = nil
            }

            func waitUntilEnteredAuth() async {
                if hasEnteredAuth { return }
                await withCheckedContinuation { cont in authEntered = cont }
            }

            func releaseAuth() {
                gateNextAuth = false
                authRelease?.resume()
                authRelease = nil
            }

            func resetVideoGate() {
                hasEnteredVideoUrl = false
                isVideoUrlReleased = false
                videoUrlEntered = nil
                videoUrlRelease = nil
            }

            func resetSlowFolderGate() {
                hasEnteredSlowFolder = false
                isSlowFolderReleased = false
                slowFolderEntered = nil
                slowFolderRelease = nil
            }

            func waitUntilEnteredSlowFolder() async {
                if hasEnteredSlowFolder { return }
                await withCheckedContinuation { cont in slowFolderEntered = cont }
            }

            func releaseSlowFolder() {
                isSlowFolderReleased = true
                slowFolderRelease?.resume()
                slowFolderRelease = nil
            }

            func waitUntilEnteredVideoUrl() async {
                if hasEnteredVideoUrl { return }
                await withCheckedContinuation { cont in videoUrlEntered = cont }
            }

            func releaseVideoUrl() {
                isVideoUrlReleased = true
                videoUrlRelease?.resume()
                videoUrlRelease = nil
            }

            func getDownloadUrlCount() -> Int { downloadUrlCount }
            func clearDownloadUrlCount() { downloadUrlCount = 0 }

            func send(_ request: URLRequest) async throws -> CloudHTTPResponse {
                let url = request.url!
                let path = url.path
                let query = url.query ?? ""
                if path.contains("getSessionForPC.action") {
                    if gateNextAuth {
                        hasEnteredAuth = true
                        authEntered?.resume()
                        authEntered = nil
                        if gateNextAuth {
                            await withCheckedContinuation { cont in authRelease = cont }
                        }
                    }
                    let b = #"{"res_code":0,"loginName":"r14@example.invalid","accessToken":"at","refreshToken":"rt_r14","sessionKey":"sk","sessionSecret":"ss"}"#
                    return CloudHTTPResponse(statusCode: 200, body: Data(b.utf8), finalURL: url)
                }
                if path.contains("listFiles.action") {
                    if query.contains("folderId=slow-a") {
                        hasEnteredSlowFolder = true
                        slowFolderEntered?.resume()
                        slowFolderEntered = nil
                        if !isSlowFolderReleased {
                            await withCheckedContinuation { cont in slowFolderRelease = cont }
                        }
                        let b = #"{"res_code":0,"fileListAO":{"count":1,"folderList":[],"fileList":[{"id":"a-1","name":"OldFolder.flac","size":1024}]}}"#
                        return CloudHTTPResponse(statusCode: 200, body: Data(b.utf8), finalURL: url)
                    }
                    if query.contains("folderId=fast-b") {
                        let b = #"{"res_code":0,"fileListAO":{"count":1,"folderList":[],"fileList":[{"id":"b-1","name":"NewFolder.flac","size":1024}]}}"#
                        return CloudHTTPResponse(statusCode: 200, body: Data(b.utf8), finalURL: url)
                    }
                    let rootBody = #"{"res_code":0,"fileListAO":{"count":2,"folderList":[{"id":"slow-a","name":"SlowA"},{"id":"fast-b","name":"FastB"}],"fileList":[]}}"#
                    return CloudHTTPResponse(statusCode: 200, body: Data(rootBody.utf8), finalURL: url)
                }
                if path.contains("getFileDownloadUrl.action") {
                    downloadUrlCount += 1
                    if query.contains("fileId=vid-gated") || query.contains("fileId=vid-dl-gated") {
                        hasEnteredVideoUrl = true
                        videoUrlEntered?.resume()
                        videoUrlEntered = nil
                        if !isVideoUrlReleased {
                            await withCheckedContinuation { cont in videoUrlRelease = cont }
                        }
                        if query.contains("fileId=vid-dl-gated") {
                            throw CloudTuneError.protocolError("模拟视频缓存源波动")
                        }
                    }
                    let b = #"{"res_code":0,"fileDownloadUrl":"https://media.example.invalid/stream.bin"}"#
                    return CloudHTTPResponse(statusCode: 200, body: Data(b.utf8), finalURL: url)
                }
                return CloudHTTPResponse(statusCode: 200, body: Data("{}".utf8), finalURL: url)
            }

            func importCookies(_ cookies: [HTTPCookie]) async {}
            func clearCookies() async {}
        }

        let transport = SequencedMockTransport()
        let store = try AccountScopedStore(rootDirectory: root)
        let preseedPaths = try await store.paths(for: "r14@example.invalid")
        let preseedCache = try CacheStore(cacheDirectory: preseedPaths.cacheDir, indexURL: preseedPaths.cacheIndexURL)
        let preseededVideoURL = await preseedCache.cacheFileURL(trackId: "vid-dl-cached", originalFileName: "CachedShow.mp4")
        try videoFixtureBytes.write(to: preseededVideoURL, options: .atomic)
        _ = try await preseedCache.recordCompletedFile(
            trackId: "vid-dl-cached",
            fileURL: preseededVideoURL,
            sizeBytes: UInt64(videoFixtureBytes.count),
            limitBytes: 64 * 1024 * 1024
        )
        let keychain = InMemoryKeychainBackend(simulatedSaveError: CloudTuneError.storageError("模拟钥匙串拒绝写入"))
        let vm = CloudTuneViewModel(
            cloudClient: Cloud189Client(transport: transport),
            accountStore: store,
            keychainBackend: keychain,
            userDefaults: isolatedDefaults,
            enableLiveObservers: false
        )

        // Issue 8: Credential save failure warning MUST be preserved in final completeEmbeddedWebLogin statusMessage
        await vm.completeEmbeddedWebLogin(
            callbackURL: URL(string: "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=warn")!,
            cookies: []
        )
        #expect(vm.isAuthenticated == true)
        #expect(vm.statusMessage?.contains("天翼官方网页登录成功") == true)
        #expect(vm.statusMessage?.contains("钥匙串保存凭据失败") == true)
        keychain.setSaveError(nil)

        // Issue 3: Out-of-order folder navigation must keep newer folder, and post-logout completion must never mutate state
        let slowBrowseTask = Task { @MainActor in
            await vm.browseTo(scope: .cloud, folderId: "slow-a", nextBreadcrumbs: [.root, BreadcrumbItem(id: "slow-a", name: "SlowA")])
        }
        await transport.waitUntilEnteredSlowFolder()
        await vm.browseTo(scope: .cloud, folderId: "fast-b", nextBreadcrumbs: [.root, BreadcrumbItem(id: "fast-b", name: "FastB")])
        #expect(vm.cloudBrowser.payload?.currentFolderId == "fast-b")
        await transport.releaseSlowFolder()
        await slowBrowseTask.value
        #expect(vm.cloudBrowser.payload?.currentFolderId == "fast-b")
        #expect(vm.busyLabel == nil)

        await transport.resetSlowFolderGate()
        let logoutBrowseTask = Task { @MainActor in
            await vm.browseTo(scope: .video, folderId: "slow-a", nextBreadcrumbs: [.root, BreadcrumbItem(id: "slow-a", name: "SlowA")])
        }
        await transport.waitUntilEnteredSlowFolder()
        await vm.logout()
        await transport.releaseSlowFolder()
        await logoutBrowseTask.value
        #expect(vm.videoBrowser.payload == nil)
        #expect(vm.busyLabel == nil)

        // Re-login cleanly for settings, write-through, video, and queue checks
        await vm.completeEmbeddedWebLogin(
            callbackURL: URL(string: "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=clean")!,
            cookies: []
        )
        #expect(vm.statusMessage == "天翼官方网页登录成功")

        // Issue 6: Simultaneous dirty cacheLimitDraft + thread drafts must NOT clobber each other
        vm.cacheLimitDraft = "3072"
        vm.downloadThreadsDraft = "12"
        vm.cacheThreadsDraft = "6"
        #expect(await vm.commitCacheLimitDraft() == true)
        #expect(vm.committedSettings.cacheLimitMb == 3072)
        #expect(vm.downloadThreadsDraft == "12")
        #expect(vm.cacheThreadsDraft == "6")
        #expect(vm.hasUnsavedSettingsDrafts == true)

        // Invalid thread draft rejects upfront in commitPendingSettingsDraftsIfNeeded without partial save
        vm.cacheLimitDraft = "4096"
        vm.downloadThreadsDraft = "99"
        #expect(await vm.commitPendingSettingsDraftsIfNeeded() == false)
        #expect(vm.committedSettings.cacheLimitMb == 3072)
        #expect(vm.cacheLimitDraft == "4096")

        // Valid simultaneous dirty cacheLimitDraft + thread drafts persist together atomically
        vm.downloadThreadsDraft = "14"
        vm.cacheThreadsDraft = "7"
        #expect(await vm.commitPendingSettingsDraftsIfNeeded() == true)
        #expect(vm.committedSettings.cacheLimitMb == 4096)
        #expect(vm.committedSettings.downloadThreads == 14)
        #expect(vm.committedSettings.cacheThreads == 7)
        #expect(vm.hasUnsavedSettingsDrafts == false)

        // Issue 7: Overlapping setAppearanceMode + updatePlaybackMode preserve both fields
        async let appearanceTask: Void = vm.setAppearanceMode(.dark)
        async let modeTask: Void = vm.updatePlaybackMode(.streamCache)
        _ = await (appearanceTask, modeTask)
        let acctKey = try #require(vm.accountStorageKey)
        let diskSettings = try await store.loadSettings(for: acctKey)
        #expect(vm.committedSettings.appearanceMode == .dark)
        #expect(vm.committedSettings.playbackMode == .streamCache)
        #expect(diskSettings.appearanceMode == .dark)
        #expect(diskSettings.playbackMode == .streamCache)
        #expect(diskSettings.cacheLimitMb == 4096)
        #expect(diskSettings.downloadThreads == 14)

        // Issue 11: prepareLoopbackStream: false skips getFileDownloadUrl.action on iOS external video prompt
        await transport.clearDownloadUrlCount()
        let iosVideo = TrackSummary(id: "vid-ios-prompt", name: "ConcertIOS.mp4", folderPath: "Videos", sizeBytes: 4096)
        let iosDirect = await vm.requestExternalVideoPlayback(iosVideo, prepareLoopbackStream: false)
        #expect(iosDirect == nil)
        #expect(await transport.getDownloadUrlCount() == 0)
        #expect(vm.pendingExternalVideoChoice == PendingExternalVideoChoice(video: iosVideo, streamURL: nil))
        vm.pendingExternalVideoChoice = nil

        // Issue 10: Background audio track auto-advance (incrementing playbackGeneration) MUST NOT abort external video prep
        let gatedVideo = TrackSummary(id: "vid-gated", name: "Stage4K.mp4", folderPath: "Videos", sizeBytes: 8192)
        let extTask = Task { @MainActor in
            await vm.requestExternalVideoPlayback(gatedVideo, prepareLoopbackStream: true)
        }
        await transport.waitUntilEnteredVideoUrl()
        await vm.playTrack(TrackSummary(id: "bg-song-1", name: "AutoAdvance.flac", folderPath: "Music", sizeBytes: 1024))
        await transport.releaseVideoUrl()
        _ = await extTask.value
        #expect(vm.pendingExternalVideoChoice?.video.id == "vid-gated")

        // Issue 10b: downloadVideoAndPrepareLocalFile MUST ALSO stay active across background audio playTrack (incrementing playbackGeneration)
        await transport.resetVideoGate()
        let dlGatedVideo = TrackSummary(
            id: "vid-dl-gated",
            name: "GatedShow.mp4",
            folderPath: "Videos",
            sizeBytes: UInt64(videoFixtureBytes.count)
        )
        let dlVideoTask = Task { @MainActor in
            await vm.downloadVideoAndPrepareLocalFile(dlGatedVideo)
        }
        await transport.waitUntilEnteredVideoUrl()
        await vm.playTrack(TrackSummary(id: "bg-song-2", name: "AutoAdvance2.flac", folderPath: "Music", sizeBytes: 64))
        #expect(vm.currentTrackId == "bg-song-2")
        await transport.releaseVideoUrl()
        _ = await dlVideoTask.value
        #expect(vm.statusMessage?.contains("模拟视频缓存源波动") == true)

        let dlCachedVideo = TrackSummary(
            id: "vid-dl-cached",
            name: "CachedShow.mp4",
            folderPath: "Videos",
            sizeBytes: UInt64(videoFixtureBytes.count)
        )
        let preparedLocalVideoURL = await vm.downloadVideoAndPrepareLocalFile(dlCachedVideo)
        #expect(preparedLocalVideoURL == preseededVideoURL)
        #expect(vm.shareFileURL == preseededVideoURL)

        // Conversely, openVideoInApp MUST invalidate in-flight external video preparation
        vm.pendingExternalVideoChoice = nil
        await transport.resetVideoGate()
        let cancelledByInAppTask = Task { @MainActor in
            await vm.requestExternalVideoPlayback(gatedVideo, prepareLoopbackStream: true)
        }
        await transport.waitUntilEnteredVideoUrl()
        let inAppTask = Task { @MainActor in
            await vm.openVideoInApp(TrackSummary(id: "vid-inapp", name: "InApp.mp4", folderPath: "Videos", sizeBytes: 64))
        }
        await transport.releaseVideoUrl()
        _ = await cancelledByInAppTask.value
        await inAppTask.value
        #expect(vm.pendingExternalVideoChoice == nil)
        #expect(vm.activeVideoTrack?.id == "vid-inapp")

        // Issue 5: Write-through callback updates cacheUsageBytes & metadata for active track,
        // and rejects stale track/generation
        let songA = TrackSummary(id: "wt-song-a", name: "SongA.flac", folderPath: "AlbumA", sizeBytes: 64)
        let songB = TrackSummary(id: "wt-song-b", name: "SongB.flac", folderPath: "AlbumB", sizeBytes: 64)
        await vm.playTrack(songA)
        #expect(vm.currentTrackId == "wt-song-a")
        vm.cacheUsageBytes = 0
        let cachedFileForProbe = try #require(preparedLocalVideoURL)
        await vm.handleWriteThroughCompleted(
            accountHash: Cloud189Protocol.accountBucketHash(for: acctKey),
            trackId: songA.id,
            localFileURL: cachedFileForProbe
        )
        #expect(vm.cacheUsageBytes >= UInt64(videoFixtureBytes.count))
        #expect(vm.nowPlayingMetadata?.title == "SongA.flac")

        await vm.playTrack(songB)
        #expect(vm.currentTrackId == "wt-song-b")
        await vm.handleWriteThroughCompleted(
            accountHash: Cloud189Protocol.accountBucketHash(for: acctKey),
            trackId: songA.id,
            localFileURL: cachedFileForProbe
        )
        #expect(vm.nowPlayingMetadata?.title == "SongB.flac")

        // Issue 12 & 13: togglePlayback() when currentTrack == nil consumes upNextQueue first; playFromUpcomingQueue removes manual item
        vm.activeTrack = nil
        vm.currentTrackId = nil
        let lib1 = TrackSummary(id: "lib-1", name: "Lib1.flac", folderPath: "Music", sizeBytes: 64)
        let lib2 = TrackSummary(id: "lib-2", name: "Lib2.flac", folderPath: "Music", sizeBytes: 64)
        let queuedCloud = TrackSummary(id: "queued-cloud", name: "QueuedCloud.flac", folderPath: "Cloud", sizeBytes: 64)
        let manualSecond = TrackSummary(id: "manual-2", name: "Manual2.flac", folderPath: "Cloud", sizeBytes: 64)
        vm.tracks = [lib1, lib2]
        vm.shuffle = false
        vm.loopMode = .off
        vm.playNext(manualSecond)
        vm.playNext(queuedCloud)
        #expect(vm.upNextQueue.map(\.id) == ["queued-cloud", "manual-2"])

        await vm.togglePlayback()
        #expect(vm.currentTrack?.id == "queued-cloud")
        #expect(vm.upNextQueue.map(\.id) == ["manual-2"])

        await vm.playFromUpcomingQueue(manualSecond)
        #expect(vm.currentTrack?.id == "manual-2")
        #expect(vm.upNextQueue.isEmpty)
        await vm.playAdjacent(direction: 1)
        #expect(vm.currentTrack?.id == "lib-1")

        // Auth generation guard: completeEmbeddedWebLogin suspended across logout() MUST NOT resurrect session
        await vm.logout()
        await transport.enableAuthGate()
        let racingLoginTask = Task { @MainActor in
            await vm.completeEmbeddedWebLogin(
                callbackURL: URL(string: "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=aborted")!,
                cookies: []
            )
        }
        await transport.waitUntilEnteredAuth()
        await vm.logout()
        await transport.releaseAuth()
        await racingLoginTask.value
        #expect(vm.isAuthenticated == false)
        #expect(vm.accountStorageKey == nil)
    }

    @Test("QRCodeGenerator maintains high-contrast dark-on-light substrate")
    func verifyQRCodeRendering() throws {
        let png = try #require(QRCodeGenerator.generatePNGData(content: "https://open.e.189.cn/qr/test", dimension: 320))
        let metrics = try SnapshotRenderer.analyzePNGData(png)
        #expect(metrics.width >= 300)
        #expect(metrics.meanLuminance > 0.45)
        #expect(metrics.highContrastPixelCount > 400)
    }

    #if os(macOS)
    @Test("macOS full-state Light & Dark offscreen PNG rendering and glyph pixel contrast")
    @MainActor
    func verifyMacOSLightAndDarkSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["CLOUDTUNE_RENDER_SNAPSHOTS"] == "1" else {
            return
        }
        let root = repoRootURL()
        let fixture = try RepresentativeFixture.load(from: root.appendingPathComponent("contracts/representative-state.json"))
        let outRoot = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDTUNE_SNAPSHOT_DIR"]
                ?? root.appendingPathComponent("dist/snapshots/macos").path
        )
        try FileManager.default.createDirectory(at: outRoot.appendingPathComponent("light"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outRoot.appendingPathComponent("dark"), withIntermediateDirectories: true)

        #expect(SnapshotScene.allCases.count == 9)

        for scene in SnapshotScene.allCases {
            let lightPNG = try SnapshotRenderer.renderMacScenePNG(scene: scene, fixture: fixture, isDark: false)
            let darkPNG = try SnapshotRenderer.renderMacScenePNG(scene: scene, fixture: fixture, isDark: true)

            try lightPNG.write(to: outRoot.appendingPathComponent("light/\(scene.rawValue).png"), options: .atomic)
            try darkPNG.write(to: outRoot.appendingPathComponent("dark/\(scene.rawValue).png"), options: .atomic)

            let lightMetrics = try SnapshotRenderer.analyzePNGData(lightPNG)
            let darkMetrics = try SnapshotRenderer.analyzePNGData(darkPNG)

            #expect(lightMetrics.isNonBlankAndLegible, "Light snapshot \(scene.rawValue) failed pixel contrast check")
            #expect(darkMetrics.isNonBlankAndLegible, "Dark snapshot \(scene.rawValue) failed pixel contrast check")
            #expect(lightMetrics.meanLuminance > 0.65, "Light snapshot \(scene.rawValue) should have warm light luminance")
            #expect(darkMetrics.meanLuminance < 0.35, "Dark snapshot \(scene.rawValue) should have pine-night dark luminance")
        }
    }
    #endif
}
