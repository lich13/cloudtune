import AVFoundation
import CloudTuneCore
import Foundation
import Observation

@MainActor
@Observable
public final class CloudTuneViewModel {
    public var appearancePreference: AppAppearancePreference = .system
    public var activeModule: ModuleTab = .music

    public var isBootstrapping: Bool = false
    public var busyLabel: String?
    public var statusMessage: String?
    public var credentialIssue: CredentialIssue?

    public var isAuthenticated: Bool = false
    public var accountName: String?

    // Strictly separated committed vs draft settings
    public private(set) var committedSettings: AccountSettings = AccountSettings()
    public var cacheLimitDraft: String = "1024"
    public var downloadThreadsDraft: String = "8"
    public var cacheThreadsDraft: String = "4"
    public var settingsValidationError: String?

    public var cacheUsageBytes: UInt64 = 0

    // Login state
    public var qrContent: String?
    public var qrPNGData: Data?
    public var qrHint: String?
    public var isShowingWebLoginSheet: Bool = false

    // Cloud browser & library
    public var breadcrumbs: [BreadcrumbItem] = [.root]
    public var browser: FolderBrowsePayload?
    public var tracks: [TrackSummary] = []
    public var searchQuery: String = ""

    // Playback state
    public var currentTrackId: String?
    public var nowPlayingMetadata: NowPlayingMetadata?
    public var isPlaying: Bool = false
    public var loadingTrackId: String?
    public var shuffle: Bool = true
    public var loopMode: LoopMode = .all
    public var currentTime: Double = 0
    public var duration: Double = 0

    // Video sheet / handoff state
    public var activeVideoURL: URL?
    public var activeVideoTrack: TrackSummary?
    public var shareFileURL: URL?

    // Transfers
    public var transferSnapshot: TransferSnapshotPayload = TransferSnapshotPayload()

    // Runtime collaborators
    public let cloudClient: Cloud189Client
    public let accountStore: AccountScopedStore
    public let semaphore: GlobalTransferSemaphore
    public let streamServer: StreamProxyServer?
    public let transferEngine: TransferEngine
    private let keychainBackend: KeychainBackend
    private var credentialMachine = CredentialStateMachine()
    private var cacheStore: CacheStore?
    private let nowPlayingCoordinator = NowPlayingCoordinator()

    @ObservationIgnored private var _player: AVPlayer?
    public var player: AVPlayer {
        if let existing = _player {
            return existing
        }
        let created = AVPlayer()
        _player = created
        return created
    }
    @ObservationIgnored private var timeObserverToken: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failObserver: NSObjectProtocol?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    private var qrPollTask: Task<Void, Never>?
    private var transferPollTask: Task<Void, Never>?
    private var prefetchedTrackId: String?
    private var prefetchingTrackId: String?
    private var plannedShuffleNextTrackId: String?
    private var playbackGeneration: Int = 0
    private var recoveryAttempts: Int = 0
    private var currentPlaybackIsLoopback: Bool = false

    public init(
        cloudClient: Cloud189Client = Cloud189Client(),
        accountStore: AccountScopedStore? = nil,
        keychainBackend: KeychainBackend = SystemKeychainBackend(),
        semaphore: GlobalTransferSemaphore = GlobalTransferSemaphore(maxPermits: 8),
        enableLiveObservers: Bool = true
    ) {
        self.cloudClient = cloudClient
        let store = (try? accountStore ?? AccountScopedStore()) ?? (try! AccountScopedStore(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("cloudtune-fallback")))
        self.accountStore = store
        self.keychainBackend = keychainBackend
        self.semaphore = semaphore
        let engine = TransferEngine(semaphore: semaphore) { [cloudClient] trackId in
            try await cloudClient.resolveDownloadURL(fileId: trackId)
        }
        self.transferEngine = engine
        if enableLiveObservers {
            self.streamServer = try? StreamProxyServer(
                semaphore: semaphore,
                onStreamStatusUpdate: { id, status in
                    await engine.updateExternalTransferStatus(id: id, status: status)
                },
                urlRefresher: { [cloudClient] trackId in
                    try await cloudClient.resolveDownloadURL(fileId: trackId)
                }
            )
        } else {
            self.streamServer = nil
        }
        syncDraftsFromCommitted()
        if enableLiveObservers {
            setupPlayerAndRemoteCommands()
        }
    }

