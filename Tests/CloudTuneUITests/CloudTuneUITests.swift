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

            func setSessionIndex(_ idx: Int) { sessionIndex = idx }
            func setFailDownloadUrl(_ fail: Bool) {
                failDownloadUrlCalls = fail
                downloadUrlCallCount = 0
            }
            func getDownloadUrlCalls() -> Int { downloadUrlCallCount }

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
        let vm = CloudTuneViewModel(cloudClient: client, accountStore: store, enableLiveObservers: false)
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
        vm.retryBaseDelayMs = 80
        await transport.setFailDownloadUrl(true)
        let videoInterruptTask = Task { @MainActor in
            await vm.playTrack(smallTrack)
        }
        try await Task.sleep(for: .milliseconds(25))
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

        vm.retryBaseDelayMs = 80
        await transport.setFailDownloadUrl(true)
        let retryTask = Task { @MainActor in
            await vm.playTrack(smallTrack)
        }
        try await Task.sleep(for: .milliseconds(25))
        await vm.logout()
        await retryTask.value
        #expect(await transport.getDownloadUrlCalls() == 1)

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
        let vm = CloudTuneViewModel(
            cloudClient: Cloud189Client(transport: FolderMockTransport()),
            accountStore: store,
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
            userDefaults: isolatedDefaults,
            enableLiveObservers: false
        )
        noProxyVM.appearancePreference = .dark
        await noProxyVM.completeEmbeddedWebLogin(
            callbackURL: URL(string: "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=noproxy")!,
            cookies: []
        )
        // Fresh account without settings.json preserves pre-login appearancePreference (.dark)
        #expect(noProxyVM.appearancePreference == .dark)
        #expect(noProxyVM.committedSettings.appearanceMode == .dark)
        let noProxyDirect = await noProxyVM.requestExternalVideoPlayback(concertVideo)
        #expect(noProxyDirect == nil)
        let noProxyChoice = try #require(noProxyVM.pendingExternalVideoChoice)
        #expect(noProxyChoice.streamURL == nil)

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
