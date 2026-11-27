package com.gosu.cloudtune.ui

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.FileProvider
import androidx.lifecycle.ViewModel
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.gosu.cloudtune.core.AccountSettings
import com.gosu.cloudtune.core.AppThemeMode
import com.gosu.cloudtune.core.BreadcrumbItem
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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Application/service-scoped runtime holder keeping `LocalStreamServer`, `MediaController`,
 * queue state, and lockscreen Next/Previous callbacks alive across `Activity` / `ViewModel` recreation.
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
    dispatcher: CoroutineDispatcher = if (appContext != null) Dispatchers.Main.immediate else Dispatchers.Unconfined
) {
    val scope = CoroutineScope(SupervisorJob() + dispatcher)

    var themeMode by mutableStateOf(AppThemeMode.SYSTEM)
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

    // Cloud browser & library
    var breadcrumbs by mutableStateOf(listOf(BreadcrumbItem.ROOT))
    var browser by mutableStateOf<FolderBrowsePayload?>(null)
    var tracks by mutableStateOf<List<TrackSummary>>(emptyList())
    var searchQuery by mutableStateOf("")

    // Playback state
    var currentTrackId by mutableStateOf<String?>(null)
    var nowPlayingTitle by mutableStateOf<String?>(null)
    var nowPlayingArtist by mutableStateOf<String?>(null)
    var isPlaying by mutableStateOf(false)
    var loadingTrackId by mutableStateOf<String?>(null)
    var shuffle by mutableStateOf(true)
    var loopMode by mutableStateOf(LoopMode.ALL)
    var currentTime by mutableDoubleStateOf(0.0)
    var duration by mutableDoubleStateOf(0.0)

    // Video state
    var activeVideoUrl by mutableStateOf<String?>(null)
    var activeVideoTitle by mutableStateOf<String?>(null)

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
                urlRefresher = { trackId ->
                    cloudClient.resolveDownloadUrl(trackId)
                }
            )
        }.getOrNull()
    } else null

    private val hasAndroidContext: Boolean = appContext != null
    private var cacheManager: CacheManager? = null
    private var mediaController: MediaController? = null
    private var pendingMediaItem: MediaItem? = null
    internal var lastPreparedPlaybackUrl: String? = null
    private var qrPollJob: Job? = null
    private var transferPollJob: Job? = null
    private var prefetchedTrackId: String? = null
    private var prefetchingTrackId: String? = null
    private var plannedShuffleNextTrackId: String? = null
    private var playbackGeneration: Int = 0
    private var recoveryAttempts = 0
    private var currentPlaybackIsLoopback = false

    init {
        syncDraftsFromCommitted()
        if (enableLiveLoops) {
            bindSkipBridge()
            if (appContext != null) {
                connectMediaController(appContext.applicationContext)
            }
        }
    }

    internal fun bindSkipBridge() {
        if (!enableLiveLoops) return
        PlaybackSessionBridge.onSkipNext = { playAdjacent(1) }
        PlaybackSessionBridge.onSkipPrevious = { playAdjacent(-1) }
    }

    internal fun onUiAttached() {
        if (enableLiveLoops) {
            bindSkipBridge()
            if (isAuthenticated && (transferPollJob == null || transferPollJob?.isActive != true)) {
                startTransferPolling()
            }
        }
    }

    internal fun onUiDetached() {
        // Keep LocalStreamServer, MediaController, and PlaybackSessionBridge alive so background
        // PlaybackService loopback streaming and lockscreen Next/Previous survive Activity finish!
        qrPollJob?.cancel()
        qrPollJob = null
        if (!isPlaying) {
            transferPollJob?.cancel()
            transferPollJob = null
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
        get() = currentTrackId?.let { id ->
            tracks.firstOrNull { it.id == id } ?: browser?.audioFiles?.firstOrNull { it.id == id }
        }

    val downloadTransfers: List<TransferStatus>
        get() = transferSnapshot.items.filter { it.kind == "download" }

    val downloadableFiles: List<TrackSummary>
        get() = browser?.let { it.audioFiles + it.videoFiles + it.otherFiles } ?: emptyList()

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

    fun commitCacheLimitDraft(): Boolean {
        val parsed = cacheLimitDraft.trim().toLongOrNull()
        if (parsed == null || parsed < AccountSettings.MIN_CACHE_LIMIT_MB) {
            val msg = "缓存上限至少设为 256 MB。"
            settingsValidationError = msg
            statusMessage = msg
            return false
        }
        val next = committedSettings.copy(cacheLimitMb = parsed)
        committedSettings = next
        syncDraftsFromCommitted()
        activeAccountKey?.let { accountStore.saveSettings(it, next) }
        cacheManager?.let { cacheUsageBytes = it.pruneToLimit(next.cacheLimitBytes) }
        statusMessage = "缓存限制已更新"
        return true
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
        val next = committedSettings.copy(downloadThreads = dl, cacheThreads = ct)
        committedSettings = next
        syncDraftsFromCommitted()
        activeAccountKey?.let { accountStore.saveSettings(it, next) }
        statusMessage = "传输参数已更新"
        return true
    }

    fun updatePlaybackMode(mode: PlaybackMode) {
        val next = committedSettings.copy(playbackMode = mode)
        committedSettings = next
        activeAccountKey?.let { accountStore.saveSettings(it, next) }
        statusMessage = if (mode == PlaybackMode.DOWNLOAD_FIRST) "已切到优先缓存播放" else "已切到边播边缓存"
    }

    fun bootstrap() {
        if (isAuthenticated || isBootstrapping) return
        scope.launch {
            val stored = withContext(Dispatchers.IO) { credentialStore?.loadCredential() } ?: return@launch
            isBootstrapping = true
            busyLabel = "恢复天翼登录会话..."
            try {
                val restored = cloudClient.restoreFromRefreshCredential(stored)
                val identity = Cloud189Protocol.resolveAccountIdentity(
                    activeSession = restored.activeSession,
                    persistedCredential = restored.persistedCredential ?: stored,
                    priorAccountKey = stored.accountKey
                )
                restored.persistedCredential?.let { cred ->
                    withContext(Dispatchers.IO) {
                        credentialStore?.saveCredential(cred.withAccountKey(identity.storageKey))
                    }
                }
                activateAccount(storageKey = identity.storageKey, displayName = identity.displayName)
                browseToSuspend(null, listOf(BreadcrumbItem.ROOT), showBusy = false)
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                isAuthenticated = false
                statusMessage = e.message
            } finally {
                busyLabel = null
                isBootstrapping = false
            }
        }
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
                qrBitmap = withContext(Dispatchers.IO) {
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
                                withContext(Dispatchers.IO) {
                                    credentialStore?.saveCredential(cred.withAccountKey(identity.storageKey))
                                }
                            }
                            qrContent = null
                            qrBitmap = null
                            activateAccount(storageKey = identity.storageKey, displayName = identity.displayName)
                            browseToSuspend(null, listOf(BreadcrumbItem.ROOT), showBusy = false)
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
                    withContext(Dispatchers.IO) {
                        credentialStore?.saveCredential(cred.withAccountKey(identity.storageKey))
                    }
                }
                isShowingWebLoginDialog = false
                qrPollJob?.cancel()
                qrContent = null
                qrBitmap = null
                activateAccount(storageKey = identity.storageKey, displayName = identity.displayName)
                browseToSuspend(null, listOf(BreadcrumbItem.ROOT), showBusy = false)
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
        val loaded = withContext(Dispatchers.IO) {
            val paths = accountStore.paths(storageKey)
            val cm = CacheManager(paths.cacheDir)
            val usage = cm.usageBytes()
            val savedSettings = accountStore.loadSettings(storageKey)
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
        syncDraftsFromCommitted()
        tracks = loaded.tracks
        transferSnapshot = loaded.snapshot
        if (enableLiveLoops) {
            startTransferPolling()
        }
    }

    private data class LoadedAccountState(
        val cacheManager: CacheManager,
        val usageBytes: Long,
        val settings: AccountSettings,
        val tracks: List<TrackSummary>,
        val snapshot: TransferSnapshotPayload
    )

    fun logout() {
        qrPollJob?.cancel()
        transferPollJob?.cancel()
        playbackGeneration += 1
        recoveryAttempts = 0
        pendingMediaItem = null
        prefetchedTrackId = null
        prefetchingTrackId = null
        plannedShuffleNextTrackId = null
        mediaController?.stop()
        mediaController?.clearMediaItems()
        activeAccountKey?.let { key ->
            streamServer?.revokeAllSources(Cloud189Protocol.accountBucketHash(key))
            transferEngine.cancelAll(key)
        }
        scope.launch {
            withContext(Dispatchers.IO) {
                credentialStore?.clearCredential()
            }
            cloudClient.clearSession()
        }

        isAuthenticated = false
        accountName = null
        accountStorageKey = null
        cacheManager = null
        cacheUsageBytes = 0L
        browser = null
        tracks = emptyList()
        breadcrumbs = listOf(BreadcrumbItem.ROOT)
        currentTrackId = null
        nowPlayingTitle = null
        nowPlayingArtist = null
        isPlaying = false
        currentTime = 0.0
        duration = 0.0
        transferSnapshot = TransferSnapshotPayload()
        committedSettings = AccountSettings()
        syncDraftsFromCommitted()
        statusMessage = "已退出登录并清理当前会话"
    }

    fun browseTo(folderId: String?, nextCrumbs: List<BreadcrumbItem>, showBusy: Boolean = true) {
        if (!isAuthenticated) return
        scope.launch {
            browseToSuspend(folderId, nextCrumbs, showBusy)
        }
    }

    private suspend fun browseToSuspend(
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
            browser = cloudClient.listRemoteFolder(
                folderId = folderId,
                folderName = resolvedName,
                folderPath = resolvedPath
            )
            breadcrumbs = nextCrumbs
        } catch (ce: CancellationException) {
            throw ce
        } catch (e: Exception) {
            statusMessage = e.message
        } finally {
            if (showBusy) busyLabel = null
        }
    }

    fun setCurrentFolderAsMusicLibrary() {
        val b = browser ?: return
        val crumb = breadcrumbs.lastOrNull() ?: return
        val acct = activeAccountKey ?: return
        val displayName = if (crumb.id == b.currentFolderId || (b.isRoot && crumb.id == null)) {
            crumb.name
        } else {
            b.currentFolderName
        }
        val next = committedSettings.copy(musicFolder = FolderSelection(b.currentFolderId, displayName))
        committedSettings = next
        scope.launch(Dispatchers.IO) {
            accountStore.saveSettings(acct, next)
        }
        statusMessage = "音乐目录已设置为 $displayName"
        scanMusicLibrary()
    }

    fun scanMusicLibrary() {
        val folder = committedSettings.musicFolder ?: run {
            statusMessage = "请先选择音乐目录"
            return
        }
        val acct = activeAccountKey ?: return
        scope.launch {
            busyLabel = "扫描 ${folder.name} 中的音乐..."
            try {
                val scanned = cloudClient.scanMusicLibrary(folder.id, folder.name)
                tracks = scanned
                withContext(Dispatchers.IO) {
                    accountStore.saveLibrary(acct, scanned)
                }
                statusMessage = "已载入 ${scanned.size} 首音乐"
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                statusMessage = e.message
            } finally {
                busyLabel = null
            }
        }
    }

    fun playTrack(
        track: TrackSummary,
        modeOverride: PlaybackMode? = null,
        forceStreamProxy: Boolean = false,
        isRecoveryRetry: Boolean = false
    ) {
        val acctKey = activeAccountKey ?: return
        val artistFallback = accountName ?: "CloudTune"
        val cm = cacheManager ?: return
        playbackGeneration += 1
        val gen = playbackGeneration
        prefetchedTrackId = null
        prefetchingTrackId = null
        plannedShuffleNextTrackId = null
        if (!isRecoveryRetry) {
            recoveryAttempts = 0
        }
        val accountHash = Cloud189Protocol.accountBucketHash(acctKey)
        scope.launch {
            loadingTrackId = track.id
            val effectiveMode = modeOverride ?: committedSettings.playbackMode
            try {
                val cached = withContext(Dispatchers.IO) {
                    cm.setProtectedTrackIds(setOf(track.id))
                    cm.existingCachedFile(track.id)
                }
                if (cached != null) {
                    val (usage, meta) = withContext(Dispatchers.IO) {
                        cm.usageBytes() to AudioMetadataHelper.extract(cached, track.name, artistFallback, track.folderPath)
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
                    val (usage, meta) = withContext(Dispatchers.IO) {
                        cm.usageBytes() to AudioMetadataHelper.extract(file, track.name, artistFallback, track.folderPath)
                    }
                    if (gen != playbackGeneration || !isAuthenticated) return@launch
                    cacheUsageBytes = usage
                    val fileUri = Uri.fromFile(file)?.toString() ?: file.toURI().toString()
                    startControllerPlayback(track, fileUri, isLoopback = false, metadata = meta)
                } else {
                    val remoteUrl = cloudClient.resolveDownloadUrl(track.id)
                    if (gen != playbackGeneration || !isAuthenticated) return@launch
                    val dest = withContext(Dispatchers.IO) { cm.cacheFile(track.id, track.name) }
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

    private fun startControllerPlayback(
        track: TrackSummary,
        uriString: String,
        isLoopback: Boolean,
        metadata: ExtractedAudioMetadata?
    ) {
        currentPlaybackIsLoopback = isLoopback
        currentTrackId = track.id
        lastPreparedPlaybackUrl = uriString
        nowPlayingTitle = metadata?.title ?: track.name
        nowPlayingArtist = metadata?.artist ?: (accountName ?: "CloudTune")
        val controller = mediaController
        if (controller != null || hasAndroidContext) {
            val metaBuilder = MediaMetadata.Builder()
                .setTitle(nowPlayingTitle)
                .setArtist(nowPlayingArtist)
                .setAlbumTitle(metadata?.album ?: track.folderPath)
            metadata?.artworkBytes?.let { art ->
                metaBuilder.setArtworkData(art, MediaMetadata.PICTURE_TYPE_FRONT_COVER)
            }
            val item = MediaItem.Builder()
                .setMediaId(track.id)
                .setUri(uriString)
                .setMediaMetadata(metaBuilder.build())
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
        statusMessage = if (isLoopback) "边播边缓存《${track.name}》" else "正在播放《${track.name}》"
    }

    fun handlePlaybackError(track: TrackSummary, message: String, wasLoopback: Boolean) {
        val failedGeneration = playbackGeneration
        val lower = message.lowercase()
        val lowerName = track.name.lowercase()
        val isTimeout = lower.contains("timeout") || lower.contains("timed out")
        val isUnsupportedExt = lowerName.endsWith(".ape") || lowerName.endsWith(".wma")
        val isDecode = (!isTimeout && isUnsupportedExt) ||
            lower.contains("decode") ||
            lower.contains("format") ||
            lower.contains("source") ||
            lower.contains("unrecognized")
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
                statusMessage = action.userMessage
            }
            PlaybackFailureAction.StopAfterMaxRetries -> {
                isPlaying = false
                statusMessage = "播放异常，已停止自动重试《${track.name}》"
            }
            is PlaybackFailureAction.RetryTransientAfterDelay -> {
                isPlaying = false
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
            val candidate = if (shuffle) tracks.randomOrNull() else tracks.firstOrNull()
            candidate?.let { playTrack(it) }
            return
        }
        val controller = mediaController
        if (controller == null) {
            isPlaying = !isPlaying
            return
        }
        if (controller.isPlaying) {
            controller.pause()
            isPlaying = false
        } else {
            if (controller.mediaItemCount == 0) playTrack(curr) else controller.play()
            isPlaying = true
        }
    }

    fun playAdjacent(direction: Int) {
        if (tracks.isEmpty()) return
        if (shuffle && tracks.size > 1) {
            if (direction > 0) {
                val preselectedId = prefetchedTrackId ?: plannedShuffleNextTrackId
                val preselected = preselectedId
                    ?.takeIf { it != currentTrackId }
                    ?.let { id -> tracks.firstOrNull { it.id == id } }
                if (preselected != null) {
                    playTrack(preselected)
                    return
                }
            }
            val pool = tracks.filter { it.id != currentTrackId }
            pool.randomOrNull()?.let { playTrack(it) }
            return
        }
        val idx = tracks.indexOfFirst { it.id == currentTrackId }
        val nextIdx = idx + direction
        if (nextIdx in tracks.indices) {
            playTrack(tracks[nextIdx])
        } else if (loopMode == LoopMode.ALL) {
            playTrack(if (direction > 0) tracks.first() else tracks.last())
        }
    }

    fun seekTo(seconds: Double) {
        currentTime = seconds.coerceAtLeast(0.0)
        mediaController?.seekTo((currentTime * 1000.0).toLong())
    }

    fun openVideoInApp(video: TrackSummary) {
        mediaController?.pause()
        isPlaying = false
        scope.launch {
            busyLabel = "获取视频地址..."
            try {
                activeVideoTitle = video.name
                activeVideoUrl = cloudClient.resolveDownloadUrl(video.id)
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                statusMessage = e.message
            } finally {
                busyLabel = null
            }
        }
    }

    fun openVideoExternally(context: Context, video: TrackSummary) {
        scope.launch {
            try {
                val cached = withContext(Dispatchers.IO) { cacheManager?.existingCachedFile(video.id) }
                val uri = if (cached != null) {
                    FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", cached)
                } else {
                    Uri.parse(cloudClient.resolveDownloadUrl(video.id))
                }
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, PlaybackDecisionPolicy.guessMimeType(video.name))
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(Intent.createChooser(intent, "选择外部播放器"))
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                statusMessage = "无法唤起外部播放器：${e.message}"
            }
        }
    }

    fun onSafTreeSelected(context: Context, treeUri: Uri) {
        val acct = activeAccountKey ?: return
        val name = SafExporter.persistTreePermission(context, treeUri)
        val next = committedSettings.copy(
            exportTreeUri = treeUri.toString(),
            exportFolderDisplayName = name
        )
        committedSettings = next
        scope.launch(Dispatchers.IO) {
            accountStore.saveSettings(acct, next)
        }
        statusMessage = "导出目录已设为 $name"
    }

    fun enqueueDownload(context: Context, track: TrackSummary) {
        val appCtx = context.applicationContext
        val acct = activeAccountKey ?: return
        val paths = accountStore.paths(acct)
        val taskId = transferEngine.enqueueExportDownload(
            accountId = acct,
            track = track,
            relativeSubpath = track.name,
            parallelThreads = committedSettings.downloadThreads,
            stagingRootDir = paths.stagingDir,
            manifestsFile = paths.transfersFile
        ) { staged, rel, _ ->
            SafExporter.exportToSafTree(
                context = appCtx,
                treeUriString = committedSettings.exportTreeUri,
                stagedFile = staged,
                relativeSubpath = rel,
                mimeType = PlaybackDecisionPolicy.guessMimeType(track.name)
            )
        }
        transferSnapshot = transferEngine.snapshot()
        statusMessage = "已添加下载任务 $taskId"
    }

    fun enqueueCurrentFolderDownload(context: Context) {
        val appCtx = context.applicationContext
        enqueueCurrentFolderDownloadWithExporter { staged, subpath, _ ->
            SafExporter.exportToSafTree(
                context = appCtx,
                treeUriString = committedSettings.exportTreeUri,
                stagedFile = staged,
                relativeSubpath = subpath,
                mimeType = PlaybackDecisionPolicy.guessMimeType(subpath)
            )
        }
    }

    internal fun enqueueCurrentFolderDownloadWithExporter(exporter: StagedFileExporter) {
        val b = browser ?: return
        val acct = activeAccountKey ?: return
        val paths = accountStore.paths(acct)
        val nonRootCrumbs = breadcrumbs.filter { it.id != null && it.id != Cloud189Constants.ROOT_FOLDER_ID }
        val crumbPath = if (!b.isRoot && nonRootCrumbs.lastOrNull()?.id == b.currentFolderId) {
            nonRootCrumbs.map { it.name }.filter { it.isNotEmpty() }.joinToString("/").takeIf { it.isNotEmpty() }
        } else null
        val rootExportFolder = crumbPath ?: b.currentFolderName

        scope.launch {
            busyLabel = "扫描文件夹 ${b.currentFolderName}..."
            try {
                val allFiles = cloudClient.scanAllFiles(b.currentFolderId, rootExportFolder)
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
                transferSnapshot = transferEngine.snapshot()
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
        transferEngine.pauseTransfer(id, accountStore.paths(acct).transfersFile)
        transferSnapshot = transferEngine.snapshot()
    }

    fun resumeTransfer(context: Context, id: String) {
        val appCtx = context.applicationContext
        val acct = activeAccountKey ?: return
        val paths = accountStore.paths(acct)
        transferEngine.resumeTransfer(id, paths.stagingDir, paths.transfersFile) { staged, rel, _ ->
            SafExporter.exportToSafTree(
                context = appCtx,
                treeUriString = committedSettings.exportTreeUri,
                stagedFile = staged,
                relativeSubpath = rel,
                mimeType = PlaybackDecisionPolicy.guessMimeType(rel)
            )
        }
        transferSnapshot = transferEngine.snapshot()
    }

    fun deleteTransfer(id: String) {
        val acct = activeAccountKey ?: return
        val paths = accountStore.paths(acct)
        transferEngine.deleteTransfer(id, paths.stagingDir, paths.transfersFile)
        transferSnapshot = transferEngine.snapshot()
    }

    private fun startTransferPolling() {
        transferPollJob?.cancel()
        transferPollJob = scope.launch {
            while (isActive) {
                delay(850L)
                transferSnapshot = transferEngine.snapshot()
                cacheManager?.let { cm ->
                    cacheUsageBytes = withContext(Dispatchers.IO) { cm.usageBytes() }
                }
                mediaController?.let { mc ->
                    if (mc.duration > 0L) duration = mc.duration / 1000.0
                    currentTime = mc.currentPosition.coerceAtLeast(0L) / 1000.0
                    isPlaying = mc.isPlaying
                }
                maybePrefetchUpcomingTrack()
            }
        }
    }

    private fun maybePrefetchUpcomingTrack() {
        val cm = cacheManager ?: return
        if (!isAuthenticated || loopMode == LoopMode.ONE || currentTrack == null) return
        val remaining = duration - currentTime
        val shouldPrefetch = committedSettings.playbackMode == PlaybackMode.DOWNLOAD_FIRST ||
            (remaining.isFinite() && remaining > 0.0 && remaining <= 30.0)
        if (!shouldPrefetch) return

        val next = pickPrefetchCandidate() ?: return
        if (next.id == prefetchedTrackId || next.id == prefetchingTrackId) return

        prefetchingTrackId = next.id
        val activeId = currentTrackId.orEmpty()
        val accountHash = activeAccountKey?.let { Cloud189Protocol.accountBucketHash(it) }
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
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

    private fun pickPrefetchCandidate(): TrackSummary? {
        if (tracks.isEmpty()) return null
        if (shuffle) {
            val existingPlanned = plannedShuffleNextTrackId
                ?.takeIf { it != currentTrackId }
                ?.let { id -> tracks.firstOrNull { it.id == id } }
            if (existingPlanned != null) return existingPlanned
            val picked = tracks.filter { it.id != currentTrackId }.randomOrNull() ?: tracks.firstOrNull()
            plannedShuffleNextTrackId = picked?.id
            return picked
        }
        val idx = tracks.indexOfFirst { it.id == currentTrackId }
        if (idx < 0) return tracks.firstOrNull()
        val next = idx + 1
        return if (next in tracks.indices) tracks[next] else if (loopMode == LoopMode.ALL) tracks.firstOrNull() else null
    }

    private fun connectMediaController(context: Context) {
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val future = MediaController.Builder(context, token).buildAsync()
        future.addListener({
            runCatching {
                val controller = future.get()
                mediaController = controller
                controller.addListener(object : Player.Listener {
                    override fun onPlaybackStateChanged(playbackState: Int) {
                        if (playbackState == Player.STATE_READY) {
                            recoveryAttempts = 0
                        } else if (playbackState == Player.STATE_ENDED) {
                            if (loopMode == LoopMode.ONE) {
                                currentTrack?.let { playTrack(it) }
                            } else {
                                playAdjacent(1)
                            }
                        }
                    }

                    override fun onPlayerError(error: PlaybackException) {
                        currentTrack?.let {
                            handlePlaybackError(it, error.message ?: "decode error", currentPlaybackIsLoopback)
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
            }
        }, context.mainExecutor)
    }

    companion object {
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

    val cloudClient: Cloud189Client get() = runtime.cloudClient
    val accountStore: AccountStore get() = runtime.accountStore
    val limiter: GlobalTransferLimiter get() = runtime.limiter
    val transferEngine: TransferEngine get() = runtime.transferEngine

    var themeMode: AppThemeMode
        get() = runtime.themeMode
        set(value) { runtime.themeMode = value }

    var activeModule: ModuleTab
        get() = runtime.activeModule
        set(value) { runtime.activeModule = value }

    var isBootstrapping: Boolean
        get() = runtime.isBootstrapping
        set(value) { runtime.isBootstrapping = value }

    var busyLabel: String?
        get() = runtime.busyLabel
        set(value) { runtime.busyLabel = value }

    var statusMessage: String?
        get() = runtime.statusMessage
        set(value) { runtime.statusMessage = value }

    var isAuthenticated: Boolean
        get() = runtime.isAuthenticated
        set(value) { runtime.isAuthenticated = value }

    var accountName: String?
        get() = runtime.accountName
        set(value) { runtime.accountName = value }

    val accountStorageKey: String?
        get() = runtime.accountStorageKey

    val committedSettings: AccountSettings
        get() = runtime.committedSettings

    var cacheLimitDraft: String
        get() = runtime.cacheLimitDraft
        set(value) { runtime.cacheLimitDraft = value }

    var downloadThreadsDraft: String
        get() = runtime.downloadThreadsDraft
        set(value) { runtime.downloadThreadsDraft = value }

    var cacheThreadsDraft: String
        get() = runtime.cacheThreadsDraft
        set(value) { runtime.cacheThreadsDraft = value }

    var settingsValidationError: String?
        get() = runtime.settingsValidationError
        set(value) { runtime.settingsValidationError = value }

    var cacheUsageBytes: Long
        get() = runtime.cacheUsageBytes
        set(value) { runtime.cacheUsageBytes = value }

    var qrContent: String?
        get() = runtime.qrContent
        set(value) { runtime.qrContent = value }

    var qrBitmap: Bitmap?
        get() = runtime.qrBitmap
        set(value) { runtime.qrBitmap = value }

    var qrHint: String?
        get() = runtime.qrHint
        set(value) { runtime.qrHint = value }

    var isShowingWebLoginDialog: Boolean
        get() = runtime.isShowingWebLoginDialog
        set(value) { runtime.isShowingWebLoginDialog = value }

    var breadcrumbs: List<BreadcrumbItem>
        get() = runtime.breadcrumbs
        set(value) { runtime.breadcrumbs = value }

    var browser: FolderBrowsePayload?
        get() = runtime.browser
        set(value) { runtime.browser = value }

    var tracks: List<TrackSummary>
        get() = runtime.tracks
        set(value) { runtime.tracks = value }

    var searchQuery: String
        get() = runtime.searchQuery
        set(value) { runtime.searchQuery = value }

    var currentTrackId: String?
        get() = runtime.currentTrackId
        set(value) { runtime.currentTrackId = value }

    var nowPlayingTitle: String?
        get() = runtime.nowPlayingTitle
        set(value) { runtime.nowPlayingTitle = value }

    var nowPlayingArtist: String?
        get() = runtime.nowPlayingArtist
        set(value) { runtime.nowPlayingArtist = value }

    var isPlaying: Boolean
        get() = runtime.isPlaying
        set(value) { runtime.isPlaying = value }

    var loadingTrackId: String?
        get() = runtime.loadingTrackId
        set(value) { runtime.loadingTrackId = value }

    var shuffle: Boolean
        get() = runtime.shuffle
        set(value) { runtime.shuffle = value }

    var loopMode: LoopMode
        get() = runtime.loopMode
        set(value) { runtime.loopMode = value }

    var currentTime: Double
        get() = runtime.currentTime
        set(value) { runtime.currentTime = value }

    var duration: Double
        get() = runtime.duration
        set(value) { runtime.duration = value }

    var activeVideoUrl: String?
        get() = runtime.activeVideoUrl
        set(value) { runtime.activeVideoUrl = value }

    var activeVideoTitle: String?
        get() = runtime.activeVideoTitle
        set(value) { runtime.activeVideoTitle = value }

    var transferSnapshot: TransferSnapshotPayload
        get() = runtime.transferSnapshot
        set(value) { runtime.transferSnapshot = value }

    val visibleTracks: List<TrackSummary> get() = runtime.visibleTracks
    val currentTrack: TrackSummary? get() = runtime.currentTrack
    val downloadTransfers: List<TransferStatus> get() = runtime.downloadTransfers
    val downloadableFiles: List<TrackSummary> get() = runtime.downloadableFiles

    fun syncDraftsFromCommitted() = runtime.syncDraftsFromCommitted()
    fun noteDraftEdited() = runtime.noteDraftEdited()
    fun commitCacheLimitDraft(): Boolean = runtime.commitCacheLimitDraft()
    fun commitTransferThreadsDraft(): Boolean = runtime.commitTransferThreadsDraft()
    fun updatePlaybackMode(mode: PlaybackMode) = runtime.updatePlaybackMode(mode)
    fun bootstrap() = runtime.bootstrap()
    fun beginQrLogin() = runtime.beginQrLogin()
    fun completeEmbeddedWebLogin(callbackUrl: String, cookieHeader: String?) =
        runtime.completeEmbeddedWebLogin(callbackUrl, cookieHeader)
    fun completeEmbeddedWebLogin(callbackUrl: String, cookiesByOrigin: Map<String, String?>) =
        runtime.completeEmbeddedWebLogin(callbackUrl, cookiesByOrigin)
    fun logout() = runtime.logout()
    fun browseTo(folderId: String?, nextCrumbs: List<BreadcrumbItem>, showBusy: Boolean = true) =
        runtime.browseTo(folderId, nextCrumbs, showBusy)
    fun setCurrentFolderAsMusicLibrary() = runtime.setCurrentFolderAsMusicLibrary()
    fun scanMusicLibrary() = runtime.scanMusicLibrary()
    fun playTrack(
        track: TrackSummary,
        modeOverride: PlaybackMode? = null,
        forceStreamProxy: Boolean = false,
        isRecoveryRetry: Boolean = false
    ) = runtime.playTrack(track, modeOverride, forceStreamProxy, isRecoveryRetry)
    fun handlePlaybackError(track: TrackSummary, message: String, wasLoopback: Boolean) =
        runtime.handlePlaybackError(track, message, wasLoopback)
    fun togglePlayback() = runtime.togglePlayback()
    fun playAdjacent(direction: Int) = runtime.playAdjacent(direction)
    fun seekTo(seconds: Double) = runtime.seekTo(seconds)
    fun openVideoInApp(video: TrackSummary) = runtime.openVideoInApp(video)
    fun openVideoExternally(context: Context, video: TrackSummary) = runtime.openVideoExternally(context, video)
    fun onSafTreeSelected(context: Context, treeUri: Uri) = runtime.onSafTreeSelected(context, treeUri)
    fun enqueueDownload(context: Context, track: TrackSummary) = runtime.enqueueDownload(context, track)
    fun enqueueCurrentFolderDownload(context: Context) = runtime.enqueueCurrentFolderDownload(context)
    fun pauseTransfer(id: String) = runtime.pauseTransfer(id)
    fun resumeTransfer(context: Context, id: String) = runtime.resumeTransfer(context, id)
    fun deleteTransfer(id: String) = runtime.deleteTransfer(id)

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
            vm.runtime.committedSettings = AccountSettings(
                musicFolder = fixture.currentFolder,
                cacheLimitMb = fixture.cacheLimitMb,
                downloadThreads = fixture.downloadThreads,
                cacheThreads = fixture.cacheThreads,
                playbackMode = fixture.playbackMode,
                exportFolderDisplayName = "MusicExports"
            )
            vm.syncDraftsFromCommitted()

            when (scene) {
                SnapshotScene.AUTH_IDLE -> {
                    vm.isAuthenticated = false
                    vm.accountName = null
                    vm.runtime.accountStorageKey = null
                    vm.cacheUsageBytes = 0L
                }
                SnapshotScene.AUTH_QR -> {
                    vm.isAuthenticated = false
                    vm.accountName = null
                    vm.runtime.accountStorageKey = null
                    vm.cacheUsageBytes = 0L
                    vm.qrContent = fixture.qrContent
                    vm.qrHint = fixture.qrMessage
                    vm.statusMessage = fixture.qrMessage
                    vm.qrBitmap = QrCodeHelper.generateQrBitmap(fixture.qrContent, 420)
                }
                SnapshotScene.MUSIC,
                SnapshotScene.VIDEO,
                SnapshotScene.DOWNLOAD,
                SnapshotScene.ERROR_BANNER -> {
                    vm.isAuthenticated = true
                    vm.accountName = fixture.accountName
                    vm.runtime.accountStorageKey = fixture.accountName
                    vm.cacheUsageBytes = fixture.cacheUsageBytes
                    vm.breadcrumbs = fixture.breadcrumbs
                    vm.browser = fixture.browser
                    vm.tracks = fixture.libraryTracks
                    vm.currentTrackId = fixture.nowPlayingTrackId
                    vm.nowPlayingTitle = fixture.nowPlayingTitle
                    vm.nowPlayingArtist = fixture.nowPlayingArtist
                    vm.isPlaying = fixture.isPlaying
                    vm.currentTime = fixture.currentTimeSeconds
                    vm.duration = fixture.durationSeconds
                    vm.shuffle = fixture.shuffle
                    vm.loopMode = fixture.loopMode
                    vm.transferSnapshot = fixture.transferSnapshot
                    vm.statusMessage = if (scene == SnapshotScene.ERROR_BANNER) {
                        fixture.errorBannerMessage
                    } else {
                        fixture.statusMessage
                    }
                    vm.activeModule = when (scene) {
                        SnapshotScene.VIDEO -> ModuleTab.VIDEO
                        SnapshotScene.DOWNLOAD -> ModuleTab.DOWNLOAD
                        else -> ModuleTab.MUSIC
                    }
                }
            }
            return vm
        }
    }
}