    public static func fixture(scene: SnapshotScene, fixture: RepresentativeFixture) -> CloudTuneViewModel {
        let isolatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudtune-fixture-\(UUID().uuidString)", isDirectory: true)
        let isolatedStore = try? AccountScopedStore(rootDirectory: isolatedRoot)
        let vm = CloudTuneViewModel(accountStore: isolatedStore, enableLiveObservers: false)
        let committed = AccountSettings(
            musicFolder: fixture.currentFolder,
            cacheLimitMb: fixture.settings.cacheLimitMb,
            downloadThreads: fixture.settings.downloadThreads,
            cacheThreads: fixture.settings.cacheThreads,
            playbackMode: fixture.settings.playbackMode,
            exportFolderDisplayName: "Downloads"
        )
        vm.committedSettings = committed
        vm.syncDraftsFromCommitted()

        switch scene {
        case .authIdle:
            vm.isAuthenticated = false
            vm.accountName = nil
            vm.cacheUsageBytes = 0
        case .authQr:
            vm.isAuthenticated = false
            vm.accountName = nil
            vm.cacheUsageBytes = 0
            vm.qrContent = fixture.qrLogin.qrContent
            vm.qrHint = fixture.qrLogin.message
            vm.statusMessage = fixture.qrLogin.message
            vm.qrPNGData = QRCodeGenerator.generatePNGData(content: fixture.qrLogin.qrContent, dimension: 480)
        case .music, .video, .download, .errorBanner:
            vm.isAuthenticated = true
            vm.accountName = fixture.accountName
            vm.cacheUsageBytes = fixture.settings.cacheUsageBytes
            vm.breadcrumbs = fixture.breadcrumbs
            vm.browser = fixture.browser
            vm.tracks = fixture.libraryTracks
            vm.currentTrackId = fixture.nowPlaying.trackId
            vm.nowPlayingMetadata = NowPlayingMetadata(
                title: fixture.nowPlaying.title,
                artist: fixture.nowPlaying.artist,
                album: fixture.nowPlaying.album
            )
            vm.isPlaying = fixture.nowPlaying.isPlaying
            vm.currentTime = fixture.nowPlaying.currentTimeSeconds
            vm.duration = fixture.nowPlaying.durationSeconds
            vm.shuffle = fixture.nowPlaying.shuffle
            vm.loopMode = fixture.nowPlaying.loopMode
            vm.transferSnapshot = fixture.transferSnapshot
            vm.statusMessage = (scene == .errorBanner) ? fixture.errorBanner.statusMessage : fixture.nowPlaying.statusMessage
            switch scene {
            case .video: vm.activeModule = .video
            case .download: vm.activeModule = .download
            default: vm.activeModule = .music
            }
        }
        return vm
    }

