import AVFoundation
import CloudTuneCore
import Foundation
import Observation

package enum BrowserScope: Sendable {
    case cloud
    case video
}

package struct BrowserPaneState: Equatable, Sendable {
    package var breadcrumbs: [BreadcrumbItem]
    package var payload: FolderBrowsePayload?

    package init(breadcrumbs: [BreadcrumbItem] = [.root], payload: FolderBrowsePayload? = nil) {
        self.breadcrumbs = breadcrumbs
        self.payload = payload
    }
}

package struct PendingExternalVideoChoice: Equatable, Identifiable, Sendable {
    package var id: String { video.id }
    package let video: TrackSummary
    package let streamURL: URL?

    package init(video: TrackSummary, streamURL: URL?) {
        self.video = video
        self.streamURL = streamURL
    }
}

@MainActor
@Observable
package final class PlaybackTimeline {
    package var currentTime: Double = 0
    package var duration: Double = 0

    package init(currentTime: Double = 0, duration: Double = 0) {
        self.currentTime = currentTime
        self.duration = duration
    }

    package func reset() {
        currentTime = 0
        duration = 0
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

    package var appearancePreference: AppearanceMode = .system {
        didSet {
            if persistPreferencesToDefaults {
                userDefaults.set(appearancePreference.rawValue, forKey: Self.appearanceDefaultsKey)
            }
        }
    }
    package var activeModule: ModuleTab = .music

    package var isBootstrapping: Bool = false
    package var busyLabel: String?
    package var statusMessage: String? {
        didSet {
            if statusMessage == nil {
                statusKind = .info
            }
        }
    }
    package var statusKind: StatusKind = .info
    package var credentialIssue: CredentialIssue?

    package func setStatus(_ message: String?, kind: StatusKind = .info) {
        if let message {
            statusKind = kind
            statusMessage = message
        } else {
            statusMessage = nil
            statusKind = .info
        }
    }

    package var isAuthenticated: Bool = false
    package var accountName: String?
    package private(set) var accountStorageKey: String?

    // Strictly separated committed vs draft settings
    package private(set) var committedSettings: AccountSettings = AccountSettings()
    package var cacheLimitDraft: String = "1024"
    package var downloadThreadsDraft: String = "8"
    package var cacheThreadsDraft: String = "4"
    package var settingsValidationError: String?

    package var cacheUsageBytes: UInt64 = 0

    // Login state
    package var qrContent: String?
    package var qrPNGData: Data?
    package var qrHint: String?
    package var isShowingWebLoginSheet: Bool = false

    // Decoupled Cloud & Video browsers + library
    package var cloudBrowser = BrowserPaneState()
    package var videoBrowser = BrowserPaneState()
    package var tracks: [TrackSummary] = [] {
        didSet {
            rebuildTrackLookups()
            if shuffle {
                shuffleOrderIds = PlaybackQueueResolver.buildShuffleOrder(
                    tracks: tracks,
                    anchorTrackId: currentTrackId
                )
            } else {
                rebuildOrderedQueueCache()
            }
            recomputeVisibleTracks(force: true)
            syncRemoteCommandAvailability()
        }
    }
    package var searchQuery: String = "" {
        didSet {
            recomputeVisibleTracks(force: false)
        }
    }
    package private(set) var visibleTracks: [TrackSummary] = []
    @ObservationIgnored package private(set) var tracksById: [String: TrackSummary] = [:]
    @ObservationIgnored package private(set) var trackIndexById: [String: Int] = [:]
    @ObservationIgnored private var orderedLibraryTracksCache: [TrackSummary] = []
    @ObservationIgnored private var orderedIndexByIdCache: [String: Int] = [:]
    @ObservationIgnored private var upNextTrackIdSet: Set<String> = []
    @ObservationIgnored private var lastNormalizedSearchQuery: String = ""

    // Isolated high-frequency playback clock
    package let timeline = PlaybackTimeline()
    package var currentTime: Double {
        get { timeline.currentTime }
        set { timeline.currentTime = newValue }
    }
    package var duration: Double {
        get { timeline.duration }
        set { timeline.duration = newValue }
    }

    // Playback & unified queue state
    package var activeTrack: TrackSummary? {
        didSet { syncRemoteCommandAvailability() }
    }
    package var currentTrackId: String? {
        didSet { syncRemoteCommandAvailability() }
    }
    package var nowPlayingMetadata: NowPlayingMetadata?
    package var isPlaying: Bool = false
    package var loadingTrackId: String?
    package var shuffle: Bool = true {
        didSet {
            if shuffle {
                shuffleOrderIds = PlaybackQueueResolver.buildShuffleOrder(
                    tracks: tracks,
                    anchorTrackId: currentTrackId
                )
            } else {
                rebuildOrderedQueueCache()
            }
            syncRemoteCommandAvailability()
        }
    }
    package var loopMode: LoopMode = .all {
        didSet { syncRemoteCommandAvailability() }
    }
    package var volume: Double = 0.85 {
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
    package var upNextQueue: [TrackSummary] = [] {
        didSet {
            upNextTrackIdSet = Set(upNextQueue.map(\.id))
            syncRemoteCommandAvailability()
        }
    }
    package private(set) var shuffleOrderIds: [String] = [] {
        didSet {
            rebuildOrderedQueueCache()
        }
    }

    // Presentation state (shared across live app & offscreen snapshot scenes)
    package var isShowingNowPlaying: Bool = false
    package var isShowingSettingsSheet: Bool = false

    // Video sheet / external handoff state
    package var activeVideoURL: URL? {
        didSet {
            if activeVideoURL == nil {
                activeVideoTrack = nil
                if let token = activeVideoSourceToken {
                    activeVideoSourceToken = nil
                    let server = streamServer
                    Task { await server?.revokeSource(token: token) }
                }
            }
        }
    }
    package var activeVideoTrack: TrackSummary?
    package var shareFileURL: URL?
    package var pendingExternalVideoChoice: PendingExternalVideoChoice?

    // Transfers
    package var transferSnapshot: TransferSnapshotPayload = TransferSnapshotPayload()

    // Runtime collaborators
    package let cloudClient: Cloud189Client
    package let accountStore: AccountScopedStore
    package let semaphore: GlobalTransferSemaphore
    package let streamServer: StreamProxyServer?
    package let transferEngine: TransferEngine
    package private(set) var hasActivePlayerObservers: Bool = false

    private let keychainBackend: KeychainBackend
    private let userDefaults: UserDefaults
    private let persistPreferencesToDefaults: Bool
    private let enableLiveObservers: Bool
    private var credentialMachine = CredentialStateMachine()
    private var cacheStore: CacheStore?
    private let nowPlayingCoordinator = NowPlayingCoordinator()

    @ObservationIgnored private var _player: AVPlayer?
    package var player: AVPlayer {
        if let existing = _player {
            return existing
        }
        let created = AVPlayer()
        created.volume = Float(volume)
        _player = created
        return created
    }
    @ObservationIgnored private weak var currentPlayerItem: AVPlayerItem?
    @ObservationIgnored private var timeObserverToken: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failObserver: NSObjectProtocol?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var activeSeekToken: UInt64 = 0
    @ObservationIgnored private var isSeekingPlayback: Bool = false
    private var qrPollTask: Task<Void, Never>?
    private var transferRefreshTask: Task<Void, Never>?
    private var retrySleepTask: Task<Void, Error>?
    private var prefetchTask: Task<Void, Never>?
    private var activeAudioSourceToken: String?
    private var activeVideoSourceToken: String?
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
    private var lastAppliedSettingsSeq: UInt64 = 0
    private var recoveryAttempts: Int = 0
    private var currentPlaybackIsLoopback: Bool = false
    private var wasPlayingBeforeInterruption: Bool = false
    package var retryBaseDelayMs: Int = 1500

    public convenience init() {
        self.init(enableLiveObservers: true)
    }

    package init(
        cloudClient: Cloud189Client = Cloud189Client(),
        accountStore: AccountScopedStore? = nil,
        keychainBackend: KeychainBackend = SystemKeychainBackend(),
        semaphore: GlobalTransferSemaphore = GlobalTransferSemaphore(maxPermits: 8),
        upstreamFetcher: UpstreamStreamFetcher = URLSessionUpstreamStreamFetcher(),
        userDefaults: UserDefaults = .standard,
        enableLiveObservers: Bool
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

        let engine = TransferEngine(semaphore: semaphore, fetcher: upstreamFetcher) { [cloudClient] trackId in
            try await cloudClient.resolveDownloadURL(fileId: trackId)
        }
        self.transferEngine = engine

        let writeThroughRelay = WriteThroughEventRelay()
        var startupWarning = resolvedStore.warning
        if enableLiveObservers {
            do {
                self.streamServer = try StreamProxyServer(
                    semaphore: semaphore,
                    fetcher: upstreamFetcher,
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
            self.setStatus(startupWarning, kind: .error)
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

    #if DEBUG
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
            keychainBackend: InMemoryKeychainBackend(),
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
            vm.setStatus(fixture.qrLogin.message, kind: .info)
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
            if scene == .errorBanner {
                vm.setStatus(fixture.errorBanner.statusMessage, kind: .error)
            } else {
                vm.setStatus(fixture.nowPlaying.statusMessage, kind: .info)
            }

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
                vm.isShowingNowPlaying = true
            default:
                vm.activeModule = .music
            }
        }
        return vm
    }
    #endif

    private func rebuildTrackLookups() {
        var byId: [String: TrackSummary] = [:]
        var indexById: [String: Int] = [:]
        byId.reserveCapacity(tracks.count)
        indexById.reserveCapacity(tracks.count)
        for (idx, track) in tracks.enumerated() where byId[track.id] == nil {
            byId[track.id] = track
            indexById[track.id] = idx
        }
        tracksById = byId
        trackIndexById = indexById
    }

    private func rebuildOrderedQueueCache() {
        if shuffle && tracks.count > 1 {
            let ordered = PlaybackQueueResolver.orderedBaseTracks(
                libraryTracks: tracks,
                shuffle: true,
                shuffleOrderIds: shuffleOrderIds,
                tracksById: tracksById
            )
            var idxMap: [String: Int] = [:]
            idxMap.reserveCapacity(ordered.count)
            for (idx, item) in ordered.enumerated() where idxMap[item.id] == nil {
                idxMap[item.id] = idx
            }
            orderedLibraryTracksCache = ordered
            orderedIndexByIdCache = idxMap
        } else {
            orderedLibraryTracksCache = tracks
            orderedIndexByIdCache = trackIndexById
        }
    }

    private func recomputeVisibleTracks(force: Bool) {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !force && trimmed == lastNormalizedSearchQuery {
            return
        }
        lastNormalizedSearchQuery = trimmed
        if trimmed.isEmpty {
            visibleTracks = tracks
        } else {
            visibleTracks = tracks.filter {
                $0.name.lowercased().contains(trimmed) || $0.folderPath.lowercased().contains(trimmed)
            }
        }
    }

    package func isManualUpNext(trackId: String) -> Bool {
        _ = upNextQueue.count
        return upNextTrackIdSet.contains(trackId)
    }

    #if DEBUG
    package nonisolated func invokeRemoteCommandForTesting(_ command: TestableRemoteCommand) -> Bool {
        nowPlayingCoordinator.invokeRemoteCommandForTesting(command)
    }
    #endif

    package var currentTrack: TrackSummary? {
        if let activeTrack, activeTrack.id == currentTrackId || currentTrackId == nil {
            return activeTrack
        }
        guard let currentTrackId else { return nil }
        _ = tracks.count
        return tracksById[currentTrackId]
            ?? cloudBrowser.payload?.audioFiles.first { $0.id == currentTrackId }
            ?? activeTrack
    }

    package var upcomingTracks: [TrackSummary] {
        _ = tracks.count
        _ = shuffleOrderIds.count
        return PlaybackQueueResolver.upcomingPreview(
            currentTrack: currentTrack,
            libraryTracks: tracks,
            upNextQueue: upNextQueue,
            shuffle: shuffle,
            shuffleOrderIds: shuffleOrderIds,
            loopMode: loopMode,
            limit: 20,
            orderedTracks: orderedLibraryTracksCache,
            orderedIndexById: orderedIndexByIdCache
        )
    }

    package var canSkipNext: Bool {
        _ = tracks.count
        _ = shuffleOrderIds.count
        return PlaybackQueueResolver.canSkipNext(
            currentTrack: currentTrack,
            libraryTracks: tracks,
            upNextQueue: upNextQueue,
            shuffle: shuffle,
            shuffleOrderIds: shuffleOrderIds,
            loopMode: loopMode,
            orderedTracks: orderedLibraryTracksCache,
            orderedIndexById: orderedIndexByIdCache
        )
    }

    package var canSkipPrevious: Bool {
        _ = tracks.count
        _ = shuffleOrderIds.count
        return PlaybackQueueResolver.canSkipPrevious(
            currentTrack: currentTrack,
            libraryTracks: tracks,
            shuffle: shuffle,
            shuffleOrderIds: shuffleOrderIds,
            loopMode: loopMode,
            orderedTracks: orderedLibraryTracksCache,
            orderedIndexById: orderedIndexByIdCache
        )
    }

    package var downloadTransfers: [TransferStatus] {
        transferSnapshot.items.filter { $0.kind == "download" }
    }

    package var activeStreamAndCacheTransfers: [TransferStatus] {
        transferSnapshot.items.filter { $0.kind != "download" }
    }

    package var downloadableBrowserFiles: [TrackSummary] {
        guard let payload = cloudBrowser.payload else { return [] }
        return payload.audioFiles + payload.videoFiles + payload.otherFiles
    }

    package var qrHost: String? {
        guard let qrContent, let url = URL(string: qrContent) else { return nil }
        return url.host
    }

    // MARK: - Settings Draft Safety & Checked Persistence

    package func syncDraftsFromCommitted() {
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

    package var hasUnsavedSettingsDrafts: Bool {
        cacheLimitDraft.trimmingCharacters(in: .whitespacesAndNewlines) != String(committedSettings.cacheLimitMb)
            || downloadThreadsDraft.trimmingCharacters(in: .whitespacesAndNewlines) != String(committedSettings.downloadThreads)
            || cacheThreadsDraft.trimmingCharacters(in: .whitespacesAndNewlines) != String(committedSettings.cacheThreads)
    }

    package func noteDraftEdited() {
        if let previousError = settingsValidationError, statusMessage == previousError {
            statusMessage = nil
        }
        settingsValidationError = nil
    }

    @discardableResult
    package func canCloseSettingsSurface() -> Bool {
        guard !hasUnsavedSettingsDrafts else {
            if settingsValidationError == nil {
                let msg = "尚有未应用的设置草稿，请先点击「应用」或「还原修改」后再关闭。"
                settingsValidationError = msg
                setStatus(msg, kind: .error)
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
            setStatus(msg, kind: .error)
            return nil
        }
        return parsed
    }

    private func parseValidatedTransferThreadsDraft() -> (downloadThreads: Int, cacheThreads: Int)? {
        guard let dl = Int(downloadThreadsDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...AccountSettings.maxDownloadThreads).contains(dl) else {
            let msg = "下载线程范围是 1-\(AccountSettings.maxDownloadThreads)"
            settingsValidationError = msg
            setStatus(msg, kind: .error)
            return nil
        }
        guard let ct = Int(cacheThreadsDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...AccountSettings.maxCacheThreads).contains(ct) else {
            let msg = "缓存线程范围是 1-\(AccountSettings.maxCacheThreads)"
            settingsValidationError = msg
            setStatus(msg, kind: .error)
            return nil
        }
        return (dl, ct)
    }

    @discardableResult
    package func commitPendingSettingsDraftsIfNeeded() async -> Bool {
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
                    setStatus("缓存清理遇到异常：\(error.localizedDescription)", kind: .error)
                }
            }
        }
        return true
    }

    @discardableResult
    package func commitCacheLimitDraft() async -> Bool {
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
                    setStatus("缓存清理遇到异常：\(error.localizedDescription)", kind: .error)
                }
            }
        }
        return true
    }

    @discardableResult
    package func commitTransferThreadsDraft() async -> Bool {
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

    package func updatePlaybackMode(_ mode: PlaybackMode) async {
        let msg = mode == .downloadFirst ? "已切到优先缓存播放" : "已切到边播边缓存"
        _ = await mutateCommittedSettings(successMessage: msg, draftSync: .none) {
            $0.playbackMode = mode
        }
    }

    package func setAppearanceMode(_ mode: AppearanceMode) async {
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
                setStatus(successMessage, kind: .info)
            }
            return true
        }

        let baseSnapshot = committedSettings
        do {
            let mutated = try await accountStore.mutateSettings(
                for: accountId,
                base: baseSnapshot,
                transform
            )
            guard isAuthenticated, activeAccountKey == accountId else {
                return false
            }
            if mutated.sequence >= lastAppliedSettingsSeq {
                lastAppliedSettingsSeq = mutated.sequence
                committedSettings = mutated.settings
            }
            applyDraftSync(draftSync)
            if let successMessage {
                setStatus(successMessage, kind: .info)
            }
            return true
        } catch {
            if isAuthenticated, activeAccountKey == accountId {
                setStatus("\(failurePrefix)：\(error.localizedDescription)", kind: .error)
            }
            return false
        }
    }

    private var activeAccountKey: String? {
        accountStorageKey?.trimmedNilIfEmpty ?? accountName?.nilIfNotDefaultDisplayName
    }

    @discardableResult
    private func saveCredentialReportingIssue(_ credential: PersistedRefreshCredential) -> String? {
        do {
            try credentialMachine.save(credential, backend: keychainBackend)
            return nil
        } catch {
            let warning = "钥匙串保存凭据失败：\(error.localizedDescription)"
            setStatus(warning, kind: .error)
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
            setStatus(issue.userMessage, kind: .error)
            return
        }
        guard let storedCred else {
            isAuthenticated = false
            return
        }

        do {
            let (sessionPayload, clientEpoch) = try await cloudClient.restoreSessionWithEpoch(storedCred)
            guard authGeneration == expectedAuthGen, !isAuthenticated else {
                await cloudClient.clearSession(ifEpoch: clientEpoch)
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
            setStatus(error.localizedDescription, kind: .error)
        }
    }

    package func beginQrLogin() async {
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
            setStatus(start.message, kind: .info)
            qrPNGData = QRCodeGenerator.generatePNGData(content: start.qrContent, dimension: 512)
            startQrPolling()
        } catch is CancellationError {
            return
        } catch {
            guard authGeneration == expectedAuthGen else { return }
            setStatus(error.localizedDescription, kind: .error)
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
                    self.setStatus(poll.message, kind: .info)
                    switch poll.state {
                    case .authenticated:
                        let clientEpoch = poll.sessionEpoch
                        guard !Task.isCancelled, self.authGeneration == expectedAuthGen else {
                            if let clientEpoch {
                                await self.cloudClient.clearSession(ifEpoch: clientEpoch)
                            }
                            return
                        }
                        guard let snapshot = await self.cloudClient.sessionSnapshot(forEpoch: clientEpoch) else {
                            return
                        }
                        let activeSession = snapshot.active
                        let persisted = snapshot.persisted
                        guard !Task.isCancelled, self.authGeneration == expectedAuthGen else {
                            if let clientEpoch {
                                await self.cloudClient.clearSession(ifEpoch: clientEpoch)
                            }
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
                        self.setStatus(error.localizedDescription, kind: .error)
                    }
                    return
                }
            }
        }
    }

    package func completeEmbeddedWebLogin(callbackURL: URL, cookies: [HTTPCookie]) async {
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
        qrPollTask?.cancel()
        qrPollTask = nil
        do {
            await cloudClient.invalidateInFlightAuth()
            guard authGeneration == loginAuthGen else { return }
            await cloudClient.importWebCookies(cookies)
            guard authGeneration == loginAuthGen else { return }
            let (parsed, clientEpoch) = try await cloudClient.exchangeRedirectForSessionWithEpoch(redirectURL: callbackURL.absoluteString)
            guard authGeneration == loginAuthGen else {
                await cloudClient.clearSession(ifEpoch: clientEpoch)
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
                setStatus("天翼官方网页登录成功（\(credentialWarning)）", kind: .error)
            } else {
                setStatus("天翼官方网页登录成功", kind: .info)
            }
        } catch is CancellationError {
            return
        } catch {
            guard authGeneration == loginAuthGen else { return }
            isShowingWebLoginSheet = false
            setStatus(
                "网页登录回调兑换失败（\(error.localizedDescription)），已切换至二维码扫码登录，可保存二维码到相册后用天翼云盘 App 识别。",
                kind: .error
            )
            await beginQrLogin()
        }
    }

    package func activateAuthenticatedAccount(storageKey: String, displayName: String) async {
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
        self.retrySleepTask?.cancel()
        self.retrySleepTask = nil
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
            self.setStatus("初始化本地缓存目录失败：\(error.localizedDescription)", kind: .error)
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
            self.setStatus("读取账户设置失败：\(error.localizedDescription)", kind: .error)
        }

        do {
            let savedTracks = try await accountStore.loadLibrary(for: storageKey)
            guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == storageKey else { return }
            self.tracks = savedTracks
        } catch {
            guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == storageKey else { return }
            self.tracks = []
            self.setStatus("读取本地曲库索引失败：\(error.localizedDescription)", kind: .error)
        }

        await transferEngine.restorePersistedDownloads(for: storageKey, accountStore: accountStore)
        guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == storageKey else { return }
        let snap = await transferEngine.snapshot()
        guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == storageKey else { return }
        await handleTransferActivityChange(snapshot: snap, hasActive: snap.hasActiveItems)
    }

    package func logout() async {
        authGeneration += 1
        isBootstrapping = false
        qrPollTask?.cancel()
        qrPollTask = nil
        transferRefreshTask?.cancel()
        transferRefreshTask = nil
        retrySleepTask?.cancel()
        retrySleepTask = nil
        playbackGeneration += 1
        externalVideoGeneration += 1
        cloudBrowserGeneration += 1
        videoBrowserGeneration += 1
        cloudBrowserIdleGeneration = cloudBrowserGeneration
        videoBrowserIdleGeneration = videoBrowserGeneration
        lastAppliedSettingsSeq = 0
        recoveryAttempts = 0
        cancelPrefetchTask()
        activeAudioSourceToken = nil
        activeVideoSourceToken = nil
        prefetchedTrackId = nil
        wasPlayingBeforeInterruption = false
        currentPlayerItem = nil
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
        activeSeekToken &+= 1
        isSeekingPlayback = false
        timeline.reset()
        activeVideoURL = nil
        activeVideoTrack = nil
        shareFileURL = nil
        pendingExternalVideoChoice = nil
        isShowingNowPlaying = false
        isShowingSettingsSheet = false
        isShowingWebLoginSheet = false
        activeModule = .music
        transferSnapshot = TransferSnapshotPayload()
        committedSettings = AccountSettings(appearanceMode: appearancePreference)
        syncDraftsFromCommitted()
        setStatus("已退出登录并清理当前会话", kind: .info)
    }

    package func shutdownForTermination() {
        qrPollTask?.cancel()
        qrPollTask = nil
        transferRefreshTask?.cancel()
        transferRefreshTask = nil
        retrySleepTask?.cancel()
        retrySleepTask = nil
        cancelPrefetchTask()
        currentPlayerItem = nil
        teardownPlayerAndRemoteCommands()
        _player?.pause()
        _player?.replaceCurrentItem(with: nil)
        nowPlayingCoordinator.updateNowPlaying(metadata: nil, isPlaying: false, elapsedSeconds: 0, durationSeconds: 0)
        streamServer?.shutdownImmediate()
        transferEngine.cancelAllImmediate()
    }

    private func cancelPrefetchTask() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchingTrackId = nil
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

    package func browseTo(
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
            setStatus(error.localizedDescription, kind: .error)
        }
    }

    package func navigateBackInBrowser(scope: BrowserScope) async {
        let crumbs = (scope == .cloud) ? cloudBrowser.breadcrumbs : videoBrowser.breadcrumbs
        guard crumbs.count > 1 else { return }
        let nextCrumbs = Array(crumbs.dropLast())
        let targetId = nextCrumbs.last?.id
        await browseTo(scope: scope, folderId: targetId, nextBreadcrumbs: nextCrumbs)
    }

    package func setFolderAsMusicLibrary(from pane: BrowserPaneState) async {
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

    package func scanMusicLibrary(showBusy: Bool = true) async {
        guard isAuthenticated, let folder = committedSettings.musicFolder, let accountId = activeAccountKey else {
            setStatus("请先在云盘目录中设为音乐库。", kind: .info)
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
                setStatus("已载入 \(scanned.count) 首音乐", kind: .info)
            } catch {
                guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == accountId else { return }
                setStatus("已载入 \(scanned.count) 首音乐（索引落盘失败：\(error.localizedDescription)）", kind: .error)
            }
        } catch is CancellationError {
            return
        } catch {
            guard authGeneration == expectedAuthGen, isAuthenticated, activeAccountKey == accountId else { return }
            setStatus(error.localizedDescription, kind: .error)
        }
    }

    // MARK: - Playback, Queue & Write-Through Backfill

    package func playNext(_ track: TrackSummary) {
        cancelPrefetchTask()
        prefetchedTrackId = nil
        upNextQueue = PlaybackQueueResolver.insertPlayNext(upNext: upNextQueue, track: track)
        setStatus("已设为下一首播放：《\(track.name)》", kind: .info)
        triggerPrefetchIfNeeded()
    }

    package func appendToQueue(_ track: TrackSummary) {
        upNextQueue = PlaybackQueueResolver.appendToQueue(upNext: upNextQueue, track: track)
        setStatus("已加入待播队列：《\(track.name)》", kind: .info)
    }

    package func removeFromQueue(trackId: String) {
        upNextQueue = PlaybackQueueResolver.removeFromQueue(upNext: upNextQueue, trackId: trackId)
    }

    package func clearUpNextQueue() {
        upNextQueue = []
    }

    package func playFromUpcomingQueue(_ track: TrackSummary) async {
        if upNextQueue.contains(where: { $0.id == track.id }) {
            upNextQueue = PlaybackQueueResolver.removeFromQueue(upNext: upNextQueue, trackId: track.id)
            prefetchedTrackId = nil
        }
        await playTrack(track)
    }

    package func toggleShuffle() {
        cancelPrefetchTask()
        prefetchedTrackId = nil
        shuffle.toggle()
        triggerPrefetchIfNeeded()
    }

    package func cycleLoopMode() {
        loopMode = switch loopMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        if loopMode == .one {
            cancelPrefetchTask()
        } else {
            triggerPrefetchIfNeeded()
        }
    }

    package func setVolume(_ nextVolume: Double) {
        volume = nextVolume
    }

    package func playTrack(
        _ track: TrackSummary,
        modeOverride: PlaybackMode? = nil,
        forceStreamProxy: Bool = false,
        resumeTime: Double = 0,
        isRecoveryRetry: Bool = false
    ) async {
        guard isAuthenticated, let accountId = activeAccountKey, let capturedStore = cacheStore else { return }
        retrySleepTask?.cancel()
        retrySleepTask = nil
        let wasPrefetchingTarget = (prefetchingTrackId == track.id)
        if !wasPrefetchingTarget {
            cancelPrefetchTask()
        }
        playbackGeneration += 1
        let gen = playbackGeneration
        currentPlayerItem = nil
        activeTrack = track
        currentTrackId = track.id
        loadingTrackId = track.id
        prefetchedTrackId = nil
        activeSeekToken &+= 1
        isSeekingPlayback = false
        if shuffle && orderedIndexByIdCache[track.id] == nil && tracksById[track.id] != nil {
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
            await capturedStore.setProtectedTrackIDs([track.id])
            if let cachedURL = await capturedStore.existingCachedFile(trackId: track.id) {
                if wasPrefetchingTarget {
                    cancelPrefetchTask()
                }
                let usage = await capturedStore.usageBytes()
                guard gen == playbackGeneration,
                      isAuthenticated,
                      activeAccountKey == accountId,
                      cacheStore === capturedStore else {
                    return
                }
                cacheUsageBytes = usage
                try await startAVPlayer(
                    track: track,
                    url: cachedURL,
                    localFileURL: cachedURL,
                    isLoopback: false,
                    resumeTime: resumeTime,
                    generation: gen,
                    expectedAccount: accountId
                )
                return
            }

            let destURL = await capturedStore.cacheFileURL(trackId: track.id, originalFileName: track.name)
            let hasInFlightDownload: Bool
            if wasPrefetchingTarget {
                hasInFlightDownload = true
            } else {
                hasInFlightDownload = await transferEngine.hasInFlightCacheDownload(for: destURL)
            }
            guard gen == playbackGeneration,
                  isAuthenticated,
                  activeAccountKey == accountId,
                  cacheStore === capturedStore else {
                return
            }
            if forceStreamProxy && wasPrefetchingTarget {
                cancelPrefetchTask()
            }

            let downloadFirst = (!forceStreamProxy && hasInFlightDownload)
                || PlaybackDecisionPolicy.shouldDownloadBeforePlayback(
                    mode: effectiveMode,
                    sizeBytes: track.sizeBytes,
                    forceStreamProxy: forceStreamProxy
                )

            if downloadFirst {
                let downloadedURL = try await transferEngine.downloadTrackToCache(
                    track: track,
                    cacheStore: capturedStore,
                    parallelThreads: committedSettings.downloadThreads,
                    cacheLimitBytes: committedSettings.cacheLimitBytes,
                    kind: "playback",
                    accountHash: accountHash
                )
                guard gen == playbackGeneration,
                      isAuthenticated,
                      activeAccountKey == accountId,
                      cacheStore === capturedStore else {
                    return
                }
                let latestUsage = await capturedStore.usageBytes()
                guard gen == playbackGeneration,
                      isAuthenticated,
                      activeAccountKey == accountId,
                      cacheStore === capturedStore else {
                    return
                }
                cacheUsageBytes = latestUsage
                try await startAVPlayer(
                    track: track,
                    url: downloadedURL,
                    localFileURL: downloadedURL,
                    isLoopback: false,
                    resumeTime: resumeTime,
                    generation: gen,
                    expectedAccount: accountId
                )
            } else {
                let remoteURL = try await cloudClient.resolveDownloadURL(fileId: track.id)
                guard gen == playbackGeneration,
                      isAuthenticated,
                      activeAccountKey == accountId,
                      cacheStore === capturedStore else {
                    return
                }
                let playbackURL: URL
                let registeredToken: String?
                if let streamServer {
                    let reg = StreamSourceRegistration(
                        accountHash: accountHash,
                        trackId: track.id,
                        remoteURL: remoteURL,
                        cacheDestinationURL: destURL,
                        expectedSize: track.sizeBytes,
                        fileName: track.name,
                        cacheLimitBytes: committedSettings.cacheLimitBytes
                    )
                    playbackURL = await streamServer.registerSource(reg, cacheStore: capturedStore)
                    guard gen == playbackGeneration,
                          isAuthenticated,
                          activeAccountKey == accountId,
                          cacheStore === capturedStore else {
                        await streamServer.revokeSource(token: reg.token)
                        return
                    }
                    registeredToken = reg.token
                } else {
                    playbackURL = remoteURL
                    registeredToken = nil
                }
                try await startAVPlayer(
                    track: track,
                    url: playbackURL,
                    localFileURL: destURL,
                    isLoopback: true,
                    resumeTime: resumeTime,
                    generation: gen,
                    expectedAccount: accountId,
                    registeredSourceToken: registeredToken
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard gen == playbackGeneration,
                  isAuthenticated,
                  activeAccountKey == accountId else {
                return
            }
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
        generation: Int,
        expectedAccount: String,
        registeredSourceToken: String? = nil
    ) async throws {
        guard generation == playbackGeneration,
              isAuthenticated,
              activeAccountKey == expectedAccount else {
            if let token = registeredSourceToken {
                await streamServer?.revokeSource(token: token)
            }
            return
        }
        if let audioSessionWarning = nowPlayingCoordinator.configureAudioSessionIfNeeded() {
            setStatus(audioSessionWarning, kind: .error)
        }
        currentPlaybackIsLoopback = isLoopback
        activeTrack = track
        currentTrackId = track.id
        activeSeekToken &+= 1
        isSeekingPlayback = false
        timeline.duration = 0
        timeline.currentTime = resumeTime

        let item = AVPlayerItem(url: url)
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            let currentStatus = observedItem.status
            let itemError = observedItem.error
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.playbackGeneration,
                      self.isAuthenticated,
                      self.activeAccountKey == expectedAccount,
                      observedItem === self._player?.currentItem else { return }
                switch currentStatus {
                case .readyToPlay:
                    self.recoveryAttempts = 0
                    let dur = observedItem.duration.seconds
                    if dur.isFinite && dur > 0 {
                        self.duration = dur
                        let rawElapsed = self._player?.currentTime().seconds ?? self.currentTime
                        let liveElapsed = (rawElapsed.isFinite && rawElapsed >= 0) ? rawElapsed : self.currentTime
                        let rate: Double? = (self._player?.timeControlStatus == .waitingToPlayAtSpecifiedRate) ? 0.0 : nil
                        self.nowPlayingCoordinator.updateNowPlaying(
                            metadata: self.nowPlayingMetadata,
                            isPlaying: self.isPlaying,
                            elapsedSeconds: liveElapsed,
                            durationSeconds: dur,
                            playbackRate: rate,
                            forceUpdate: true
                        )
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
        guard generation == playbackGeneration,
              isAuthenticated,
              activeAccountKey == expectedAccount else {
            itemStatusObservation?.invalidate()
            itemStatusObservation = nil
            if let token = registeredSourceToken {
                await streamServer?.revokeSource(token: token)
            }
            return
        }
        let priorAudioToken = activeAudioSourceToken
        activeAudioSourceToken = registeredSourceToken
        if let priorAudioToken, priorAudioToken != registeredSourceToken {
            await streamServer?.revokeSource(token: priorAudioToken)
        }
        currentPlayerItem = item
        player.volume = Float(volume)
        player.replaceCurrentItem(with: item)
        if resumeTime > 0 {
            await player.seek(to: CMTime(seconds: resumeTime, preferredTimescale: 600))
        }
        guard generation == playbackGeneration,
              isAuthenticated,
              activeAccountKey == expectedAccount else {
            itemStatusObservation?.invalidate()
            itemStatusObservation = nil
            if _player?.currentItem === item {
                _player?.pause()
                _player?.replaceCurrentItem(with: nil)
            }
            if currentPlayerItem === item {
                currentPlayerItem = nil
            }
            if let token = registeredSourceToken {
                await streamServer?.revokeSource(token: token)
            }
            return
        }
        player.play()
        isPlaying = true
        if statusMessage == nil || !statusMessage!.hasPrefix("音频会话配置失败") {
            setStatus(isLoopback ? "边播边缓存《\(track.name)》" : "正在播放《\(track.name)》", kind: .info)
        }

        let fallbackAlbum = track.folderPath.isEmpty ? (committedSettings.musicFolder?.name ?? "天翼云盘") : track.folderPath
        let meta = await AudioMetadataReader.readMetadata(from: localFileURL, fallbackTitle: track.name, fallbackAlbum: fallbackAlbum)
        guard generation == playbackGeneration,
              isAuthenticated,
              activeAccountKey == expectedAccount else {
            return
        }
        nowPlayingMetadata = meta
        syncRemoteCommandAvailability()
        let rawPlayerSeconds = _player?.currentTime().seconds ?? currentTime
        let liveElapsed = (rawPlayerSeconds.isFinite && rawPlayerSeconds >= 0) ? rawPlayerSeconds : max(0, resumeTime)
        let rate: Double? = (hasActivePlayerObservers && _player?.timeControlStatus == .waitingToPlayAtSpecifiedRate) ? 0.0 : nil
        nowPlayingCoordinator.updateNowPlaying(
            metadata: meta,
            isPlaying: isPlaying,
            elapsedSeconds: liveElapsed,
            durationSeconds: duration,
            playbackRate: rate,
            forceUpdate: true
        )
    }

    package func handleWriteThroughCompleted(accountHash: String, trackId: String, localFileURL: URL) async {
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

    package func handlePlaybackPreparationFailure(
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
            setStatus("《\(track.name)》优先缓存超时，改用流式代理直接起播", kind: .info)
            await playTrack(
                track,
                modeOverride: .streamCache,
                forceStreamProxy: true,
                resumeTime: resumeTime,
                isRecoveryRetry: true
            )
        case .fallbackToFullDownloadOnce:
            guard isAuthenticated, playbackGeneration == failedGeneration else { return }
            setStatus("流式容器受限，回退整曲下载《\(track.name)》", kind: .info)
            await playTrack(
                track,
                modeOverride: .downloadFirst,
                forceStreamProxy: false,
                resumeTime: resumeTime,
                isRecoveryRetry: true
            )
        case let .stopImmediatelyUnsupportedCodec(msg):
            isPlaying = false
            setStatus(msg, kind: .error)
        case .stopAfterMaxRetries:
            isPlaying = false
            setStatus("播放异常，已停止自动重试《\(track.name)》", kind: .error)
        case let .retryTransientAfterDelay(attempt):
            isPlaying = false
            guard isAuthenticated, playbackGeneration == failedGeneration else { return }
            setStatus("播放波动，正在重试《\(track.name)》(\(attempt)/\(PlaybackDecisionPolicy.maxRecoveryAttempts))", kind: .info)
            let delayMs = max(0, retryBaseDelayMs) * attempt
            if delayMs > 0 {
                let sleepTask = Task {
                    try await Task.sleep(for: .milliseconds(delayMs))
                }
                retrySleepTask?.cancel()
                retrySleepTask = sleepTask
                defer {
                    if retrySleepTask == sleepTask {
                        retrySleepTask = nil
                    }
                }
                do {
                    try await withTaskCancellationHandler {
                        try await sleepTask.value
                    } onCancel: {
                        sleepTask.cancel()
                    }
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

    package func togglePlayback() async {
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

    package func playIfPaused() async {
        guard !isPlaying else { return }
        await togglePlayback()
    }

    package func pauseIfPlaying() {
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

    package func playAdjacent(direction: Int, autoAdvanceAtEnd: Bool = false) async {
        let step: QueueStepResult
        if direction >= 0 {
            step = PlaybackQueueResolver.resolveNext(
                currentTrack: currentTrack,
                libraryTracks: tracks,
                upNextQueue: upNextQueue,
                shuffle: shuffle,
                shuffleOrderIds: shuffleOrderIds,
                loopMode: loopMode,
                autoAdvanceAtEnd: autoAdvanceAtEnd,
                orderedTracks: orderedLibraryTracksCache,
                orderedIndexById: orderedIndexByIdCache
            )
        } else {
            step = PlaybackQueueResolver.resolvePrevious(
                currentTrack: currentTrack,
                libraryTracks: tracks,
                upNextQueue: upNextQueue,
                shuffle: shuffle,
                shuffleOrderIds: shuffleOrderIds,
                loopMode: loopMode,
                orderedTracks: orderedLibraryTracksCache,
                orderedIndexById: orderedIndexByIdCache
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

    package func seekPlayback(to seconds: Double) async {
        let expectedGen = playbackGeneration
        let expectedAccount = activeAccountKey
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        activeSeekToken &+= 1
        let mySeekToken = activeSeekToken
        isSeekingPlayback = true
        defer {
            if activeSeekToken == mySeekToken {
                isSeekingPlayback = false
            }
        }
        timeline.currentTime = clamped
        await player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        guard expectedGen == playbackGeneration,
              isAuthenticated,
              activeAccountKey == expectedAccount else {
            return
        }
        nowPlayingCoordinator.updateNowPlaying(
            metadata: nowPlayingMetadata,
            isPlaying: isPlaying,
            elapsedSeconds: clamped,
            durationSeconds: duration,
            playbackRate: (hasActivePlayerObservers && _player?.timeControlStatus == .waitingToPlayAtSpecifiedRate) ? 0.0 : nil,
            forceUpdate: true
        )
    }

    // MARK: - Video (Loopback Proxy + Safe External Handoff) & Transfers

    package func openVideoInApp(_ video: TrackSummary) async {
        guard isAuthenticated, let expectedAccount = activeAccountKey else { return }
        retrySleepTask?.cancel()
        retrySleepTask = nil
        cancelPrefetchTask()
        prefetchedTrackId = nil
        playbackGeneration += 1
        externalVideoGeneration += 1
        pendingExternalVideoChoice = nil
        let gen = playbackGeneration
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
                if let priorVideoToken = activeVideoSourceToken {
                    activeVideoSourceToken = nil
                    await streamServer?.revokeSource(token: priorVideoToken)
                }
                activeVideoTrack = video
                activeVideoURL = cached
                setStatus("正在播放已缓存视频：\(video.name)", kind: .info)
                return
            }
            let remoteURL = try await cloudClient.resolveDownloadURL(fileId: video.id)
            guard gen == playbackGeneration,
                  isAuthenticated,
                  activeAccountKey == expectedAccount else {
                return
            }
            let playbackURL: URL
            let registeredToken: String?
            if let streamServer, let capturedStore = cacheStore, let accountId = activeAccountKey, accountId == expectedAccount {
                let accountHash = Cloud189Protocol.accountBucketHash(for: accountId)
                let destURL = await capturedStore.cacheFileURL(trackId: video.id, originalFileName: video.name)
                guard gen == playbackGeneration,
                      isAuthenticated,
                      activeAccountKey == accountId,
                      cacheStore === capturedStore else {
                    return
                }
                let reg = StreamSourceRegistration(
                    accountHash: accountHash,
                    trackId: video.id,
                    remoteURL: remoteURL,
                    cacheDestinationURL: destURL,
                    expectedSize: video.sizeBytes,
                    fileName: video.name,
                    cacheLimitBytes: committedSettings.cacheLimitBytes
                )
                playbackURL = await streamServer.registerSource(reg, cacheStore: capturedStore)
                registeredToken = reg.token
            } else {
                playbackURL = remoteURL
                registeredToken = nil
            }
            guard gen == playbackGeneration,
                  isAuthenticated,
                  activeAccountKey == expectedAccount else {
                if let token = registeredToken {
                    await streamServer?.revokeSource(token: token)
                }
                return
            }
            let priorVideoToken = activeVideoSourceToken
            activeVideoSourceToken = registeredToken
            if let priorVideoToken, priorVideoToken != registeredToken {
                await streamServer?.revokeSource(token: priorVideoToken)
            }
            activeVideoTrack = video
            activeVideoURL = playbackURL
            setStatus("正在应用内播放视频：\(video.name)", kind: .info)
        } catch is CancellationError {
            return
        } catch {
            guard gen == playbackGeneration,
                  isAuthenticated,
                  activeAccountKey == expectedAccount else {
                return
            }
            setStatus(error.localizedDescription, kind: .error)
        }
    }

    /// Returns a local cached `file://` URL immediately if available; otherwise prepares a loopback stream URL
    /// (when `prepareLoopbackStream` is `true`) and sets `pendingExternalVideoChoice` so callers NEVER hand raw `https://` URLs to a web browser.
    package func requestExternalVideoPlayback(
        _ video: TrackSummary,
        prepareLoopbackStream: Bool = true
    ) async -> URL? {
        guard isAuthenticated, let expectedAccount = activeAccountKey else { return nil }
        externalVideoGeneration += 1
        let extGen = externalVideoGeneration
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
            let registeredToken: String?
            if let streamServer, let capturedStore = cacheStore, let accountId = activeAccountKey, accountId == expectedAccount {
                let accountHash = Cloud189Protocol.accountBucketHash(for: accountId)
                let destURL = await capturedStore.cacheFileURL(trackId: video.id, originalFileName: video.name)
                guard extGen == externalVideoGeneration,
                      isAuthenticated,
                      activeAccountKey == expectedAccount,
                      cacheStore === capturedStore else {
                    return nil
                }
                let reg = StreamSourceRegistration(
                    accountHash: accountHash,
                    trackId: video.id,
                    remoteURL: remoteURL,
                    cacheDestinationURL: destURL,
                    expectedSize: video.sizeBytes,
                    fileName: video.name,
                    cacheLimitBytes: committedSettings.cacheLimitBytes
                )
                loopbackStreamURL = await streamServer.registerSource(reg, cacheStore: capturedStore)
                registeredToken = reg.token
            } else {
                loopbackStreamURL = nil
                registeredToken = nil
            }
            guard extGen == externalVideoGeneration,
                  isAuthenticated,
                  activeAccountKey == expectedAccount else {
                if let token = registeredToken {
                    await streamServer?.revokeSource(token: token)
                }
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
            setStatus("获取视频源失败：\(error.localizedDescription)", kind: .error)
            return nil
        }
    }

    package func downloadVideoAndPrepareLocalFile(_ video: TrackSummary) async -> URL? {
        guard isAuthenticated, let accountId = activeAccountKey, let capturedStore = cacheStore else {
            setStatus("请先登录后再缓存视频。", kind: .error)
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
            setStatus("视频缓存完成，正在调用本地播放器打开", kind: .info)
            return localURL
        } catch is CancellationError {
            return nil
        } catch {
            guard extGen == externalVideoGeneration,
                  isAuthenticated,
                  activeAccountKey == accountId else {
                return nil
            }
            setStatus("缓存视频失败：\(error.localizedDescription)", kind: .error)
            return nil
        }
    }

    package func enqueueTrackDownload(_ track: TrackSummary, explicitDirectoryURL: URL? = nil) async {
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
            setStatus("已创建下载任务 \(taskId)", kind: .info)
        } catch is CancellationError {
            return
        } catch {
            setStatus(error.localizedDescription, kind: .error)
        }
    }

    package func enqueueFolderDownload(from pane: BrowserPaneState, explicitDirectoryURL: URL? = nil) async {
        guard isAuthenticated, let payload = pane.payload, let accountId = activeAccountKey else { return }
        let expectedAuthGen = authGeneration
        let nonRootCrumbs = pane.breadcrumbs.filter { $0.id != nil && $0.id != Cloud189Constants.rootFolderId }
        let crumbPath: String? = (!payload.isRoot && nonRootCrumbs.last?.id == payload.currentFolderId)
            ? nonRootCrumbs.map(\.name).filter { !$0.isEmpty }.joined(separator: "/")
            : nil
        let rootExportFolder = (crumbPath?.isEmpty == false ? crumbPath! : payload.currentFolderName)
        let assignedBusy = "扫描文件夹 \(payload.currentFolderName)..."
        busyLabel = assignedBusy
        operationBusyToken += 1
        let myBusyToken = operationBusyToken
        defer {
            if operationBusyToken == myBusyToken, busyLabel == assignedBusy {
                busyLabel = nil
            }
        }
        do {
            let allFiles = try await cloudClient.scanAllFiles(
                folderId: payload.currentFolderId,
                folderName: rootExportFolder
            )
            guard authGeneration == expectedAuthGen,
                  isAuthenticated,
                  activeAccountKey == accountId else {
                return
            }
            let batchItems: [(track: TrackSummary, relativeExportSubpath: String)] = allFiles.map { item in
                let rel = item.folderPath.hasPrefix(rootExportFolder)
                    ? "\(item.folderPath)/\(item.name)"
                    : "\(rootExportFolder)/\(item.name)"
                return (track: item, relativeExportSubpath: rel)
            }
            if !batchItems.isEmpty {
                _ = try await transferEngine.enqueueExportDownloads(
                    accountId: accountId,
                    items: batchItems,
                    parallelThreads: committedSettings.downloadThreads,
                    explicitDirectoryURL: explicitDirectoryURL,
                    accountStore: accountStore
                )
            }
            let latestSnap = await transferEngine.snapshot()
            guard authGeneration == expectedAuthGen,
                  isAuthenticated,
                  activeAccountKey == accountId else {
                return
            }
            transferSnapshot = latestSnap
            setStatus("目录下载已入队（共 \(allFiles.count) 个文件）", kind: .info)
        } catch is CancellationError {
            return
        } catch {
            guard authGeneration == expectedAuthGen,
                  isAuthenticated,
                  activeAccountKey == accountId else {
                return
            }
            setStatus(error.localizedDescription, kind: .error)
        }
    }

    package func pauseTransfer(_ id: String) async {
        await transferEngine.pauseTransfer(id: id, accountStore: accountStore)
        transferSnapshot = await transferEngine.snapshot()
    }

    package func resumeTransfer(_ id: String) async {
        await transferEngine.resumeTransfer(id: id, accountStore: accountStore)
        transferSnapshot = await transferEngine.snapshot()
    }

    package func deleteTransfer(_ id: String) async {
        await transferEngine.deleteTransfer(id: id, accountStore: accountStore)
        transferSnapshot = await transferEngine.snapshot()
    }

    @discardableResult
    package func saveExportDirectoryBookmark(_ url: URL) async -> Bool {
        guard isAuthenticated, let accountId = activeAccountKey else { return false }
        let baseSnapshot = committedSettings
        do {
            let result = try await accountStore.saveExportDirectoryBookmarkAndSettings(
                url,
                baseSettings: baseSnapshot,
                for: accountId
            )
            guard isAuthenticated, activeAccountKey == accountId else { return false }
            if result.sequence >= lastAppliedSettingsSeq {
                lastAppliedSettingsSeq = result.sequence
                committedSettings = result.settings
            }
            setStatus("下载导出目录已设为 \(result.displayName)", kind: .info)
            return true
        } catch {
            guard isAuthenticated, activeAccountKey == accountId else { return false }
            setStatus(error.localizedDescription, kind: .error)
            return false
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
            MainActor.assumeIsolated {
                guard let self else { return }
                let secs = cmTime.seconds
                if !self.isSeekingPlayback,
                   secs.isFinite,
                   secs >= 0,
                   abs(secs - self.timeline.currentTime) >= 0.05 {
                    self.timeline.currentTime = secs
                }
                if let itemDur = self._player?.currentItem?.duration.seconds,
                   itemDur.isFinite,
                   itemDur > 0,
                   abs(itemDur - self.timeline.duration) >= 0.05 {
                    self.timeline.duration = itemDur
                }
                self.triggerPrefetchIfNeeded()
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            let status = observedPlayer.timeControlStatus
            let rawSeconds = observedPlayer.currentTime().seconds
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.handleTimeControlStatusChange(status: status, rawSeconds: rawSeconds)
                }
            } else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let latestRaw = self._player?.currentTime().seconds ?? rawSeconds
                    self.handleTimeControlStatusChange(status: status, rawSeconds: latestRaw)
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

    private func handleTimeControlStatusChange(
        status: AVPlayer.TimeControlStatus,
        rawSeconds: Double
    ) {
        guard currentTrack != nil,
              let activeItem = _player?.currentItem,
              activeItem === currentPlayerItem else {
            return
        }
        let finiteSeconds = (rawSeconds.isFinite && rawSeconds >= 0) ? rawSeconds : nil
        switch status {
        case .waitingToPlayAtSpecifiedRate:
            let liveElapsed = finiteSeconds ?? currentTime
            if let finiteSeconds {
                currentTime = finiteSeconds
            }
            nowPlayingCoordinator.updateNowPlaying(
                metadata: nowPlayingMetadata,
                isPlaying: isPlaying,
                elapsedSeconds: liveElapsed,
                durationSeconds: duration,
                playbackRate: 0.0,
                forceUpdate: true
            )
        case .playing:
            isPlaying = true
            if let finiteSeconds {
                currentTime = finiteSeconds
            }
            nowPlayingCoordinator.updateNowPlaying(
                metadata: nowPlayingMetadata,
                isPlaying: true,
                elapsedSeconds: currentTime,
                durationSeconds: duration,
                playbackRate: 1.0,
                forceUpdate: true
            )
        case .paused:
            isPlaying = false
            if let finiteSeconds {
                currentTime = finiteSeconds
            }
            nowPlayingCoordinator.updateNowPlaying(
                metadata: nowPlayingMetadata,
                isPlaying: false,
                elapsedSeconds: currentTime,
                durationSeconds: duration,
                playbackRate: 0.0,
                forceUpdate: true
            )
        @unknown default:
            break
        }
    }

    package func teardownPlayerAndRemoteCommands() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        currentPlayerItem = nil
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

    package func triggerPrefetchIfNeeded() {
        guard isAuthenticated,
              loopMode != .one,
              let capturedStore = cacheStore,
              let expectedAccount = activeAccountKey,
              currentTrack != nil else {
            return
        }
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
            loopMode: loopMode,
            orderedTracks: orderedLibraryTracksCache,
            orderedIndexById: orderedIndexByIdCache
        ),
        next.id != prefetchedTrackId,
        next.id != prefetchingTrackId else {
            return
        }

        prefetchTask?.cancel()
        prefetchingTrackId = next.id
        let expectedAuthGen = authGeneration
        let expectedPlayGen = playbackGeneration
        let activeId = currentTrackId ?? ""
        let accountHash = Cloud189Protocol.accountBucketHash(for: expectedAccount)
        let cacheThreads = committedSettings.cacheThreads
        let cacheLimitBytes = committedSettings.cacheLimitBytes

        let spawned = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPrefetchUpcomingTrack(
                next: next,
                activeId: activeId,
                expectedAuthGen: expectedAuthGen,
                expectedPlayGen: expectedPlayGen,
                expectedAccount: expectedAccount,
                accountHash: accountHash,
                capturedStore: capturedStore,
                cacheThreads: cacheThreads,
                cacheLimitBytes: cacheLimitBytes
            )
        }
        prefetchTask = spawned
    }

    private func performPrefetchUpcomingTrack(
        next: TrackSummary,
        activeId: String,
        expectedAuthGen: Int,
        expectedPlayGen: Int,
        expectedAccount: String,
        accountHash: String,
        capturedStore: CacheStore,
        cacheThreads: Int,
        cacheLimitBytes: UInt64
    ) async {
        defer {
            if self.prefetchingTrackId == next.id {
                self.prefetchingTrackId = nil
            }
        }
        await capturedStore.setProtectedTrackIDs([activeId, next.id])
        if await capturedStore.existingCachedFile(trackId: next.id) != nil {
            guard !Task.isCancelled,
                  self.authGeneration == expectedAuthGen,
                  self.playbackGeneration == expectedPlayGen,
                  self.isAuthenticated,
                  self.activeAccountKey == expectedAccount,
                  self.cacheStore === capturedStore else {
                return
            }
            self.prefetchedTrackId = next.id
            return
        }
        guard !Task.isCancelled,
              self.authGeneration == expectedAuthGen,
              self.playbackGeneration == expectedPlayGen,
              self.isAuthenticated,
              self.activeAccountKey == expectedAccount,
              self.cacheStore === capturedStore else {
            return
        }
        do {
            _ = try await self.transferEngine.downloadTrackToCache(
                track: next,
                cacheStore: capturedStore,
                parallelThreads: cacheThreads,
                cacheLimitBytes: cacheLimitBytes,
                kind: "prefetch",
                accountHash: accountHash
            )
            guard !Task.isCancelled,
                  self.authGeneration == expectedAuthGen,
                  self.playbackGeneration == expectedPlayGen,
                  self.isAuthenticated,
                  self.activeAccountKey == expectedAccount,
                  self.cacheStore === capturedStore else {
                return
            }
            self.prefetchedTrackId = next.id
        } catch {
            // Best-effort prefetch; errors do not interrupt active playback
        }
    }
}
