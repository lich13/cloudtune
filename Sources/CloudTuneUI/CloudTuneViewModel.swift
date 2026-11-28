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
    public let streamURL: URL?

    public init(video: TrackSummary, streamURL: URL?) {
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

private final class SettingsMutationSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0

    func next() -> UInt64 {
        lock.withLock {
            current += 1
            return current
        }
    }
}

private final class SettingsMutationSequenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func store(_ next: UInt64) {
        lock.withLock { value = next }
    }

    func load() -> UInt64 {
        lock.withLock { value }
    }
}

private final class IsolatedFixtureKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PersistedRefreshCredential?

    func readCredential() -> KeychainLoadResult {
        lock.withLock {
            if let stored { return .found(stored) }
            return .notFound
        }
    }

    func saveCredential(_ credential: PersistedRefreshCredential) throws {
        lock.withLock { stored = credential }
    }

    func deleteCredential() {
        lock.withLock { stored = nil }
    }
}

private enum DraftSyncScope {
    case none
    case cacheLimitOnly
    case threadsOnly
    case all
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
    private var authGeneration: Int = 0
    private var playbackGeneration: Int = 0
    private var externalVideoGeneration: Int = 0
    private var cloudBrowserGeneration: Int = 0
    private var videoBrowserGeneration: Int = 0
    private var cloudBrowserIdleGeneration: Int = 0
    private var videoBrowserIdleGeneration: Int = 0
    private var browserBusyToken: Int = 0
    private var operationBusyToken: Int = 0
    private let settingsSequence = SettingsMutationSequence()
    private var lastAppliedSettingsSeq: UInt64 = 0
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
        let vm = CloudTuneViewModel(
            accountStore: isolatedStore,
            keychainBackend: IsolatedFixtureKeychainBackend(),
            enableLiveObservers: false
        )
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
        applyDraftSync(.all)
    }

    private func applyDraftSync(_ scope: DraftSyncScope) {
        switch scope {
        case .none:
            return
        case .cacheLimitOnly:
            cacheLimitDraft = String(committedSettings.cacheLimitMb)
        case .threadsOnly:
            downloadThreadsDraft = String(committedSettings.downloadThreads)
            cacheThreadsDraft = String(committedSettings.cacheThreads)
        case .all:
            cacheLimitDraft = String(committedSettings.cacheLimitMb)
            downloadThreadsDraft = String(committedSettings.downloadThreads)
            cacheThreadsDraft = String(committedSettings.cacheThreads)
        }
        if let previousError = settingsValidationError, statusMessage == previousError {
            statusMessage = nil
        }
        settingsValidationError = nil
    }

    public var hasUnsavedSettingsDrafts: Bool {
        cacheLimitDraft.trimmingCharacters(in: .whitespacesAndNewlines) != String(committedSettings.cacheLimitMb)
            || downloadThreadsDraft.trimmingCharacters(in: .whitespacesAndNewlines) != String(committedSettings.downloadThreads)
            || cacheThreadsDraft.trimmingCharacters(in: .whitespacesAndNewlines) != String(committedSettings.cacheThreads)
    }

    public func noteDraftEdited() {
        if let previousError = settingsValidationError, statusMessage == previousError {
            statusMessage = nil
        }
        settingsValidationError = nil
    }

    @discardableResult
    public func canCloseSettingsSurface() -> Bool {
        guard !hasUnsavedSettingsDrafts else {
            if settingsValidationError == nil {
                let msg = "尚有未应用的设置草稿，请先点击「应用」或「还原修改」后再关闭。"
                settingsValidationError = msg
                statusMessage = msg
            }
            return false
        }
        isShowingSettingsSheet = false
        return true
    }

    private func parseValidatedCacheLimitDraft() -> UInt64? {
        guard let parsed = UInt64(cacheLimitDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed >= AccountSettings.minCacheLimitMB else {
            let msg = "缓存上限至少设为 256 MB。"
            settingsValidationError = msg
            statusMessage = msg
            return nil
        }
        return parsed
    }

    private func parseValidatedTransferThreadsDraft() -> (downloadThreads: Int, cacheThreads: Int)? {
        guard let dl = Int(downloadThreadsDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...AccountSettings.maxDownloadThreads).contains(dl) else {
            let msg = "下载线程范围是 1-\(AccountSettings.maxDownloadThreads)"
            settingsValidationError = msg
            statusMessage = msg
            return nil
        }
        guard let ct = Int(cacheThreadsDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...AccountSettings.maxCacheThreads).contains(ct) else {
            let msg = "缓存线程范围是 1-\(AccountSettings.maxCacheThreads)"
            settingsValidationError = msg
            statusMessage = msg
            return nil
        }
        return (dl, ct)
    }

    @discardableResult
    public func commitPendingSettingsDraftsIfNeeded() async -> Bool {
        let cacheDirty = cacheLimitDraft.trimmingCharacters(in: .whitespacesAndNewlines) != String(committedSettings.cacheLimitMb)
        let threadsDirty = downloadThreadsDraft.trimmingCharacters(in: .whitespacesAndNewlines) != String(committedSettings.downloadThreads)
            || cacheThreadsDraft.trimmingCharacters(in: .whitespacesAndNewlines) != String(committedSettings.cacheThreads)
        guard cacheDirty || threadsDirty else {
            return true
        }

        let parsedCacheLimit: UInt64?
        if cacheDirty {
            guard let validLimit = parseValidatedCacheLimitDraft() else { return false }
            parsedCacheLimit = validLimit
        } else {
            parsedCacheLimit = nil
        }

        let parsedThreads: (downloadThreads: Int, cacheThreads: Int)?
        if threadsDirty {
            guard let validThreads = parseValidatedTransferThreadsDraft() else { return false }
            parsedThreads = validThreads
        } else {
            parsedThreads = nil
        }

        let successMessage: String = switch (cacheDirty, threadsDirty) {
        case (true, true): "设置已更新"
        case (true, false): "缓存限制已更新"
        case (false, true): "传输参数已更新"
        case (false, false): "设置已更新"
        }
        let syncScope: DraftSyncScope = switch (cacheDirty, threadsDirty) {
        case (true, true): .all
        case (true, false): .cacheLimitOnly
        case (false, true): .threadsOnly
        case (false, false): .none
        }

        guard await mutateCommittedSettings(
            successMessage: successMessage,
            draftSync: syncScope,
            { settings in
                if let parsedCacheLimit {
                    settings.cacheLimitMb = parsedCacheLimit
                }
                if let parsedThreads {
                    settings.downloadThreads = parsedThreads.downloadThreads
                    settings.cacheThreads = parsedThreads.cacheThreads
                }
            }
        ) else {
            return false
        }

        if parsedCacheLimit != nil, let capturedStore = cacheStore {
            let expectedAccount = activeAccountKey
            do {
                let pruned = try await capturedStore.pruneToLimit(limitBytes: committedSettings.cacheLimitBytes)
                if isAuthenticated, activeAccountKey == expectedAccount, cacheStore === capturedStore {
                    cacheUsageBytes = pruned
                }
            } catch {
                if isAuthenticated, activeAccountKey == expectedAccount {
                    statusMessage = "缓存清理遇到异常：\(error.localizedDescription)"
                }
            }
        }
        return true
    }

    @discardableResult
    public func commitCacheLimitDraft() async -> Bool {
        guard let parsed = parseValidatedCacheLimitDraft() else {
            return false
        }
        guard await mutateCommittedSettings(
            successMessage: "缓存限制已更新",
            draftSync: .cacheLimitOnly,
            { $0.cacheLimitMb = parsed }
        ) else {
            return false
        }
        if let capturedStore = cacheStore {
            let expectedAccount = activeAccountKey
            do {
                let pruned = try await capturedStore.pruneToLimit(limitBytes: committedSettings.cacheLimitBytes)
                if isAuthenticated, activeAccountKey == expectedAccount, cacheStore === capturedStore {
                    cacheUsageBytes = pruned
                }
            } catch {
                if isAuthenticated, activeAccountKey == expectedAccount {
                    statusMessage = "缓存清理遇到异常：\(error.localizedDescription)"
                }
            }
        }
        return true
    }

    @discardableResult
    public func commitTransferThreadsDraft() async -> Bool {
        guard let parsed = parseValidatedTransferThreadsDraft() else {
            return false
        }
        return await mutateCommittedSettings(
            successMessage: "传输参数已更新",
            draftSync: .threadsOnly,
            { settings in
                settings.downloadThreads = parsed.downloadThreads
                settings.cacheThreads = parsed.cacheThreads
            }
        )
    }

    public func updatePlaybackMode(_ mode: PlaybackMode) async {
        let msg = mode == .downloadFirst ? "已切到优先缓存播放" : "已切到边播边缓存"
        _ = await mutateCommittedSettings(successMessage: msg, draftSync: .none) {
            $0.playbackMode = mode
        }
    }

    public func setAppearanceMode(_ mode: AppearanceMode) async {
        appearancePreference = mode
        _ = await mutateCommittedSettings(
            successMessage: nil,
            failurePrefix: "保存外观设置失败",
            draftSync: .none
        ) {
            $0.appearanceMode = mode
        }
    }

    @discardableResult
    private func mutateCommittedSettings(
        expectedAccount: String? = nil,
        successMessage: String?,
        failurePrefix: String = "保存设置失败",
        draftSync: DraftSyncScope,
        _ transform: @escaping @Sendable (inout AccountSettings) -> Void
    ) async -> Bool {
        let targetAccount = expectedAccount ?? activeAccountKey
        guard let accountId = targetAccount else {
            guard expectedAccount == nil else { return false }
            var next = committedSettings
            transform(&next)
            committedSettings = next
            applyDraftSync(draftSync)
            if let successMessage {
                statusMessage = successMessage
            }
            return true
        }

        let baseSnapshot = committedSettings
        let seqBox = SettingsMutationSequenceBox()
        let sequenceGenerator = settingsSequence
        do {
            let updated = try await accountStore.mutateSettings(for: accountId, base: baseSnapshot) { settings in
                transform(&settings)
                seqBox.store(sequenceGenerator.next())
            }
            guard isAuthenticated, activeAccountKey == accountId else {
                return false
            }
            let seq = seqBox.load()
            if seq >= lastAppliedSettingsSeq {
                lastAppliedSettingsSeq = seq
                committedSettings = updated
            }
            applyDraftSync(draftSync)
            if let successMessage {
                statusMessage = successMessage
            }
            return true
        } catch {
            if isAuthenticated, activeAccountKey == accountId {
                statusMessage = "\(failurePrefix)：\(error.localizedDescription)"
            }
            return false
        }
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

    @discardableResult
    private func saveCredentialReportingIssue(_ credential: PersistedRefreshCredential) -> String? {
        do {
            try credentialMachine.save(credential, backend: keychainBackend)
            return nil
        } catch {
            let warning = "钥匙串保存凭据失败：\(error.localizedDescription)"
            statusMessage = warning
            return warning
        }
    }

    // MARK: - Bootstrap & Auth

    public func bootstrap(userInitiatedKeychainRetry: Bool = false) async {
        guard !isAuthenticated else { return }
        let expectedAuthGen = authGeneration
        isBootstrapping = true
        let assignedBusy = "同步本地配置..."
        busyLabel = assignedBusy
        operationBusyToken += 1
        let myBusyToken = operationBusyToken
        defer {
            if operationBusyToken == myBusyToken, busyLabel == assignedBusy {
                busyLabel = nil
            }
            if authGeneration == expectedAuthGen {
                isBootstrapping = false
            }
        }

        let migrated = await accountStore.migrateLegacyTauriDataIfPresent()
        guard authGeneration == expectedAuthGen, !isAuthenticated else { return }

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
            guard authGeneration == expectedAuthGen, !isAuthenticated else {
                await cloudClient.clearSession()
                return
            }
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
            guard isAuthenticated, activeAccountKey == identity.storageKey else { return }
            await browseTo(scope: .cloud, folderId: nil, nextBreadcrumbs: [.root], showBusy: false)
        } catch is CancellationError {
            return
        } catch {
            guard authGeneration == expectedAuthGen else { return }
            isAuthenticated = false
            statusMessage = error.localizedDescription
        }
    }

    public func beginQrLogin() async {
        qrPollTask?.cancel()
        let expectedAuthGen = authGeneration
        let assignedBusy = "生成二维码..."
        busyLabel = assignedBusy
        operationBusyToken += 1
        let myBusyToken = operationBusyToken
        defer {
            if operationBusyToken == myBusyToken, busyLabel == assignedBusy {
                busyLabel = nil
            }
        }
        do {
            let start = try await cloudClient.startQrLogin()
            guard authGeneration == expectedAuthGen, !isAuthenticated else { return }
            qrContent = start.qrContent
            qrHint = start.message
            statusMessage = start.message
            qrPNGData = QRCodeGenerator.generatePNGData(content: start.qrContent, dimension: 512)
            startQrPolling()
        } catch is CancellationError {
            return
        } catch {
            guard authGeneration == expectedAuthGen else { return }
            statusMessage = error.localizedDescription
        }
    }

    private func startQrPolling() {
        qrPollTask?.cancel()
        let expectedAuthGen = authGeneration
        qrPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(2500))
                } catch {
                    break
                }
                guard !Task.isCancelled, let self, self.authGeneration == expectedAuthGen else { break }
                do {
                    let poll = try await self.cloudClient.pollQrLogin()
                    guard !Task.isCancelled, self.authGeneration == expectedAuthGen else { return }
                    self.qrHint = poll.message
                    self.statusMessage = poll.message
                    switch poll.state {
                    case .authenticated:
                        let activeSession = await self.cloudClient.activeSession
                        let persisted = await self.cloudClient.persistedCredential
                        guard !Task.isCancelled, self.authGeneration == expectedAuthGen else {
                            await self.cloudClient.clearSession()
                            return
                        }
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
                        guard self.isAuthenticated, self.activeAccountKey == identity.storageKey else { return }
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
                    if self.authGeneration == expectedAuthGen {
                        self.statusMessage = error.localizedDescription
                    }
                    return
                }
            }
        }
    }

    public func completeEmbeddedWebLogin(callbackURL: URL, cookies: [HTTPCookie]) async {
        authGeneration += 1
        let loginAuthGen = authGeneration
        isBootstrapping = false
        let assignedBusy = "正在验证天翼登录会话..."
        busyLabel = assignedBusy
        operationBusyToken += 1
        let myBusyToken = operationBusyToken
        defer {
            if operationBusyToken == myBusyToken, busyLabel == assignedBusy {
                busyLabel = nil
            }
        }
        do {
            await cloudClient.importWebCookies(cookies)
            guard authGeneration == loginAuthGen else { return }
            let parsed = try await cloudClient.exchangeRedirectForSession(redirectURL: callbackURL.absoluteString)
            guard authGeneration == loginAuthGen else {
                await cloudClient.clearSession()
                return
            }
            let identity = Cloud189Protocol.resolveAccountIdentity(
                activeSession: parsed.activeSession,
                persistedCredential: parsed.persistedCredential
            )
            var credentialWarning: String?
            if let persisted = parsed.persistedCredential {
                credentialWarning = saveCredentialReportingIssue(persisted.withAccountKey(identity.storageKey))
            }
            isShowingWebLoginSheet = false
            qrPollTask?.cancel()
            qrContent = nil
            qrPNGData = nil
            await activateAuthenticatedAccount(
                storageKey: identity.storageKey,
                displayName: identity.displayName
            )
            guard isAuthenticated, activeAccountKey == identity.storageKey else { return }
            await browseTo(scope: .cloud, folderId: nil, nextBreadcrumbs: [.root], showBusy: false)
            guard isAuthenticated, activeAccountKey == identity.storageKey else { return }
            if let credentialWarning {
                statusMessage = "天翼官方网页登录成功（\(credentialWarning)）"
            } else {
                statusMessage = "天翼官方网页登录成功"
            }
        } catch is CancellationError {
            return
        } catch {
            guard authGeneration == loginAuthGen else { return }
            isShowingWebLoginSheet = false
            statusMessage = "网页登录回调兑换失败（\(error.localizedDescription)），已切换至二维码扫码登录，可保存二维码到相册后用天翼云盘 App 识别。"
            await beginQrLogin()
        }
    }

    public func activateAuthenticatedAccount(storageKey: String, displayName: String) async {
        if enableLiveObservers {
            setupPlayerAndRemoteCommands()
        }
        self.authGeneration += 1
        let expectedAuthGen = self.authGeneration
        self.isAuthenticated = true
        self.accountStorageKey = storageKey
        self.accountName = displayName
        self.credentialIssue = nil
        self.lastAppliedSettingsSeq = 0
        self.playbackGeneration += 1
        self.externalVideoGeneration += 1
        self.cloudBrowserGeneration += 1
        self.videoBrowserGeneration += 1
        self.cloudBrowserIdleGeneration = self.cloudBrowserGeneration
        self.videoBrowserIdleGeneration = self.videoBrowserGeneration

        do {
            let paths = try await accountStore.paths(for: storageKey)
            guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == storageKey else { return }
            let store = try CacheStore(cacheDirectory: paths.cacheDir, indexURL: paths.cacheIndexURL)
            self.cacheStore = store
            let bytes = await store.usageBytes()
            guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == storageKey, cacheStore === store else { return }
            self.cacheUsageBytes = bytes
        } catch {
            guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == storageKey else { return }
            self.cacheStore = nil
            self.cacheUsageBytes = 0
            self.statusMessage = "初始化本地缓存目录失败：\(error.localizedDescription)"
        }

        do {
            if let savedSettings = try await accountStore.loadSettingsIfPresent(for: storageKey) {
                guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == storageKey else { return }
                if lastAppliedSettingsSeq == 0 {
                    self.committedSettings = savedSettings
                    self.appearancePreference = savedSettings.appearanceMode
                    syncDraftsFromCommitted()
                }
            } else {
                guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == storageKey else { return }
                if lastAppliedSettingsSeq == 0 {
                    self.committedSettings = AccountSettings(appearanceMode: appearancePreference)
                    syncDraftsFromCommitted()
                }
            }
        } catch {
            guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == storageKey else { return }
            self.statusMessage = "读取账户设置失败：\(error.localizedDescription)"
        }

        do {
            let savedTracks = try await accountStore.loadLibrary(for: storageKey)
            guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == storageKey else { return }
            self.tracks = savedTracks
        } catch {
            guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == storageKey else { return }
            self.tracks = []
            self.statusMessage = "读取本地曲库索引失败：\(error.localizedDescription)"
        }

        await transferEngine.restorePersistedDownloads(for: storageKey, accountStore: accountStore)
        guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == storageKey else { return }
        let snap = await transferEngine.snapshot()
        guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == storageKey else { return }
        await handleTransferActivityChange(snapshot: snap, hasActive: snap.hasActiveItems)
    }

    public func logout() async {
        authGeneration += 1
        isBootstrapping = false
        qrPollTask?.cancel()
        qrPollTask = nil
        transferRefreshTask?.cancel()
        transferRefreshTask = nil
        playbackGeneration += 1
        externalVideoGeneration += 1
        cloudBrowserGeneration += 1
        videoBrowserGeneration += 1
        cloudBrowserIdleGeneration = cloudBrowserGeneration
        videoBrowserIdleGeneration = videoBrowserGeneration
        lastAppliedSettingsSeq = 0
        recoveryAttempts = 0
        prefetchedTrackId = nil
        prefetchingTrackId = nil
        wasPlayingBeforeInterruption = false
        teardownPlayerAndRemoteCommands()
        _player?.pause()
        _player?.replaceCurrentItem(with: nil)
        nowPlayingCoordinator.updateNowPlaying(metadata: nil, isPlaying: false, elapsedSeconds: 0, durationSeconds: 0)

        let previousAccountId = activeAccountKey
        isAuthenticated = false
        busyLabel = nil
        accountName = nil
        accountStorageKey = nil

        if let accountId = previousAccountId {
            let hash = Cloud189Protocol.accountBucketHash(for: accountId)
            await streamServer?.revokeAllSources(forAccountHash: hash)
            await transferEngine.cancelAll(forAccountId: accountId)
        }
        await cloudClient.clearSession()
        credentialMachine.clear(backend: keychainBackend)

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
        shareFileURL = nil
        pendingExternalVideoChoice = nil
        isShowingNowPlayingSheet = false
        isShowingSettingsSheet = false
        isShowingWebLoginSheet = false
        isShowingQueuePopover = false
        activeModule = .music
        transferSnapshot = TransferSnapshotPayload()
        committedSettings = AccountSettings(appearanceMode: appearancePreference)
        syncDraftsFromCommitted()
        statusMessage = "已退出登录并清理当前会话"
    }

    // MARK: - Decoupled Cloud & Video Folder Browsers + Library

    private func nextBrowserGeneration(for scope: BrowserScope) -> Int {
        switch scope {
        case .cloud:
            cloudBrowserGeneration += 1
            return cloudBrowserGeneration
        case .video:
            videoBrowserGeneration += 1
            return videoBrowserGeneration
        }
    }

    private func currentBrowserGeneration(for scope: BrowserScope) -> Int {
        switch scope {
        case .cloud: cloudBrowserGeneration
        case .video: videoBrowserGeneration
        }
    }

    public func browseTo(
        scope: BrowserScope = .cloud,
        folderId: String?,
        nextBreadcrumbs: [BreadcrumbItem],
        showBusy: Bool = true
    ) async {
        guard isAuthenticated else { return }
        let expectedAccount = activeAccountKey
        let gen = nextBrowserGeneration(for: scope)
        let assignedBusy: String?
        let myBusyToken: Int
        if showBusy {
            let label = "读取云盘目录..."
            busyLabel = label
            browserBusyToken += 1
            assignedBusy = label
            myBusyToken = browserBusyToken
        } else {
            assignedBusy = nil
            myBusyToken = 0
        }
        defer {
            if let assignedBusy, browserBusyToken == myBusyToken, busyLabel == assignedBusy {
                busyLabel = nil
            }
        }
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
            guard gen == currentBrowserGeneration(for: scope),
                  isAuthenticated,
                  activeAccountKey == expectedAccount else {
                return
            }
            let updatedPane = BrowserPaneState(breadcrumbs: nextBreadcrumbs, payload: listing)
            switch scope {
            case .cloud:
                cloudBrowser = updatedPane
                if isRoot && videoBrowser.payload == nil && videoBrowserGeneration == videoBrowserIdleGeneration {
                    videoBrowser = updatedPane
                }
            case .video:
                videoBrowser = updatedPane
                if isRoot && cloudBrowser.payload == nil && cloudBrowserGeneration == cloudBrowserIdleGeneration {
                    cloudBrowser = updatedPane
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard gen == currentBrowserGeneration(for: scope),
                  isAuthenticated,
                  activeAccountKey == expectedAccount else {
                return
            }
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
        let assignedBusy = "保存 \(displayName) 为音乐目录..."
        busyLabel = assignedBusy
        defer {
            if busyLabel == assignedBusy {
                busyLabel = nil
            }
        }
        let selection = FolderSelection(id: payload.currentFolderId, name: displayName)
        guard await mutateCommittedSettings(
            expectedAccount: accountId,
            successMessage: "音乐目录已设置为 \(displayName)",
            failurePrefix: "保存音乐目录失败",
            draftSync: .none,
            { $0.musicFolder = selection }
        ) else {
            return
        }
        await scanMusicLibrary(showBusy: false)
    }

    public func scanMusicLibrary(showBusy: Bool = true) async {
        guard isAuthenticated, let folder = committedSettings.musicFolder, let accountId = activeAccountKey else {
            statusMessage = "请先在云盘目录中设为音乐库。"
            return
        }
        let expectedAuthGen = authGeneration
        let assignedBusy: String?
        let myBusyToken: Int
        if showBusy {
            let label = "扫描 \(folder.name) 中的音乐..."
            busyLabel = label
            operationBusyToken += 1
            assignedBusy = label
            myBusyToken = operationBusyToken
        } else {
            assignedBusy = nil
            myBusyToken = 0
        }
        defer {
            if let assignedBusy, operationBusyToken == myBusyToken, busyLabel == assignedBusy {
                busyLabel = nil
            }
        }
        do {
            let scanned = try await cloudClient.scanMusicLibrary(folderId: folder.id, folderName: folder.name)
            guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == accountId else { return }
            tracks = scanned
            do {
                try await accountStore.saveLibrary(scanned, for: accountId)
                guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == accountId else { return }
                statusMessage = "已载入 \(scanned.count) 首音乐"
            } catch {
                guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == accountId else { return }
                statusMessage = "已载入 \(scanned.count) 首音乐（索引落盘失败：\(error.localizedDescription)）"
            }
        } catch is CancellationError {
            return
        } catch {
            guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == accountId else { return }
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

    public func playFromUpcomingQueue(_ track: TrackSummary) async {
        if upNextQueue.contains(where: { $0.id == track.id }) {
            upNextQueue = PlaybackQueueResolver.removeFromQueue(upNext: upNextQueue, trackId: track.id)
            prefetchedTrackId = nil
        }
        await playTrack(track)
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
                let usage = await cacheStore.usageBytes()
                guard gen == playbackGeneration, isAuthenticated else { return }
                cacheUsageBytes = usage
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
            guard generation == playbackGeneration, isAuthenticated else { return }
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
              let expectedAccount = activeAccountKey,
              Cloud189Protocol.accountBucketHash(for: expectedAccount) == accountHash else {
            return
        }
        let capturedStore = cacheStore
        let gen = playbackGeneration
        let capturedTrack = (currentTrackId == trackId) ? currentTrack : nil
        let fallbackAlbum = capturedTrack.map {
            $0.folderPath.isEmpty ? (committedSettings.musicFolder?.name ?? "天翼云盘") : $0.folderPath
        }

        if let capturedStore {
            let latestUsage = await capturedStore.usageBytes()
            guard isAuthenticated,
                  activeAccountKey == expectedAccount,
                  cacheStore === capturedStore else {
                return
            }
            cacheUsageBytes = latestUsage
        }

        guard isAuthenticated,
              activeAccountKey == expectedAccount,
              cacheStore === capturedStore,
              gen == playbackGeneration,
              currentTrackId == trackId,
              let track = capturedTrack ?? currentTrack else {
            return
        }
        let resolvedFallbackAlbum = fallbackAlbum
            ?? (track.folderPath.isEmpty ? (committedSettings.musicFolder?.name ?? "天翼云盘") : track.folderPath)
        let enriched = await AudioMetadataReader.readMetadata(
            from: localFileURL,
            fallbackTitle: track.name,
            fallbackAlbum: resolvedFallbackAlbum
        )
        guard isAuthenticated,
              activeAccountKey == expectedAccount,
              cacheStore === capturedStore,
              gen == playbackGeneration,
              currentTrackId == trackId else {
            return
        }
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
            if let firstUpNext = upNextQueue.first {
                upNextQueue = Array(upNextQueue.dropFirst())
                prefetchedTrackId = nil
                await playTrack(firstUpNext)
                return
            }
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
        guard isAuthenticated else { return }
        playbackGeneration += 1
        externalVideoGeneration += 1
        pendingExternalVideoChoice = nil
        let gen = playbackGeneration
        let expectedAccount = activeAccountKey
        recoveryAttempts = 0
        pauseIfPlaying()
        let assignedBusy = "准备视频流 \(video.name)..."
        busyLabel = assignedBusy
        defer {
            if busyLabel == assignedBusy {
                busyLabel = nil
            }
        }
        do {
            if let capturedStore = cacheStore, let cached = await capturedStore.existingCachedFile(trackId: video.id) {
                guard gen == playbackGeneration,
                      isAuthenticated,
                      activeAccountKey == expectedAccount,
                      cacheStore === capturedStore else {
                    return
                }
                activeVideoTrack = video
                activeVideoURL = cached
                statusMessage = "正在播放已缓存视频：\(video.name)"
                return
            }
            let remoteURL = try await cloudClient.resolveDownloadURL(fileId: video.id)
            guard gen == playbackGeneration,
                  isAuthenticated,
                  activeAccountKey == expectedAccount else {
                return
            }
            let playbackURL: URL
            if let streamServer, let capturedStore = cacheStore, let accountId = activeAccountKey, accountId == expectedAccount {
                let accountHash = Cloud189Protocol.accountBucketHash(for: accountId)
                let destURL = await capturedStore.cacheFileURL(trackId: video.id, originalFileName: video.name)
                guard gen == playbackGeneration,
                      isAuthenticated,
                      activeAccountKey == accountId,
                      cacheStore === capturedStore else {
                    return
                }
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
                    cacheStore: capturedStore
                )
            } else {
                playbackURL = remoteURL
            }
            guard gen == playbackGeneration,
                  isAuthenticated,
                  activeAccountKey == expectedAccount else {
                return
            }
            activeVideoTrack = video
            activeVideoURL = playbackURL
            statusMessage = "正在应用内播放视频：\(video.name)"
        } catch is CancellationError {
            return
        } catch {
            guard gen == playbackGeneration,
                  isAuthenticated,
                  activeAccountKey == expectedAccount else {
                return
            }
            statusMessage = error.localizedDescription
        }
    }

    /// Returns a local cached `file://` URL immediately if available; otherwise prepares a loopback stream URL
    /// (when `prepareLoopbackStream` is `true`) and sets `pendingExternalVideoChoice` so callers NEVER hand raw `https://` URLs to a web browser.
    public func requestExternalVideoPlayback(
        _ video: TrackSummary,
        prepareLoopbackStream: Bool = true
    ) async -> URL? {
        guard isAuthenticated else { return nil }
        externalVideoGeneration += 1
        let extGen = externalVideoGeneration
        let expectedAccount = activeAccountKey
        let assignedBusy = "检查本地视频缓存 \(video.name)..."
        busyLabel = assignedBusy
        defer {
            if busyLabel == assignedBusy {
                busyLabel = nil
            }
        }
        if let capturedStore = cacheStore, let cached = await capturedStore.existingCachedFile(trackId: video.id) {
            guard extGen == externalVideoGeneration,
                  isAuthenticated,
                  activeAccountKey == expectedAccount,
                  cacheStore === capturedStore else {
                return nil
            }
            shareFileURL = cached
            return cached
        }
        guard extGen == externalVideoGeneration,
              isAuthenticated,
              activeAccountKey == expectedAccount else {
            return nil
        }
        guard prepareLoopbackStream else {
            pendingExternalVideoChoice = PendingExternalVideoChoice(video: video, streamURL: nil)
            return nil
        }
        do {
            let remoteURL = try await cloudClient.resolveDownloadURL(fileId: video.id)
            guard extGen == externalVideoGeneration,
                  isAuthenticated,
                  activeAccountKey == expectedAccount else {
                return nil
            }
            let loopbackStreamURL: URL?
            if let streamServer, let capturedStore = cacheStore, let accountId = activeAccountKey, accountId == expectedAccount {
                let accountHash = Cloud189Protocol.accountBucketHash(for: accountId)
                let destURL = await capturedStore.cacheFileURL(trackId: video.id, originalFileName: video.name)
                guard extGen == externalVideoGeneration,
                      isAuthenticated,
                      activeAccountKey == expectedAccount,
                      cacheStore === capturedStore else {
                    return nil
                }
                loopbackStreamURL = await streamServer.registerSource(
                    StreamSourceRegistration(
                        accountHash: accountHash,
                        trackId: video.id,
                        remoteURL: remoteURL,
                        cacheDestinationURL: destURL,
                        expectedSize: video.sizeBytes,
                        fileName: video.name,
                        cacheLimitBytes: committedSettings.cacheLimitBytes
                    ),
                    cacheStore: capturedStore
                )
            } else {
                loopbackStreamURL = nil
            }
            guard extGen == externalVideoGeneration,
                  isAuthenticated,
                  activeAccountKey == expectedAccount else {
                return nil
            }
            pendingExternalVideoChoice = PendingExternalVideoChoice(video: video, streamURL: loopbackStreamURL)
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            guard extGen == externalVideoGeneration,
                  isAuthenticated,
                  activeAccountKey == expectedAccount else {
                return nil
            }
            statusMessage = "获取视频源失败：\(error.localizedDescription)"
            return nil
        }
    }

    public func downloadVideoAndPrepareLocalFile(_ video: TrackSummary) async -> URL? {
        guard isAuthenticated, let accountId = activeAccountKey, let capturedStore = cacheStore else {
            statusMessage = "请先登录后再缓存视频。"
            return nil
        }
        externalVideoGeneration += 1
        let extGen = externalVideoGeneration
        pendingExternalVideoChoice = nil
        let assignedBusy = "正在下载视频至本地缓存：《\(video.name)》..."
        busyLabel = assignedBusy
        defer {
            if busyLabel == assignedBusy {
                busyLabel = nil
            }
        }
        let accountHash = Cloud189Protocol.accountBucketHash(for: accountId)
        do {
            let localURL = try await transferEngine.downloadTrackToCache(
                track: video,
                cacheStore: capturedStore,
                parallelThreads: committedSettings.downloadThreads,
                cacheLimitBytes: max(committedSettings.cacheLimitBytes, video.sizeBytes),
                kind: "playback",
                accountHash: accountHash
            )
            guard extGen == externalVideoGeneration,
                  isAuthenticated,
                  activeAccountKey == accountId,
                  cacheStore === capturedStore else {
                return nil
            }
            let latestUsage = await capturedStore.usageBytes()
            guard extGen == externalVideoGeneration,
                  isAuthenticated,
                  activeAccountKey == accountId,
                  cacheStore === capturedStore else {
                return nil
            }
            cacheUsageBytes = latestUsage
            shareFileURL = localURL
            statusMessage = "视频缓存完成，正在调用本地播放器打开"
            return localURL
        } catch is CancellationError {
            return nil
        } catch {
            guard extGen == externalVideoGeneration,
                  isAuthenticated,
                  activeAccountKey == accountId else {
                return nil
            }
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
        let baseSnapshot = committedSettings
        let seqBox = SettingsMutationSequenceBox()
        let sequenceGenerator = settingsSequence
        do {
            let result = try await accountStore.saveExportDirectoryBookmarkAndSettings(
                url,
                baseSettings: baseSnapshot,
                for: accountId,
                afterMutate: {
                    seqBox.store(sequenceGenerator.next())
                }
            )
            guard isAuthenticated, activeAccountKey == accountId else { return }
            let seq = seqBox.load()
            if seq >= lastAppliedSettingsSeq {
                lastAppliedSettingsSeq = seq
                committedSettings = result.settings
            }
            statusMessage = "下载导出目录已设为 \(result.displayName)"
        } catch {
            guard isAuthenticated, activeAccountKey == accountId else { return }
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
                                let expectedAccount = self.activeAccountKey
                                let bytes = await store.usageBytes()
                                if self.isAuthenticated, self.activeAccountKey == expectedAccount, self.cacheStore === store {
                                    self.cacheUsageBytes = bytes
                                }
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
                let expectedAccount = activeAccountKey
                let bytes = await store.usageBytes()
                if isAuthenticated, activeAccountKey == expectedAccount, cacheStore === store {
                    cacheUsageBytes = bytes
                }
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