    public var visibleTracks: [TrackSummary] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return tracks }
        return tracks.filter {
            $0.name.lowercased().contains(trimmed) || $0.folderPath.lowercased().contains(trimmed)
        }
    }

    public var currentTrack: TrackSummary? {
        guard let currentTrackId else { return nil }
        return tracks.first { $0.id == currentTrackId }
            ?? browser?.audioFiles.first { $0.id == currentTrackId }
    }

    public var downloadTransfers: [TransferStatus] {
        transferSnapshot.items.filter { $0.kind == "download" }
    }

    public var downloadableBrowserFiles: [TrackSummary] {
        guard let browser else { return [] }
        return browser.audioFiles + browser.videoFiles + browser.otherFiles
    }

    public var qrHost: String? {
        guard let qrContent, let url = URL(string: qrContent) else { return nil }
        return url.host
    }

    // MARK: - Settings Draft Safety

    public func syncDraftsFromCommitted() {
        cacheLimitDraft = String(committedSettings.cacheLimitMb)
        downloadThreadsDraft = String(committedSettings.downloadThreads)
        cacheThreadsDraft = String(committedSettings.cacheThreads)
        settingsValidationError = nil
    }

    public func noteDraftEdited() {
        settingsValidationError = nil
    }

    @discardableResult
    public func commitCacheLimitDraft() async -> Bool {
        guard let parsed = UInt64(cacheLimitDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed >= AccountSettings.minCacheLimitMB else {
            let msg = "缓存上限至少设为 256 MB。"
            settingsValidationError = msg
            statusMessage = msg
            return false
        }
        var next = committedSettings
        next.cacheLimitMb = parsed
        await persistCommittedSettings(next, successMessage: "缓存限制已更新")
        if let cacheStore {
            cacheUsageBytes = (try? await cacheStore.pruneToLimit(limitBytes: next.cacheLimitBytes)) ?? cacheUsageBytes
        }
        return true
    }

    @discardableResult
    public func commitTransferThreadsDraft() async -> Bool {
        guard let dl = Int(downloadThreadsDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...AccountSettings.maxDownloadThreads).contains(dl) else {
            let msg = "下载线程范围是 1-\(AccountSettings.maxDownloadThreads)"
            settingsValidationError = msg
            statusMessage = msg
            return false
        }
        guard let ct = Int(cacheThreadsDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...AccountSettings.maxCacheThreads).contains(ct) else {
            let msg = "缓存线程范围是 1-\(AccountSettings.maxCacheThreads)"
            settingsValidationError = msg
            statusMessage = msg
            return false
        }
        var next = committedSettings
        next.downloadThreads = dl
        next.cacheThreads = ct
        await persistCommittedSettings(next, successMessage: "传输参数已更新")
        return true
    }

    public func updatePlaybackMode(_ mode: PlaybackMode) async {
        var next = committedSettings
        next.playbackMode = mode
        committedSettings = next
        if let accountId = activeAccountKey {
            try? await accountStore.saveSettings(next, for: accountId)
        }
        statusMessage = mode == .downloadFirst ? "已切到优先缓存播放" : "已切到边播边缓存"
    }

    private func persistCommittedSettings(_ next: AccountSettings, successMessage: String) async {
        committedSettings = next
        syncDraftsFromCommitted()
        if let accountId = activeAccountKey {
            try? await accountStore.saveSettings(next, for: accountId)
        }
        statusMessage = successMessage
    }

    private var activeAccountKey: String? {
        guard let trimmed = accountName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: - Bootstrap & Auth

    public func bootstrap(userInitiatedKeychainRetry: Bool = false) async {
        isBootstrapping = true
        busyLabel = "同步本地配置..."
        defer {
            busyLabel = nil
            isBootstrapping = false
        }

        if let migrated = await accountStore.migrateLegacyTauriDataIfPresent() {
            try? credentialMachine.save(migrated, backend: keychainBackend)
        }

        let (storedCred, issue) = credentialMachine.load(
            isInteractiveGUI: true,
            userInitiatedRetry: userInitiatedKeychainRetry,
            backend: keychainBackend
        )
        credentialIssue = issue
        if let issue {
            statusMessage = issue.userMessage
            return
        }
        guard let storedCred else {
            isAuthenticated = false
            return
        }

        do {
            let sessionPayload = try await cloudClient.restoreFromRefreshCredential(storedCred)
            if let refreshedCred = sessionPayload.persistedCredential {
                try? credentialMachine.save(refreshedCred, backend: keychainBackend)
            }
            await activateAuthenticatedAccount(
                accountName: sessionPayload.activeSession.loginName ?? storedCred.accountName ?? "天翼云盘用户"
            )
            await browseTo(folderId: nil, nextBreadcrumbs: [.root], showBusy: false)
        } catch {
            isAuthenticated = false
            statusMessage = error.localizedDescription
        }
    }

    public func beginQrLogin() async {
        qrPollTask?.cancel()
        busyLabel = "生成二维码..."
        defer { busyLabel = nil }
        do {
            let start = try await cloudClient.startQrLogin()
            qrContent = start.qrContent
            qrHint = start.message
            statusMessage = start.message
            qrPNGData = QRCodeGenerator.generatePNGData(content: start.qrContent, dimension: 512)
            startQrPolling()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func startQrPolling() {
        qrPollTask?.cancel()
        qrPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2500))
                guard !Task.isCancelled, let self else { break }
                do {
                    let poll = try await self.cloudClient.pollQrLogin()
                    self.qrHint = poll.message
                    self.statusMessage = poll.message
                    switch poll.state {
                    case .authenticated:
                        if let persisted = await self.cloudClient.persistedCredential {
                            try? self.credentialMachine.save(persisted, backend: self.keychainBackend)
                        }
                        let clientName = await self.cloudClient.accountName
                        let resolvedName = poll.accountName ?? clientName ?? "天翼云盘用户"
                        self.qrContent = nil
                        self.qrPNGData = nil
                        await self.activateAuthenticatedAccount(accountName: resolvedName)
                        await self.browseTo(folderId: nil, nextBreadcrumbs: [.root], showBusy: false)
                        return
                    case .expired:
                        self.qrContent = nil
                        self.qrPNGData = nil
                        return
                    case .waitingScan, .waitingConfirm:
                        continue
                    }
                } catch {
                    self.statusMessage = error.localizedDescription
                    return
                }
            }
        }
    }

    public func completeEmbeddedWebLogin(callbackURL: URL, cookies: [HTTPCookie]) async {
        busyLabel = "正在验证天翼登录会话..."
        defer { busyLabel = nil }
        do {
            await cloudClient.importWebCookies(cookies)
            let parsed = try await cloudClient.exchangeRedirectForSession(redirectURL: callbackURL.absoluteString)
            if let persisted = parsed.persistedCredential {
                try? credentialMachine.save(persisted, backend: keychainBackend)
            }
            isShowingWebLoginSheet = false
            qrPollTask?.cancel()
            qrContent = nil
            qrPNGData = nil
            let name = parsed.activeSession.loginName ?? "天翼云盘用户"
            await activateAuthenticatedAccount(accountName: name)
            await browseTo(folderId: nil, nextBreadcrumbs: [.root], showBusy: false)
            statusMessage = "天翼官方网页登录成功"
        } catch {
            isShowingWebLoginSheet = false
            statusMessage = "网页登录回调兑换失败（\(error.localizedDescription)），已为您切换至二维码扫码登录，可保存二维码到相册后用天翼云盘 App 识别。"
            await beginQrLogin()
        }
    }

    private func activateAuthenticatedAccount(accountName: String) async {
        self.isAuthenticated = true
        self.accountName = accountName
        self.credentialIssue = nil

        if let paths = try? await accountStore.paths(for: accountName) {
            let store = try? CacheStore(cacheDirectory: paths.cacheDir, indexURL: paths.cacheIndexURL)
            self.cacheStore = store
            self.cacheUsageBytes = await store?.usageBytes() ?? 0
        }
        if let savedSettings = try? await accountStore.loadSettings(for: accountName) {
            self.committedSettings = savedSettings
            syncDraftsFromCommitted()
        }
        if let savedTracks = try? await accountStore.loadLibrary(for: accountName) {
            self.tracks = savedTracks
        }
        await transferEngine.restorePersistedDownloads(for: accountName, accountStore: accountStore)
        transferSnapshot = await transferEngine.snapshot()
        startTransferPolling()
    }

    public func logout() async {
        qrPollTask?.cancel()
        transferPollTask?.cancel()
        playbackGeneration += 1
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        _player?.pause()
        _player?.replaceCurrentItem(with: nil)
        nowPlayingCoordinator.updateNowPlaying(metadata: nil, isPlaying: false, elapsedSeconds: 0, durationSeconds: 0)

        if let accountId = activeAccountKey {
            let hash = Cloud189Protocol.accountBucketHash(for: accountId)
            await streamServer?.revokeAllSources(forAccountHash: hash)
            await transferEngine.cancelAll(forAccountId: accountId)
        }
        await cloudClient.clearSession()
        credentialMachine.clear(backend: keychainBackend)

        isAuthenticated = false
        accountName = nil
        cacheStore = nil
        cacheUsageBytes = 0
        browser = nil
        tracks = []
        breadcrumbs = [.root]
        currentTrackId = nil
        nowPlayingMetadata = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        transferSnapshot = TransferSnapshotPayload()
        committedSettings = AccountSettings()
        syncDraftsFromCommitted()
        statusMessage = "已退出登录并清理当前会话"
    }

    // MARK: - Cloud Folder & Library

    public func browseTo(folderId: String?, nextBreadcrumbs: [BreadcrumbItem], showBusy: Bool = true) async {
        guard isAuthenticated else { return }
        if showBusy { busyLabel = "读取云盘目录..." }
        defer { if showBusy { busyLabel = nil } }
        do {
            let listing = try await cloudClient.listRemoteFolder(folderId: folderId)
            browser = listing
            breadcrumbs = nextBreadcrumbs
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func setCurrentFolderAsMusicLibrary() async {
        guard let browser, let lastCrumb = breadcrumbs.last, let accountId = activeAccountKey else { return }
        busyLabel = "保存 \(lastCrumb.name) 为音乐目录..."
        defer { busyLabel = nil }
        var next = committedSettings
        next.musicFolder = FolderSelection(id: browser.currentFolderId, name: lastCrumb.name)
        committedSettings = next
        try? await accountStore.saveSettings(next, for: accountId)
        statusMessage = "音乐目录已设置为 \(lastCrumb.name)"
        await scanMusicLibrary(showBusy: false)
    }

    public func scanMusicLibrary(showBusy: Bool = true) async {
        guard let folder = committedSettings.musicFolder, let accountId = activeAccountKey else {
            statusMessage = "请先在目录中设为音乐库。"
            return
        }
        if showBusy { busyLabel = "扫描 \(folder.name) 中的音乐..." }
        defer { if showBusy { busyLabel = nil } }
        do {
            let scanned = try await cloudClient.scanMusicLibrary(folderId: folder.id, folderName: folder.name)
            tracks = scanned
            try? await accountStore.saveLibrary(scanned, for: accountId)
            statusMessage = "已载入 \(scanned.count) 首音乐"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Playback & Prefetch

    public func playTrack(
        _ track: TrackSummary,
        modeOverride: PlaybackMode? = nil,
        forceStreamProxy: Bool = false,
        resumeTime: Double = 0
    ) async {
        guard let accountId = activeAccountKey, let cacheStore else { return }
        playbackGeneration += 1
        let gen = playbackGeneration
        loadingTrackId = track.id
        prefetchedTrackId = nil
        prefetchingTrackId = nil
        plannedShuffleNextTrackId = nil
        if modeOverride == nil && !forceStreamProxy && resumeTime == 0 {
            recoveryAttempts = 0
        }
        defer {
            if gen == playbackGeneration { loadingTrackId = nil }
        }

        let effectiveMode = modeOverride ?? committedSettings.playbackMode
        let accountHash = Cloud189Protocol.accountBucketHash(for: accountId)

        do {
            await cacheStore.setProtectedTrackIDs([track.id])
            if let cachedURL = await cacheStore.existingCachedFile(trackId: track.id) {
                cacheUsageBytes = await cacheStore.usageBytes()
                try await startAVPlayer(
                    track: track,
                    url: cachedURL,
                    localFileURL: cachedURL,
                    isLoopback: false,
                    resumeTime: resumeTime,
                    generation: gen
                )
                return
            }

            let downloadFirst = PlaybackDecisionPolicy.shouldDownloadBeforePlayback(
                mode: effectiveMode,
                sizeBytes: track.sizeBytes,
                forceStreamProxy: forceStreamProxy
            )

            if downloadFirst {
                let downloadedURL = try await transferEngine.downloadTrackToCache(
                    track: track,
                    cacheStore: cacheStore,
                    parallelThreads: committedSettings.downloadThreads,
                    cacheLimitBytes: committedSettings.cacheLimitBytes,
                    kind: "playback"
                )
                guard gen == playbackGeneration else { return }
                cacheUsageBytes = await cacheStore.usageBytes()
                try await startAVPlayer(
                    track: track,
                    url: downloadedURL,
                    localFileURL: downloadedURL,
                    isLoopback: false,
                    resumeTime: resumeTime,
                    generation: gen
                )
            } else {
                let remoteURL = try await cloudClient.resolveDownloadURL(fileId: track.id)
                guard gen == playbackGeneration else { return }
                let destURL = await cacheStore.cacheFileURL(trackId: track.id, originalFileName: track.name)
                let playbackURL: URL
                if let streamServer {
                    playbackURL = await streamServer.registerSource(
                        StreamSourceRegistration(
                            accountHash: accountHash,
                            trackId: track.id,
                            remoteURL: remoteURL,
                            cacheDestinationURL: destURL,
                            expectedSize: track.sizeBytes,
                            fileName: track.name,
                            cacheLimitBytes: committedSettings.cacheLimitBytes
                        ),
                        cacheStore: cacheStore
                    )
                } else {
                    playbackURL = remoteURL
                }
                try await startAVPlayer(
                    track: track,
                    url: playbackURL,
                    localFileURL: destURL,
                    isLoopback: true,
                    resumeTime: resumeTime,
                    generation: gen
                )
            }
        } catch {
            guard gen == playbackGeneration else { return }
            await handlePlaybackPreparationFailure(
                track: track,
                error: error,
                wasLoopback: false,
                resumeTime: resumeTime
            )
        }
    }

    private func startAVPlayer(
        track: TrackSummary,
        url: URL,
        localFileURL: URL,
        isLoopback: Bool,
        resumeTime: Double,
        generation: Int
    ) async throws {
        nowPlayingCoordinator.configureAudioSessionIfNeeded()
        currentPlaybackIsLoopback = isLoopback
        currentTrackId = track.id

        let item = AVPlayerItem(url: url)
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            let currentStatus = observedItem.status
            let itemError = observedItem.error
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.playbackGeneration,
                      observedItem === self._player?.currentItem else { return }
                switch currentStatus {
                case .readyToPlay:
                    self.recoveryAttempts = 0
                case .failed:
                    self.itemStatusObservation?.invalidate()
                    self.itemStatusObservation = nil
                    let err = itemError ?? CloudTuneError.unsupportedLocalMediaFormat("系统解码器无法播放该音频格式")
                    await self.handlePlaybackPreparationFailure(
                        track: track,
                        error: err,
                        wasLoopback: isLoopback,
                        resumeTime: self.currentTime
                    )
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        if resumeTime > 0 {
            await player.seek(to: CMTime(seconds: resumeTime, preferredTimescale: 600))
        }
        player.play()
        isPlaying = true
        statusMessage = isLoopback ? "边播边缓存《\(track.name)》" : "正在播放《\(track.name)》"

        let fallbackAlbum = track.folderPath.isEmpty ? (committedSettings.musicFolder?.name ?? "天翼云盘") : track.folderPath
        let meta = await AudioMetadataReader.readMetadata(from: localFileURL, fallbackTitle: track.name, fallbackAlbum: fallbackAlbum)
        guard generation == playbackGeneration else { return }
        nowPlayingMetadata = meta
        nowPlayingCoordinator.updateNowPlaying(
            metadata: meta,
            isPlaying: true,
            elapsedSeconds: resumeTime,
            durationSeconds: duration
        )
    }

    public func handlePlaybackPreparationFailure(
        track: TrackSummary,
        error: Error,
        wasLoopback: Bool,
        resumeTime: Double
    ) async {
        let nsError = error as NSError
        let lower = error.localizedDescription.lowercased()
        let lowerName = track.name.lowercased()
        let isURLTimeout = nsError.domain == NSURLErrorDomain && [
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotConnectToHost
        ].contains(nsError.code)
        let isTimeout = isURLTimeout || lower.contains("timed out") || lower.contains("timeout") || lower.contains("网络连接")

        let isAVDecodeError = (nsError.domain == AVFoundationErrorDomain && [
            AVError.fileFormatNotRecognized.rawValue,
            AVError.decoderNotFound.rawValue,
            AVError.decoderTemporarilyUnavailable.rawValue,
            AVError.failedToParse.rawValue,
            AVError.contentIsUnavailable.rawValue
        ].contains(nsError.code)) || [-12847, -12848, -11828, -11829].contains(nsError.code)
        let isUnsupportedExt = lowerName.hasSuffix(".ape") || lowerName.hasSuffix(".wma")
        let isDecode: Bool
        if case .unsupportedLocalMediaFormat = error as? CloudTuneError {
            isDecode = true
        } else {
            isDecode = isAVDecodeError
                || (!isTimeout && isUnsupportedExt)
                || lower.contains("decode")
                || lower.contains("format")
                || lower.contains("不支持")
                || lower.contains("cannot open")
        }
        let action = PlaybackDecisionPolicy.classifyPlaybackFailure(
            fileName: track.name,
            wasLoopbackStream: wasLoopback,
            wasDownloadPhaseTimeout: isTimeout,
            isDecodeOrFormatUnsupported: isDecode,
            priorAttemptCount: recoveryAttempts
        )
        recoveryAttempts += 1
        switch action {
        case .fallbackToStreamProxyOnce:
            statusMessage = "《\(track.name)》优先缓存超时，改用流式代理直接起播"
            await playTrack(track, modeOverride: .streamCache, forceStreamProxy: true, resumeTime: resumeTime)
        case .fallbackToFullDownloadOnce:
            statusMessage = "流式容器受限，回退整曲下载《\(track.name)》"
            await playTrack(track, modeOverride: .downloadFirst, forceStreamProxy: false, resumeTime: resumeTime)
        case let .stopImmediatelyUnsupportedCodec(msg):
            isPlaying = false
            statusMessage = msg
        case .stopAfterMaxRetries:
            isPlaying = false
            statusMessage = "播放异常，已停止自动重试《\(track.name)》"
        case let .retryTransientAfterDelay(attempt):
            isPlaying = false
            statusMessage = "播放波动，正在重试《\(track.name)》(\(attempt)/\(PlaybackDecisionPolicy.maxRecoveryAttempts))"
            try? await Task.sleep(for: .milliseconds(1500 * attempt))
            await playTrack(track, resumeTime: resumeTime)
        }
    }

    public func togglePlayback() async {
        guard let currentTrack else {
            if let candidate = tracks.randomElement() ?? visibleTracks.first {
                await playTrack(candidate)
            }
            return
        }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if player.currentItem == nil {
                await playTrack(currentTrack)
                return
            }
            player.play()
            isPlaying = true
        }
        nowPlayingCoordinator.updateNowPlaying(
            metadata: nowPlayingMetadata,
            isPlaying: isPlaying,
            elapsedSeconds: currentTime,
            durationSeconds: duration
        )
    }

    public func playIfPaused() async {
        guard !isPlaying else { return }
        await togglePlayback()
    }

    public func pauseIfPlaying() {
        guard isPlaying else { return }
        _player?.pause()
        isPlaying = false
        nowPlayingCoordinator.updateNowPlaying(
            metadata: nowPlayingMetadata,
            isPlaying: false,
            elapsedSeconds: currentTime,
            durationSeconds: duration
        )
    }

    public func playAdjacent(direction: Int) async {
        guard !tracks.isEmpty else { return }
        if shuffle && tracks.count > 1 {
            if direction > 0,
               let preselectedId = prefetchedTrackId ?? plannedShuffleNextTrackId,
               preselectedId != currentTrackId,
               let preselected = tracks.first(where: { $0.id == preselectedId }) {
                await playTrack(preselected)
                return
            }
            let pool = tracks.filter { $0.id != currentTrackId }
            if let next = pool.randomElement() {
                await playTrack(next)
            }
            return
        }
        let idx = tracks.firstIndex { $0.id == currentTrackId } ?? -1
        let nextIdx = idx + direction
        if tracks.indices.contains(nextIdx) {
            await playTrack(tracks[nextIdx])
        } else if loopMode == .all {
            let wrapped = direction > 0 ? tracks.first : tracks.last
            if let wrapped { await playTrack(wrapped) }
        }
    }

    public func seekPlayback(to seconds: Double) async {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        currentTime = clamped
        await player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        nowPlayingCoordinator.updateNowPlaying(
            metadata: nowPlayingMetadata,
            isPlaying: isPlaying,
            elapsedSeconds: clamped,
            durationSeconds: duration
        )
    }

    // MARK: - Video & Downloads

    public func openVideoInApp(_ video: TrackSummary) async {
        pauseIfPlaying()
        busyLabel = "准备视频流 \(video.name)..."
        defer { busyLabel = nil }
        do {
            let url = try await cloudClient.resolveDownloadURL(fileId: video.id)
            activeVideoTrack = video
            activeVideoURL = url
            statusMessage = "正在应用内播放视频：\(video.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func prepareVideoForExternalApp(_ video: TrackSummary) async -> URL? {
        busyLabel = "准备外部播放源 \(video.name)..."
        defer { busyLabel = nil }
        if let cacheStore, let cached = await cacheStore.existingCachedFile(trackId: video.id) {
            shareFileURL = cached
            return cached
        }
        return try? await cloudClient.resolveDownloadURL(fileId: video.id)
    }

    public func enqueueTrackDownload(_ track: TrackSummary, explicitDirectoryURL: URL? = nil) async {
        guard let accountId = activeAccountKey else { return }
        do {
            let taskId = try await transferEngine.enqueueExportDownload(
                accountId: accountId,
                track: track,
                relativeExportSubpath: track.name,
                parallelThreads: committedSettings.downloadThreads,
                explicitDirectoryURL: explicitDirectoryURL,
                accountStore: accountStore
            )
            transferSnapshot = await transferEngine.snapshot()
            statusMessage = "已创建下载任务 \(taskId)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func enqueueCurrentFolderDownload(explicitDirectoryURL: URL? = nil) async {
        guard let browser, let accountId = activeAccountKey else { return }
        busyLabel = "扫描文件夹 \(browser.currentFolderName)..."
        defer { busyLabel = nil }
        do {
            let allFiles = try await cloudClient.scanAllFiles(
                folderId: browser.currentFolderId,
                folderName: browser.currentFolderName
            )
            for item in allFiles {
                let rel = item.folderPath.hasPrefix(browser.currentFolderName)
                    ? "\(item.folderPath)/\(item.name)"
                    : "\(browser.currentFolderName)/\(item.name)"
                _ = try await transferEngine.enqueueExportDownload(
                    accountId: accountId,
                    track: item,
                    relativeExportSubpath: rel,
                    parallelThreads: committedSettings.downloadThreads,
                    explicitDirectoryURL: explicitDirectoryURL,
                    accountStore: accountStore
                )
            }
            transferSnapshot = await transferEngine.snapshot()
            statusMessage = "目录下载已入队（共 \(allFiles.count) 个文件）"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func pauseTransfer(_ id: String) async {
        await transferEngine.pauseTransfer(id: id, accountStore: accountStore)
        transferSnapshot = await transferEngine.snapshot()
    }

    public func resumeTransfer(_ id: String) async {
        await transferEngine.resumeTransfer(id: id, accountStore: accountStore)
        transferSnapshot = await transferEngine.snapshot()
    }

    public func deleteTransfer(_ id: String) async {
        await transferEngine.deleteTransfer(id: id, accountStore: accountStore)
        transferSnapshot = await transferEngine.snapshot()
    }

    public func saveExportDirectoryBookmark(_ url: URL) async {
        guard let accountId = activeAccountKey else { return }
        do {
            let name = try await accountStore.saveExportDirectoryBookmark(url, for: accountId)
            var next = committedSettings
            next.exportFolderDisplayName = name
            committedSettings = next
            statusMessage = "下载导出目录已设为 \(name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Observers

    private func startTransferPolling() {
        transferPollTask?.cancel()
        transferPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, let self else { break }
                self.transferSnapshot = await self.transferEngine.snapshot()
                if let store = self.cacheStore {
                    self.cacheUsageBytes = await store.usageBytes()
                }
            }
        }
    }

    private func setupPlayerAndRemoteCommands() {
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] cmTime in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let secs = cmTime.seconds
                if secs.isFinite && secs >= 0 {
                    self.currentTime = secs
                }
                if let itemDur = self.player.currentItem?.duration.seconds, itemDur.isFinite, itemDur > 0 {
                    self.duration = itemDur
                }
                self.nowPlayingCoordinator.updateNowPlaying(
                    metadata: self.nowPlayingMetadata,
                    isPlaying: self.isPlaying,
                    elapsedSeconds: self.currentTime,
                    durationSeconds: self.duration
                )
                await self.maybePrefetchUpcomingTrack()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let itemObj = note.object as? AVPlayerItem
            Task { @MainActor [weak self] in
                guard let self, itemObj === self.player.currentItem else { return }
                if self.loopMode == .one, let current = self.currentTrack {
                    await self.playTrack(current)
                } else {
                    await self.playAdjacent(direction: 1)
                }
            }
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let itemObj = note.object as? AVPlayerItem
            let err = itemObj?.error ?? CloudTuneError.protocolError("系统解码器无法播放该音频格式")
            Task { @MainActor [weak self] in
                guard let self, itemObj === self._player?.currentItem, let track = self.currentTrack else { return }
                await self.handlePlaybackPreparationFailure(
                    track: track,
                    error: err,
                    wasLoopback: self.currentPlaybackIsLoopback,
                    resumeTime: self.currentTime
                )
            }
        }

        nowPlayingCoordinator.registerRemoteCommands(RemoteCommandCallbacks(
            onPlay: { [weak self] in Task { @MainActor in await self?.playIfPaused() } },
            onPause: { [weak self] in Task { @MainActor in self?.pauseIfPlaying() } },
            onTogglePlayPause: { [weak self] in Task { @MainActor in await self?.togglePlayback() } },
            onNextTrack: { [weak self] in Task { @MainActor in await self?.playAdjacent(direction: 1) } },
            onPreviousTrack: { [weak self] in Task { @MainActor in await self?.playAdjacent(direction: -1) } },
            onSeekDelta: { [weak self] delta in
                Task { @MainActor in
                    guard let self else { return }
                    await self.seekPlayback(to: self.currentTime + delta)
                }
            },
            onSeekToPosition: { [weak self] pos in
                Task { @MainActor in await self?.seekPlayback(to: pos) }
            }
        ))
    }

    private func maybePrefetchUpcomingTrack() async {
        guard isAuthenticated, loopMode != .one, let cacheStore, currentTrack != nil else { return }
        let remaining = duration - currentTime
        let shouldPrefetch = (committedSettings.playbackMode == .downloadFirst)
            || (remaining.isFinite && remaining > 0 && remaining <= 30)
        guard shouldPrefetch else { return }

        guard let next = pickPrefetchCandidate(),
              next.id != prefetchedTrackId,
              next.id != prefetchingTrackId else { return }

        prefetchingTrackId = next.id
        let activeId = currentTrackId ?? ""
        await cacheStore.setProtectedTrackIDs([activeId, next.id])
        Task { [weak self] in
            guard let self else { return }
            if (try? await self.transferEngine.downloadTrackToCache(
                track: next,
                cacheStore: cacheStore,
                parallelThreads: self.committedSettings.cacheThreads,
                cacheLimitBytes: self.committedSettings.cacheLimitBytes,
                kind: "prefetch"
            )) != nil {
                self.prefetchedTrackId = next.id
            }
            if self.prefetchingTrackId == next.id {
                self.prefetchingTrackId = nil
            }
        }
    }

    private func pickPrefetchCandidate() -> TrackSummary? {
        guard !tracks.isEmpty else { return nil }
        if shuffle {
            if let plannedId = plannedShuffleNextTrackId,
               plannedId != currentTrackId,
               let planned = tracks.first(where: { $0.id == plannedId }) {
                return planned
            }
            let candidate = tracks.filter { $0.id != currentTrackId }.randomElement() ?? tracks.first
            plannedShuffleNextTrackId = candidate?.id
            return candidate
        }
        guard let idx = tracks.firstIndex(where: { $0.id == currentTrackId }) else { return tracks.first }
        let next = idx + 1
        if tracks.indices.contains(next) { return tracks[next] }
        return loopMode == .all ? tracks.first : nil
    }
}
