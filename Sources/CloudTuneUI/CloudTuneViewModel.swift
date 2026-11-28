import AVFoundation
import CloudTuneCore
import Foundation
import Observation

public enum BrowserScope: Sendable {
    case cloud
    case video
}

public struct BrowserPaneState: Equatable, Sendable {
    public var breadcrumbs: [BreadcrumbItem]
    public var payload: FolderBrowsePayload?

    public init(breadcrumbs: [BreadcrumbItem] = [.root], payload: FolderBrowsePayload? = nil) {
        self.breadcrumbs = breadcrumbs
        self.payload = payload
    }
}

public struct PendingExternalVideoChoice: Equatable, Identifiable, Sendable {
    public var id: String { video.id }
    public let video: TrackSummary
    public let streamURL: URL

    public init(video: TrackSummary, streamURL: URL) {
        self.video = video
        self.streamURL = streamURL
    }
}

private final class WriteThroughEventRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String, String, URL) async -> Void)?

    func bind(_ next: @escaping @Sendable (String, String, URL) async -> Void) {
        lock.withLock { handler = next }
    }

    func forward(accountHash: String, trackId: String, localURL: URL) async {
        let target = lock.withLock { handler }
        await target?(accountHash, trackId, localURL)
    }
}

@MainActor
@Observable
public final class CloudTuneViewModel {
    private static let appearanceDefaultsKey = "com.gosu.cloudtune.appearanceMode"
    private static let volumeDefaultsKey = "com.gosu.cloudtune.playerVolume"

    public var appearancePreference: AppearanceMode = .system {
        didSet {
            if persistPreferencesToDefaults {
                userDefaults.set(appearancePreference.rawValue, forKey: Self.appearanceDefaultsKey)
            }
        }
    }
    public var activeModule: ModuleTab = .music

    public var isBootstrapping: Bool = false
    public var busyLabel: String?
    public var statusMessage: String?
    public var credentialIssue: CredentialIssue?

    public var isAuthenticated: Bool = false
    public var accountName: String?
    public private(set) var accountStorageKey: String?

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

    // Decoupled Cloud & Video browsers + library
    public var cloudBrowser = BrowserPaneState()
    public var videoBrowser = BrowserPaneState()
    public var tracks: [TrackSummary] = [] {
        didSet {
            if shuffle {
                shuffleOrderIds = PlaybackQueueResolver.buildShuffleOrder(
                    tracks: tracks,
                    anchorTrackId: currentTrackId
                )
            }
            syncRemoteCommandAvailability()
        }
    }
    public var searchQuery: String = ""

    public var breadcrumbs: [BreadcrumbItem] {
        get { cloudBrowser.breadcrumbs }
        set { cloudBrowser.breadcrumbs = newValue }
    }

    public var browser: FolderBrowsePayload? {
        get { cloudBrowser.payload }
        set { cloudBrowser.payload = newValue }
    }

    // Playback & unified queue state
    public var activeTrack: TrackSummary? {
        didSet { syncRemoteCommandAvailability() }
    }
    public var currentTrackId: String? {
        didSet { syncRemoteCommandAvailability() }
    }
    public var nowPlayingMetadata: NowPlayingMetadata?
    public var isPlaying: Bool = false
    public var loadingTrackId: String?
    public var shuffle: Bool = true {
        didSet {
            if shuffle {
                shuffleOrderIds = PlaybackQueueResolver.buildShuffleOrder(
                    tracks: tracks,
                    anchorTrackId: currentTrackId
                )
            }
            syncRemoteCommandAvailability()
        }
    }
    public var loopMode: LoopMode = .all {
        didSet { syncRemoteCommandAvailability() }
    }
    public var currentTime: Double = 0
    public var duration: Double = 0
    public var volume: Double = 0.85 {
        didSet {
            let clamped = min(1.0, max(0.0, volume.isFinite ? volume : 0.85))
            if volume != clamped {
                volume = clamped
                return
            }
            _player?.volume = Float(clamped)
            if persistPreferencesToDefaults {
                userDefaults.set(clamped, forKey: Self.volumeDefaultsKey)
            }
        }
    }
    public var upNextQueue: [TrackSummary] = [] {
        didSet { syncRemoteCommandAvailability() }
    }
    public private(set) var shuffleOrderIds: [String] = []

    // Presentation state (shared across live app & offscreen snapshot scenes)
    public var isShowingNowPlayingSheet: Bool = false
    public var isShowingSettingsSheet: Bool = false
    public var isShowingQueuePopover: Bool = false

    // Video sheet / external handoff state
    public var activeVideoURL: URL?
    public var activeVideoTrack: TrackSummary?
    public var shareFileURL: URL?
    public var pendingExternalVideoChoice: PendingExternalVideoChoice?

    // Transfers
    public var transferSnapshot: TransferSnapshotPayload = TransferSnapshotPayload()

    // Runtime collaborators
    public let cloudClient: Cloud189Client
    public let accountStore: AccountScopedStore
    public let semaphore: GlobalTransferSemaphore
    public let streamServer: StreamProxyServer?
    public let transferEngine: TransferEngine
    public private(set) var hasActivePlayerObservers: Bool = false

    private let keychainBackend: KeychainBackend
    private let userDefaults: UserDefaults
    private let persistPreferencesToDefaults: Bool
    private let enableLiveObservers: Bool
    private var credentialMachine = CredentialStateMachine()
    private var cacheStore: CacheStore?
    private let nowPlayingCoordinator = NowPlayingCoordinator()

    @ObservationIgnored private var _player: AVPlayer?
    public var player: AVPlayer {
        if let existing = _player {
            return existing
        }
        let created = AVPlayer()
        created.volume = Float(volume)
        _player = created
        return created
    }
    @ObservationIgnored private var timeObserverToken: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failObserver: NSObjectProtocol?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    private var qrPollTask: Task<Void, Never>?
    private var transferRefreshTask: Task<Void, Never>?
    private var prefetchedTrackId: String?
    private var prefetchingTrackId: String?
    private var playbackGeneration: Int = 0
    private var recoveryAttempts: Int = 0
    private var currentPlaybackIsLoopback: Bool = false
    private var wasPlayingBeforeInterruption: Bool = false
    public var retryBaseDelayMs: Int = 1500

