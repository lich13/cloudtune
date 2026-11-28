package com.gosu.cloudtune.ui

import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.webkit.CookieManager
import androidx.compose.runtime.Stable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.FileProvider
import androidx.lifecycle.ViewModel
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.gosu.cloudtune.core.AccountSettings
import com.gosu.cloudtune.core.AppearanceMode
import com.gosu.cloudtune.core.BreadcrumbItem
import com.gosu.cloudtune.core.BrowserPaneState
import com.gosu.cloudtune.core.BrowserScope
import com.gosu.cloudtune.core.CacheManager
import com.gosu.cloudtune.core.Cloud189Client
import com.gosu.cloudtune.core.Cloud189Constants
import com.gosu.cloudtune.core.Cloud189Protocol
import com.gosu.cloudtune.core.ExportDownloadItem
import com.gosu.cloudtune.core.FolderBrowsePayload
import com.gosu.cloudtune.core.FolderSelection
import com.gosu.cloudtune.core.GlobalTransferLimiter
import com.gosu.cloudtune.core.LocalStreamServer
import com.gosu.cloudtune.core.LoopMode
import com.gosu.cloudtune.core.ModuleTab
import com.gosu.cloudtune.core.PlaybackDecisionPolicy
import com.gosu.cloudtune.core.PlaybackFailureAction
import com.gosu.cloudtune.core.PlaybackMode
import com.gosu.cloudtune.core.PlaybackQueueResolver
import com.gosu.cloudtune.core.QrLoginState
import com.gosu.cloudtune.core.StagedFileExporter
import com.gosu.cloudtune.core.StreamSourceRegistration
import com.gosu.cloudtune.core.TrackSummary
import com.gosu.cloudtune.core.TransferEngine
import com.gosu.cloudtune.core.TransferSnapshotPayload
import com.gosu.cloudtune.core.TransferStatus
import com.gosu.cloudtune.data.AccountStore
import com.gosu.cloudtune.data.CredentialStore
import com.gosu.cloudtune.data.EncryptedCredentialStore
import com.gosu.cloudtune.data.SafExporter
import com.gosu.cloudtune.media.AudioMetadataHelper
import com.gosu.cloudtune.media.ExtractedAudioMetadata
import com.gosu.cloudtune.media.PlaybackService
import com.gosu.cloudtune.media.PlaybackSessionBridge
import com.gosu.cloudtune.media.QrCodeHelper
import java.io.File
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

enum class StatusKind {
    INFO,
    ERROR
}

data class PendingExternalVideoAction(
    val video: TrackSummary,
    val streamUrl: String?
)

internal enum class DraftSyncScope {
    NONE,
    CACHE_LIMIT_ONLY,
    THREADS_ONLY,
    ALL
}

/**
 * Application/service-scoped runtime keeping `LocalStreamServer`, `MediaController`,
 * unified queue state, lifecycle-safe video `ExoPlayer`, and lockscreen callbacks alive.
 */
