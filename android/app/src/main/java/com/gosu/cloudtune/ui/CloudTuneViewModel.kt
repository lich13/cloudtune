package com.gosu.cloudtune.ui

import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.webkit.CookieManager
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
import com.gosu.cloudtune.core.RepresentativeFixture
import com.gosu.cloudtune.core.SnapshotScene
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

data class PendingExternalVideoAction(
    val video: TrackSummary,
    val streamUrl: String?
)

/**
 * Application/service-scoped runtime keeping `LocalStreamServer`, `MediaController`,
 * unified queue state, lifecycle-safe video `ExoPlayer`, and lockscreen callbacks alive.
 */
class CloudTuneAppRuntime(
    appContext: Context? = null,
    val cloudClient: Cloud189Client = Cloud189Client(),
    val accountStore: AccountStore = AccountStore(
        appContext?.applicationContext?.filesDir ?: File(System.getProperty("java.io.tmpdir"), "cloudtune-android")
    ),
    val credentialStore: CredentialStore? = appContext?.applicationContext?.let { EncryptedCredentialStore(it) },
    val limiter: GlobalTransferLimiter = GlobalTransferLimiter(maxPermits = 8),
    val enableLiveLoops: Boolean = true,
    dispatcher: CoroutineDispatcher = if (appContext != null) Dispatchers.Main.immediate else Dispatchers.Unconfined,
    private val ioDispatcher: CoroutineDispatcher = if (appContext != null) Dispatchers.IO else Dispatchers.Unconfined
) {
    private val appCtx: Context? = appContext?.applicationContext
    private val uiPrefs = appCtx?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    val scope = CoroutineScope(SupervisorJob() + dispatcher)

    var themeMode by mutableStateOf(AppearanceMode.SYSTEM)
    var dynamicColorEnabled by mutableStateOf(false)
    var activeModule by mutableStateOf(ModuleTab.MUSIC)
    var isBootstrapping by mutableStateOf(false)
    var busyLabel by mutableStateOf<String?>(null)
    var statusMessage by mutableStateOf<String?>(null)

    var isAuthenticated by mutableStateOf(false)
    var accountName by mutableStateOf<String?>(null)
    var accountStorageKey by mutableStateOf<String?>(null)
        internal set

    // Strictly separated committed vs draft settings
    var committedSettings by mutableStateOf(AccountSettings())
        internal set
    var cacheLimitDraft by mutableStateOf("1024")
    var downloadThreadsDraft by mutableStateOf("8")
    var cacheThreadsDraft by mutableStateOf("4")
    var settingsValidationError by mutableStateOf<String?>(null)

    var cacheUsageBytes by mutableLongStateOf(0L)

    // Login state
    var qrContent by mutableStateOf<String?>(null)
    var qrBitmap by mutableStateOf<Bitmap?>(null)
    var qrHint by mutableStateOf<String?>(null)
    var isShowingWebLoginDialog by mutableStateOf(false)

    // Decoupled Cloud & Video folder browsers + Music library
    var cloudBrowser by mutableStateOf(BrowserPaneState())
    var videoBrowser by mutableStateOf(BrowserPaneState())
    var tracks by mutableStateOf<List<TrackSummary>>(emptyList())
    var searchQuery by mutableStateOf("")

    var breadcrumbs: List<BreadcrumbItem>
        get() = cloudBrowser.breadcrumbs
        set(value) { cloudBrowser = cloudBrowser.copy(breadcrumbs = value) }

    var browser: FolderBrowsePayload?
        get() = cloudBrowser.payload
        set(value) { cloudBrowser = cloudBrowser.copy(payload = value) }

    // Playback & unified queue state
    var activeTrack by mutableStateOf<TrackSummary?>(null)
    var currentTrackId by mutableStateOf<String?>(null)
    var nowPlayingTitle by mutableStateOf<String?>(null)
    var nowPlayingArtist by mutableStateOf<String?>(null)
    var nowPlayingAlbum by mutableStateOf<String?>(null)
    var nowPlayingArtwork by mutableStateOf<Bitmap?>(null)
    var isPlaying by mutableStateOf(false)
    var loadingTrackId by mutableStateOf<String?>(null)
    var shuffle by mutableStateOf(true)
    var loopMode by mutableStateOf(LoopMode.ALL)
    var currentTime by mutableDoubleStateOf(0.0)
    var duration by mutableDoubleStateOf(0.0)
    var upNextQueue by mutableStateOf<List<TrackSummary>>(emptyList())
    var shuffleOrderIds by mutableStateOf<List<String>>(emptyList())
    var isShowingNowPlayingSheet by mutableStateOf(false)
    var isUserScrubbing by mutableStateOf(false)

    // Lifecycle-safe Video player state
    var activeVideoTrack by mutableStateOf<TrackSummary?>(null)
    var activeVideoTitle by mutableStateOf<String?>(null)
    var activeVideoUrl by mutableStateOf<String?>(null)
    var isVideoPlaying by mutableStateOf(false)
    var videoPlayer by mutableStateOf<ExoPlayer?>(null)
        private set
    var pendingExternalVideoAction by mutableStateOf<PendingExternalVideoAction?>(null)

    // Transfers
    var transferSnapshot by mutableStateOf(TransferSnapshotPayload())

    var retryBaseDelayMs: Long = 1500L

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
    private var prefetchedTrackId: String? = null
    private var prefetchingTrackId: String? = null
    private var playbackGeneration: Int = 0
    private var recoveryAttempts = 0
    private var currentPlaybackIsLoopback = false
    private var attachedUiCount = 0
    private var isUiForegroundVisible = true

    init {
        uiPrefs?.let { prefs ->
            themeMode = AppearanceMode.fromWire(prefs.getString(KEY_APPEARANCE_MODE, null))
            dynamicColorEnabled = prefs.getBoolean(KEY_DYNAMIC_COLOR, false)
            committedSettings = committedSettings.copy(
                appearanceMode = themeMode,
                dynamicColorEnabled = dynamicColorEnabled
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

    val visibleTracks: List<TrackSummary>
        get() {
            val q = searchQuery.trim().lowercase()
            if (q.isEmpty()) return tracks
            return tracks.filter {
                it.name.lowercase().contains(q) || it.folderPath.lowercase().contains(q)
            }
        }

    val currentTrack: TrackSummary?
        get() {
            val held = activeTrack
            if (held != null && (held.id == currentTrackId || currentTrackId == null)) {
                return held
            }
            val id = currentTrackId ?: return null
            return tracks.firstOrNull { it.id == id }
                ?: cloudBrowser.payload?.audioFiles?.firstOrNull { it.id == id }
                ?: held
        }

    val upcomingTracks: List<TrackSummary>
        get() = PlaybackQueueResolver.upcomingPreview(
            currentTrack = currentTrack,
            libraryTracks = tracks,
            upNextQueue = upNextQueue,
            shuffle = shuffle,
            shuffleOrderIds = shuffleOrderIds,
            loopMode = loopMode,
            limit = 20
        )

    val canSkipNext: Boolean
        get() = PlaybackQueueResolver.canSkipNext(
            currentTrack = currentTrack,
            libraryTracks = tracks,
            upNextQueue = upNextQueue,
            shuffle = shuffle,
            shuffleOrderIds = shuffleOrderIds,
            loopMode = loopMode
        )

    val canSkipPrevious: Boolean
        get() = PlaybackQueueResolver.canSkipPrevious(
            currentTrack = currentTrack,
            libraryTracks = tracks,
            shuffle = shuffle,
            shuffleOrderIds = shuffleOrderIds,
            loopMode = loopMode
        )

    val downloadTransfers: List<TransferStatus>
        get() = transferSnapshot.items.filter { it.kind == "download" }

    val activeStreamTransfers: List<TransferStatus>
        get() = transferSnapshot.items.filter { it.kind != "download" }

    val downloadableFiles: List<TrackSummary>
        get() = cloudBrowser.payload?.let { it.audioFiles + it.videoFiles + it.otherFiles } ?: emptyList()

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
        cacheLimitDraft = committedSettings.cacheLimitMb.toString()
        downloadThreadsDraft = committedSettings.downloadThreads.toString()
        cacheThreadsDraft = committedSettings.cacheThreads.toString()
        val prevErr = settingsValidationError
        if (prevErr != null && statusMessage == prevErr) {
            statusMessage = null
        }
        settingsValidationError = null
    }

    fun noteDraftEdited() {
        val prevErr = settingsValidationError
        if (prevErr != null && statusMessage == prevErr) {
            statusMessage = null
        }
        settingsValidationError = null
    }

    suspend fun mutateAccountSettings(
        successMessage: String? = null,
        resyncDrafts: Boolean = false,
        transform: (AccountSettings) -> AccountSettings
    ): Boolean {
        val acct = activeAccountKey
        if (acct == null) {
            val updated = transform(committedSettings)
            committedSettings = updated
            if (resyncDrafts) syncDraftsFromCommitted()
            if (successMessage != null) statusMessage = successMessage
            return true
        }
        val mutex = settingsMutexFor(acct)
        return mutex.withLock {
            val ioResult = runCatching {
                withContext(ioDispatcher) {
                    val base = accountStore.loadSettingsOrNull(acct) ?: committedSettings
                    val updated = transform(base)
                    accountStore.saveSettings(acct, updated)
                    updated
                }
            }
            val saved = ioResult.getOrElse { err ->
                if (activeAccountKey == acct) {
                    statusMessage = "保存设置失败：${err.message ?: "磁盘写入异常"}"
                }
                return@withLock false
            }
            if (activeAccountKey == acct) {
                committedSettings = saved
                if (resyncDrafts) syncDraftsFromCommitted()
                if (successMessage != null) statusMessage = successMessage
            }
            true
        }
    }

    suspend fun commitCacheLimitDraftAsync(): Boolean {
        val parsed = cacheLimitDraft.trim().toLongOrNull()
        if (parsed == null || parsed < AccountSettings.MIN_CACHE_LIMIT_MB) {
            val msg = "缓存上限至少设为 256 MB。"
            settingsValidationError = msg
            statusMessage = msg
            return false
        }
        val cm = cacheManager
        val ok = mutateAccountSettings(
            successMessage = "缓存限制已更新",
            resyncDrafts = true
        ) { prev -> prev.copy(cacheLimitMb = parsed) }
        if (ok && cm != null) {
            val prunedUsage = runCatching {
                withContext(ioDispatcher) { cm.pruneToLimit(parsed * 1024L * 1024L) }
            }.getOrNull()
            if (prunedUsage != null && cm === cacheManager) {
                cacheUsageBytes = prunedUsage
            }
        }
        return ok
    }

    fun commitCacheLimitDraft(): Boolean {
        val parsed = cacheLimitDraft.trim().toLongOrNull()
        if (parsed == null || parsed < AccountSettings.MIN_CACHE_LIMIT_MB) {
            val msg = "缓存上限至少设为 256 MB。"
            settingsValidationError = msg
            statusMessage = msg
            return false
        }
        var completedOutcome: Boolean? = null
        scope.launch {
            completedOutcome = commitCacheLimitDraftAsync()
        }
        return completedOutcome ?: true
    }

    suspend fun commitTransferThreadsDraftAsync(): Boolean {
        val dl = downloadThreadsDraft.trim().toIntOrNull()
        if (dl == null || dl !in 1..AccountSettings.MAX_DOWNLOAD_THREADS) {
            val msg = "下载线程范围是 1-${AccountSettings.MAX_DOWNLOAD_THREADS}"
            settingsValidationError = msg
            statusMessage = msg
            return false
        }
        val ct = cacheThreadsDraft.trim().toIntOrNull()
        if (ct == null || ct !in 1..AccountSettings.MAX_CACHE_THREADS) {
            val msg = "缓存线程范围是 1-${AccountSettings.MAX_CACHE_THREADS}"
            settingsValidationError = msg
            statusMessage = msg
            return false
        }
        return mutateAccountSettings(
            successMessage = "传输参数已更新",
            resyncDrafts = true
        ) { prev -> prev.copy(downloadThreads = dl, cacheThreads = ct) }
    }

    fun commitTransferThreadsDraft(): Boolean {
        val dl = downloadThreadsDraft.trim().toIntOrNull()
        if (dl == null || dl !in 1..AccountSettings.MAX_DOWNLOAD_THREADS) {
            val msg = "下载线程范围是 1-${AccountSettings.MAX_DOWNLOAD_THREADS}"
            settingsValidationError = msg
            statusMessage = msg
            return false
        }
        val ct = cacheThreadsDraft.trim().toIntOrNull()
        if (ct == null || ct !in 1..AccountSettings.MAX_CACHE_THREADS) {
            val msg = "缓存线程范围是 1-${AccountSettings.MAX_CACHE_THREADS}"
            settingsValidationError = msg
            statusMessage = msg
            return false
        }
        var completedOutcome: Boolean? = null
        scope.launch {
            completedOutcome = commitTransferThreadsDraftAsync()
        }
        return completedOutcome ?: true
    }

    fun updatePlaybackMode(mode: PlaybackMode) {
        val msg = if (mode == PlaybackMode.DOWNLOAD_FIRST) "已切到优先缓存播放" else "已切到边播边缓存"
        scope.launch {
            mutateAccountSettings(successMessage = msg) { prev -> prev.copy(playbackMode = mode) }
            scheduleUpcomingPrefetch()
        }
    }

    fun updateAppearanceMode(mode: AppearanceMode) {
        themeMode = mode
        mirrorThemePrefs(mode, dynamicColorEnabled)
        scope.launch {
            mutateAccountSettings { prev -> prev.copy(appearanceMode = mode) }
        }
    }

    fun updateDynamicColorEnabled(enabled: Boolean) {
        dynamicColorEnabled = enabled
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
        val created = scope.async {
            try {
                val stored = withContext(ioDispatcher) { credentialStore?.loadCredential() } ?: return@async
                isBootstrapping = true
                busyLabel = "恢复天翼登录会话..."
                val restored = cloudClient.restoreFromRefreshCredential(stored)
                val identity = Cloud189Protocol.resolveAccountIdentity(
                    activeSession = restored.activeSession,
                    persistedCredential = restored.persistedCredential ?: stored,
                    priorAccountKey = stored.accountKey
                )
                restored.persistedCredential?.let { cred ->
                    runCatching {
                        withContext(ioDispatcher) {
                            credentialStore?.saveCredential(cred.withAccountKey(identity.storageKey))
                        }
                    }.onFailure { err ->
                        statusMessage = "登录凭据持久化警告：${err.message}"
                    }
                }
                activateAccount(storageKey = identity.storageKey, displayName = identity.displayName)
                browseToSuspend(BrowserScope.CLOUD, null, listOf(BreadcrumbItem.ROOT), showBusy = false)
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                isAuthenticated = false
                statusMessage = e.message
            } finally {
                busyLabel = null
                isBootstrapping = false
                synchronized(bootstrapLock) {
                    bootstrapDeferred = null
                }
            }
        }
        bootstrapDeferred = created
        created
    }

    fun beginQrLogin() {
        qrPollJob?.cancel()
        scope.launch {
            busyLabel = "生成二维码..."
            try {
                val start = cloudClient.startQrLogin()
                qrContent = start.qrContent
                qrHint = start.message
                statusMessage = start.message
                qrBitmap = withContext(ioDispatcher) {
                    QrCodeHelper.generateQrBitmap(start.qrContent, 480)
                }
                startQrPolling()
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                statusMessage = e.message
            } finally {
                busyLabel = null
            }
        }
    }

    private fun startQrPolling() {
        qrPollJob?.cancel()
        qrPollJob = scope.launch {
            while (isActive) {
                delay(2500L)
                try {
                    val poll = cloudClient.pollQrLogin()
                    qrHint = poll.message
                    statusMessage = poll.message
                    when (poll.state) {
                        QrLoginState.AUTHENTICATED -> {
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
                                        credentialStore?.saveCredential(cred.withAccountKey(identity.storageKey))
                                    }
                                }.onFailure { err ->
                                    statusMessage = "登录凭据保存异常：${err.message}"
                                }
                            }
                            qrContent = null
                            qrBitmap = null
                            activateAccount(storageKey = identity.storageKey, displayName = identity.displayName)
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
                    statusMessage = e.message
                    return@launch
                }
            }
        }
    }

    fun completeEmbeddedWebLogin(callbackUrl: String, cookieHeader: String?) {
        completeEmbeddedWebLogin(
            callbackUrl = callbackUrl,
            cookiesByOrigin = mapOf(
                "https://open.e.189.cn" to cookieHeader,
                "https://cloud.189.cn" to cookieHeader,
                "https://api.cloud.189.cn" to cookieHeader,
                "https://m.cloud.189.cn" to cookieHeader
            )
        )
    }

    fun completeEmbeddedWebLogin(callbackUrl: String, cookiesByOrigin: Map<String, String?>) {
        scope.launch {
            busyLabel = "正在验证天翼登录会话..."
            try {
                for ((origin, header) in cookiesByOrigin) {
                    cloudClient.importWebCookies(origin, header)
                }
                val parsed = cloudClient.exchangeRedirectForSession(callbackUrl)
                val identity = Cloud189Protocol.resolveAccountIdentity(
                    activeSession = parsed.activeSession,
                    persistedCredential = parsed.persistedCredential
                )
                parsed.persistedCredential?.let { cred ->
                    runCatching {
                        withContext(ioDispatcher) {
                            credentialStore?.saveCredential(cred.withAccountKey(identity.storageKey))
                        }
                    }.onFailure { err ->
                        statusMessage = "登录凭据保存异常：${err.message}"
                    }
                }
                isShowingWebLoginDialog = false
                qrPollJob?.cancel()
                qrContent = null
                qrBitmap = null
                activateAccount(storageKey = identity.storageKey, displayName = identity.displayName)
                browseToSuspend(BrowserScope.CLOUD, null, listOf(BreadcrumbItem.ROOT), showBusy = false)
                statusMessage = "天翼官方网页一键登录成功"
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                isShowingWebLoginDialog = false
                statusMessage = "网页回调兑换失败（${e.message}），已自动切换二维码登录，可保存二维码到相册识别。"
                beginQrLogin()
            } finally {
                busyLabel = null
            }
        }
    }

    internal suspend fun activateAccount(storageKey: String, displayName: String) {
        val loaded = withContext(ioDispatcher) {
            val paths = accountStore.paths(storageKey)
            val cm = CacheManager(paths.cacheDir)
            val usage = cm.usageBytes()
            val savedSettings = accountStore.loadSettingsOrNull(storageKey)
                ?: AccountSettings(appearanceMode = themeMode, dynamicColorEnabled = dynamicColorEnabled)
            val savedTracks = accountStore.loadLibrary(storageKey)
            transferEngine.restorePersistedDownloads(storageKey, paths.stagingDir, paths.transfersFile)
            val snap = transferEngine.snapshot()
            LoadedAccountState(cm, usage, savedSettings, savedTracks, snap)
        }
        isAuthenticated = true
        accountStorageKey = storageKey
        accountName = displayName
        cacheManager = loaded.cacheManager
        cacheUsageBytes = loaded.usageBytes
        committedSettings = loaded.settings
        themeMode = loaded.settings.appearanceMode
        dynamicColorEnabled = loaded.settings.dynamicColorEnabled
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
        synchronized(bootstrapLock) {
            bootstrapDeferred?.cancel()
            bootstrapDeferred = null
        }
        qrPollJob?.cancel()
        qrPollJob = null
        transferRefreshJob?.cancel()
        transferRefreshJob = null
        uiProgressClockJob?.cancel()
        uiProgressClockJob = null
        scheduledPrefetchJob?.cancel()
        scheduledPrefetchJob = null
        playbackGeneration += 1
        recoveryAttempts = 0
        pendingMediaItem = null
        prefetchedTrackId = null
        prefetchingTrackId = null
        closeVideoPlayer()
        mediaController?.stop()
        mediaController?.clearMediaItems()
        activeAccountKey?.let { key ->
            streamServer?.revokeAllSources(Cloud189Protocol.accountBucketHash(key))
            transferEngine.cancelAll(key)
        }
        cloudClient.clearSessionImmediate()
        cookieCleanupDeferred = scope.async {
            runCatching {
                withContext(ioDispatcher) { credentialStore?.clearCredential() }
            }
            if (hasAndroidContext) {
                clearWebViewCookiesAndFlush()
            }
        }

        isAuthenticated = false
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
        statusMessage = "已退出登录并清理当前会话"
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

    private suspend fun browseToSuspend(
        scopeTarget: BrowserScope,
        folderId: String?,
        nextCrumbs: List<BreadcrumbItem>,
        showBusy: Boolean
    ) {
        if (!isAuthenticated) return
        if (showBusy) busyLabel = "读取云盘目录..."
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
            val nextPane = BrowserPaneState(breadcrumbs = nextCrumbs, payload = listing)
            when (scopeTarget) {
                BrowserScope.CLOUD -> {
                    cloudBrowser = nextPane
                    if (isRoot && videoBrowser.payload == null) {
                        videoBrowser = nextPane
                    }
                }
                BrowserScope.VIDEO -> {
                    videoBrowser = nextPane
                    if (isRoot && cloudBrowser.payload == null) {
                        cloudBrowser = nextPane
                    }
                }
            }
        } catch (ce: CancellationException) {
            throw ce
        } catch (e: Exception) {
            statusMessage = e.message
        } finally {
            if (showBusy) busyLabel = null
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
        val folder = committedSettings.musicFolder ?: run {
            statusMessage = "请先在云盘目录中设为音乐库"
            return
        }
        val acct = activeAccountKey ?: return
        scope.launch {
            busyLabel = "扫描 ${folder.name} 中的音乐..."
            try {
                val scanned = cloudClient.scanMusicLibrary(folder.id, folder.name)
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
                statusMessage = if (persistedOk) {
                    "已载入 ${scanned.size} 首音乐"
                } else {
                    "已载入 ${scanned.size} 首音乐（本地索引保存失败）"
                }
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                statusMessage = e.message
            } finally {
                busyLabel = null
            }
        }
    }

    fun playNext(track: TrackSummary) {
        upNextQueue = PlaybackQueueResolver.insertPlayNext(upNextQueue, track)
        prefetchedTrackId = null
        syncQueueAvailabilityToBridge()
        statusMessage = "已设为下一首播放：《${track.name}》"
        scheduleUpcomingPrefetch()
    }

    fun appendToQueue(track: TrackSummary) {
        upNextQueue = PlaybackQueueResolver.appendToQueue(upNextQueue, track)
        syncQueueAvailabilityToBridge()
        statusMessage = "已加入待播队列：《${track.name}》"
    }

    fun removeFromQueue(trackId: String) {
        upNextQueue = PlaybackQueueResolver.removeFromQueue(upNextQueue, trackId)
        syncQueueAvailabilityToBridge()
    }

    fun clearUpNextQueue() {
        upNextQueue = emptyList()
        syncQueueAvailabilityToBridge()
    }

    fun toggleShuffle() {
        shuffle = !shuffle
        if (shuffle) {
            shuffleOrderIds = PlaybackQueueResolver.buildShuffleOrder(tracks, currentTrackId)
        }
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
        closeVideoPlayer()
        playbackGeneration += 1
        val gen = playbackGeneration
        activeTrack = track
        currentTrackId = track.id
        prefetchedTrackId = null
        prefetchingTrackId = null
        scheduledPrefetchJob?.cancel()
        if (shuffle && track.id !in shuffleOrderIds && tracks.any { it.id == track.id }) {
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
                val cached = withContext(ioDispatcher) {
                    cm.setProtectedTrackIds(setOf(track.id))
                    cm.existingCachedFile(track.id)
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
                    if (gen != playbackGeneration || !isAuthenticated) return@launch
                    cacheUsageBytes = usage
                    val fileUri = Uri.fromFile(cached)?.toString() ?: cached.toURI().toString()
                    startControllerPlayback(track, fileUri, isLoopback = false, metadata = meta)
                    return@launch
                }
                val downloadFirst = PlaybackDecisionPolicy.shouldDownloadBeforePlayback(
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
                    if (gen != playbackGeneration || !isAuthenticated) return@launch
                    val (usage, meta) = withContext(ioDispatcher) {
                        cm.usageBytes() to AudioMetadataHelper.extract(
                            localFile = file,
                            fallbackTitle = track.name,
                            fallbackArtist = null,
                            fallbackAlbum = fallbackAlbum
                        )
                    }
                    if (gen != playbackGeneration || !isAuthenticated) return@launch
                    cacheUsageBytes = usage
                    val fileUri = Uri.fromFile(file)?.toString() ?: file.toURI().toString()
                    startControllerPlayback(track, fileUri, isLoopback = false, metadata = meta)
                } else {
                    val remoteUrl = cloudClient.resolveDownloadUrl(track.id)
                    if (gen != playbackGeneration || !isAuthenticated) return@launch
                    val dest = withContext(ioDispatcher) { cm.cacheFile(track.id, track.name) }
                    if (gen != playbackGeneration || !isAuthenticated) return@launch
                    val playUrl = streamServer?.registerSource(
                        StreamSourceRegistration(
                            accountHash = accountHash,
                            trackId = track.id,
                            remoteUrl = remoteUrl,
                            cacheDestination = dest,
                            expectedSize = track.sizeBytes,
                            fileName = track.name,
                            cacheLimitBytes = committedSettings.cacheLimitBytes
                        ),
                        cacheManager = cm
                    ) ?: remoteUrl
                    startControllerPlayback(track, playUrl, isLoopback = true, metadata = null)
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

    private fun decodeArtworkBitmap(bytes: ByteArray?): Bitmap? {
        if (bytes == null || bytes.isEmpty()) return null
        return runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }.getOrNull()
    }

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
        metadata: ExtractedAudioMetadata?
    ) {
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
        statusMessage = if (isLoopback) "边播边缓存《${track.name}》" else "正在播放《${track.name}》"
    }

    internal suspend fun handleWriteThroughCompleted(
        accountHash: String,
        trackId: String,
        localFile: File
    ) {
        val acct = activeAccountKey ?: return
        if (!isAuthenticated || Cloud189Protocol.accountBucketHash(acct) != accountHash) return
        cacheManager?.let { cm ->
            cacheUsageBytes = withContext(ioDispatcher) { cm.usageBytes() }
        }
        val track = currentTrack ?: return
        if (currentTrackId != trackId) return
        val gen = playbackGeneration
        val fallbackAlbum = track.folderPath.ifBlank { committedSettings.musicFolder?.name ?: "CloudTune" }
        val (enriched, bmp) = withContext(ioDispatcher) {
            val m = AudioMetadataHelper.extract(
                localFile = localFile,
                fallbackTitle = track.name,
                fallbackArtist = null,
                fallbackAlbum = fallbackAlbum
            )
            m to decodeArtworkBitmap(m.artworkBytes)
        }
        if (!isAuthenticated || gen != playbackGeneration || currentTrackId != trackId) return
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
                statusMessage = action.userMessage
            }
            PlaybackFailureAction.StopAfterMaxRetries -> {
                isPlaying = false
                updateUiProgressClock()
                statusMessage = "播放异常，已停止自动重试《${track.name}》"
            }
            is PlaybackFailureAction.RetryTransientAfterDelay -> {
                isPlaying = false
                updateUiProgressClock()
                if (!isAuthenticated || playbackGeneration != failedGeneration) return
                statusMessage = "播放波动，正在重试《${track.name}》(${action.attempt}/${PlaybackDecisionPolicy.MAX_RECOVERY_ATTEMPTS})"
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
            val candidate = if (shuffle) tracks.randomOrNull() else visibleTracks.firstOrNull()
            (candidate ?: tracks.firstOrNull())?.let { playTrack(it) }
            return
        }
        val controller = mediaController
        if (controller == null) {
            isPlaying = !isPlaying
            updateUiProgressClock()
            return
        }
        if (controller.isPlaying) {
            controller.pause()
            isPlaying = false
        } else {
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
                autoAdvanceAtEnd = autoAdvanceAtEnd
            )
        } else {
            PlaybackQueueResolver.resolvePrevious(
                currentTrack = currentTrack,
                libraryTracks = tracks,
                upNextQueue = upNextQueue,
                shuffle = shuffle,
                shuffleOrderIds = shuffleOrderIds,
                loopMode = loopMode
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
        playbackGeneration += 1
        val gen = playbackGeneration
        recoveryAttempts = 0
        scheduledPrefetchJob?.cancel()
        mediaController?.pause()
        isPlaying = false
        updateUiProgressClock()

        scope.launch {
            busyLabel = "准备视频播放 ${video.name}..."
            try {
                val cm = cacheManager
                val acct = activeAccountKey
                val cached = withContext(ioDispatcher) { cm?.existingCachedFile(video.id) }
                if (gen != playbackGeneration || !isAuthenticated) return@launch
                val resolvedPlayUrl = if (cached != null) {
                    Uri.fromFile(cached)?.toString() ?: cached.toURI().toString()
                } else {
                    val remoteUrl = cloudClient.resolveDownloadUrl(video.id)
                    if (gen != playbackGeneration || !isAuthenticated) return@launch
                    if (streamServer != null && cm != null && acct != null) {
                        val dest = withContext(ioDispatcher) { cm.cacheFile(video.id, video.name) }
                        if (gen != playbackGeneration || !isAuthenticated) return@launch
                        streamServer.registerSource(
                            StreamSourceRegistration(
                                accountHash = Cloud189Protocol.accountBucketHash(acct),
                                trackId = video.id,
                                remoteUrl = remoteUrl,
                                cacheDestination = dest,
                                expectedSize = video.sizeBytes,
                                fileName = video.name,
                                cacheLimitBytes = committedSettings.cacheLimitBytes
                            ),
                            cacheManager = cm
                        )
                    } else {
                        remoteUrl
                    }
                }
                if (gen != playbackGeneration || !isAuthenticated) return@launch
                activeVideoTrack = video
                activeVideoTitle = video.name
                activeVideoUrl = resolvedPlayUrl
                prepareRuntimeVideoPlayer(resolvedPlayUrl)
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                if (gen == playbackGeneration && isAuthenticated) {
                    statusMessage = e.message
                }
            } finally {
                if (gen == playbackGeneration) {
                    busyLabel = null
                }
            }
        }
    }

    private fun prepareRuntimeVideoPlayer(playUrl: String) {
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
            statusMessage = if (ok) "二维码已保存到系统相册" else "保存二维码失败"
        }
    }

    fun openVideoExternally(context: Context, video: TrackSummary) {
        scope.launch {
            try {
                val cached = withContext(ioDispatcher) { cacheManager?.existingCachedFile(video.id) }
                if (cached != null) {
                    launchFileProviderVideoIntent(context, cached, video.name)
                    return@launch
                }
                val remoteUrl = cloudClient.resolveDownloadUrl(video.id)
                val cm = cacheManager
                val acct = activeAccountKey
                val loopbackUrl: String? = if (streamServer != null && cm != null && acct != null) {
                    val dest = withContext(ioDispatcher) { cm.cacheFile(video.id, video.name) }
                    streamServer.registerSource(
                        StreamSourceRegistration(
                            accountHash = Cloud189Protocol.accountBucketHash(acct),
                            trackId = video.id,
                            remoteUrl = remoteUrl,
                            cacheDestination = dest,
                            expectedSize = video.sizeBytes,
                            fileName = video.name,
                            cacheLimitBytes = committedSettings.cacheLimitBytes
                        ),
                        cacheManager = cm
                    )
                } else null
                pendingExternalVideoAction = PendingExternalVideoAction(video, loopbackUrl)
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                statusMessage = "准备外部播放失败：${e.message}"
            }
        }
    }

    fun downloadVideoAndOpenExternally(context: Context, video: TrackSummary) {
        val cm = cacheManager ?: return
        val acct = activeAccountKey ?: return
        pendingExternalVideoAction = null
        val appContextRef = context.applicationContext
        scope.launch {
            busyLabel = "正在缓存视频《${video.name}》..."
            try {
                val localFile = transferEngine.downloadTrackToCache(
                    track = video,
                    cacheManager = cm,
                    parallelThreads = committedSettings.downloadThreads,
                    cacheLimitBytes = maxOf(committedSettings.cacheLimitBytes, video.sizeBytes),
                    kind = "playback",
                    accountHash = Cloud189Protocol.accountBucketHash(acct)
                )
                cacheUsageBytes = withContext(ioDispatcher) { cm.usageBytes() }
                launchFileProviderVideoIntent(appContextRef, localFile, video.name)
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                statusMessage = "缓存视频失败：${e.message}"
            } finally {
                busyLabel = null
            }
        }
    }

    fun launchLoopbackStreamInVideoApp(context: Context, action: PendingExternalVideoAction) {
        pendingExternalVideoAction = null
        val streamUrl = action.streamUrl ?: return
        val uri = Uri.parse(streamUrl)
        if (uri?.host != "127.0.0.1") return
        val mime = PlaybackDecisionPolicy.guessMimeType(action.video.name)
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
            statusMessage = "未能唤起外部视频播放器：${err.message}"
        }
    }

    private fun launchFileProviderVideoIntent(context: Context, localFile: File, fileName: String) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", localFile)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, PlaybackDecisionPolicy.guessMimeType(fileName))
            clipData = ClipData.newRawUri("", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val chooser = Intent.createChooser(intent, "选择本地视频播放器").apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(chooser)
    }

    fun onSafTreeSelected(context: Context, treeUri: Uri) {
        val appContextRef = context.applicationContext
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        runCatching { appContextRef.contentResolver.takePersistableUriPermission(treeUri, flags) }
        val fallbackName = treeUri.lastPathSegment ?: "已选文件夹"
        scope.launch {
            val resolvedName = withContext(ioDispatcher) {
                runCatching { SafExporter.persistTreePermission(appContextRef, treeUri) }.getOrDefault(fallbackName)
            }
            mutateAccountSettings(successMessage = "导出目录已设为 $resolvedName") { prev ->
                prev.copy(
                    exportTreeUri = treeUri.toString(),
                    exportFolderDisplayName = resolvedName
                )
            }
        }
    }

    fun enqueueDownload(context: Context, track: TrackSummary) {
        val appContextRef = context.applicationContext
        val acct = activeAccountKey ?: return
        val threads = committedSettings.downloadThreads
        scope.launch {
            val (taskId, snap) = withContext(ioDispatcher) {
                val paths = accountStore.paths(acct)
                val id = transferEngine.enqueueExportDownload(
                    accountId = acct,
                    track = track,
                    relativeSubpath = track.name,
                    parallelThreads = threads,
                    stagingRootDir = paths.stagingDir,
                    manifestsFile = paths.transfersFile
                ) { staged, rel, _ ->
                    SafExporter.exportToSafTree(
                        context = appContextRef,
                        treeUriString = committedSettings.exportTreeUri,
                        stagedFile = staged,
                        relativeSubpath = rel,
                        mimeType = PlaybackDecisionPolicy.guessMimeType(track.name)
                    )
                }
                id to transferEngine.snapshot()
            }
            transferSnapshot = snap
            statusMessage = "已添加下载任务 $taskId"
        }
    }

    fun enqueueCurrentFolderDownload(context: Context, pane: BrowserPaneState = cloudBrowser) {
        val appContextRef = context.applicationContext
        enqueueCurrentFolderDownloadWithExporter(pane) { staged, subpath, _ ->
            SafExporter.exportToSafTree(
                context = appContextRef,
                treeUriString = committedSettings.exportTreeUri,
                stagedFile = staged,
                relativeSubpath = subpath,
                mimeType = PlaybackDecisionPolicy.guessMimeType(subpath)
            )
        }
    }

    internal fun enqueueCurrentFolderDownloadWithExporter(
        pane: BrowserPaneState = cloudBrowser,
        exporter: StagedFileExporter
    ) {
        val b = pane.payload ?: return
        val acct = activeAccountKey ?: return
        val nonRootCrumbs = pane.breadcrumbs.filter { it.id != null && it.id != Cloud189Constants.ROOT_FOLDER_ID }
        val crumbPath = if (!b.isRoot && nonRootCrumbs.lastOrNull()?.id == b.currentFolderId) {
            nonRootCrumbs.map { it.name }.filter { it.isNotEmpty() }.joinToString("/").takeIf { it.isNotEmpty() }
        } else null
        val rootExportFolder = crumbPath ?: b.currentFolderName

        scope.launch {
            busyLabel = "扫描文件夹 ${b.currentFolderName}..."
            try {
                val allFiles = cloudClient.scanAllFiles(b.currentFolderId, rootExportFolder)
                val snap = withContext(ioDispatcher) {
                    val paths = accountStore.paths(acct)
                    for (item in allFiles) {
                        val rel = if (item.folderPath.startsWith(rootExportFolder)) {
                            "${item.folderPath}/${item.name}"
                        } else {
                            "$rootExportFolder/${item.name}"
                        }
                        transferEngine.enqueueExportDownload(
                            accountId = acct,
                            track = item,
                            relativeSubpath = rel,
                            parallelThreads = committedSettings.downloadThreads,
                            stagingRootDir = paths.stagingDir,
                            manifestsFile = paths.transfersFile,
                            exporter = exporter
                        )
                    }
                    transferEngine.snapshot()
                }
                transferSnapshot = snap
                statusMessage = "目录下载已入队（共 ${allFiles.size} 个文件）"
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                statusMessage = e.message
            } finally {
                busyLabel = null
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
            transferSnapshot = snap
        }
    }

    fun resumeTransfer(context: Context, id: String) {
        val appContextRef = context.applicationContext
        val acct = activeAccountKey ?: return
        scope.launch {
            val snap = withContext(ioDispatcher) {
                val paths = accountStore.paths(acct)
                transferEngine.resumeTransfer(id, paths.stagingDir, paths.transfersFile) { staged, rel, _ ->
                    SafExporter.exportToSafTree(
                        context = appContextRef,
                        treeUriString = committedSettings.exportTreeUri,
                        stagedFile = staged,
                        relativeSubpath = rel,
                        mimeType = PlaybackDecisionPolicy.guessMimeType(rel)
                    )
                }
                transferEngine.snapshot()
            }
            transferSnapshot = snap
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
        if (!isAuthenticated || loopMode == LoopMode.ONE || currentTrack == null) return
        val next = PlaybackQueueResolver.peekPrefetchCandidate(
            currentTrack = currentTrack,
            libraryTracks = tracks,
            upNextQueue = upNextQueue,
            shuffle = shuffle,
            shuffleOrderIds = shuffleOrderIds,
            loopMode = loopMode
        ) ?: return
        if (next.id == prefetchedTrackId || next.id == prefetchingTrackId) return

        prefetchingTrackId = next.id
        val activeId = currentTrackId.orEmpty()
        val accountHash = activeAccountKey?.let { Cloud189Protocol.accountBucketHash(it) }
        scope.launch {
            try {
                withContext(ioDispatcher) {
                    cm.setProtectedTrackIds(setOf(activeId, next.id))
                }
                transferEngine.downloadTrackToCache(
                    track = next,
                    cacheManager = cm,
                    parallelThreads = committedSettings.cacheThreads,
                    cacheLimitBytes = committedSettings.cacheLimitBytes,
                    kind = "prefetch",
                    accountHash = accountHash
                )
                prefetchedTrackId = next.id
            } catch (ce: CancellationException) {
                throw ce
            } catch (_: Exception) {
                // Best-effort background prefetch
            } finally {
                if (prefetchingTrackId == next.id) {
                    prefetchingTrackId = null
                }
            }
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
        credentialStore: CredentialStore? = appContext?.applicationContext?.let { EncryptedCredentialStore(it) },
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

    // Minimal lifecycle & contract entrypoints; Compose UI binds directly to `viewModel.runtime`.
    var themeMode: AppearanceMode
        get() = runtime.themeMode
        set(value) { runtime.themeMode = value }
    var activeModule: ModuleTab
        get() = runtime.activeModule
        set(value) { runtime.activeModule = value }
    var isAuthenticated: Boolean
        get() = runtime.isAuthenticated
        set(value) { runtime.isAuthenticated = value }
    val accountName: String? get() = runtime.accountName
    val accountStorageKey: String? get() = runtime.accountStorageKey
    val committedSettings: AccountSettings get() = runtime.committedSettings
    var cacheLimitDraft: String
        get() = runtime.cacheLimitDraft
        set(value) { runtime.cacheLimitDraft = value }
    val settingsValidationError: String? get() = runtime.settingsValidationError
    val statusMessage: String? get() = runtime.statusMessage
    val browser: FolderBrowsePayload? get() = runtime.browser
    var tracks: List<TrackSummary>
        get() = runtime.tracks
        set(value) { runtime.tracks = value }
    val currentTrackId: String? get() = runtime.currentTrackId
    var shuffle: Boolean
        get() = runtime.shuffle
        set(value) { runtime.shuffle = value }
    val downloadTransfers: List<TransferStatus> get() = runtime.downloadTransfers

    fun bootstrap(): Deferred<Unit> = runtime.bootstrap()
    fun noteDraftEdited() = runtime.noteDraftEdited()
    fun commitCacheLimitDraft(): Boolean = runtime.commitCacheLimitDraft()
    suspend fun commitCacheLimitDraftAsync(): Boolean = runtime.commitCacheLimitDraftAsync()
    fun updatePlaybackMode(mode: PlaybackMode) = runtime.updatePlaybackMode(mode)
    fun completeEmbeddedWebLogin(callbackUrl: String, cookiesByOrigin: Map<String, String?>) =
        runtime.completeEmbeddedWebLogin(callbackUrl, cookiesByOrigin)
    fun logout() = runtime.logout()
    fun browseTo(folderId: String?, nextCrumbs: List<BreadcrumbItem>, showBusy: Boolean = true) =
        runtime.browseTo(folderId, nextCrumbs, showBusy)
    fun playTrack(
        track: TrackSummary,
        modeOverride: PlaybackMode? = null,
        forceStreamProxy: Boolean = false,
        isRecoveryRetry: Boolean = false
    ) = runtime.playTrack(track, modeOverride, forceStreamProxy, isRecoveryRetry)
    fun handlePlaybackError(
        track: TrackSummary,
        message: String,
        wasLoopback: Boolean,
        explicitIsDecode: Boolean? = null
    ) = runtime.handlePlaybackError(track, message, wasLoopback, explicitIsDecode)
    fun openVideoInApp(video: TrackSummary) = runtime.openVideoInApp(video)

    internal fun clearViewModelForTest() {
        onCleared()
    }

    public override fun onCleared() {
        runtime.onUiDetached()
        super.onCleared()
    }

    companion object {
        fun fixture(scene: SnapshotScene, fixture: RepresentativeFixture): CloudTuneViewModel {
            val isolatedDir = File(System.getProperty("java.io.tmpdir"), "cloudtune-fixture-${UUID.randomUUID()}")
            val vm = CloudTuneViewModel(accountStore = AccountStore(isolatedDir), enableLiveLoops = false)
            val rt = vm.runtime
            rt.committedSettings = AccountSettings(
                musicFolder = fixture.currentFolder,
                cacheLimitMb = fixture.cacheLimitMb,
                downloadThreads = fixture.downloadThreads,
                cacheThreads = fixture.cacheThreads,
                playbackMode = fixture.playbackMode,
                exportFolderDisplayName = "MusicExports",
                appearanceMode = fixture.appearanceMode,
                dynamicColorEnabled = fixture.dynamicColorEnabled
            )
            rt.themeMode = fixture.appearanceMode
            rt.dynamicColorEnabled = fixture.dynamicColorEnabled
            rt.syncDraftsFromCommitted()

            when (scene) {
                SnapshotScene.AUTH_IDLE -> {
                    rt.isAuthenticated = false
                    rt.accountName = null
                    rt.accountStorageKey = null
                    rt.cacheUsageBytes = 0L
                }
                SnapshotScene.AUTH_QR -> {
                    rt.isAuthenticated = false
                    rt.accountName = null
                    rt.accountStorageKey = null
                    rt.cacheUsageBytes = 0L
                    rt.qrContent = fixture.qrContent
                    rt.qrHint = fixture.qrMessage
                    rt.statusMessage = fixture.qrMessage
                    rt.qrBitmap = QrCodeHelper.generateQrBitmap(fixture.qrContent, 420)
                }
                SnapshotScene.MUSIC,
                SnapshotScene.VIDEO,
                SnapshotScene.DOWNLOAD,
                SnapshotScene.ERROR_BANNER,
                SnapshotScene.CLOUD,
                SnapshotScene.SETTINGS,
                SnapshotScene.NOW_PLAYING -> {
                    rt.isAuthenticated = true
                    rt.accountName = fixture.accountName
                    rt.accountStorageKey = fixture.accountName
                    rt.cacheUsageBytes = fixture.cacheUsageBytes
                    val pane = BrowserPaneState(breadcrumbs = fixture.breadcrumbs, payload = fixture.browser)
                    rt.cloudBrowser = pane
                    rt.videoBrowser = pane
                    rt.tracks = fixture.libraryTracks
                    rt.activeTrack = fixture.libraryTracks.firstOrNull { it.id == fixture.nowPlayingTrackId }
                        ?: fixture.browser.audioFiles.firstOrNull { it.id == fixture.nowPlayingTrackId }
                    rt.currentTrackId = fixture.nowPlayingTrackId
                    rt.nowPlayingTitle = fixture.nowPlayingTitle
                    rt.nowPlayingArtist = fixture.nowPlayingArtist
                    rt.nowPlayingAlbum = fixture.nowPlayingAlbum
                    rt.isPlaying = scene != SnapshotScene.ERROR_BANNER && fixture.isPlaying
                    rt.currentTime = fixture.currentTimeSeconds
                    rt.duration = fixture.durationSeconds
                    rt.shuffle = fixture.shuffle
                    rt.shuffleOrderIds = fixture.libraryTracks.map { it.id }
                    rt.loopMode = fixture.loopMode
                    rt.upNextQueue = fixture.libraryTracks.filterNot { it.id == fixture.nowPlayingTrackId }.take(2)
                    rt.transferSnapshot = fixture.transferSnapshot
                    rt.statusMessage = if (scene == SnapshotScene.ERROR_BANNER) {
                        fixture.errorBannerMessage
                    } else {
                        fixture.statusMessage
                    }
                    when (scene) {
                        SnapshotScene.VIDEO -> rt.activeModule = ModuleTab.VIDEO
                        SnapshotScene.DOWNLOAD -> rt.activeModule = ModuleTab.TRANSFERS
                        SnapshotScene.CLOUD -> rt.activeModule = ModuleTab.CLOUD
                        SnapshotScene.SETTINGS -> rt.activeModule = ModuleTab.SETTINGS
                        SnapshotScene.NOW_PLAYING -> {
                            rt.activeModule = ModuleTab.MUSIC
                            rt.isShowingNowPlayingSheet = true
                        }
                        else -> rt.activeModule = ModuleTab.MUSIC
                    }
                }
            }
            return vm
        }
    }
}