    public init(
        cloudClient: Cloud189Client = Cloud189Client(),
        accountStore: AccountScopedStore? = nil,
        keychainBackend: KeychainBackend = SystemKeychainBackend(),
        semaphore: GlobalTransferSemaphore = GlobalTransferSemaphore(maxPermits: 8),
        userDefaults: UserDefaults = .standard,
        enableLiveObservers: Bool = true
    ) {
        self.cloudClient = cloudClient
        let resolvedStore = AccountScopedStore.resolveOrFallback(accountStore)
        self.accountStore = resolvedStore.store
        self.keychainBackend = keychainBackend
        self.semaphore = semaphore
        self.userDefaults = userDefaults
        self.enableLiveObservers = enableLiveObservers
        self.persistPreferencesToDefaults = enableLiveObservers

        if enableLiveObservers {
            if let savedModeRaw = userDefaults.string(forKey: Self.appearanceDefaultsKey),
               let savedMode = AppearanceMode(rawValue: savedModeRaw) {
                self.appearancePreference = savedMode
            }
            if userDefaults.object(forKey: Self.volumeDefaultsKey) != nil {
                let savedVol = userDefaults.double(forKey: Self.volumeDefaultsKey)
                self.volume = min(1.0, max(0.0, savedVol))
            }
        }

        let engine = TransferEngine(semaphore: semaphore) { [cloudClient] trackId in
            try await cloudClient.resolveDownloadURL(fileId: trackId)
        }
        self.transferEngine = engine

        let writeThroughRelay = WriteThroughEventRelay()
        var startupWarning = resolvedStore.warning
        if enableLiveObservers {
            do {
                self.streamServer = try StreamProxyServer(
                    semaphore: semaphore,
                    onAccountStreamStatusUpdate: { id, accountHash, status in
                        await engine.updateExternalTransferStatus(id: id, accountHash: accountHash, status: status)
                    },
                    onWriteThroughCompleted: { accountHash, trackId, localURL in
                        await writeThroughRelay.forward(accountHash: accountHash, trackId: trackId, localURL: localURL)
                    },
                    urlRefresher: { [cloudClient] trackId in
                        try await cloudClient.resolveDownloadURL(fileId: trackId)
                    }
                )
            } catch {
                self.streamServer = nil
                startupWarning = "本地流代理启动失败：\(error.localizedDescription)"
            }
        } else {
            self.streamServer = nil
        }

        if let startupWarning {
            self.statusMessage = startupWarning
        }
        syncDraftsFromCommitted()

        writeThroughRelay.bind { [weak self] accountHash, trackId, localURL in
            await self?.handleWriteThroughCompleted(accountHash: accountHash, trackId: trackId, localFileURL: localURL)
        }
        Task { [weak self] in
            await engine.setOnActivityChange { [weak self] snapshot, hasActive in
                Task { @MainActor [weak self] in
                    await self?.handleTransferActivityChange(snapshot: snapshot, hasActive: hasActive)
                }
            }
        }
        if enableLiveObservers {
            setupPlayerAndRemoteCommands()
        }
    }