@Stable
class CloudTuneAppRuntime(
    appContext: Context? = null,
    val cloudClient: Cloud189Client = Cloud189Client(),
    val accountStore: AccountStore = AccountStore(
        appContext?.applicationContext?.filesDir ?: File(System.getProperty("java.io.tmpdir"), "cloudtune-android")
    ),
    val credentialStore: CredentialStore? = appContext?.applicationContext?.let {
        runCatching { EncryptedCredentialStore(it) }.getOrNull()
    },
    val limiter: GlobalTransferLimiter = GlobalTransferLimiter(maxPermits = 8),
    val enableLiveLoops: Boolean = true,
    dispatcher: CoroutineDispatcher = if (appContext != null) Dispatchers.Main.immediate else Dispatchers.Unconfined,
    private val ioDispatcher: CoroutineDispatcher = if (appContext != null) Dispatchers.IO else Dispatchers.Unconfined
) {
    private val appCtx: Context? = appContext?.applicationContext
    private val uiPrefs = appCtx?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    val scope = CoroutineScope(SupervisorJob() + dispatcher)

    val themeMode: AppearanceMode
        get() = committedSettings.appearanceMode
    val dynamicColorEnabled: Boolean
        get() = committedSettings.dynamicColorEnabled
    var activeModule by mutableStateOf(ModuleTab.MUSIC)
    var isBootstrapping by mutableStateOf(false)
        internal set
    var busyLabel by mutableStateOf<String?>(null)
        internal set
    var statusMessage by mutableStateOf<String?>(null)
        internal set
    var statusKind by mutableStateOf(StatusKind.INFO)
        internal set

    internal fun setStatus(message: String?, kind: StatusKind = StatusKind.INFO) {
        statusMessage = message
        statusKind = if (message.isNullOrBlank()) StatusKind.INFO else kind
    }

    var isAuthenticated by mutableStateOf(false)
        internal set
    var accountName by mutableStateOf<String?>(null)
        internal set
    var accountStorageKey by mutableStateOf<String?>(null)
        internal set

    // Strictly separated committed vs draft settings
    var committedSettings by mutableStateOf(AccountSettings())
        internal set
    var cacheLimitDraft by mutableStateOf("1024")
    var downloadThreadsDraft by mutableStateOf("8")
    var cacheThreadsDraft by mutableStateOf("4")
    var settingsValidationError by mutableStateOf<String?>(null)
        internal set

    var cacheUsageBytes by mutableLongStateOf(0L)
        internal set

    // Login state
    var qrContent by mutableStateOf<String?>(null)
        internal set
    var qrBitmap by mutableStateOf<Bitmap?>(null)
        internal set
    var qrHint by mutableStateOf<String?>(null)
        internal set
    var isShowingWebLoginDialog by mutableStateOf(false)

    // Decoupled Cloud & Video folder browsers + Music library
    var cloudBrowser by mutableStateOf(BrowserPaneState())
        internal set
    var videoBrowser by mutableStateOf(BrowserPaneState())
        internal set
    var tracks by mutableStateOf<List<TrackSummary>>(emptyList())
        internal set
    var searchQuery by mutableStateOf("")

    var breadcrumbs: List<BreadcrumbItem>
        get() = cloudBrowser.breadcrumbs
        internal set(value) { cloudBrowser = cloudBrowser.copy(breadcrumbs = value) }

    var browser: FolderBrowsePayload?
        get() = cloudBrowser.payload
        internal set(value) { cloudBrowser = cloudBrowser.copy(payload = value) }

    // Playback & unified queue state
    var activeTrack by mutableStateOf<TrackSummary?>(null)
        internal set
    var currentTrackId by mutableStateOf<String?>(null)
        internal set
    var nowPlayingTitle by mutableStateOf<String?>(null)
        internal set
    var nowPlayingArtist by mutableStateOf<String?>(null)
        internal set
    var nowPlayingAlbum by mutableStateOf<String?>(null)
        internal set
    var nowPlayingArtwork by mutableStateOf<Bitmap?>(null)
        internal set
    var isPlaying by mutableStateOf(false)
        internal set
    var loadingTrackId by mutableStateOf<String?>(null)
        internal set
    var shuffle by mutableStateOf(true)
        internal set
    var loopMode by mutableStateOf(LoopMode.ALL)
        internal set
    var currentTime by mutableDoubleStateOf(0.0)
        internal set
    var duration by mutableDoubleStateOf(0.0)
        internal set
    var upNextQueue by mutableStateOf<List<TrackSummary>>(emptyList())
        internal set
    var shuffleOrderIds by mutableStateOf<List<String>>(emptyList())
        internal set
    var isShowingNowPlayingSheet by mutableStateOf(false)
    var isUserScrubbing by mutableStateOf(false)

    // Lifecycle-safe Video player state
    var activeVideoTrack by mutableStateOf<TrackSummary?>(null)
        internal set
    var activeVideoTitle by mutableStateOf<String?>(null)
        internal set
    var activeVideoUrl by mutableStateOf<String?>(null)
        internal set
    var isVideoPlaying by mutableStateOf(false)
        internal set
    var videoPlayer by mutableStateOf<ExoPlayer?>(null)
        private set
    var pendingExternalVideoAction by mutableStateOf<PendingExternalVideoAction?>(null)

    // Transfers
    var transferSnapshot by mutableStateOf(TransferSnapshotPayload())
        internal set

    internal var retryBaseDelayMs: Long = 1500L

    val transferEngine = TransferEngine(limiter = limiter) { trackId ->
        cloudClient.resolveDownloadUrl(trackId)
    }

    internal val streamServer: LocalStreamServer? = if (enableLiveLoops) {
        runCatching {
            LocalStreamServer(
                limiter = limiter,
                onAccountStreamStatusUpdate = { id, accountHash, status ->
                    transferEngine.updateExternalTransferStatus(id, status, accountHash)
                },
                onWriteThroughCompleted = { accountHash, trackId, localFile ->
                    scope.launch {
                        handleWriteThroughCompleted(accountHash, trackId, localFile)
                    }
                },
                urlRefresher = { trackId ->
                    cloudClient.resolveDownloadUrl(trackId)
                }
            )
        }.getOrNull()
    } else null

    private val hasAndroidContext: Boolean = appCtx != null
    private val settingsMutexes = ConcurrentHashMap<String, Mutex>()
    private val bootstrapLock = Any()
    private var bootstrapDeferred: Deferred<Unit>? = null
    internal var cookieCleanupDeferred: Deferred<Unit>? = null
    private var cacheManager: CacheManager? = null
    private var mediaController: MediaController? = null
    private var pendingMediaItem: MediaItem? = null
    internal var lastPreparedPlaybackUrl: String? = null
    private var qrPollJob: Job? = null
    private var transferRefreshJob: Job? = null
    private var uiProgressClockJob: Job? = null
    private var scheduledPrefetchJob: Job? = null
    private var activePrefetchJob: Job? = null
    private var activeAudioSourceToken: String? = null
    private var activeVideoSourceToken: String? = null
    internal var lastExternalVideoJob: Job? = null
    private var prefetchedTrackId: String? = null
    private var prefetchingTrackId: String? = null
    @Volatile private var authEpoch: Int = 0
    @Volatile private var playbackGeneration: Int = 0
    @Volatile private var externalVideoGeneration: Int = 0
    @Volatile private var cloudBrowserGeneration: Int = 0
    @Volatile private var videoBrowserGeneration: Int = 0
    @Volatile private var cloudBrowserIdleGeneration: Int = 0
    @Volatile private var videoBrowserIdleGeneration: Int = 0
    @Volatile private var browserBusyToken: Int = 0
    @Volatile private var operationBusyToken: Int = 0
    private var recoveryAttempts = 0
    private var currentPlaybackIsLoopback = false
    private var attachedUiCount = 0
    private var isUiForegroundVisible = true

    init {
        uiPrefs?.let { prefs ->
            committedSettings = committedSettings.copy(
                appearanceMode = AppearanceMode.fromWire(prefs.getString(KEY_APPEARANCE_MODE, null)),
                dynamicColorEnabled = prefs.getBoolean(KEY_DYNAMIC_COLOR, false)
            )
        }
        syncDraftsFromCommitted()
        transferEngine.setOnActivityChange { snapshot, hasActive ->
            scope.launch {
                handleTransferActivityChange(snapshot, hasActive)
            }
        }
        if (enableLiveLoops) {
            bindSkipBridge()
            if (appCtx != null) {
                connectMediaController(appCtx)
            }
        }
    }

    internal fun bindSkipBridge() {
        if (!enableLiveLoops) return
        PlaybackSessionBridge.onSkipNext = { playAdjacent(1) }
        PlaybackSessionBridge.onSkipPrevious = { playAdjacent(-1) }
        syncQueueAvailabilityToBridge()
    }

    internal fun onUiAttached() {
        attachedUiCount += 1
        if (enableLiveLoops) {
            bindSkipBridge()
            updateUiProgressClock()
            if (isAuthenticated && transferEngine.hasActiveTransfers()) {
                ensureTransferRefreshRunning()
            }
        }
    }

    internal fun onUiDetached() {
        // Keep LocalStreamServer, MediaController, and PlaybackSessionBridge alive so background
        // PlaybackService loopback streaming and lockscreen Next/Previous survive Activity finish!
        attachedUiCount = (attachedUiCount - 1).coerceAtLeast(0)
        if (attachedUiCount > 0) return
        qrPollJob?.cancel()
        qrPollJob = null
        transferRefreshJob?.cancel()
        transferRefreshJob = null
        updateUiProgressClock()
    }

    fun setUiForegroundVisible(visible: Boolean) {
        if (isUiForegroundVisible == visible) return
        isUiForegroundVisible = visible
        if (!visible) {
            videoPlayer?.pause()
        }
        updateUiProgressClock()
        if (visible && isAuthenticated) {
            transferSnapshot = transferEngine.snapshot()
            if (transferSnapshot.hasActiveItems) {
                ensureTransferRefreshRunning()
            }
            mediaController?.let { mc ->
                if (mc.duration > 0L) duration = mc.duration / 1000.0
                if (!isUserScrubbing) currentTime = mc.currentPosition.coerceAtLeast(0L) / 1000.0
                isPlaying = mc.isPlaying
            }
        }
    }

    val activeAccountKey: String?
        get() {
            val key = accountStorageKey?.trim()
            if (!key.isNullOrEmpty()) return key
            val display = accountName?.trim()
            if (!display.isNullOrEmpty() && display != Cloud189Constants.DEFAULT_ACCOUNT_DISPLAY_NAME) {
                return display
            }
            return null
        }

    internal val tracksById: Map<String, TrackSummary> by derivedStateOf {
        if (tracks.isEmpty()) {
            emptyMap()
        } else {
            val map = LinkedHashMap<String, TrackSummary>(tracks.size)
            for (track in tracks) {
                map.putIfAbsent(track.id, track)
            }
            map
        }
    }

    val orderedBaseTracks: List<TrackSummary> by derivedStateOf {
        PlaybackQueueResolver.orderedBaseTracks(
            libraryTracks = tracks,
            shuffle = shuffle,
            shuffleOrderIds = shuffleOrderIds,
            tracksById = tracksById
        )
    }

    internal val trackIndexById: Map<String, Int> by derivedStateOf {
        val ordered = orderedBaseTracks
        if (ordered.isEmpty()) {
            emptyMap()
        } else {
            val indexMap = HashMap<String, Int>(ordered.size * 2)
            for (idx in ordered.indices) {
                indexMap.putIfAbsent(ordered[idx].id, idx)
            }
            indexMap
        }
    }

    val visibleTracks: List<TrackSummary> by derivedStateOf {
        val q = searchQuery.trim().lowercase(Locale.ROOT)
        if (q.isEmpty()) {
            tracks
        } else {
            tracks.filter {
                it.name.lowercase(Locale.ROOT).contains(q) || it.folderPath.lowercase(Locale.ROOT).contains(q)
            }
        }
    }

    val currentTrack: TrackSummary? by derivedStateOf {
        val held = activeTrack
        if (held != null && (held.id == currentTrackId || currentTrackId == null)) {
            held
        } else {
            val id = currentTrackId
            if (id == null) {
                null
            } else {
                tracksById[id]
                    ?: cloudBrowser.payload?.audioFiles?.firstOrNull { it.id == id }
                    ?: held
            }
        }
    }

    val upcomingTracks: List<TrackSummary> by derivedStateOf {
        PlaybackQueueResolver.upcomingPreview(
            currentTrack = currentTrack,
            libraryTracks = tracks,
            upNextQueue = upNextQueue,
            shuffle = shuffle,
            shuffleOrderIds = shuffleOrderIds,
            loopMode = loopMode,
            limit = 20,
            precomputedOrdered = orderedBaseTracks,
            orderedIndexById = trackIndexById
        )
    }

    val canSkipNext: Boolean by derivedStateOf {
        PlaybackQueueResolver.canSkipNext(
            currentTrack = currentTrack,
            libraryTracks = tracks,
            upNextQueue = upNextQueue,
            shuffle = shuffle,
            shuffleOrderIds = shuffleOrderIds,
            loopMode = loopMode,
            precomputedOrdered = orderedBaseTracks,
            orderedIndexById = trackIndexById
        )
    }

    val canSkipPrevious: Boolean by derivedStateOf {
        PlaybackQueueResolver.canSkipPrevious(
            currentTrack = currentTrack,
            libraryTracks = tracks,
            shuffle = shuffle,
            shuffleOrderIds = shuffleOrderIds,
            loopMode = loopMode,
            precomputedOrdered = orderedBaseTracks,
            orderedIndexById = trackIndexById
        )
    }

    val canTogglePlayback: Boolean by derivedStateOf {
        !(currentTrack == null && upNextQueue.isEmpty() && tracks.isEmpty())
    }

    val downloadTransfers: List<TransferStatus> by derivedStateOf {
        transferSnapshot.items.filter { it.kind == "download" }
    }

    val hasUncommittedCacheDraft: Boolean by derivedStateOf {
        cacheLimitDraft.trim() != committedSettings.cacheLimitMb.toString()
    }

    val hasUncommittedThreadDrafts: Boolean by derivedStateOf {
        downloadThreadsDraft.trim() != committedSettings.downloadThreads.toString() ||
            cacheThreadsDraft.trim() != committedSettings.cacheThreads.toString()
    }

    private fun syncQueueAvailabilityToBridge() {
        if (!enableLiveLoops) return
        PlaybackSessionBridge.updateAvailability(canNext = canSkipNext, canPrev = canSkipPrevious)
    }

    private fun settingsMutexFor(accountId: String): Mutex =
        settingsMutexes.computeIfAbsent(accountId) { Mutex() }

    private fun mirrorThemePrefs(mode: AppearanceMode, dynamicColor: Boolean) {
        uiPrefs?.edit()
            ?.putString(KEY_APPEARANCE_MODE, mode.wireValue)
            ?.putBoolean(KEY_DYNAMIC_COLOR, dynamicColor)
            ?.apply()
    }

    fun syncDraftsFromCommitted() {
        applyDraftSync(DraftSyncScope.ALL)
    }

    private fun applyDraftSync(scopeTarget: DraftSyncScope) {
        when (scopeTarget) {
            DraftSyncScope.NONE -> return
            DraftSyncScope.CACHE_LIMIT_ONLY -> {
                cacheLimitDraft = committedSettings.cacheLimitMb.toString()
            }
            DraftSyncScope.THREADS_ONLY -> {
                downloadThreadsDraft = committedSettings.downloadThreads.toString()
                cacheThreadsDraft = committedSettings.cacheThreads.toString()
            }
            DraftSyncScope.ALL -> {
                cacheLimitDraft = committedSettings.cacheLimitMb.toString()
                downloadThreadsDraft = committedSettings.downloadThreads.toString()
                cacheThreadsDraft = committedSettings.cacheThreads.toString()
            }
        }
        val prevErr = settingsValidationError
        if (prevErr != null && statusMessage == prevErr) {
            setStatus(null, StatusKind.INFO)
        }
        settingsValidationError = null
    }

    fun noteDraftEdited() {
        val prevErr = settingsValidationError
        if (prevErr != null && statusMessage == prevErr) {
            setStatus(null, StatusKind.INFO)
        }
        settingsValidationError = null
    }

    internal suspend fun mutateAccountSettings(
        expectedAccount: String? = null,
        successMessage: String? = null,
        draftSync: DraftSyncScope = DraftSyncScope.NONE,
        transform: (AccountSettings) -> AccountSettings
    ): Boolean {
        val acct = expectedAccount ?: activeAccountKey
        if (acct == null) {
            if (expectedAccount != null) return false
            val updated = transform(committedSettings)
            committedSettings = updated
            applyDraftSync(draftSync)
            if (successMessage != null) setStatus(successMessage, StatusKind.INFO)
            return true
        }
        val mutex = settingsMutexFor(acct)
        return mutex.withLock {
            if (!isAuthenticated || activeAccountKey != acct) {
                return@withLock false
            }
            val ioResult = runCatching {
                withContext(ioDispatcher) {
                    val base = accountStore.loadSettingsOrNull(acct) ?: committedSettings
                    val updated = transform(base)
                    accountStore.saveSettings(acct, updated)
                    updated
                }
            }
            val saved = ioResult.getOrElse { err ->
                if (isAuthenticated && activeAccountKey == acct) {
                    setStatus("保存设置失败：${err.message ?: "磁盘写入异常"}", StatusKind.ERROR)
                }
                return@withLock false
            }
            if (!isAuthenticated || activeAccountKey != acct) {
                return@withLock false
            }
            committedSettings = saved
            applyDraftSync(draftSync)
            if (successMessage != null) setStatus(successMessage, StatusKind.INFO)
            true
        }
    }

    suspend fun commitCacheLimitDraftAsync(): Boolean {
        val parsed = cacheLimitDraft.trim().toLongOrNull()
        if (parsed == null || parsed < AccountSettings.MIN_CACHE_LIMIT_MB) {
            val msg = "缓存上限至少设为 256 MB。"
            settingsValidationError = msg
            setStatus(msg, StatusKind.ERROR)
            return false
        }
        val expectedAccount = activeAccountKey
        val cm = cacheManager
        val ok = mutateAccountSettings(
            expectedAccount = expectedAccount,
            successMessage = "缓存限制已更新",
            draftSync = DraftSyncScope.CACHE_LIMIT_ONLY
        ) { prev -> prev.copy(cacheLimitMb = parsed) }
        if (ok && cm != null) {
            val prunedUsage = runCatching {
                withContext(ioDispatcher) { cm.pruneToLimit(parsed * 1024L * 1024L) }
            }.getOrNull()
            if (prunedUsage != null && isAuthenticated && activeAccountKey == expectedAccount && cm === cacheManager) {
                cacheUsageBytes = prunedUsage
            }
        }
        return ok
    }

    fun commitCacheLimitDraft() {
        scope.launch {
            commitCacheLimitDraftAsync()
        }
    }

    suspend fun commitTransferThreadsDraftAsync(): Boolean {
        val dl = downloadThreadsDraft.trim().toIntOrNull()
        if (dl == null || dl !in 1..AccountSettings.MAX_DOWNLOAD_THREADS) {
            val msg = "下载线程范围是 1-${AccountSettings.MAX_DOWNLOAD_THREADS}"
            settingsValidationError = msg
            setStatus(msg, StatusKind.ERROR)
            return false
        }
        val ct = cacheThreadsDraft.trim().toIntOrNull()
        if (ct == null || ct !in 1..AccountSettings.MAX_CACHE_THREADS) {
            val msg = "缓存线程范围是 1-${AccountSettings.MAX_CACHE_THREADS}"
            settingsValidationError = msg
            setStatus(msg, StatusKind.ERROR)
            return false
        }
        return mutateAccountSettings(
            expectedAccount = activeAccountKey,
            successMessage = "传输参数已更新",
            draftSync = DraftSyncScope.THREADS_ONLY
        ) { prev -> prev.copy(downloadThreads = dl, cacheThreads = ct) }
    }

    fun commitTransferThreadsDraft() {
        scope.launch {
            commitTransferThreadsDraftAsync()
        }
    }

    fun updatePlaybackMode(mode: PlaybackMode) {
        val msg = if (mode == PlaybackMode.DOWNLOAD_FIRST) "已切到优先缓存播放" else "已切到边播边缓存"
        scope.launch {
            mutateAccountSettings(successMessage = msg) { prev -> prev.copy(playbackMode = mode) }
            scheduleUpcomingPrefetch()
        }
    }

    fun updateAppearanceMode(mode: AppearanceMode) {
        committedSettings = committedSettings.copy(appearanceMode = mode)
        mirrorThemePrefs(mode, dynamicColorEnabled)
        scope.launch {
            mutateAccountSettings { prev -> prev.copy(appearanceMode = mode) }
        }
    }

    fun updateDynamicColorEnabled(enabled: Boolean) {
        committedSettings = committedSettings.copy(dynamicColorEnabled = enabled)
        mirrorThemePrefs(themeMode, enabled)
        scope.launch {
            mutateAccountSettings { prev -> prev.copy(dynamicColorEnabled = enabled) }
        }
    }

    /**
     * Single-flight cold-start bootstrap shared between `MainActivity` and `PlaybackService`
     * so concurrent launches never trigger duplicate refresh-token exchanges.
     */
    fun bootstrap(): Deferred<Unit> = synchronized(bootstrapLock) {
        if (isAuthenticated) return CompletableDeferred(Unit)
        val existing = bootstrapDeferred
        if (existing != null && existing.isActive) return existing
        val expectedAuthEpoch = authEpoch
        val pendingCleanup = cookieCleanupDeferred
        operationBusyToken += 1
        val myBusyToken = operationBusyToken
        val assignedBusy = "恢复天翼登录会话..."
        var selfDeferred: Deferred<Unit>? = null
        val created = scope.async {
            try {
                if (pendingCleanup != null) {
                    try {
                        pendingCleanup.await()
                    } catch (ce: CancellationException) {
                        if (!isActive) throw ce
                    } catch (_: Throwable) {
                    }
                }
                if (!isActive || authEpoch != expectedAuthEpoch || isAuthenticated) return@async
                val stored = withContext(ioDispatcher) {
                    if (authEpoch == expectedAuthEpoch) credentialStore?.loadCredential() else null
                } ?: return@async
                if (!isActive || authEpoch != expectedAuthEpoch || isAuthenticated) return@async
                isBootstrapping = true
                busyLabel = assignedBusy
                val (restored, clientEpoch) = cloudClient.restoreFromRefreshCredentialWithEpoch(stored)
                if (authEpoch != expectedAuthEpoch) {
                    cloudClient.clearSessionImmediate(clientEpoch)
                    return@async
                }
                val identity = Cloud189Protocol.resolveAccountIdentity(
                    activeSession = restored.activeSession,
                    persistedCredential = restored.persistedCredential ?: stored,
                    priorAccountKey = stored.accountKey
                )
                if (authEpoch != expectedAuthEpoch) {
                    cloudClient.clearSessionImmediate(clientEpoch)
                    return@async
                }
                restored.persistedCredential?.let { cred ->
                    runCatching {
                        withContext(ioDispatcher) {
                            if (authEpoch == expectedAuthEpoch) {
                                credentialStore?.saveCredential(cred.withAccountKey(identity.storageKey))
                            }
                        }
                    }.onFailure { err ->
                        if (authEpoch == expectedAuthEpoch) {
                            setStatus("登录凭据持久化警告：${err.message}", StatusKind.ERROR)
                        }
                    }
                }
                if (authEpoch != expectedAuthEpoch) {
                    cloudClient.clearSessionImmediate(clientEpoch)
                    return@async
                }
                activateAccount(
                    storageKey = identity.storageKey,
                    displayName = identity.displayName,
                    expectedAuthEpoch = expectedAuthEpoch
                )
                if (authEpoch != expectedAuthEpoch || !isAuthenticated) {
                    if (authEpoch != expectedAuthEpoch) {
                        cloudClient.clearSessionImmediate(clientEpoch)
                    }
                    return@async
                }
                browseToSuspend(BrowserScope.CLOUD, null, listOf(BreadcrumbItem.ROOT), showBusy = false)
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                if (authEpoch == expectedAuthEpoch) {
                    isAuthenticated = false
                    setStatus(e.message, StatusKind.ERROR)
                }
            } finally {
                if (operationBusyToken == myBusyToken && busyLabel == assignedBusy) {
                    busyLabel = null
                }
                if (authEpoch == expectedAuthEpoch) {
                    isBootstrapping = false
                }
                synchronized(bootstrapLock) {
                    if (selfDeferred != null && bootstrapDeferred === selfDeferred) {
                        bootstrapDeferred = null
                    }
                }
            }
        }
        if (!created.isCompleted) {
            selfDeferred = created
            bootstrapDeferred = created
        }
        created
    }

    fun beginQrLogin() {
        qrPollJob?.cancel()
        val startEpoch: Int
        val myBusyToken: Int
        synchronized(bootstrapLock) {
            startEpoch = authEpoch
            operationBusyToken += 1
            myBusyToken = operationBusyToken
        }
        scope.launch {
            val assignedBusy = "生成二维码..."
            busyLabel = assignedBusy
            try {
                val start = cloudClient.startQrLogin()
                if (authEpoch != startEpoch || isAuthenticated) return@launch
                qrContent = start.qrContent
                qrHint = start.message
                setStatus(start.message, StatusKind.INFO)
                val bmp = withContext(ioDispatcher) {
                    QrCodeHelper.generateQrBitmap(start.qrContent, 480)
                }
                if (authEpoch != startEpoch || isAuthenticated) return@launch
                qrBitmap = bmp
                startQrPolling(startEpoch)
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                if (authEpoch == startEpoch) {
                    setStatus(e.message, StatusKind.ERROR)
                }
            } finally {
                if (operationBusyToken == myBusyToken && busyLabel == assignedBusy) {
                    busyLabel = null
                }
            }
        }
    }

    private fun startQrPolling(startEpoch: Int = authEpoch) {
        qrPollJob?.cancel()
        qrPollJob = scope.launch {
            while (isActive && authEpoch == startEpoch) {
                delay(2500L)
                if (!isActive || authEpoch != startEpoch) return@launch
                try {
                    val (poll, clientEpoch) = cloudClient.pollQrLoginWithEpoch()
                    if (!isActive || authEpoch != startEpoch) {
                        if (clientEpoch != null) {
                            cloudClient.clearSessionImmediate(clientEpoch)
                        }
                        return@launch
                    }
                    qrHint = poll.message
                    setStatus(
                        poll.message,
                        if (poll.state == QrLoginState.EXPIRED) StatusKind.ERROR else StatusKind.INFO
                    )
                    when (poll.state) {
                        QrLoginState.AUTHENTICATED -> {
                            val qrAuthEpoch: Int
                            val pendingCleanup: Deferred<Unit>?
                            synchronized(bootstrapLock) {
                                if (authEpoch != startEpoch) {
                                    if (clientEpoch != null) {
                                        cloudClient.clearSessionImmediate(clientEpoch)
                                    }
                                    return@launch
                                }
                                authEpoch += 1
                                qrAuthEpoch = authEpoch
                                pendingCleanup = cookieCleanupDeferred
                                isBootstrapping = false
                                bootstrapDeferred?.cancel()
                                bootstrapDeferred = null
                            }
                            if (pendingCleanup != null) {
                                try {
                                    pendingCleanup.await()
                                } catch (ce: CancellationException) {
                                    if (!isActive) throw ce
                                } catch (_: Throwable) {
                                }
                            }
                            if (!isActive || authEpoch != qrAuthEpoch) {
                                if (clientEpoch != null) {
                                    cloudClient.clearSessionImmediate(clientEpoch)
                                }
                                return@launch
                            }
                            val active = cloudClient.activeSession
                            val persisted = cloudClient.persistedCredential
                            val identity = if (active != null) {
                                Cloud189Protocol.resolveAccountIdentity(active, persisted)
                            } else {
                                val fallbackDisplay = poll.accountName ?: Cloud189Constants.DEFAULT_ACCOUNT_DISPLAY_NAME
                                val fallbackKey = if (fallbackDisplay != Cloud189Constants.DEFAULT_ACCOUNT_DISPLAY_NAME) {
                                    fallbackDisplay
                                } else {
                                    Cloud189Protocol.deriveFallbackAccountKey(
                                        refreshToken = persisted?.refreshToken,
                                        accessToken = null,
                                        sessionKey = UUID.randomUUID().toString()
                                    )
                                }
                                Cloud189Protocol.AccountIdentity(fallbackKey, fallbackDisplay)
                            }
                            persisted?.let { cred ->
                                runCatching {
                                    withContext(ioDispatcher) {
                                        if (authEpoch == qrAuthEpoch) {
                                            credentialStore?.saveCredential(cred.withAccountKey(identity.storageKey))
                                        }
                                    }
                                }.onFailure { err ->
                                    if (authEpoch == qrAuthEpoch) {
                                        setStatus("登录凭据保存异常：${err.message}", StatusKind.ERROR)
                                    }
                                }
                            }
                            if (authEpoch != qrAuthEpoch) {
                                if (clientEpoch != null) {
                                    cloudClient.clearSessionImmediate(clientEpoch)
                                }
                                return@launch
                            }
                            qrContent = null
                            qrBitmap = null
                            activateAccount(
                                storageKey = identity.storageKey,
                                displayName = identity.displayName,
                                expectedAuthEpoch = qrAuthEpoch
                            )
                            if (authEpoch != qrAuthEpoch || !isAuthenticated) {
                                if (authEpoch != qrAuthEpoch && clientEpoch != null) {
                                    cloudClient.clearSessionImmediate(clientEpoch)
                                }
                                return@launch
                            }
                            browseToSuspend(BrowserScope.CLOUD, null, listOf(BreadcrumbItem.ROOT), showBusy = false)
                            return@launch
                        }
                        QrLoginState.EXPIRED -> {
                            qrContent = null
                            qrBitmap = null
                            return@launch
                        }
                        else -> Unit
                    }
                } catch (ce: CancellationException) {
                    throw ce
                } catch (e: Exception) {
                    if (authEpoch == startEpoch) {
                        setStatus(e.message, StatusKind.ERROR)
                    }
                    return@launch
                }
            }
        }
    }

    fun completeEmbeddedWebLogin(callbackUrl: String, cookiesByOrigin: Map<String, String?>) {
        val loginEpoch: Int
        val pendingCleanup: Deferred<Unit>?
        val myBusyToken: Int
        synchronized(bootstrapLock) {
            authEpoch += 1
            loginEpoch = authEpoch
            pendingCleanup = cookieCleanupDeferred
            isBootstrapping = false
            bootstrapDeferred?.cancel()
            bootstrapDeferred = null
            operationBusyToken += 1
            myBusyToken = operationBusyToken
        }
        scope.launch {
            val assignedBusy = "正在验证天翼登录会话..."
            busyLabel = assignedBusy
            try {
                if (pendingCleanup != null) {
                    try {
                        pendingCleanup.await()
                    } catch (ce: CancellationException) {
                        if (!isActive) throw ce
                    } catch (_: Throwable) {
                    }
                }
                if (!isActive || authEpoch != loginEpoch) return@launch
                for ((origin, header) in cookiesByOrigin) {
                    cloudClient.importWebCookies(origin, header)
                }
                val (parsed, clientEpoch) = cloudClient.exchangeRedirectForSessionWithEpoch(callbackUrl)
                if (authEpoch != loginEpoch) {
                    cloudClient.clearSessionImmediate(clientEpoch)
                    return@launch
                }
                val identity = Cloud189Protocol.resolveAccountIdentity(
                    activeSession = parsed.activeSession,
                    persistedCredential = parsed.persistedCredential
                )
                var credentialWarning: String? = null
                parsed.persistedCredential?.let { cred ->
                    runCatching {
                        withContext(ioDispatcher) {
                            if (authEpoch == loginEpoch) {
                                credentialStore?.saveCredential(cred.withAccountKey(identity.storageKey))
                            }
                        }
                    }.onFailure { err ->
                        val warning = "登录凭据保存异常：${err.message ?: "未知错误"}"
                        credentialWarning = warning
                        if (authEpoch == loginEpoch) {
                            setStatus(warning, StatusKind.ERROR)
                        }
                    }
                }
                if (authEpoch != loginEpoch) {
                    cloudClient.clearSessionImmediate(clientEpoch)
                    return@launch
                }
                isShowingWebLoginDialog = false
                qrPollJob?.cancel()
                qrContent = null
                qrBitmap = null
                activateAccount(
                    storageKey = identity.storageKey,
                    displayName = identity.displayName,
                    expectedAuthEpoch = loginEpoch
                )
                if (authEpoch != loginEpoch || !isAuthenticated) {
                    if (authEpoch != loginEpoch) {
                        cloudClient.clearSessionImmediate(clientEpoch)
                    }
                    return@launch
                }
                browseToSuspend(BrowserScope.CLOUD, null, listOf(BreadcrumbItem.ROOT), showBusy = false)
                if (authEpoch == loginEpoch && isAuthenticated && activeAccountKey == identity.storageKey) {
                    if (credentialWarning != null) {
                        setStatus("天翼官方网页一键登录成功（$credentialWarning）", StatusKind.ERROR)
                    } else {
                        setStatus("天翼官方网页一键登录成功", StatusKind.INFO)
                    }
                }
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                if (authEpoch == loginEpoch) {
                    isShowingWebLoginDialog = false
                    setStatus(
                        "网页回调兑换失败（${e.message}），已自动切换二维码登录，可保存二维码到相册识别。",
                        StatusKind.ERROR
                    )
                    beginQrLogin()
                }
            } finally {
                if (operationBusyToken == myBusyToken && busyLabel == assignedBusy) {
                    busyLabel = null
                }
            }
        }
    }

    internal suspend fun activateAccount(
        storageKey: String,
        displayName: String,
        expectedAuthEpoch: Int = authEpoch
    ) {
        val fallbackAppearance = committedSettings.appearanceMode
        val fallbackDynamicColor = committedSettings.dynamicColorEnabled
        val loaded = withContext(ioDispatcher) {
            val paths = accountStore.paths(storageKey)
            val cm = CacheManager(paths.cacheDir)
            val usage = cm.usageBytes()
            val savedSettings = accountStore.loadSettingsOrNull(storageKey)
                ?: AccountSettings(
                    appearanceMode = fallbackAppearance,
                    dynamicColorEnabled = fallbackDynamicColor
                )
            val savedTracks = accountStore.loadLibrary(storageKey)
            transferEngine.restorePersistedDownloads(storageKey, paths.stagingDir, paths.transfersFile)
            val snap = transferEngine.snapshot()
            LoadedAccountState(cm, usage, savedSettings, savedTracks, snap)
        }
        if (authEpoch != expectedAuthEpoch) return
        isAuthenticated = true
        accountStorageKey = storageKey
        accountName = displayName
        playbackGeneration += 1
        externalVideoGeneration += 1
        cloudBrowserGeneration += 1
        videoBrowserGeneration += 1
        cloudBrowserIdleGeneration = cloudBrowserGeneration
        videoBrowserIdleGeneration = videoBrowserGeneration
        cacheManager = loaded.cacheManager
        cacheUsageBytes = loaded.usageBytes
        committedSettings = loaded.settings
        mirrorThemePrefs(themeMode, dynamicColorEnabled)
        syncDraftsFromCommitted()
        tracks = loaded.tracks
        shuffleOrderIds = PlaybackQueueResolver.buildShuffleOrder(loaded.tracks, currentTrackId)
        transferSnapshot = loaded.snapshot
        syncQueueAvailabilityToBridge()
        handleTransferActivityChange(loaded.snapshot, loaded.snapshot.hasActiveItems)
    }

    private data class LoadedAccountState(
        val cacheManager: CacheManager,
        val usageBytes: Long,
        val settings: AccountSettings,
        val tracks: List<TrackSummary>,
        val snapshot: TransferSnapshotPayload
    )

    fun logout() {
        val previousAccountKey = activeAccountKey
        synchronized(bootstrapLock) {
            authEpoch += 1
            val cleanupEpoch = authEpoch
            isAuthenticated = false
            isBootstrapping = false
            bootstrapDeferred?.cancel()
            bootstrapDeferred = null
            val previousCleanup = cookieCleanupDeferred
            cookieCleanupDeferred = scope.async {
                if (previousCleanup != null) {
                    try {
                        previousCleanup.await()
                    } catch (ce: CancellationException) {
                        if (!isActive) throw ce
                    } catch (_: Throwable) {
                    }
                }
                if (authEpoch != cleanupEpoch || isAuthenticated) return@async
                runCatching {
                    withContext(ioDispatcher) {
                        if (authEpoch == cleanupEpoch && !isAuthenticated) {
                            credentialStore?.clearCredential()
                        }
                    }
                }
                if (hasAndroidContext && authEpoch == cleanupEpoch && !isAuthenticated) {
                    clearWebViewCookiesAndFlush()
                }
            }
        }
        qrPollJob?.cancel()
        qrPollJob = null
        transferRefreshJob?.cancel()
        transferRefreshJob = null
        uiProgressClockJob?.cancel()
        uiProgressClockJob = null
        scheduledPrefetchJob?.cancel()
        scheduledPrefetchJob = null
        activePrefetchJob?.cancel()
        activePrefetchJob = null
        lastExternalVideoJob?.cancel()
        lastExternalVideoJob = null
        playbackGeneration += 1
        externalVideoGeneration += 1
        cloudBrowserGeneration += 1
        videoBrowserGeneration += 1
        cloudBrowserIdleGeneration = cloudBrowserGeneration
        videoBrowserIdleGeneration = videoBrowserGeneration
        recoveryAttempts = 0
        pendingMediaItem = null
        prefetchedTrackId = null
        prefetchingTrackId = null
        activeAudioSourceToken?.let { token ->
            activeAudioSourceToken = null
            streamServer?.revokeSource(token)
        }
        closeVideoPlayer()
        mediaController?.stop()
        mediaController?.clearMediaItems()
        previousAccountKey?.let { key ->
            streamServer?.revokeAllSources(Cloud189Protocol.accountBucketHash(key))
            transferEngine.cancelAll(key)
        }
        cloudClient.clearSessionImmediate()

        busyLabel = null
        accountName = null
        accountStorageKey = null
        cacheManager = null
        cacheUsageBytes = 0L
        cloudBrowser = BrowserPaneState()
        videoBrowser = BrowserPaneState()
        tracks = emptyList()
        upNextQueue = emptyList()
        shuffleOrderIds = emptyList()
        activeTrack = null
        currentTrackId = null
        nowPlayingTitle = null
        nowPlayingArtist = null
        nowPlayingAlbum = null
        nowPlayingArtwork = null
        isPlaying = false
        loadingTrackId = null
        currentTime = 0.0
        duration = 0.0
        isShowingNowPlayingSheet = false
        isShowingWebLoginDialog = false
        activeModule = ModuleTab.MUSIC
        pendingExternalVideoAction = null
        transferSnapshot = TransferSnapshotPayload()
        committedSettings = AccountSettings(
            appearanceMode = themeMode,
            dynamicColorEnabled = dynamicColorEnabled
        )
        syncDraftsFromCommitted()
        syncQueueAvailabilityToBridge()
        setStatus("已退出登录并清理当前会话", StatusKind.INFO)
    }

    private suspend fun clearWebViewCookiesAndFlush() {
        val cookieMgr = runCatching { CookieManager.getInstance() }.getOrNull() ?: return
        withTimeoutOrNull(1500L) {
            suspendCancellableCoroutine<Unit> { cont ->
                runCatching {
                    cookieMgr.removeAllCookies {
                        if (cont.isActive) cont.resume(Unit)
                    }
                }.onFailure {
                    if (cont.isActive) cont.resume(Unit)
                }
            }
        }
        withContext(Dispatchers.IO) {
            runCatching { cookieMgr.flush() }
        }
    }

    fun browseTo(folderId: String?, nextCrumbs: List<BreadcrumbItem>, showBusy: Boolean = true) {
        browseTo(BrowserScope.CLOUD, folderId, nextCrumbs, showBusy)
    }

    fun browseTo(
        scopeTarget: BrowserScope,
        folderId: String?,
        nextCrumbs: List<BreadcrumbItem>,
        showBusy: Boolean = true
    ) {
        if (!isAuthenticated) return
        scope.launch {
            browseToSuspend(scopeTarget, folderId, nextCrumbs, showBusy)
        }
    }

    fun navigateBackInBrowser(scopeTarget: BrowserScope) {
        val crumbs = if (scopeTarget == BrowserScope.CLOUD) cloudBrowser.breadcrumbs else videoBrowser.breadcrumbs
        if (crumbs.size <= 1) return
        val nextCrumbs = crumbs.dropLast(1)
        browseTo(scopeTarget, nextCrumbs.lastOrNull()?.id, nextCrumbs)
    }

    private fun nextBrowserGeneration(scopeTarget: BrowserScope): Int {
        return when (scopeTarget) {
            BrowserScope.CLOUD -> {
                cloudBrowserGeneration += 1
                cloudBrowserGeneration
            }
            BrowserScope.VIDEO -> {
                videoBrowserGeneration += 1
                videoBrowserGeneration
            }
        }
    }

    private fun currentBrowserGeneration(scopeTarget: BrowserScope): Int {
        return when (scopeTarget) {
            BrowserScope.CLOUD -> cloudBrowserGeneration
            BrowserScope.VIDEO -> videoBrowserGeneration
        }
    }

    internal suspend fun browseToSuspend(
        scopeTarget: BrowserScope,
        folderId: String?,
        nextCrumbs: List<BreadcrumbItem>,
        showBusy: Boolean
    ) {
        if (!isAuthenticated) return
        val expectedAccount = activeAccountKey
        val gen = nextBrowserGeneration(scopeTarget)
        val assignedBusy: String?
        val myBusyToken: Int
        if (showBusy) {
            val label = "读取云盘目录..."
            busyLabel = label
            browserBusyToken += 1
            assignedBusy = label
            myBusyToken = browserBusyToken
        } else {
            assignedBusy = null
            myBusyToken = 0
        }
        val isRoot = folderId == null || folderId == Cloud189Constants.ROOT_FOLDER_ID
        val nonRootCrumbs = nextCrumbs.filter { it.id != null && it.id != Cloud189Constants.ROOT_FOLDER_ID }
        val resolvedName = if (isRoot) {
            Cloud189Constants.ROOT_FOLDER_NAME
        } else {
            nonRootCrumbs.lastOrNull()?.name ?: nextCrumbs.lastOrNull()?.name
        }
        val resolvedPath = if (isRoot) {
            Cloud189Constants.ROOT_FOLDER_NAME
        } else {
            nonRootCrumbs.map { it.name }.filter { it.isNotEmpty() }.joinToString("/").takeIf { it.isNotEmpty() }
        }
        try {
            val listing = cloudClient.listRemoteFolder(
                folderId = folderId,
                folderName = resolvedName,
                folderPath = resolvedPath
            )
            if (gen != currentBrowserGeneration(scopeTarget) || !isAuthenticated || activeAccountKey != expectedAccount) {
                return
            }
            val nextPane = BrowserPaneState(breadcrumbs = nextCrumbs, payload = listing)
            when (scopeTarget) {
                BrowserScope.CLOUD -> {
                    cloudBrowser = nextPane
                    if (isRoot && videoBrowser.payload == null && videoBrowserGeneration == videoBrowserIdleGeneration) {
                        videoBrowser = nextPane
                    }
                }
                BrowserScope.VIDEO -> {
                    videoBrowser = nextPane
                    if (isRoot && cloudBrowser.payload == null && cloudBrowserGeneration == cloudBrowserIdleGeneration) {
                        cloudBrowser = nextPane
                    }
                }
            }
        } catch (ce: CancellationException) {
            throw ce
        } catch (e: Exception) {
            if (gen == currentBrowserGeneration(scopeTarget) && isAuthenticated && activeAccountKey == expectedAccount) {
                setStatus(e.message, StatusKind.ERROR)
            }
        } finally {
            if (assignedBusy != null && browserBusyToken == myBusyToken && busyLabel == assignedBusy) {
                busyLabel = null
            }
        }
    }

    fun setCurrentFolderAsMusicLibrary(pane: BrowserPaneState = cloudBrowser) {
        val b = pane.payload ?: return
        val crumb = pane.breadcrumbs.lastOrNull() ?: return
        val displayName = if (crumb.id == b.currentFolderId || (b.isRoot && crumb.id == null)) {
            crumb.name
        } else {
            b.currentFolderName
        }
        scope.launch {
            val ok = mutateAccountSettings(
                successMessage = "音乐目录已设置为 $displayName"
            ) { prev ->
                prev.copy(musicFolder = FolderSelection(b.currentFolderId, displayName))
            }
            if (ok) {
                scanMusicLibrary()
            }
        }
    }

    fun scanMusicLibrary() {
        if (!isAuthenticated) {
            setStatus("请先在云盘目录中设为音乐库", StatusKind.INFO)
            return
        }
        val folder = committedSettings.musicFolder ?: run {
            setStatus("请先在云盘目录中设为音乐库", StatusKind.INFO)
            return
        }
        val acct = activeAccountKey ?: return
        val expectedEpoch: Int
        val myBusyToken: Int
        synchronized(bootstrapLock) {
            expectedEpoch = authEpoch
            operationBusyToken += 1
            myBusyToken = operationBusyToken
        }
        scope.launch {
            val assignedBusy = "扫描 ${folder.name} 中的音乐..."
            busyLabel = assignedBusy
            try {
                val scanned = cloudClient.scanMusicLibrary(folder.id, folder.name)
                if (!isAuthenticated || authEpoch != expectedEpoch || activeAccountKey != acct) return@launch
                tracks = scanned
                if (shuffle) {
                    shuffleOrderIds = PlaybackQueueResolver.buildShuffleOrder(scanned, currentTrackId)
                }
                syncQueueAvailabilityToBridge()
                val persistedOk = runCatching {
                    withContext(ioDispatcher) {
                        accountStore.saveLibrary(acct, scanned)
                    }
                }.isSuccess
                if (isAuthenticated && authEpoch == expectedEpoch && activeAccountKey == acct) {
                    if (persistedOk) {
                        setStatus("已载入 ${scanned.size} 首音乐", StatusKind.INFO)
                    } else {
                        setStatus("已载入 ${scanned.size} 首音乐（本地索引保存失败）", StatusKind.ERROR)
                    }
                }
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                if (isAuthenticated && authEpoch == expectedEpoch && activeAccountKey == acct) {
                    setStatus(e.message, StatusKind.ERROR)
                }
            } finally {
                if (operationBusyToken == myBusyToken && busyLabel == assignedBusy) {
                    busyLabel = null
                }
            }
        }
    }

    fun playNext(track: TrackSummary) {
        upNextQueue = PlaybackQueueResolver.insertPlayNext(upNextQueue, track)
        activePrefetchJob?.cancel()
        activePrefetchJob = null
        prefetchingTrackId = null
        prefetchedTrackId = null
        syncQueueAvailabilityToBridge()
        setStatus("已设为下一首播放：《${track.name}》", StatusKind.INFO)
        scheduleUpcomingPrefetch()
    }

    fun appendToQueue(track: TrackSummary) {
        upNextQueue = PlaybackQueueResolver.appendToQueue(upNextQueue, track)
        syncQueueAvailabilityToBridge()
        setStatus("已加入待播队列：《${track.name}》", StatusKind.INFO)
    }

    fun removeFromQueue(trackId: String) {
        upNextQueue = PlaybackQueueResolver.removeFromQueue(upNextQueue, trackId)
        syncQueueAvailabilityToBridge()
    }

    fun clearUpNextQueue() {
        upNextQueue = emptyList()
        syncQueueAvailabilityToBridge()
    }

    fun playFromUpcomingQueue(track: TrackSummary) {
        if (upNextQueue.any { it.id == track.id }) {
            upNextQueue = PlaybackQueueResolver.removeFromQueue(upNextQueue, track.id)
            prefetchedTrackId = null
            syncQueueAvailabilityToBridge()
        }
        playTrack(track)
    }

    fun toggleShuffle() {
        shuffle = !shuffle
        if (shuffle) {
            shuffleOrderIds = PlaybackQueueResolver.buildShuffleOrder(tracks, currentTrackId)
        }
        activePrefetchJob?.cancel()
        activePrefetchJob = null
        prefetchingTrackId = null
        prefetchedTrackId = null
        syncQueueAvailabilityToBridge()
        scheduleUpcomingPrefetch()
    }

    fun cycleLoopMode() {
        loopMode = when (loopMode) {
            LoopMode.OFF -> LoopMode.ALL
            LoopMode.ALL -> LoopMode.ONE
            LoopMode.ONE -> LoopMode.OFF
        }
        if (loopMode == LoopMode.ONE) {
            activePrefetchJob?.cancel()
            activePrefetchJob = null
            prefetchingTrackId = null
        }
        syncQueueAvailabilityToBridge()
        scheduleUpcomingPrefetch()
    }

    fun playTrack(
        track: TrackSummary,
        modeOverride: PlaybackMode? = null,
        forceStreamProxy: Boolean = false,
        isRecoveryRetry: Boolean = false
    ) {
        val acctKey = activeAccountKey ?: return
        val cm = cacheManager ?: return
        activeAudioSourceToken?.let { token ->
            activeAudioSourceToken = null
            streamServer?.revokeSource(token)
        }
        closeVideoPlayer()
        playbackGeneration += 1
        val gen = playbackGeneration
        activeTrack = track
        currentTrackId = track.id
        prefetchedTrackId = null
        val candidateCacheDest = cm.cacheFile(track.id, track.name)
        val coalesceInFlightPrefetch = !forceStreamProxy && (
            prefetchingTrackId == track.id || transferEngine.hasInFlightCacheDownload(candidateCacheDest)
        )
        if (!coalesceInFlightPrefetch) {
            activePrefetchJob?.cancel()
            activePrefetchJob = null
            prefetchingTrackId = null
        }
        scheduledPrefetchJob?.cancel()
        scheduledPrefetchJob = null
        if (shuffle && track.id !in shuffleOrderIds && tracksById.containsKey(track.id)) {
            shuffleOrderIds = PlaybackQueueResolver.buildShuffleOrder(tracks, track.id)
        }
        syncQueueAvailabilityToBridge()
        if (!isRecoveryRetry) {
            recoveryAttempts = 0
        }
        val accountHash = Cloud189Protocol.accountBucketHash(acctKey)
        val fallbackAlbum = track.folderPath.ifBlank { committedSettings.musicFolder?.name ?: "CloudTune" }

        scope.launch {
            loadingTrackId = track.id
            val effectiveMode = modeOverride ?: committedSettings.playbackMode
            try {
                val (cached, inFlightNow) = withContext(ioDispatcher) {
                    cm.setProtectedTrackIds(setOf(track.id))
                    val existing = cm.existingCachedFile(track.id)
                    val inFlight = if (existing == null && !forceStreamProxy) {
                        transferEngine.hasInFlightCacheDownload(cm.cacheFile(track.id, track.name))
                    } else {
                        false
                    }
                    existing to inFlight
                }
                if (cached != null) {
                    val (usage, meta) = withContext(ioDispatcher) {
                        cm.usageBytes() to AudioMetadataHelper.extract(
                            localFile = cached,
                            fallbackTitle = track.name,
                            fallbackArtist = null,
                            fallbackAlbum = fallbackAlbum
                        )
                    }
                    if (!isActive || gen != playbackGeneration || !isAuthenticated || activeAccountKey != acctKey || cacheManager !== cm) return@launch
                    cacheUsageBytes = usage
                    val fileUri = Uri.fromFile(cached)?.toString() ?: cached.toURI().toString()
                    startControllerPlayback(track, fileUri, isLoopback = false, metadata = meta)
                    return@launch
                }
                val downloadFirst = (!forceStreamProxy && (coalesceInFlightPrefetch || inFlightNow)) ||
                    PlaybackDecisionPolicy.shouldDownloadBeforePlayback(
                        mode = effectiveMode,
                        sizeBytes = track.sizeBytes,
                        forceStreamProxy = forceStreamProxy
                    )
                if (downloadFirst) {
                    val file = transferEngine.downloadTrackToCache(
                        track = track,
                        cacheManager = cm,
                        parallelThreads = committedSettings.downloadThreads,
                        cacheLimitBytes = committedSettings.cacheLimitBytes,
                        kind = "playback",
                        accountHash = accountHash
                    )
                    if (!isActive || gen != playbackGeneration || !isAuthenticated || activeAccountKey != acctKey || cacheManager !== cm) return@launch
                    val (usage, meta) = withContext(ioDispatcher) {
                        cm.usageBytes() to AudioMetadataHelper.extract(
                            localFile = file,
                            fallbackTitle = track.name,
                            fallbackArtist = null,
                            fallbackAlbum = fallbackAlbum
                        )
                    }
                    if (!isActive || gen != playbackGeneration || !isAuthenticated || activeAccountKey != acctKey || cacheManager !== cm) return@launch
                    cacheUsageBytes = usage
                    val fileUri = Uri.fromFile(file)?.toString() ?: file.toURI().toString()
                    startControllerPlayback(track, fileUri, isLoopback = false, metadata = meta)
                } else {
                    val remoteUrl = cloudClient.resolveDownloadUrl(track.id)
                    if (!isActive || gen != playbackGeneration || !isAuthenticated || activeAccountKey != acctKey || cacheManager !== cm) return@launch
                    val dest = withContext(ioDispatcher) { cm.cacheFile(track.id, track.name) }
                    if (!isActive || gen != playbackGeneration || !isAuthenticated || activeAccountKey != acctKey || cacheManager !== cm) return@launch
                    val server = streamServer
                    val reg = StreamSourceRegistration(
                        accountHash = accountHash,
                        trackId = track.id,
                        remoteUrl = remoteUrl,
                        cacheDestination = dest,
                        expectedSize = track.sizeBytes,
                        fileName = track.name,
                        cacheLimitBytes = committedSettings.cacheLimitBytes
                    )
                    val playUrl = server?.registerSource(reg, cacheManager = cm) ?: remoteUrl
                    val registeredToken = if (server != null) reg.token else null
                    if (!isActive || gen != playbackGeneration || !isAuthenticated || activeAccountKey != acctKey || cacheManager !== cm) {
                        registeredToken?.let { server?.revokeSource(it) }
                        return@launch
                    }
                    startControllerPlayback(
                        track = track,
                        uriString = playUrl,
                        isLoopback = true,
                        metadata = null,
                        sourceToken = registeredToken
                    )
                }
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                if (gen == playbackGeneration && isAuthenticated) {
                    handlePlaybackError(track, e.message.orEmpty(), wasLoopback = false)
                }
            } finally {
                if (gen == playbackGeneration) {
                    loadingTrackId = null
                }
            }
        }
    }

    private fun decodeArtworkBitmap(bytes: ByteArray?): Bitmap? =
        AudioMetadataHelper.decodeSampledBitmap(bytes, maxDimensionPx = AudioMetadataHelper.MAX_ARTWORK_DIMENSION_PX)

    private fun buildMediaMetadata(
        track: TrackSummary,
        title: String,
        artist: String?,
        album: String,
        artworkBytes: ByteArray?
    ): MediaMetadata {
        val builder = MediaMetadata.Builder()
            .setTitle(title)
            .setAlbumTitle(album.ifBlank { track.folderPath })
        if (!artist.isNullOrBlank()) {
            builder.setArtist(artist)
        }
        if (artworkBytes != null && artworkBytes.isNotEmpty()) {
            builder.setArtworkData(artworkBytes, MediaMetadata.PICTURE_TYPE_FRONT_COVER)
        }
        return builder.build()
    }

    private fun startControllerPlayback(
        track: TrackSummary,
        uriString: String,
        isLoopback: Boolean,
        metadata: ExtractedAudioMetadata?,
        sourceToken: String? = null
    ) {
        val priorAudioToken = activeAudioSourceToken
        activeAudioSourceToken = sourceToken
        if (priorAudioToken != null && priorAudioToken != sourceToken) {
            streamServer?.revokeSource(priorAudioToken)
        }
        currentPlaybackIsLoopback = isLoopback
        activeTrack = track
        currentTrackId = track.id
        lastPreparedPlaybackUrl = uriString
        val resolvedTitle = metadata?.title ?: track.name
        val resolvedArtist = metadata?.artist
        val resolvedAlbum = metadata?.album ?: track.folderPath.ifBlank { committedSettings.musicFolder?.name ?: "CloudTune" }
        nowPlayingTitle = resolvedTitle
        nowPlayingArtist = resolvedArtist
        nowPlayingAlbum = resolvedAlbum
        nowPlayingArtwork = decodeArtworkBitmap(metadata?.artworkBytes)
        currentTime = 0.0

        val controller = mediaController
        if (controller != null || hasAndroidContext) {
            val mediaMeta = buildMediaMetadata(
                track = track,
                title = resolvedTitle,
                artist = resolvedArtist,
                album = resolvedAlbum,
                artworkBytes = metadata?.artworkBytes
            )
            val item = MediaItem.Builder()
                .setMediaId(track.id)
                .setUri(uriString)
                .setMediaMetadata(mediaMeta)
                .build()
            if (controller != null) {
                pendingMediaItem = null
                controller.setMediaItem(item)
                controller.prepare()
                controller.play()
            } else {
                pendingMediaItem = item
            }
        }
        isPlaying = true
        updateUiProgressClock()
        syncQueueAvailabilityToBridge()
        scheduleUpcomingPrefetch()
        setStatus(
            if (isLoopback) "边播边缓存《${track.name}》" else "正在播放《${track.name}》",
            StatusKind.INFO
        )
    }

    internal suspend fun handleWriteThroughCompleted(
        accountHash: String,
        trackId: String,
        localFile: File
    ) {
        val expectedAccount = activeAccountKey ?: return
        if (!isAuthenticated || Cloud189Protocol.accountBucketHash(expectedAccount) != accountHash) return
        val capturedManager = cacheManager
        val gen = playbackGeneration
        val capturedTrack = if (currentTrackId == trackId) currentTrack else null
        val fallbackAlbum = capturedTrack?.let {
            it.folderPath.ifBlank { committedSettings.musicFolder?.name ?: "CloudTune" }
        }

        if (capturedManager != null) {
            val latestUsage = withContext(ioDispatcher) { capturedManager.usageBytes() }
            if (!isAuthenticated || activeAccountKey != expectedAccount || cacheManager !== capturedManager) return
            cacheUsageBytes = latestUsage
        }

        if (
            !isAuthenticated ||
            activeAccountKey != expectedAccount ||
            cacheManager !== capturedManager ||
            gen != playbackGeneration ||
            currentTrackId != trackId
        ) {
            return
        }
        val track = capturedTrack ?: currentTrack ?: return
        val resolvedAlbum = fallbackAlbum ?: track.folderPath.ifBlank { committedSettings.musicFolder?.name ?: "CloudTune" }
        val (enriched, bmp) = withContext(ioDispatcher) {
            val m = AudioMetadataHelper.extract(
                localFile = localFile,
                fallbackTitle = track.name,
                fallbackArtist = null,
                fallbackAlbum = resolvedAlbum
            )
            m to decodeArtworkBitmap(m.artworkBytes)
        }
        if (
            !isAuthenticated ||
            activeAccountKey != expectedAccount ||
            cacheManager !== capturedManager ||
            gen != playbackGeneration ||
            currentTrackId != trackId
        ) {
            return
        }
        nowPlayingTitle = enriched.title
        nowPlayingArtist = enriched.artist
        nowPlayingAlbum = enriched.album
        nowPlayingArtwork = bmp
        mediaController?.let { mc ->
            if (mc.currentMediaItem?.mediaId == trackId && mc.currentMediaItem != null) {
                val updatedItem = mc.currentMediaItem!!.buildUpon()
                    .setMediaMetadata(
                        buildMediaMetadata(
                            track = track,
                            title = enriched.title,
                            artist = enriched.artist,
                            album = enriched.album,
                            artworkBytes = enriched.artworkBytes
                        )
                    )
                    .build()
                runCatching { mc.replaceMediaItem(mc.currentMediaItemIndex, updatedItem) }
            }
        }
    }

    fun handlePlaybackError(
        track: TrackSummary,
        message: String,
        wasLoopback: Boolean,
        explicitIsDecode: Boolean? = null
    ) {
        val failedGeneration = playbackGeneration
        val lower = message.lowercase()
        val lowerName = track.name.lowercase()
        val isTimeout = lower.contains("timeout") || lower.contains("timed out")
        val isUnsupportedExt = lowerName.endsWith(".ape") || lowerName.endsWith(".wma")
        val isDecode = explicitIsDecode ?: (
            lower.contains("decode") ||
                lower.contains("unrecognized") ||
                lower.contains("unsupported") ||
                (wasLoopback && !isTimeout && isUnsupportedExt)
            )
        val action = PlaybackDecisionPolicy.classifyPlaybackFailure(
            fileName = track.name,
            wasLoopbackStream = wasLoopback,
            wasDownloadPhaseTimeout = isTimeout,
            isDecodeOrFormatUnsupported = isDecode,
            priorAttemptCount = recoveryAttempts
        )
        recoveryAttempts += 1
        when (action) {
            PlaybackFailureAction.FallbackToStreamProxyOnce -> {
                if (!isAuthenticated || playbackGeneration != failedGeneration) return
                playTrack(
                    track = track,
                    modeOverride = PlaybackMode.STREAM_CACHE,
                    forceStreamProxy = true,
                    isRecoveryRetry = true
                )
            }
            PlaybackFailureAction.FallbackToFullDownloadOnce -> {
                if (!isAuthenticated || playbackGeneration != failedGeneration) return
                playTrack(
                    track = track,
                    modeOverride = PlaybackMode.DOWNLOAD_FIRST,
                    forceStreamProxy = false,
                    isRecoveryRetry = true
                )
            }
            is PlaybackFailureAction.StopImmediatelyUnsupportedCodec -> {
                isPlaying = false
                updateUiProgressClock()
                setStatus(action.userMessage, StatusKind.ERROR)
            }
            PlaybackFailureAction.StopAfterMaxRetries -> {
                isPlaying = false
                updateUiProgressClock()
                setStatus("播放异常，已停止自动重试《${track.name}》", StatusKind.ERROR)
            }
            is PlaybackFailureAction.RetryTransientAfterDelay -> {
                isPlaying = false
                updateUiProgressClock()
                if (!isAuthenticated || playbackGeneration != failedGeneration) return
                setStatus(
                    "播放波动，正在重试《${track.name}》(${action.attempt}/${PlaybackDecisionPolicy.MAX_RECOVERY_ATTEMPTS})",
                    StatusKind.INFO
                )
                val delayMs = maxOf(0L, retryBaseDelayMs) * action.attempt
                scope.launch {
                    if (delayMs > 0L) {
                        delay(delayMs)
                    }
                    if (!isActive || !isAuthenticated || playbackGeneration != failedGeneration) {
                        return@launch
                    }
                    playTrack(track = track, isRecoveryRetry = true)
                }
            }
        }
    }

    fun togglePlayback() {
        val curr = currentTrack ?: run {
            if (upNextQueue.isNotEmpty()) {
                val firstUpNext = upNextQueue.first()
                upNextQueue = upNextQueue.drop(1)
                prefetchedTrackId = null
                syncQueueAvailabilityToBridge()
                playTrack(firstUpNext)
                return
            }
            val candidate = if (shuffle) tracks.randomOrNull() else visibleTracks.firstOrNull()
            (candidate ?: tracks.firstOrNull())?.let { playTrack(it) }
            return
        }
        val controller = mediaController
        if (controller == null) {
            val nextPlaying = !isPlaying
            if (nextPlaying && (activeVideoUrl != null || videoPlayer != null)) {
                closeVideoPlayer()
            }
            isPlaying = nextPlaying
            updateUiProgressClock()
            return
        }
        if (controller.isPlaying) {
            controller.pause()
            isPlaying = false
        } else {
            if (activeVideoUrl != null || videoPlayer != null) {
                closeVideoPlayer()
            }
            if (controller.mediaItemCount == 0) playTrack(curr) else controller.play()
            isPlaying = true
        }
        updateUiProgressClock()
        scheduleUpcomingPrefetch()
    }

    fun playAdjacent(direction: Int, autoAdvanceAtEnd: Boolean = false) {
        val step = if (direction >= 0) {
            PlaybackQueueResolver.resolveNext(
                currentTrack = currentTrack,
                libraryTracks = tracks,
                upNextQueue = upNextQueue,
                shuffle = shuffle,
                shuffleOrderIds = shuffleOrderIds,
                loopMode = loopMode,
                autoAdvanceAtEnd = autoAdvanceAtEnd,
                precomputedOrdered = orderedBaseTracks,
                orderedIndexById = trackIndexById
            )
        } else {
            PlaybackQueueResolver.resolvePrevious(
                currentTrack = currentTrack,
                libraryTracks = tracks,
                upNextQueue = upNextQueue,
                shuffle = shuffle,
                shuffleOrderIds = shuffleOrderIds,
                loopMode = loopMode,
                precomputedOrdered = orderedBaseTracks,
                orderedIndexById = trackIndexById
            )
        }
        upNextQueue = step.remainingUpNext
        syncQueueAvailabilityToBridge()
        if (step.track != null) {
            playTrack(step.track)
        } else if (autoAdvanceAtEnd) {
            isPlaying = false
            updateUiProgressClock()
        }
    }

    fun seekTo(seconds: Double) {
        val clamped = if (duration > 0.0) seconds.coerceIn(0.0, duration) else seconds.coerceAtLeast(0.0)
        currentTime = clamped
        mediaController?.seekTo((clamped * 1000.0).toLong())
        scheduleUpcomingPrefetch()
    }

    // MARK: - Lifecycle-Safe In-App Video ExoPlayer & Safe External Handoff

    fun openVideoInApp(video: TrackSummary) {
        if (!isAuthenticated) return
        playbackGeneration += 1
        externalVideoGeneration += 1
        lastExternalVideoJob?.cancel()
        lastExternalVideoJob = null
        pendingExternalVideoAction = null
        val gen = playbackGeneration
        val expectedAccount = activeAccountKey
        recoveryAttempts = 0
        scheduledPrefetchJob?.cancel()
        scheduledPrefetchJob = null
        activePrefetchJob?.cancel()
        activePrefetchJob = null
        prefetchingTrackId = null
        mediaController?.pause()
        isPlaying = false
        updateUiProgressClock()

        scope.launch {
            val assignedBusy = "准备视频播放 ${video.name}..."
            busyLabel = assignedBusy
            try {
                val cm = cacheManager
                val cached = withContext(ioDispatcher) { cm?.existingCachedFile(video.id) }
                if (!isActive || gen != playbackGeneration || !isAuthenticated || activeAccountKey != expectedAccount) return@launch
                var registeredToken: String? = null
                val resolvedPlayUrl = if (cached != null && cm === cacheManager) {
                    Uri.fromFile(cached)?.toString() ?: cached.toURI().toString()
                } else {
                    val remoteUrl = cloudClient.resolveDownloadUrl(video.id)
                    if (!isActive || gen != playbackGeneration || !isAuthenticated || activeAccountKey != expectedAccount) return@launch
                    val acct = activeAccountKey
                    val currentCm = cacheManager
                    val server = streamServer
                    if (server != null && currentCm != null && acct != null && acct == expectedAccount) {
                        val dest = withContext(ioDispatcher) { currentCm.cacheFile(video.id, video.name) }
                        if (!isActive || gen != playbackGeneration || !isAuthenticated || activeAccountKey != expectedAccount || cacheManager !== currentCm) return@launch
                        val reg = StreamSourceRegistration(
                            accountHash = Cloud189Protocol.accountBucketHash(acct),
                            trackId = video.id,
                            remoteUrl = remoteUrl,
                            cacheDestination = dest,
                            expectedSize = video.sizeBytes,
                            fileName = video.name,
                            cacheLimitBytes = committedSettings.cacheLimitBytes
                        )
                        registeredToken = reg.token
                        server.registerSource(reg, cacheManager = currentCm)
                    } else {
                        remoteUrl
                    }
                }
                if (!isActive || gen != playbackGeneration || !isAuthenticated || activeAccountKey != expectedAccount) {
                    registeredToken?.let { streamServer?.revokeSource(it) }
                    return@launch
                }
                val priorVideoToken = activeVideoSourceToken
                activeVideoSourceToken = registeredToken
                if (priorVideoToken != null && priorVideoToken != registeredToken) {
                    streamServer?.revokeSource(priorVideoToken)
                }
                activeVideoTrack = video
                activeVideoTitle = video.name
                activeVideoUrl = resolvedPlayUrl
                prepareRuntimeVideoPlayer(resolvedPlayUrl)
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                if (gen == playbackGeneration && isAuthenticated && activeAccountKey == expectedAccount) {
                    setStatus(e.message, StatusKind.ERROR)
                }
            } finally {
                if (busyLabel == assignedBusy) {
                    busyLabel = null
                }
            }
        }
    }

    private fun prepareRuntimeVideoPlayer(playUrl: String) {
        if (!enableLiveLoops) {
            isVideoPlaying = true
            return
        }
        val ctx = appCtx ?: return
        val player = videoPlayer ?: run {
            val videoAttrs = AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build()
            ExoPlayer.Builder(ctx)
                .setAudioAttributes(videoAttrs, true)
                .setHandleAudioBecomingNoisy(true)
                .build()
                .also { created ->
                    created.addListener(object : Player.Listener {
                        override fun onIsPlayingChanged(playing: Boolean) {
                            isVideoPlaying = playing
                        }
                    })
                    videoPlayer = created
                }
        }
        player.setMediaItem(MediaItem.fromUri(playUrl))
        player.prepare()
        player.playWhenReady = true
        isVideoPlaying = true
    }

    fun closeVideoPlayer() {
        isVideoPlaying = false
        activeVideoUrl = null
        activeVideoTitle = null
        activeVideoTrack = null
        activeVideoSourceToken?.let { token ->
            activeVideoSourceToken = null
            streamServer?.revokeSource(token)
        }
        videoPlayer?.let { p ->
            runCatching {
                p.stop()
                p.release()
            }
        }
        videoPlayer = null
    }

    fun saveQrToGallery(context: Context) {
        val bmp = qrBitmap ?: return
        val targetCtx = context.applicationContext
        scope.launch {
            val ok = withContext(ioDispatcher) {
                QrCodeHelper.saveQrBitmapToGallery(targetCtx, bmp)
            }
            if (ok) {
                setStatus("二维码已保存到系统相册", StatusKind.INFO)
            } else {
                setStatus("保存二维码失败", StatusKind.ERROR)
            }
        }
    }

    fun openVideoExternally(context: Context, video: TrackSummary) {
        if (!isAuthenticated) return
        externalVideoGeneration += 1
        val extGen = externalVideoGeneration
        val expectedAccount = activeAccountKey
        val appContextRef = context.applicationContext ?: context
        lastExternalVideoJob?.cancel()
        lastExternalVideoJob = scope.launch {
            val assignedBusy = "准备外部播放《${video.name}》..."
            busyLabel = assignedBusy
            try {
                val capturedCm = cacheManager
                val cached = withContext(ioDispatcher) { capturedCm?.existingCachedFile(video.id) }
                if (extGen != externalVideoGeneration || !isAuthenticated || activeAccountKey != expectedAccount) {
                    return@launch
                }
                if (cached != null && capturedCm === cacheManager) {
                    launchFileProviderVideoIntent(appContextRef, cached, video.name)
                    return@launch
                }
                val remoteUrl = cloudClient.resolveDownloadUrl(video.id)
                if (extGen != externalVideoGeneration || !isAuthenticated || activeAccountKey != expectedAccount) {
                    return@launch
                }
                val cm = cacheManager
                val acct = activeAccountKey
                val server = streamServer
                var registeredToken: String? = null
                val loopbackUrl: String? = if (server != null && cm != null && acct != null && acct == expectedAccount) {
                    val dest = withContext(ioDispatcher) { cm.cacheFile(video.id, video.name) }
                    if (!isActive || extGen != externalVideoGeneration || !isAuthenticated || activeAccountKey != expectedAccount || cacheManager !== cm) {
                        return@launch
                    }
                    val reg = StreamSourceRegistration(
                        accountHash = Cloud189Protocol.accountBucketHash(acct),
                        trackId = video.id,
                        remoteUrl = remoteUrl,
                        cacheDestination = dest,
                        expectedSize = video.sizeBytes,
                        fileName = video.name,
                        cacheLimitBytes = committedSettings.cacheLimitBytes
                    )
                    registeredToken = reg.token
                    server.registerSource(reg, cacheManager = cm)
                } else null
                if (!isActive || extGen != externalVideoGeneration || !isAuthenticated || activeAccountKey != expectedAccount) {
                    registeredToken?.let { server?.revokeSource(it) }
                    return@launch
                }
                pendingExternalVideoAction = PendingExternalVideoAction(video, loopbackUrl)
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                if (extGen == externalVideoGeneration && isAuthenticated && activeAccountKey == expectedAccount) {
                    setStatus("准备外部播放失败：${e.message}", StatusKind.ERROR)
                }
            } finally {
                if (busyLabel == assignedBusy) {
                    busyLabel = null
                }
            }
        }
    }

    fun downloadVideoAndOpenExternally(context: Context, video: TrackSummary) {
        if (!isAuthenticated) return
        val cm = cacheManager ?: return
        val acct = activeAccountKey ?: return
        externalVideoGeneration += 1
        val extGen = externalVideoGeneration
        pendingExternalVideoAction = null
        val appContextRef = context.applicationContext ?: context
        lastExternalVideoJob?.cancel()
        lastExternalVideoJob = scope.launch {
            val assignedBusy = "正在缓存视频《${video.name}》..."
            busyLabel = assignedBusy
            try {
                val localFile = transferEngine.downloadTrackToCache(
                    track = video,
                    cacheManager = cm,
                    parallelThreads = committedSettings.downloadThreads,
                    cacheLimitBytes = maxOf(committedSettings.cacheLimitBytes, video.sizeBytes),
                    kind = "playback",
                    accountHash = Cloud189Protocol.accountBucketHash(acct)
                )
                if (extGen != externalVideoGeneration || !isAuthenticated || activeAccountKey != acct || cacheManager !== cm) {
                    return@launch
                }
                val usage = withContext(ioDispatcher) { cm.usageBytes() }
                if (extGen != externalVideoGeneration || !isAuthenticated || activeAccountKey != acct || cacheManager !== cm) {
                    return@launch
                }
                cacheUsageBytes = usage
                launchFileProviderVideoIntent(appContextRef, localFile, video.name)
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                if (extGen == externalVideoGeneration && isAuthenticated && activeAccountKey == acct) {
                    setStatus("缓存视频失败：${e.message}", StatusKind.ERROR)
                }
            } finally {
                if (busyLabel == assignedBusy) {
                    busyLabel = null
                }
            }
        }
    }

    fun launchLoopbackStreamInVideoApp(context: Context, action: PendingExternalVideoAction) {
        pendingExternalVideoAction = null
        val streamUrl = action.streamUrl ?: return
        val uri = Uri.parse(streamUrl)
        if (uri?.host != "127.0.0.1") return
        val mime = Cloud189Protocol.guessMimeType(action.video.name)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val chooser = Intent.createChooser(intent, "选择本地视频播放器").apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        runCatching {
            context.startActivity(chooser)
        }.onFailure { err ->
            setStatus("未能唤起外部视频播放器：${err.message}", StatusKind.ERROR)
        }
    }

    private fun launchFileProviderVideoIntent(context: Context, localFile: File, fileName: String) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", localFile)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, Cloud189Protocol.guessMimeType(fileName))
            clipData = ClipData.newRawUri("", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val chooser = Intent.createChooser(intent, "选择本地视频播放器").apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(chooser)
    }

    fun onSafTreeSelected(
        context: Context,
        treeUri: Uri,
        onSaved: ((String) -> Unit)? = null
    ) {
        if (!isAuthenticated) return
        val expectedAccount = activeAccountKey ?: return
        val appContextRef = context.applicationContext ?: context
        val treeUriString = treeUri.toString()
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        runCatching { appContextRef.contentResolver.takePersistableUriPermission(treeUri, flags) }
        val fallbackName = treeUri.lastPathSegment ?: "已选文件夹"
        scope.launch {
            if (!isAuthenticated || activeAccountKey != expectedAccount) return@launch
            val resolvedName = withContext(ioDispatcher) {
                runCatching { SafExporter.persistTreePermission(appContextRef, treeUri) }.getOrDefault(fallbackName)
            }
            if (!isAuthenticated || activeAccountKey != expectedAccount) return@launch
            val ok = mutateAccountSettings(
                expectedAccount = expectedAccount,
                successMessage = "导出目录已设为 $resolvedName"
            ) { prev ->
                prev.copy(
                    exportTreeUri = treeUriString,
                    exportFolderDisplayName = resolvedName
                )
            }
            if (ok && isAuthenticated && activeAccountKey == expectedAccount) {
                onSaved?.invoke(treeUriString)
            }
        }
    }

    private fun buildSafStagedExporter(
        appContextRef: Context,
        accountKey: String,
        explicitTreeUri: String?,
        fallbackTreeUri: String?
    ): StagedFileExporter = object : StagedFileExporter {
        private fun resolveEffectiveTreeUri(manifestTreeUri: String?): String? =
            explicitTreeUri
                ?: manifestTreeUri?.takeIf { it.isNotBlank() }
                ?: accountStore.loadSettingsOrNull(accountKey)?.exportTreeUri
                ?: fallbackTreeUri

        override suspend fun export(
            stagedFile: File,
            relativeSubpath: String,
            accountId: String,
            exportTreeUri: String?
        ): String {
            return SafExporter.exportToSafTree(
                context = appContextRef,
                treeUriString = resolveEffectiveTreeUri(exportTreeUri),
                stagedFile = stagedFile,
                relativeSubpath = relativeSubpath,
                mimeType = Cloud189Protocol.guessMimeType(relativeSubpath)
            )
        }

        override suspend fun exportParts(
            partFiles: List<File>,
            expectedTotalBytes: Long,
            relativeSubpath: String,
            accountId: String,
            exportTreeUri: String?
        ): String {
            return SafExporter.exportPartsToSafTree(
                context = appContextRef,
                treeUriString = resolveEffectiveTreeUri(exportTreeUri),
                partFiles = partFiles,
                expectedTotalBytes = expectedTotalBytes,
                relativeSubpath = relativeSubpath,
                mimeType = Cloud189Protocol.guessMimeType(relativeSubpath)
            )
        }
    }

    fun enqueueDownload(
        context: Context,
        track: TrackSummary,
        treeUriString: String? = null
    ) {
        val appContextRef = context.applicationContext ?: context
        val acct = activeAccountKey ?: return
        val explicitTreeUri = treeUriString?.takeIf { it.isNotBlank() }
        val fallbackTreeUri = committedSettings.exportTreeUri
        val pinnedTreeUri = explicitTreeUri ?: fallbackTreeUri?.takeIf { it.isNotBlank() }
        enqueueDownloadWithExporter(
            track = track,
            expectedAccount = acct,
            exportTreeUri = pinnedTreeUri,
            exporter = buildSafStagedExporter(appContextRef, acct, explicitTreeUri, fallbackTreeUri)
        )
    }

    internal fun enqueueDownloadWithExporter(
        track: TrackSummary,
        expectedAccount: String? = activeAccountKey,
        exportTreeUri: String? = null,
        exporter: StagedFileExporter
    ) {
        val acct = expectedAccount ?: return
        val expectedEpoch = authEpoch
        val threads = committedSettings.downloadThreads
        val inMemoryTreeUri = committedSettings.exportTreeUri
        scope.launch {
            if (authEpoch != expectedEpoch || !isAuthenticated || activeAccountKey != acct) return@launch
            val (taskId, snap) = withContext(ioDispatcher) {
                val paths = accountStore.paths(acct)
                val resolvedTreeUri = exportTreeUri?.takeIf { it.isNotBlank() }
                    ?: accountStore.loadSettingsOrNull(acct)?.exportTreeUri?.takeIf { it.isNotBlank() }
                    ?: inMemoryTreeUri?.takeIf { it.isNotBlank() }
                val id = transferEngine.enqueueExportDownload(
                    accountId = acct,
                    track = track,
                    relativeSubpath = track.name,
                    parallelThreads = threads,
                    stagingRootDir = paths.stagingDir,
                    manifestsFile = paths.transfersFile,
                    exportTreeUri = resolvedTreeUri,
                    exporter = exporter
                )
                id to transferEngine.snapshot()
            }
            if (authEpoch == expectedEpoch && isAuthenticated && activeAccountKey == acct) {
                transferSnapshot = snap
                setStatus("已添加下载任务 $taskId", StatusKind.INFO)
            }
        }
    }

    fun enqueueCurrentFolderDownload(
        context: Context,
        pane: BrowserPaneState = cloudBrowser,
        treeUriString: String? = null
    ) {
        val appContextRef = context.applicationContext ?: context
        val acct = activeAccountKey ?: return
        val explicitTreeUri = treeUriString?.takeIf { it.isNotBlank() }
        val fallbackTreeUri = committedSettings.exportTreeUri
        val pinnedTreeUri = explicitTreeUri ?: fallbackTreeUri?.takeIf { it.isNotBlank() }
        enqueueCurrentFolderDownloadWithExporter(
            pane = pane,
            expectedAccount = acct,
            exportTreeUri = pinnedTreeUri,
            exporter = buildSafStagedExporter(appContextRef, acct, explicitTreeUri, fallbackTreeUri)
        )
    }

    internal fun enqueueCurrentFolderDownloadWithExporter(
        pane: BrowserPaneState = cloudBrowser,
        expectedAccount: String? = activeAccountKey,
        exportTreeUri: String? = null,
        exporter: StagedFileExporter
    ) {
        val b = pane.payload ?: return
        val acct = expectedAccount ?: return
        val threads = committedSettings.downloadThreads
        val inMemoryTreeUri = committedSettings.exportTreeUri
        val nonRootCrumbs = pane.breadcrumbs.filter { it.id != null && it.id != Cloud189Constants.ROOT_FOLDER_ID }
        val crumbPath = if (!b.isRoot && nonRootCrumbs.lastOrNull()?.id == b.currentFolderId) {
            nonRootCrumbs.map { it.name }.filter { it.isNotEmpty() }.joinToString("/").takeIf { it.isNotEmpty() }
        } else null
        val rootExportFolder = crumbPath ?: b.currentFolderName
        val expectedEpoch: Int
        val myBusyToken: Int
        synchronized(bootstrapLock) {
            expectedEpoch = authEpoch
            operationBusyToken += 1
            myBusyToken = operationBusyToken
        }

        scope.launch {
            val assignedBusy = "扫描文件夹 ${b.currentFolderName}..."
            busyLabel = assignedBusy
            try {
                val allFiles = cloudClient.scanAllFiles(b.currentFolderId, rootExportFolder)
                if (authEpoch != expectedEpoch || !isAuthenticated || activeAccountKey != acct) return@launch
                val batchItems = allFiles.map { item ->
                    val rel = if (item.folderPath.startsWith(rootExportFolder)) {
                        "${item.folderPath}/${item.name}"
                    } else {
                        "$rootExportFolder/${item.name}"
                    }
                    ExportDownloadItem(track = item, relativeSubpath = rel)
                }
                val snap = withContext(ioDispatcher) {
                    if (authEpoch != expectedEpoch || !isAuthenticated || activeAccountKey != acct) {
                        return@withContext transferEngine.snapshot()
                    }
                    val paths = accountStore.paths(acct)
                    val resolvedTreeUri = exportTreeUri?.takeIf { it.isNotBlank() }
                        ?: accountStore.loadSettingsOrNull(acct)?.exportTreeUri?.takeIf { it.isNotBlank() }
                        ?: inMemoryTreeUri?.takeIf { it.isNotBlank() }
                    transferEngine.enqueueExportDownloads(
                        accountId = acct,
                        items = batchItems,
                        parallelThreads = threads,
                        stagingRootDir = paths.stagingDir,
                        manifestsFile = paths.transfersFile,
                        exportTreeUri = resolvedTreeUri,
                        exporter = exporter
                    )
                    transferEngine.snapshot()
                }
                if (authEpoch == expectedEpoch && isAuthenticated && activeAccountKey == acct) {
                    transferSnapshot = snap
                    setStatus("目录下载已入队（共 ${batchItems.size} 个文件）", StatusKind.INFO)
                }
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                if (authEpoch == expectedEpoch && isAuthenticated && activeAccountKey == acct) {
                    setStatus(e.message, StatusKind.ERROR)
                }
            } finally {
                if (operationBusyToken == myBusyToken && busyLabel == assignedBusy) {
                    busyLabel = null
                }
            }
        }
    }

    fun pauseTransfer(id: String) {
        val acct = activeAccountKey ?: return
        scope.launch {
            val snap = withContext(ioDispatcher) {
                transferEngine.pauseTransfer(id, accountStore.paths(acct).transfersFile)
                transferEngine.snapshot()
            }
            if (isAuthenticated && activeAccountKey == acct) {
                transferSnapshot = snap
            }
        }
    }

    fun resumeTransfer(
        context: Context,
        id: String,
        treeUriString: String? = null
    ) {
        val appContextRef = context.applicationContext ?: context
        val acct = activeAccountKey ?: return
        val explicitTreeUri = treeUriString?.takeIf { it.isNotBlank() }
        val fallbackTreeUri = committedSettings.exportTreeUri
        val safExporter = buildSafStagedExporter(appContextRef, acct, explicitTreeUri, fallbackTreeUri)
        scope.launch {
            val snap = withContext(ioDispatcher) {
                val paths = accountStore.paths(acct)
                transferEngine.resumeTransfer(id, paths.stagingDir, paths.transfersFile, safExporter)
                transferEngine.snapshot()
            }
            if (isAuthenticated && activeAccountKey == acct) {
                transferSnapshot = snap
            }
        }
    }

    fun deleteTransfer(id: String) {
        val acct = activeAccountKey ?: return
        scope.launch {
            val snap = withContext(ioDispatcher) {
                val paths = accountStore.paths(acct)
                transferEngine.deleteTransfer(id, paths.stagingDir, paths.transfersFile)
                transferEngine.snapshot()
            }
            transferSnapshot = snap
        }
    }

    // MARK: - Event-Driven Transfer Refresh, Foreground UI Clock & One-Shot Prefetch Scheduler

    private fun handleTransferActivityChange(snapshot: TransferSnapshotPayload, hasActive: Boolean) {
        transferSnapshot = snapshot
        if (hasActive && enableLiveLoops && attachedUiCount > 0 && isUiForegroundVisible) {
            ensureTransferRefreshRunning()
        } else if (!hasActive) {
            transferRefreshJob?.cancel()
            transferRefreshJob = null
            cacheManager?.let { cm ->
                scope.launch {
                    val bytes = withContext(ioDispatcher) { cm.usageBytes() }
                    if (cm === cacheManager) {
                        cacheUsageBytes = bytes
                    }
                }
            }
        }
    }

    private fun ensureTransferRefreshRunning() {
        if (transferRefreshJob?.isActive == true) return
        transferRefreshJob = scope.launch {
            while (isActive && attachedUiCount > 0 && isUiForegroundVisible) {
                delay(400L)
                val latest = transferEngine.snapshot()
                transferSnapshot = latest
                if (!latest.hasActiveItems) {
                    cacheManager?.let { cm ->
                        val bytes = withContext(ioDispatcher) { cm.usageBytes() }
                        if (cm === cacheManager) cacheUsageBytes = bytes
                    }
                    break
                }
            }
            transferRefreshJob = null
        }
    }

    private fun updateUiProgressClock() {
        val shouldRun = enableLiveLoops &&
            attachedUiCount > 0 &&
            isUiForegroundVisible &&
            isPlaying &&
            mediaController != null
        if (!shouldRun) {
            uiProgressClockJob?.cancel()
            uiProgressClockJob = null
            return
        }
        if (uiProgressClockJob?.isActive == true) return
        uiProgressClockJob = scope.launch {
            while (isActive && attachedUiCount > 0 && isUiForegroundVisible && isPlaying) {
                mediaController?.let { mc ->
                    if (mc.duration > 0L) {
                        duration = mc.duration / 1000.0
                    }
                    if (!isUserScrubbing) {
                        currentTime = mc.currentPosition.coerceAtLeast(0L) / 1000.0
                    }
                }
                delay(200L)
            }
            uiProgressClockJob = null
        }
    }

    /**
     * Zero-polling lockscreen-safe next-track prefetch scheduler:
     * - `DOWNLOAD_FIRST`: triggers immediately upon playback start.
     * - `STREAM_CACHE`: schedules a single one-shot timer for `remainingMs - 30_000L` based on `Player` state/seek.
     */
    private fun scheduleUpcomingPrefetch() {
        scheduledPrefetchJob?.cancel()
        scheduledPrefetchJob = null
        if (!enableLiveLoops || !isAuthenticated || loopMode == LoopMode.ONE || currentTrack == null) return

        if (committedSettings.playbackMode == PlaybackMode.DOWNLOAD_FIRST) {
            triggerUpcomingPrefetchNow()
            return
        }

        val mc = mediaController
        val durMs = mc?.duration?.takeIf { it > 0L } ?: (duration * 1000.0).toLong()
        val posMs = mc?.currentPosition?.coerceAtLeast(0L) ?: (currentTime * 1000.0).toLong()
        if (durMs <= 0L) return

        val remainingMs = (durMs - posMs).coerceAtLeast(0L)
        if (remainingMs <= 30_000L) {
            triggerUpcomingPrefetchNow()
        } else if (isPlaying) {
            val waitMs = remainingMs - 30_000L
            val gen = playbackGeneration
            scheduledPrefetchJob = scope.launch {
                delay(waitMs)
                if (isActive && isAuthenticated && isPlaying && gen == playbackGeneration) {
                    triggerUpcomingPrefetchNow()
                }
            }
        }
    }

    private fun triggerUpcomingPrefetchNow() {
        val cm = cacheManager ?: return
        val expectedAcct = activeAccountKey ?: return
        if (!isAuthenticated || loopMode == LoopMode.ONE || currentTrack == null) return
        val next = PlaybackQueueResolver.peekPrefetchCandidate(
            currentTrack = currentTrack,
            libraryTracks = tracks,
            upNextQueue = upNextQueue,
            shuffle = shuffle,
            shuffleOrderIds = shuffleOrderIds,
            loopMode = loopMode,
            precomputedOrdered = orderedBaseTracks,
            orderedIndexById = trackIndexById
        ) ?: return
        if (next.id == prefetchedTrackId || next.id == prefetchingTrackId) return
        activePrefetchJob?.cancel()
        activePrefetchJob = null

        val expectedEpoch = authEpoch
        val expectedPlayGen = playbackGeneration
        prefetchingTrackId = next.id
        val activeId = currentTrackId.orEmpty()
        val accountHash = Cloud189Protocol.accountBucketHash(expectedAcct)
        var launchedJob: Job? = null
        val job = scope.launch {
            try {
                withContext(ioDispatcher) {
                    if (isAuthenticated && authEpoch == expectedEpoch && activeAccountKey == expectedAcct && cacheManager === cm) {
                        cm.setProtectedTrackIds(setOf(activeId, next.id))
                    }
                }
                if (!isActive || !isAuthenticated || authEpoch != expectedEpoch || playbackGeneration != expectedPlayGen || activeAccountKey != expectedAcct || cacheManager !== cm) {
                    return@launch
                }
                transferEngine.downloadTrackToCache(
                    track = next,
                    cacheManager = cm,
                    parallelThreads = committedSettings.cacheThreads,
                    cacheLimitBytes = committedSettings.cacheLimitBytes,
                    kind = "prefetch",
                    accountHash = accountHash
                )
                if (isActive && isAuthenticated && authEpoch == expectedEpoch && playbackGeneration == expectedPlayGen && activeAccountKey == expectedAcct && cacheManager === cm) {
                    prefetchedTrackId = next.id
                }
            } catch (ce: CancellationException) {
                throw ce
            } catch (_: Exception) {
                // Best-effort background prefetch
            } finally {
                if (prefetchingTrackId == next.id) {
                    prefetchingTrackId = null
                }
                if (launchedJob != null && activePrefetchJob === launchedJob) {
                    activePrefetchJob = null
                }
            }
        }
        if (!job.isCompleted) {
            launchedJob = job
            activePrefetchJob = job
        }
    }

    private fun connectMediaController(context: Context) {
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val future = MediaController.Builder(context, token).buildAsync()
        future.addListener({
            runCatching {
                val controller = future.get()
                mediaController = controller
                controller.addListener(object : Player.Listener {
                    override fun onIsPlayingChanged(playing: Boolean) {
                        if (playing && (activeVideoUrl != null || videoPlayer != null)) {
                            closeVideoPlayer()
                        }
                        isPlaying = playing
                        updateUiProgressClock()
                        scheduleUpcomingPrefetch()
                    }

                    override fun onPlaybackStateChanged(playbackState: Int) {
                        if (playbackState == Player.STATE_READY) {
                            recoveryAttempts = 0
                            if (controller.duration > 0L) {
                                duration = controller.duration / 1000.0
                            }
                            scheduleUpcomingPrefetch()
                        } else if (playbackState == Player.STATE_ENDED) {
                            playAdjacent(1, autoAdvanceAtEnd = true)
                        }
                    }

                    override fun onPositionDiscontinuity(
                        oldPosition: Player.PositionInfo,
                        newPosition: Player.PositionInfo,
                        reason: Int
                    ) {
                        if (!isUserScrubbing) {
                            currentTime = newPosition.positionMs.coerceAtLeast(0L) / 1000.0
                        }
                        scheduleUpcomingPrefetch()
                    }

                    override fun onPlayerError(error: PlaybackException) {
                        val isDecodeError = error.errorCode in setOf(
                            PlaybackException.ERROR_CODE_DECODING_FAILED,
                            PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
                            PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
                            PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
                            PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
                            PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
                            PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
                            PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED,
                            PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED
                        )
                        val isIoTimeout = error.errorCode == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT
                        val errMsg = when {
                            isIoTimeout -> "network connection timeout"
                            !error.message.isNullOrBlank() -> error.message!!
                            else -> "playback error (${error.errorCodeName})"
                        }
                        currentTrack?.let {
                            handlePlaybackError(
                                track = it,
                                message = errMsg,
                                wasLoopback = currentPlaybackIsLoopback,
                                explicitIsDecode = isDecodeError
                            )
                        }
                    }
                })
                pendingMediaItem?.let { queued ->
                    pendingMediaItem = null
                    controller.setMediaItem(queued)
                    controller.prepare()
                    if (isPlaying) {
                        controller.play()
                    }
                }
                updateUiProgressClock()
            }
        }, context.mainExecutor)
    }

    companion object {
        private const val PREFS_NAME = "cloudtune_ui_prefs"
        private const val KEY_APPEARANCE_MODE = "appearance_mode"
        private const val KEY_DYNAMIC_COLOR = "dynamic_color_enabled"

        private val instanceLock = Any()
        @Volatile private var sharedInstance: CloudTuneAppRuntime? = null

        internal fun setSharedInstanceForTest(instance: CloudTuneAppRuntime?) {
            synchronized(instanceLock) {
                sharedInstance = instance
            }
        }

        fun getOrCreate(context: Context): CloudTuneAppRuntime {
            sharedInstance?.let { return it }
            return synchronized(instanceLock) {
                sharedInstance ?: CloudTuneAppRuntime(appContext = context.applicationContext).also {
                    sharedInstance = it
                }
            }
        }
    }
}

class CloudTuneViewModel(
    val runtime: CloudTuneAppRuntime
) : ViewModel() {

    constructor(
        appContext: Context? = null,
        cloudClient: Cloud189Client = Cloud189Client(),
        accountStore: AccountStore = AccountStore(
            appContext?.applicationContext?.filesDir ?: File(System.getProperty("java.io.tmpdir"), "cloudtune-android")
        ),
        credentialStore: CredentialStore? = appContext?.applicationContext?.let {
            runCatching { EncryptedCredentialStore(it) }.getOrNull()
        },
        limiter: GlobalTransferLimiter = GlobalTransferLimiter(maxPermits = 8),
        enableLiveLoops: Boolean = true
    ) : this(
        CloudTuneAppRuntime(
            appContext = appContext,
            cloudClient = cloudClient,
            accountStore = accountStore,
            credentialStore = credentialStore,
            limiter = limiter,
            enableLiveLoops = enableLiveLoops
        )
    )

    init {
        runtime.onUiAttached()
    }

    fun bootstrap(): Deferred<Unit> = runtime.bootstrap()

    public override fun onCleared() {
        runtime.onUiDetached()
        super.onCleared()
    }
}