    public static func fixture(scene: SnapshotScene, fixture: RepresentativeFixture) -> CloudTuneViewModel {
        let isolatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudtune-fixture-\(UUID().uuidString)", isDirectory: true)
        let isolatedStore: AccountScopedStore?
        do {
            isolatedStore = try AccountScopedStore(rootDirectory: isolatedRoot)
        } catch {
            isolatedStore = nil
        }
        let vm = CloudTuneViewModel(accountStore: isolatedStore, enableLiveObservers: false)
        let resolvedAppearance = fixture.settings.appearanceMode ?? .system
        let committed = AccountSettings(
            musicFolder: fixture.currentFolder,
            cacheLimitMb: fixture.settings.cacheLimitMb,
            downloadThreads: fixture.settings.downloadThreads,
            cacheThreads: fixture.settings.cacheThreads,
            playbackMode: fixture.settings.playbackMode,
            exportFolderDisplayName: "Downloads",
            appearanceMode: resolvedAppearance,
            dynamicColorEnabled: fixture.settings.dynamicColorEnabled ?? false
        )
        vm.committedSettings = committed
        vm.appearancePreference = resolvedAppearance
        vm.syncDraftsFromCommitted()

        switch scene {
        case .authIdle:
            vm.isAuthenticated = false
            vm.accountName = nil
            vm.accountStorageKey = nil
            vm.cacheUsageBytes = 0
        case .authQr:
            vm.isAuthenticated = false
            vm.accountName = nil
            vm.accountStorageKey = nil
            vm.cacheUsageBytes = 0
            vm.qrContent = fixture.qrLogin.qrContent
            vm.qrHint = fixture.qrLogin.message
            vm.statusMessage = fixture.qrLogin.message
            vm.qrPNGData = QRCodeGenerator.generatePNGData(content: fixture.qrLogin.qrContent, dimension: 480)
        case .music, .video, .download, .errorBanner, .cloud, .settings, .nowPlaying:
            vm.isAuthenticated = true
            vm.accountName = fixture.accountName
            vm.accountStorageKey = fixture.accountName
            vm.cacheUsageBytes = fixture.settings.cacheUsageBytes
            let pane = BrowserPaneState(breadcrumbs: fixture.breadcrumbs, payload: fixture.browser)
            vm.cloudBrowser = pane
            vm.videoBrowser = pane
            vm.tracks = fixture.libraryTracks
            let active = fixture.libraryTracks.first { $0.id == fixture.nowPlaying.trackId }
                ?? fixture.browser.audioFiles.first { $0.id == fixture.nowPlaying.trackId }
            vm.activeTrack = active
            vm.currentTrackId = fixture.nowPlaying.trackId
            vm.shuffle = fixture.nowPlaying.shuffle
            vm.shuffleOrderIds = fixture.libraryTracks.map(\.id)
            vm.loopMode = fixture.nowPlaying.loopMode
            vm.upNextQueue = Array(fixture.libraryTracks.filter { $0.id != fixture.nowPlaying.trackId }.prefix(2))
            vm.nowPlayingMetadata = NowPlayingMetadata(
                title: fixture.nowPlaying.title,
                artist: fixture.nowPlaying.artist,
                album: fixture.nowPlaying.album
            )
            vm.isPlaying = (scene == .errorBanner) ? false : fixture.nowPlaying.isPlaying
            vm.currentTime = fixture.nowPlaying.currentTimeSeconds
            vm.duration = fixture.nowPlaying.durationSeconds
            vm.transferSnapshot = fixture.transferSnapshot
            vm.statusMessage = (scene == .errorBanner) ? fixture.errorBanner.statusMessage : fixture.nowPlaying.statusMessage

            switch scene {
            case .video:
                vm.activeModule = .video
            case .download:
                vm.activeModule = .transfers
            case .cloud:
                vm.activeModule = .cloud
            case .settings:
                vm.activeModule = .settings
                vm.isShowingSettingsSheet = true
            case .nowPlaying:
                vm.activeModule = .music
                vm.isShowingNowPlayingSheet = true
                vm.isShowingQueuePopover = true
            default:
                vm.activeModule = .music
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
        if let activeTrack, activeTrack.id == currentTrackId || currentTrackId == nil {
            return activeTrack
        }
        guard let currentTrackId else { return nil }
        return tracks.first { $0.id == currentTrackId }
            ?? cloudBrowser.payload?.audioFiles.first { $0.id == currentTrackId }
            ?? activeTrack
    }

    public var upcomingTracks: [TrackSummary] {
        PlaybackQueueResolver.upcomingPreview(
            currentTrack: currentTrack,
            libraryTracks: tracks,
            upNextQueue: upNextQueue,
            shuffle: shuffle,
            shuffleOrderIds: shuffleOrderIds,
            loopMode: loopMode,
            limit: 20
        )
    }

    public var canSkipNext: Bool {
        PlaybackQueueResolver.canSkipNext(
            currentTrack: currentTrack,
            libraryTracks: tracks,
            upNextQueue: upNextQueue,
            shuffle: shuffle,
            shuffleOrderIds: shuffleOrderIds,
            loopMode: loopMode
        )
    }

    public var canSkipPrevious: Bool {
        PlaybackQueueResolver.canSkipPrevious(
            currentTrack: currentTrack,
            libraryTracks: tracks,
            shuffle: shuffle,
            shuffleOrderIds: shuffleOrderIds,
            loopMode: loopMode
        )
    }

    public var downloadTransfers: [TransferStatus] {
        transferSnapshot.items.filter { $0.kind == "download" }
    }

    public var activeStreamAndCacheTransfers: [TransferStatus] {
        transferSnapshot.items.filter { $0.kind != "download" }
    }

    public var downloadableBrowserFiles: [TrackSummary] {
        guard let payload = cloudBrowser.payload else { return [] }
        return payload.audioFiles + payload.videoFiles + payload.otherFiles
    }

    public var qrHost: String? {
        guard let qrContent, let url = URL(string: qrContent) else { return nil }
        return url.host
    }

    // MARK: - Settings Draft Safety & Checked Persistence

    public func syncDraftsFromCommitted() {
        cacheLimitDraft = String(committedSettings.cacheLimitMb)
        downloadThreadsDraft = String(committedSettings.downloadThreads)
        cacheThreadsDraft = String(committedSettings.cacheThreads)
        if let previousError = settingsValidationError, statusMessage == previousError {
            statusMessage = nil
        }
        settingsValidationError = nil
    }

    public func noteDraftEdited() {
        if let previousError = settingsValidationError, statusMessage == previousError {
            statusMessage = nil
        }
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
        guard await persistCommittedSettings(next, successMessage: "缓存限制已更新") else {
            return false
        }
        if let cacheStore {
            do {
                cacheUsageBytes = try await cacheStore.pruneToLimit(limitBytes: next.cacheLimitBytes)
            } catch {
                statusMessage = "缓存清理遇到异常：\(error.localizedDescription)"
            }
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
        return await persistCommittedSettings(next, successMessage: "传输参数已更新")
    }

    public func updatePlaybackMode(_ mode: PlaybackMode) async {
        var next = committedSettings
        next.playbackMode = mode
        let msg = mode == .downloadFirst ? "已切到优先缓存播放" : "已切到边播边缓存"
        _ = await persistCommittedSettings(next, successMessage: msg, resyncDrafts: false)
    }

    public func setAppearanceMode(_ mode: AppearanceMode) async {
        appearancePreference = mode
        var next = committedSettings
        next.appearanceMode = mode
        if let accountId = activeAccountKey {
            do {
                try await accountStore.saveSettings(next, for: accountId)
                committedSettings = next
            } catch {
                statusMessage = "保存外观设置失败：\(error.localizedDescription)"
            }
        } else {
            committedSettings = next
        }
    }

    @discardableResult
    private func persistCommittedSettings(
        _ next: AccountSettings,
        successMessage: String,
        resyncDrafts: Bool = true
    ) async -> Bool {
        if let accountId = activeAccountKey {
            do {
                try await accountStore.saveSettings(next, for: accountId)
            } catch {
                statusMessage = "保存设置失败：\(error.localizedDescription)"
                return false
            }
        }
        committedSettings = next
        if resyncDrafts {
            syncDraftsFromCommitted()
        }
        statusMessage = successMessage
        return true
    }

    private var activeAccountKey: String? {
        if let key = accountStorageKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        guard let trimmed = accountName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != Cloud189Constants.defaultAccountDisplayName else {
            return nil
        }
        return trimmed
    }

    private func saveCredentialReportingIssue(_ credential: PersistedRefreshCredential) {
        do {
            try credentialMachine.save(credential, backend: keychainBackend)
        } catch {
            statusMessage = "钥匙串保存凭据失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Bootstrap & Auth

    public func bootstrap(userInitiatedKeychainRetry: Bool = false) async {
        isBootstrapping = true
        busyLabel = "同步本地配置..."
        defer {
            busyLabel = nil
            isBootstrapping = false
        }

        let migrated = await accountStore.migrateLegacyTauriDataIfPresent()

        var (storedCred, issue) = credentialMachine.load(
            isInteractiveGUI: true,
            userInitiatedRetry: userInitiatedKeychainRetry,
            backend: keychainBackend
        )
        if storedCred == nil, issue == nil, let migrated {
            saveCredentialReportingIssue(migrated)
            storedCred = migrated
        }
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
            let identity = Cloud189Protocol.resolveAccountIdentity(
                activeSession: sessionPayload.activeSession,
                persistedCredential: sessionPayload.persistedCredential ?? storedCred,
                priorAccountKey: storedCred.accountKey
            )
            if let refreshedCred = sessionPayload.persistedCredential {
                saveCredentialReportingIssue(refreshedCred.withAccountKey(identity.storageKey))
            }
            await activateAuthenticatedAccount(
                storageKey: identity.storageKey,
                displayName: identity.displayName
            )
            await browseTo(scope: .cloud, folderId: nil, nextBreadcrumbs: [.root], showBusy: false)
        } catch is CancellationError {
            return
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
        } catch is CancellationError {
            return
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func startQrPolling() {
        qrPollTask?.cancel()
        qrPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(2500))
                } catch {
                    break
                }
                guard !Task.isCancelled, let self else { break }
                do {
                    let poll = try await self.cloudClient.pollQrLogin()
                    self.qrHint = poll.message
                    self.statusMessage = poll.message
                    switch poll.state {
                    case .authenticated:
                        let activeSession = await self.cloudClient.activeSession
                        let persisted = await self.cloudClient.persistedCredential
                        let identity: (storageKey: String, displayName: String)
                        if let activeSession {
                            identity = Cloud189Protocol.resolveAccountIdentity(
                                activeSession: activeSession,
                                persistedCredential: persisted
                            )
                        } else {
                            let fallbackName = poll.accountName ?? Cloud189Constants.defaultAccountDisplayName
                            let fallbackKey = (fallbackName != Cloud189Constants.defaultAccountDisplayName)
                                ? fallbackName
                                : Cloud189Protocol.deriveFallbackAccountKey(
                                    refreshToken: persisted?.refreshToken,
                                    accessToken: nil,
                                    sessionKey: UUID().uuidString
                                )
                            identity = (fallbackKey, fallbackName)
                        }
                        if let persisted {
                            self.saveCredentialReportingIssue(persisted.withAccountKey(identity.storageKey))
                        }
                        self.qrContent = nil
                        self.qrPNGData = nil
                        await self.activateAuthenticatedAccount(
                            storageKey: identity.storageKey,
                            displayName: identity.displayName
                        )
                        await self.browseTo(scope: .cloud, folderId: nil, nextBreadcrumbs: [.root], showBusy: false)
                        return
                    case .expired:
                        self.qrContent = nil
                        self.qrPNGData = nil
                        return
                    case .waitingScan, .waitingConfirm:
                        continue
                    }
                } catch is CancellationError {
                    return
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
            let identity = Cloud189Protocol.resolveAccountIdentity(
                activeSession: parsed.activeSession,
                persistedCredential: parsed.persistedCredential
            )
            if let persisted = parsed.persistedCredential {
                saveCredentialReportingIssue(persisted.withAccountKey(identity.storageKey))
            }
            isShowingWebLoginSheet = false
            qrPollTask?.cancel()
            qrContent = nil
            qrPNGData = nil
            await activateAuthenticatedAccount(
                storageKey: identity.storageKey,
                displayName: identity.displayName
            )
            await browseTo(scope: .cloud, folderId: nil, nextBreadcrumbs: [.root], showBusy: false)
            statusMessage = "天翼官方网页登录成功"
        } catch is CancellationError {
            return
        } catch {
            isShowingWebLoginSheet = false
            statusMessage = "网页登录回调兑换失败（\(error.localizedDescription)），已切换至二维码扫码登录，可保存二维码到相册后用天翼云盘 App 识别。"
            await beginQrLogin()
        }
    }

    public func activateAuthenticatedAccount(storageKey: String, displayName: String) async {
        if enableLiveObservers {
            setupPlayerAndRemoteCommands()
        }
        self.isAuthenticated = true
        self.accountStorageKey = storageKey
        self.accountName = displayName
        self.credentialIssue = nil

        do {
            let paths = try await accountStore.paths(for: storageKey)
            let store = try CacheStore(cacheDirectory: paths.cacheDir, indexURL: paths.cacheIndexURL)
            self.cacheStore = store
            self.cacheUsageBytes = await store.usageBytes()
        } catch {
            self.cacheStore = nil
            self.cacheUsageBytes = 0
            self.statusMessage = "初始化本地缓存目录失败：\(error.localizedDescription)"
        }

        do {
            let savedSettings = try await accountStore.loadSettings(for: storageKey)
            self.committedSettings = savedSettings
            self.appearancePreference = savedSettings.appearanceMode
            syncDraftsFromCommitted()
        } catch {
            self.statusMessage = "读取账户设置失败：\(error.localizedDescription)"
        }

        do {
            let savedTracks = try await accountStore.loadLibrary(for: storageKey)
            self.tracks = savedTracks
        } catch {
            self.tracks = []
            self.statusMessage = "读取本地曲库索引失败：\(error.localizedDescription)"
        }

        await transferEngine.restorePersistedDownloads(for: storageKey, accountStore: accountStore)
        let snap = await transferEngine.snapshot()
        await handleTransferActivityChange(snapshot: snap, hasActive: snap.hasActiveItems)
    }

    public func logout() async {
        qrPollTask?.cancel()
        qrPollTask = nil
        transferRefreshTask?.cancel()
        transferRefreshTask = nil
        playbackGeneration += 1
        recoveryAttempts = 0
        prefetchedTrackId = nil
        prefetchingTrackId = nil
        wasPlayingBeforeInterruption = false
        teardownPlayerAndRemoteCommands()
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
        accountStorageKey = nil
        cacheStore = nil
        cacheUsageBytes = 0
        cloudBrowser = BrowserPaneState()
        videoBrowser = BrowserPaneState()
        tracks = []
        upNextQueue = []
        shuffleOrderIds = []
        activeTrack = nil
        currentTrackId = nil
        nowPlayingMetadata = nil
        isPlaying = false
        loadingTrackId = nil
        currentTime = 0
        duration = 0
        activeVideoURL = nil
        activeVideoTrack = nil
        pendingExternalVideoChoice = nil
        isShowingNowPlayingSheet = false
        isShowingQueuePopover = false
        transferSnapshot = TransferSnapshotPayload()
        committedSettings = AccountSettings(appearanceMode: appearancePreference)
        syncDraftsFromCommitted()
        statusMessage = "已退出登录并清理当前会话"
    }

    // MARK: - Decoupled Cloud & Video Folder Browsers + Library

    public func browseTo(
        scope: BrowserScope = .cloud,
        folderId: String?,
        nextBreadcrumbs: [BreadcrumbItem],
        showBusy: Bool = true
    ) async {
        guard isAuthenticated else { return }
        if showBusy { busyLabel = "读取云盘目录..." }
        defer { if showBusy { busyLabel = nil } }
        let isRoot = (folderId == nil || folderId == Cloud189Constants.rootFolderId)
        let nonRootCrumbs = nextBreadcrumbs.filter { $0.id != nil && $0.id != Cloud189Constants.rootFolderId }
        let resolvedName = isRoot
            ? Cloud189Constants.rootFolderName
            : (nonRootCrumbs.last?.name ?? nextBreadcrumbs.last?.name)
        let resolvedPath = isRoot
            ? Cloud189Constants.rootFolderName
            : nonRootCrumbs.map(\.name).filter { !$0.isEmpty }.joined(separator: "/")
        do {
            let listing = try await cloudClient.listRemoteFolder(
                folderId: folderId,
                folderName: resolvedName,
                folderPath: resolvedPath.isEmpty ? nil : resolvedPath
            )
            let updatedPane = BrowserPaneState(breadcrumbs: nextBreadcrumbs, payload: listing)
            switch scope {
            case .cloud:
                cloudBrowser = updatedPane
                if isRoot && videoBrowser.payload == nil {
                    videoBrowser = updatedPane
                }
            case .video:
                videoBrowser = updatedPane
                if isRoot && cloudBrowser.payload == nil {
                    cloudBrowser = updatedPane
                }
            }
        } catch is CancellationError {
            return
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func navigateBackInBrowser(scope: BrowserScope) async {
        let crumbs = (scope == .cloud) ? cloudBrowser.breadcrumbs : videoBrowser.breadcrumbs
        guard crumbs.count > 1 else { return }
        let nextCrumbs = Array(crumbs.dropLast())
        let targetId = nextCrumbs.last?.id
        await browseTo(scope: scope, folderId: targetId, nextBreadcrumbs: nextCrumbs)
    }

    public func setCurrentFolderAsMusicLibrary() async {
        await setFolderAsMusicLibrary(from: cloudBrowser)
    }

    public func setFolderAsMusicLibrary(from pane: BrowserPaneState) async {
        guard let payload = pane.payload, let lastCrumb = pane.breadcrumbs.last, let accountId = activeAccountKey else { return }
        let displayName = (lastCrumb.id == payload.currentFolderId || (payload.isRoot && lastCrumb.id == nil))
            ? lastCrumb.name
            : payload.currentFolderName
        busyLabel = "保存 \(displayName) 为音乐目录..."
        defer { busyLabel = nil }
        var next = committedSettings
        next.musicFolder = FolderSelection(id: payload.currentFolderId, name: displayName)
        do {
            try await accountStore.saveSettings(next, for: accountId)
            committedSettings = next
            statusMessage = "音乐目录已设置为 \(displayName)"
            await scanMusicLibrary(showBusy: false)
        } catch {
            statusMessage = "保存音乐目录失败：\(error.localizedDescription)"
        }
    }

    public func scanMusicLibrary(showBusy: Bool = true) async {
        guard let folder = committedSettings.musicFolder, let accountId = activeAccountKey else {
            statusMessage = "请先在云盘目录中设为音乐库。"
            return
        }
        if showBusy { busyLabel = "扫描 \(folder.name) 中的音乐..." }
        defer { if showBusy { busyLabel = nil } }
        do {
            let scanned = try await cloudClient.scanMusicLibrary(folderId: folder.id, folderName: folder.name)
            tracks = scanned
            do {
                try await accountStore.saveLibrary(scanned, for: accountId)
                statusMessage = "已载入 \(scanned.count) 首音乐"
            } catch {
                statusMessage = "已载入 \(scanned.count) 首音乐（索引落盘失败：\(error.localizedDescription)）"
            }
        } catch is CancellationError {
            return
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Playback, Queue & Write-Through Backfill

    public func playNext(_ track: TrackSummary) {
        upNextQueue = PlaybackQueueResolver.insertPlayNext(upNext: upNextQueue, track: track)
        prefetchedTrackId = nil
        statusMessage = "已设为下一首播放：《\(track.name)》"
        Task { await maybePrefetchUpcomingTrack() }
    }

    public func appendToQueue(_ track: TrackSummary) {
        upNextQueue = PlaybackQueueResolver.appendToQueue(upNext: upNextQueue, track: track)
        statusMessage = "已加入待播队列：《\(track.name)》"
    }

    public func removeFromQueue(trackId: String) {
        upNextQueue = PlaybackQueueResolver.removeFromQueue(upNext: upNextQueue, trackId: trackId)
    }

    public func clearUpNextQueue() {
        upNextQueue = []
    }

    public func toggleShuffle() {
        shuffle.toggle()
    }

    public func cycleLoopMode() {
        loopMode = switch loopMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    public func setVolume(_ nextVolume: Double) {
        volume = nextVolume
    }

    public func playTrack(
        _ track: TrackSummary,
        modeOverride: PlaybackMode? = nil,
        forceStreamProxy: Bool = false,
        resumeTime: Double = 0,
        isRecoveryRetry: Bool = false
    ) async {
        guard let accountId = activeAccountKey, let cacheStore else { return }
        playbackGeneration += 1
        let gen = playbackGeneration
        activeTrack = track
        currentTrackId = track.id
        loadingTrackId = track.id
        prefetchedTrackId = nil
        prefetchingTrackId = nil
        if shuffle && !shuffleOrderIds.contains(track.id) && tracks.contains(where: { $0.id == track.id }) {
            shuffleOrderIds = PlaybackQueueResolver.buildShuffleOrder(tracks: tracks, anchorTrackId: track.id)
        }
        if !isRecoveryRetry {
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
                    kind: "playback",
                    accountHash: accountHash
                )
                guard gen == playbackGeneration, isAuthenticated else { return }
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
                guard gen == playbackGeneration, isAuthenticated else { return }
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
        } catch is CancellationError {
            return
        } catch {
            guard gen == playbackGeneration, isAuthenticated else { return }
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
        if let audioSessionWarning = nowPlayingCoordinator.configureAudioSessionIfNeeded() {
            statusMessage = audioSessionWarning
        }
        currentPlaybackIsLoopback = isLoopback
        activeTrack = track
        currentTrackId = track.id
        duration = 0
        currentTime = resumeTime

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
                    let dur = observedItem.duration.seconds
                    if dur.isFinite && dur > 0 {
                        self.duration = dur
                    }
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
        player.volume = Float(volume)
        player.replaceCurrentItem(with: item)
        if resumeTime > 0 {
            await player.seek(to: CMTime(seconds: resumeTime, preferredTimescale: 600))
        }
        player.play()
        isPlaying = true
        if statusMessage == nil || !statusMessage!.hasPrefix("音频会话配置失败") {
            statusMessage = isLoopback ? "边播边缓存《\(track.name)》" : "正在播放《\(track.name)》"
        }

        let fallbackAlbum = track.folderPath.isEmpty ? (committedSettings.musicFolder?.name ?? "天翼云盘") : track.folderPath
        let meta = await AudioMetadataReader.readMetadata(from: localFileURL, fallbackTitle: track.name, fallbackAlbum: fallbackAlbum)
        guard generation == playbackGeneration else { return }
        nowPlayingMetadata = meta
        syncRemoteCommandAvailability()
        nowPlayingCoordinator.updateNowPlaying(
            metadata: meta,
            isPlaying: isPlaying,
            elapsedSeconds: resumeTime,
            durationSeconds: duration,
            forceUpdate: true
        )
    }

    public func handleWriteThroughCompleted(accountHash: String, trackId: String, localFileURL: URL) async {
        guard isAuthenticated,
              let accountId = activeAccountKey,
              Cloud189Protocol.accountBucketHash(for: accountId) == accountHash else {
            return
        }
        if let cacheStore {
            cacheUsageBytes = await cacheStore.usageBytes()
        }
        guard currentTrackId == trackId, let track = currentTrack else { return }
        let gen = playbackGeneration
        let fallbackAlbum = track.folderPath.isEmpty ? (committedSettings.musicFolder?.name ?? "天翼云盘") : track.folderPath
        let enriched = await AudioMetadataReader.readMetadata(
            from: localFileURL,
            fallbackTitle: track.name,
            fallbackAlbum: fallbackAlbum
        )
        guard isAuthenticated, gen == playbackGeneration, currentTrackId == trackId else { return }
        nowPlayingMetadata = enriched
        nowPlayingCoordinator.updateNowPlaying(
            metadata: enriched,
            isPlaying: isPlaying,
            elapsedSeconds: currentTime,
            durationSeconds: duration,
            forceUpdate: true
        )
    }

    public func handlePlaybackPreparationFailure(
        track: TrackSummary,
        error: Error,
        wasLoopback: Bool,
        resumeTime: Double
    ) async {
        if error is CancellationError {
            return
        }
        let failedGeneration = playbackGeneration
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
        let isNetworkError = (nsError.domain == NSURLErrorDomain)
        let isCloudProtocolOrHttpError: Bool = switch error as? CloudTuneError {
        case .httpStatus, .protocolError, .sessionExpired, .unauthenticated, .invalidRequest, .storageError, .exportPermissionRevoked:
            true
        case .unsupportedLocalMediaFormat, .none:
            false
        }
        let isDecode: Bool
        if case .unsupportedLocalMediaFormat = error as? CloudTuneError {
            isDecode = true
        } else if isNetworkError || isCloudProtocolOrHttpError {
            isDecode = false
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
            guard isAuthenticated, playbackGeneration == failedGeneration else { return }
            statusMessage = "《\(track.name)》优先缓存超时，改用流式代理直接起播"
            await playTrack(
                track,
                modeOverride: .streamCache,
                forceStreamProxy: true,
                resumeTime: resumeTime,
                isRecoveryRetry: true
            )
        case .fallbackToFullDownloadOnce:
            guard isAuthenticated, playbackGeneration == failedGeneration else { return }
            statusMessage = "流式容器受限，回退整曲下载《\(track.name)》"
            await playTrack(
                track,
                modeOverride: .downloadFirst,
                forceStreamProxy: false,
                resumeTime: resumeTime,
                isRecoveryRetry: true
            )
        case let .stopImmediatelyUnsupportedCodec(msg):
            isPlaying = false
            statusMessage = msg
        case .stopAfterMaxRetries:
            isPlaying = false
            statusMessage = "播放异常，已停止自动重试《\(track.name)》"
        case let .retryTransientAfterDelay(attempt):
            isPlaying = false
            guard isAuthenticated, playbackGeneration == failedGeneration else { return }
            statusMessage = "播放波动，正在重试《\(track.name)》(\(attempt)/\(PlaybackDecisionPolicy.maxRecoveryAttempts))"
            let delayMs = max(0, retryBaseDelayMs) * attempt
            if delayMs > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(delayMs))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled,
                  isAuthenticated,
                  playbackGeneration == failedGeneration else {
                return
            }
            await playTrack(track, resumeTime: resumeTime, isRecoveryRetry: true)
        }
    }

    public func togglePlayback() async {
        guard let currentTrack else {
            let candidate = shuffle ? tracks.randomElement() : visibleTracks.first
            if let picked = candidate ?? tracks.first {
                await playTrack(picked)
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
            durationSeconds: duration,
            forceUpdate: true
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
            durationSeconds: duration,
            forceUpdate: true
        )
    }

    public func playAdjacent(direction: Int, autoAdvanceAtEnd: Bool = false) async {
        let step: QueueStepResult
        if direction >= 0 {
            step = PlaybackQueueResolver.resolveNext(
                currentTrack: currentTrack,
                libraryTracks: tracks,
                upNextQueue: upNextQueue,
                shuffle: shuffle,
                shuffleOrderIds: shuffleOrderIds,
                loopMode: loopMode,
                autoAdvanceAtEnd: autoAdvanceAtEnd
            )
        } else {
            step = PlaybackQueueResolver.resolvePrevious(
                currentTrack: currentTrack,
                libraryTracks: tracks,
                upNextQueue: upNextQueue,
                shuffle: shuffle,
                shuffleOrderIds: shuffleOrderIds,
                loopMode: loopMode
            )
        }
        upNextQueue = step.remainingUpNext
        if let target = step.track {
            await playTrack(target)
        } else if autoAdvanceAtEnd {
            isPlaying = false
            nowPlayingCoordinator.updateNowPlaying(
                metadata: nowPlayingMetadata,
                isPlaying: false,
                elapsedSeconds: duration,
                durationSeconds: duration,
                forceUpdate: true
            )
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
            durationSeconds: duration,
            forceUpdate: true
        )
    }

    // MARK: - Video (Loopback Proxy + Safe External Handoff) & Transfers

    public func openVideoInApp(_ video: TrackSummary) async {
        playbackGeneration += 1
        recoveryAttempts = 0
        pauseIfPlaying()
        busyLabel = "准备视频流 \(video.name)..."
        defer { busyLabel = nil }
        do {
            if let cacheStore, let cached = await cacheStore.existingCachedFile(trackId: video.id) {
                activeVideoTrack = video
                activeVideoURL = cached
                statusMessage = "正在播放已缓存视频：\(video.name)"
                return
            }
            let remoteURL = try await cloudClient.resolveDownloadURL(fileId: video.id)
            let playbackURL: URL
            if let streamServer, let cacheStore, let accountId = activeAccountKey {
                let accountHash = Cloud189Protocol.accountBucketHash(for: accountId)
                let destURL = await cacheStore.cacheFileURL(trackId: video.id, originalFileName: video.name)
                playbackURL = await streamServer.registerSource(
                    StreamSourceRegistration(
                        accountHash: accountHash,
                        trackId: video.id,
                        remoteURL: remoteURL,
                        cacheDestinationURL: destURL,
                        expectedSize: video.sizeBytes,
                        fileName: video.name,
                        cacheLimitBytes: committedSettings.cacheLimitBytes
                    ),
                    cacheStore: cacheStore
                )
            } else {
                playbackURL = remoteURL
            }
            activeVideoTrack = video
            activeVideoURL = playbackURL
            statusMessage = "正在应用内播放视频：\(video.name)"
        } catch is CancellationError {
            return
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Returns a local cached `file://` URL immediately if available; otherwise prepares a loopback stream URL
    /// and sets `pendingExternalVideoChoice` so callers NEVER hand raw `https://` URLs to a web browser.
    public func requestExternalVideoPlayback(_ video: TrackSummary) async -> URL? {
        busyLabel = "检查本地视频缓存 \(video.name)..."
        defer { busyLabel = nil }
        if let cacheStore, let cached = await cacheStore.existingCachedFile(trackId: video.id) {
            shareFileURL = cached
            return cached
        }
        do {
            let remoteURL = try await cloudClient.resolveDownloadURL(fileId: video.id)
            let streamURL: URL
            if let streamServer, let cacheStore, let accountId = activeAccountKey {
                let accountHash = Cloud189Protocol.accountBucketHash(for: accountId)
                let destURL = await cacheStore.cacheFileURL(trackId: video.id, originalFileName: video.name)
                streamURL = await streamServer.registerSource(
                    StreamSourceRegistration(
                        accountHash: accountHash,
                        trackId: video.id,
                        remoteURL: remoteURL,
                        cacheDestinationURL: destURL,
                        expectedSize: video.sizeBytes,
                        fileName: video.name,
                        cacheLimitBytes: committedSettings.cacheLimitBytes
                    ),
                    cacheStore: cacheStore
                )
            } else {
                streamURL = remoteURL
            }
            pendingExternalVideoChoice = PendingExternalVideoChoice(video: video, streamURL: streamURL)
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            statusMessage = "获取视频源失败：\(error.localizedDescription)"
            return nil
        }
    }

    public func downloadVideoAndPrepareLocalFile(_ video: TrackSummary) async -> URL? {
        guard let accountId = activeAccountKey, let cacheStore else {
            statusMessage = "请先登录后再缓存视频。"
            return nil
        }
        pendingExternalVideoChoice = nil
        busyLabel = "正在下载视频至本地缓存：《\(video.name)》..."
        defer { busyLabel = nil }
        let accountHash = Cloud189Protocol.accountBucketHash(for: accountId)
        do {
            let localURL = try await transferEngine.downloadTrackToCache(
                track: video,
                cacheStore: cacheStore,
                parallelThreads: committedSettings.downloadThreads,
                cacheLimitBytes: max(committedSettings.cacheLimitBytes, video.sizeBytes),
                kind: "playback",
                accountHash: accountHash
            )
            cacheUsageBytes = await cacheStore.usageBytes()
            shareFileURL = localURL
            statusMessage = "视频缓存完成，正在调用本地播放器打开"
            return localURL
        } catch is CancellationError {
            return nil
        } catch {
            statusMessage = "缓存视频失败：\(error.localizedDescription)"
            return nil
        }
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
        } catch is CancellationError {
            return
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func enqueueCurrentFolderDownload(explicitDirectoryURL: URL? = nil) async {
        await enqueueFolderDownload(from: cloudBrowser, explicitDirectoryURL: explicitDirectoryURL)
    }

    public func enqueueFolderDownload(from pane: BrowserPaneState, explicitDirectoryURL: URL? = nil) async {
        guard let payload = pane.payload, let accountId = activeAccountKey else { return }
        let nonRootCrumbs = pane.breadcrumbs.filter { $0.id != nil && $0.id != Cloud189Constants.rootFolderId }
        let crumbPath: String? = (!payload.isRoot && nonRootCrumbs.last?.id == payload.currentFolderId)
            ? nonRootCrumbs.map(\.name).filter { !$0.isEmpty }.joined(separator: "/")
            : nil
        let rootExportFolder = (crumbPath?.isEmpty == false ? crumbPath! : payload.currentFolderName)
        busyLabel = "扫描文件夹 \(payload.currentFolderName)..."
        defer { busyLabel = nil }
        do {
            let allFiles = try await cloudClient.scanAllFiles(
                folderId: payload.currentFolderId,
                folderName: rootExportFolder
            )
            for item in allFiles {
                let rel = item.folderPath.hasPrefix(rootExportFolder)
                    ? "\(item.folderPath)/\(item.name)"
                    : "\(rootExportFolder)/\(item.name)"
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
        } catch is CancellationError {
            return
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

    // MARK: - Event-Driven Transfer Refresh & Idempotent Player / RemoteCommand Observers

    private func handleTransferActivityChange(snapshot: TransferSnapshotPayload, hasActive: Bool) async {
        transferSnapshot = snapshot
        if hasActive && enableLiveObservers {
            if transferRefreshTask == nil {
                transferRefreshTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .milliseconds(400))
                        } catch {
                            break
                        }
                        guard !Task.isCancelled, let self else { break }
                        let latest = await self.transferEngine.snapshot()
                        self.transferSnapshot = latest
                        if !latest.hasActiveItems {
                            if let store = self.cacheStore {
                                self.cacheUsageBytes = await store.usageBytes()
                            }
                            break
                        }
                    }
                    if let self {
                        self.transferRefreshTask = nil
                    }
                }
            }
        } else {
            transferRefreshTask?.cancel()
            transferRefreshTask = nil
            if let store = cacheStore {
                cacheUsageBytes = await store.usageBytes()
            }
        }
    }

    private func syncRemoteCommandAvailability() {
        guard hasActivePlayerObservers else { return }
        nowPlayingCoordinator.updateCommandAvailability(
            canSkipNext: canSkipNext,
            canSkipPrevious: canSkipPrevious,
            hasActiveTrack: currentTrack != nil
        )
    }

    private func setupPlayerAndRemoteCommands() {
        guard enableLiveObservers, !hasActivePlayerObservers else { return }
        hasActivePlayerObservers = true

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

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            let status = observedPlayer.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, self.currentTrack != nil, self.loadingTrackId == nil else { return }
                switch status {
                case .playing:
                    if !self.isPlaying {
                        self.isPlaying = true
                        self.nowPlayingCoordinator.updateNowPlaying(
                            metadata: self.nowPlayingMetadata,
                            isPlaying: true,
                            elapsedSeconds: self.currentTime,
                            durationSeconds: self.duration,
                            forceUpdate: true
                        )
                    }
                case .paused:
                    if self.isPlaying && observedPlayer.currentItem != nil {
                        self.isPlaying = false
                        self.nowPlayingCoordinator.updateNowPlaying(
                            metadata: self.nowPlayingMetadata,
                            isPlaying: false,
                            elapsedSeconds: self.currentTime,
                            durationSeconds: self.duration,
                            forceUpdate: true
                        )
                    }
                case .waitingToPlayAtSpecifiedRate:
                    break
                @unknown default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let itemObj = note.object as? AVPlayerItem
            Task { @MainActor [weak self] in
                guard let self, itemObj === self._player?.currentItem else { return }
                await self.playAdjacent(direction: 1, autoAdvanceAtEnd: true)
            }
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let itemObj = note.object as? AVPlayerItem
            let err = itemObj?.error ?? CloudTuneError.unsupportedLocalMediaFormat("系统解码器无法播放该音频格式")
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
            },
            onInterruptionBegan: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.wasPlayingBeforeInterruption = self.isPlaying
                    self.pauseIfPlaying()
                }
            },
            onInterruptionEndedShouldResume: { [weak self] in
                Task { @MainActor in
                    guard let self, self.wasPlayingBeforeInterruption else { return }
                    self.wasPlayingBeforeInterruption = false
                    await self.playIfPaused()
                }
            },
            onOldAudioDeviceUnavailable: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.wasPlayingBeforeInterruption = false
                    self.pauseIfPlaying()
                }
            }
        ))
        syncRemoteCommandAvailability()
    }

    public func teardownPlayerAndRemoteCommands() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let token = timeObserverToken {
            _player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
            self.failObserver = nil
        }
        nowPlayingCoordinator.unregisterRemoteCommands()
        hasActivePlayerObservers = false
    }

    private func maybePrefetchUpcomingTrack() async {
        guard isAuthenticated, loopMode != .one, let cacheStore, currentTrack != nil else { return }
        let remaining = duration - currentTime
        let shouldPrefetch = (committedSettings.playbackMode == .downloadFirst)
            || (remaining.isFinite && remaining > 0 && remaining <= 30)
        guard shouldPrefetch else { return }

        guard let next = PlaybackQueueResolver.peekPrefetchCandidate(
            currentTrack: currentTrack,
            libraryTracks: tracks,
            upNextQueue: upNextQueue,
            shuffle: shuffle,
            shuffleOrderIds: shuffleOrderIds,
            loopMode: loopMode
        ),
        next.id != prefetchedTrackId,
        next.id != prefetchingTrackId else { return }

        prefetchingTrackId = next.id
        let activeId = currentTrackId ?? ""
        let accountHash = activeAccountKey.map { Cloud189Protocol.accountBucketHash(for: $0) }
        await cacheStore.setProtectedTrackIDs([activeId, next.id])
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.transferEngine.downloadTrackToCache(
                    track: next,
                    cacheStore: cacheStore,
                    parallelThreads: self.committedSettings.cacheThreads,
                    cacheLimitBytes: self.committedSettings.cacheLimitBytes,
                    kind: "prefetch",
                    accountHash: accountHash
                )
                self.prefetchedTrackId = next.id
            } catch {
                // Best-effort prefetch; errors do not interrupt active playback
            }
            if self.prefetchingTrackId == next.id {
                self.prefetchingTrackId = nil
            }
        }
    }
}
