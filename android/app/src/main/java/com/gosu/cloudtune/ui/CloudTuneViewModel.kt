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
import androidx.lifecycle.viewModelScope
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class CloudTuneViewModel(
    private val appContext: Context? = null,
    val cloudClient: Cloud189Client = Cloud189Client(),
    val accountStore: AccountStore = AccountStore(
        appContext?.filesDir ?: File(System.getProperty("java.io.tmpdir"), "cloudtune-android")
    ),
    private val credentialStore: CredentialStore? = appContext?.let { EncryptedCredentialStore(it) },
    val limiter: GlobalTransferLimiter = GlobalTransferLimiter(maxPermits = 8),
    enableLiveLoops: Boolean = true
) : ViewModel() {

    var themeMode by mutableStateOf(AppThemeMode.SYSTEM)
    var activeModule by mutableStateOf(ModuleTab.MUSIC)
    var isBootstrapping by mutableStateOf(false)
    var busyLabel by mutableStateOf<String?>(null)
    var statusMessage by mutableStateOf<String?>(null)

    var isAuthenticated by mutableStateOf(false)
    var accountName by mutableStateOf<String?>(null)

    // Strictly separated committed vs draft settings
    var committedSettings by mutableStateOf(AccountSettings())
        private set
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

    val transferEngine = TransferEngine(limiter = limiter) { trackId ->
        cloudClient.resolveDownloadUrl(trackId)
    }

    private val streamServer: LocalStreamServer? = if (enableLiveLoops) {
        runCatching {
            LocalStreamServer(
                limiter = limiter,
                onStreamStatusUpdate = { id, status ->
                    transferEngine.updateExternalTransferStatus(id, status)
                },
                urlRefresher = { trackId ->
                    cloudClient.resolveDownloadUrl(trackId)
                }
            )
        }.getOrNull()
    } else null

    private var cacheManager: CacheManager? = null
    private var mediaController: MediaController? = null
    private var pendingMediaItem: MediaItem? = null
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
            PlaybackSessionBridge.onSkipNext = { playAdjacent(1) }
            PlaybackSessionBridge.onSkipPrevious = { playAdjacent(-1) }
            if (appContext != null) {
                connectMediaController(appContext)
            }
        }
    }

    companion object {
        fun fixture(scene: SnapshotScene, fixture: RepresentativeFixture): CloudTuneViewModel {
            val isolatedDir = File(System.getProperty("java.io.tmpdir"), "cloudtune-fixture-${UUID.randomUUID()}")
            val vm = CloudTuneViewModel(accountStore = AccountStore(isolatedDir), enableLiveLoops = false)
            vm.committedSettings = AccountSettings(
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
                    vm.cacheUsageBytes = 0L
                }
                SnapshotScene.AUTH_QR -> {
                    vm.isAuthenticated = false
                    vm.accountName = null
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
        settingsValidationError = null
    }

    fun noteDraftEdited() {
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
        accountName?.let { accountStore.saveSettings(it, next) }
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
        accountName?.let { accountStore.saveSettings(it, next) }
        statusMessage = "传输参数已更新"
        return true
    }

    fun updatePlaybackMode(mode: PlaybackMode) {
        val next = committedSettings.copy(playbackMode = mode)
        committedSettings = next
        accountName?.let { accountStore.saveSettings(it, next) }
        statusMessage = if (mode == PlaybackMode.DOWNLOAD_FIRST) "已切到优先缓存播放" else "已切到边播边缓存"
    }

    fun bootstrap() {
        val stored = credentialStore?.loadCredential() ?: return
        viewModelScope.launch {
            isBootstrapping = true
            busyLabel = "恢复天翼登录会话..."
            try {
                val restored = cloudClient.restoreFromRefreshCredential(stored)
                restored.persistedCredential?.let { credentialStore.saveCredential(it) }
                val name = restored.activeSession.loginName ?: stored.accountName ?: "天翼云盘用户"
                activateAccount(name)
                browseTo(null, listOf(BreadcrumbItem.ROOT), showBusy = false)
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
        viewModelScope.launch {
            busyLabel = "生成二维码..."
            try {
                val start = cloudClient.startQrLogin()
                qrContent = start.qrContent
                qrHint = start.message
                statusMessage = start.message
                qrBitmap = QrCodeHelper.generateQrBitmap(start.qrContent, 480)
                startQrPolling()
            } catch (e: Exception) {
                statusMessage = e.message
            } finally {
                busyLabel = null
            }
        }
    }

    private fun startQrPolling() {
        qrPollJob?.cancel()
        qrPollJob = viewModelScope.launch {
            while (isActive) {
                delay(2500L)
                try {
                    val poll = cloudClient.pollQrLogin()
                    qrHint = poll.message
                    statusMessage = poll.message
                    when (poll.state) {
                        QrLoginState.AUTHENTICATED -> {
                            cloudClient.persistedCredential?.let { credentialStore?.saveCredential(it) }
                            val name = poll.accountName ?: cloudClient.accountName ?: "天翼云盘用户"
                            qrContent = null
                            qrBitmap = null
                            activateAccount(name)
                            browseTo(null, listOf(BreadcrumbItem.ROOT), showBusy = false)
                            return@launch
                        }
                        QrLoginState.EXPIRED -> {
                            qrContent = null
                            qrBitmap = null
                            return@launch
                        }
                        else -> Unit
                    }
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
        viewModelScope.launch {
            busyLabel = "正在验证天翼登录会话..."
            try {
                for ((origin, header) in cookiesByOrigin) {
                    cloudClient.importWebCookies(origin, header)
                }
                val parsed = cloudClient.exchangeRedirectForSession(callbackUrl)
                parsed.persistedCredential?.let { credentialStore?.saveCredential(it) }
                isShowingWebLoginDialog = false
                qrPollJob?.cancel()
                qrContent = null
                qrBitmap = null
                val name = parsed.activeSession.loginName ?: "天翼云盘用户"
                activateAccount(name)
                browseTo(null, listOf(BreadcrumbItem.ROOT), showBusy = false)
                statusMessage = "天翼官方网页一键登录成功"
            } catch (e: Exception) {
                isShowingWebLoginDialog = false
                statusMessage = "网页回调兑换失败（${e.message}），已自动切换二维码登录，可保存二维码到相册识别。"
                beginQrLogin()
            } finally {
                busyLabel = null
            }
        }
    }

    private fun activateAccount(name: String) {
        isAuthenticated = true
        accountName = name
        val paths = accountStore.paths(name)
        cacheManager = CacheManager(paths.cacheDir).also { cacheUsageBytes = it.usageBytes() }
        committedSettings = accountStore.loadSettings(name)
        syncDraftsFromCommitted()
        tracks = accountStore.loadLibrary(name)
        transferEngine.restorePersistedDownloads(name, paths.stagingDir, paths.transfersFile)
        transferSnapshot = transferEngine.snapshot()
        startTransferPolling()
    }

    fun logout() {
        qrPollJob?.cancel()
        transferPollJob?.cancel()
        playbackGeneration += 1
        pendingMediaItem = null
        prefetchedTrackId = null
        prefetchingTrackId = null
        plannedShuffleNextTrackId = null
        mediaController?.stop()
        mediaController?.clearMediaItems()
        accountName?.let {
            streamServer?.revokeAllSources(Cloud189Protocol.accountBucketHash(it))
            transferEngine.cancelAll(it)
        }
        viewModelScope.launch { cloudClient.clearSession() }
        credentialStore?.clearCredential()

        isAuthenticated = false
        accountName = null
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
        viewModelScope.launch {
            if (showBusy) busyLabel = "读取云盘目录..."
            try {
                browser = cloudClient.listRemoteFolder(folderId)
                breadcrumbs = nextCrumbs
            } catch (e: Exception) {
                statusMessage = e.message
            } finally {
                if (showBusy) busyLabel = null
            }
        }
    }

    fun setCurrentFolderAsMusicLibrary() {
        val b = browser ?: return
        val crumb = breadcrumbs.lastOrNull() ?: return
        val acct = accountName ?: return
        val next = committedSettings.copy(musicFolder = FolderSelection(b.currentFolderId, crumb.name))
        committedSettings = next
        accountStore.saveSettings(acct, next)
        statusMessage = "音乐目录已设置为 ${crumb.name}"
        scanMusicLibrary()
    }

    fun scanMusicLibrary() {
        val folder = committedSettings.musicFolder ?: run {
            statusMessage = "请先选择音乐目录"
            return
        }
        val acct = accountName ?: return
        viewModelScope.launch {
            busyLabel = "扫描 ${folder.name} 中的音乐..."
            try {
                val scanned = cloudClient.scanMusicLibrary(folder.id, folder.name)
                tracks = scanned
                accountStore.saveLibrary(acct, scanned)
                statusMessage = "已载入 ${scanned.size} 首音乐"
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
        forceStreamProxy: Boolean = false
    ) {
        val acct = accountName ?: return
        val cm = cacheManager ?: return
        playbackGeneration += 1
        val gen = playbackGeneration
        prefetchedTrackId = null
        prefetchingTrackId = null
        plannedShuffleNextTrackId = null
        if (modeOverride == null && !forceStreamProxy) {
            recoveryAttempts = 0
        }
        viewModelScope.launch {
            loadingTrackId = track.id
            val effectiveMode = modeOverride ?: committedSettings.playbackMode
            try {
                cm.setProtectedTrackIds(setOf(track.id))
                val cached = cm.existingCachedFile(track.id)
                if (cached != null) {
                    cacheUsageBytes = cm.usageBytes()
                    val meta = withContext(Dispatchers.IO) {
                        AudioMetadataHelper.extract(cached, track.name, acct, track.folderPath)
                    }
                    if (gen != playbackGeneration) return@launch
                    startControllerPlayback(track, Uri.fromFile(cached).toString(), isLoopback = false, metadata = meta)
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
                        cacheLimitBytes = committedSettings.cacheLimitBytes
                    )
                    if (gen != playbackGeneration) return@launch
                    cacheUsageBytes = cm.usageBytes()
                    val meta = withContext(Dispatchers.IO) {
                        AudioMetadataHelper.extract(file, track.name, acct, track.folderPath)
                    }
                    if (gen != playbackGeneration) return@launch
                    startControllerPlayback(track, Uri.fromFile(file).toString(), isLoopback = false, metadata = meta)
                } else {
                    val remoteUrl = cloudClient.resolveDownloadUrl(track.id)
                    if (gen != playbackGeneration) return@launch
                    val dest = cm.cacheFile(track.id, track.name)
                    val playUrl = streamServer?.registerSource(
                        StreamSourceRegistration(
                            accountHash = Cloud189Protocol.accountBucketHash(acct),
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
            } catch (e: Exception) {
                if (gen == playbackGeneration) {
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
        nowPlayingTitle = metadata?.title ?: track.name
        nowPlayingArtist = metadata?.artist ?: (accountName ?: "CloudTune")
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
        val controller = mediaController
        if (controller != null) {
            pendingMediaItem = null
            controller.setMediaItem(item)
            controller.prepare()
            controller.play()
        } else {
            pendingMediaItem = item
        }
        isPlaying = true
        statusMessage = if (isLoopback) "边播边缓存《${track.name}》" else "正在播放《${track.name}》"
    }

    fun handlePlaybackError(track: TrackSummary, message: String, wasLoopback: Boolean) {
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
            PlaybackFailureAction.FallbackToStreamProxyOnce ->
                playTrack(track, modeOverride = PlaybackMode.STREAM_CACHE, forceStreamProxy = true)
            PlaybackFailureAction.FallbackToFullDownloadOnce ->
                playTrack(track, modeOverride = PlaybackMode.DOWNLOAD_FIRST, forceStreamProxy = false)
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
                viewModelScope.launch {
                    delay(1500L * action.attempt)
                    playTrack(track)
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
        viewModelScope.launch {
            busyLabel = "获取视频地址..."
            try {
                activeVideoTitle = video.name
                activeVideoUrl = cloudClient.resolveDownloadUrl(video.id)
            } catch (e: Exception) {
                statusMessage = e.message
            } finally {
                busyLabel = null
            }
        }
    }

    fun openVideoExternally(context: Context, video: TrackSummary) {
        viewModelScope.launch {
            try {
                val cached = cacheManager?.existingCachedFile(video.id)
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
            } catch (e: Exception) {
                statusMessage = "无法唤起外部播放器：${e.message}"
            }
        }
    }

    fun onSafTreeSelected(context: Context, treeUri: Uri) {
        val acct = accountName ?: return
        val name = SafExporter.persistTreePermission(context, treeUri)
        val next = committedSettings.copy(
            exportTreeUri = treeUri.toString(),
            exportFolderDisplayName = name
        )
        committedSettings = next
        accountStore.saveSettings(acct, next)
        statusMessage = "导出目录已设为 $name"
    }

    fun enqueueDownload(context: Context, track: TrackSummary) {
        val acct = accountName ?: return
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
                context = context,
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
        val b = browser ?: return
        val acct = accountName ?: return
        val paths = accountStore.paths(acct)
        viewModelScope.launch {
            busyLabel = "扫描文件夹 ${b.currentFolderName}..."
            try {
                val allFiles = cloudClient.scanAllFiles(b.currentFolderId, b.currentFolderName)
                for (item in allFiles) {
                    val rel = if (item.folderPath.startsWith(b.currentFolderName)) {
                        "${item.folderPath}/${item.name}"
                    } else {
                        "${b.currentFolderName}/${item.name}"
                    }
                    transferEngine.enqueueExportDownload(
                        accountId = acct,
                        track = item,
                        relativeSubpath = rel,
                        parallelThreads = committedSettings.downloadThreads,
                        stagingRootDir = paths.stagingDir,
                        manifestsFile = paths.transfersFile
                    ) { staged, subpath, _ ->
                        SafExporter.exportToSafTree(
                            context = context,
                            treeUriString = committedSettings.exportTreeUri,
                            stagedFile = staged,
                            relativeSubpath = subpath,
                            mimeType = PlaybackDecisionPolicy.guessMimeType(item.name)
                        )
                    }
                }
                transferSnapshot = transferEngine.snapshot()
                statusMessage = "目录下载已入队（共 ${allFiles.size} 个文件）"
            } catch (e: Exception) {
                statusMessage = e.message
            } finally {
                busyLabel = null
            }
        }
    }

    fun pauseTransfer(id: String) {
        val acct = accountName ?: return
        transferEngine.pauseTransfer(id, accountStore.paths(acct).transfersFile)
        transferSnapshot = transferEngine.snapshot()
    }

    fun resumeTransfer(context: Context, id: String) {
        val acct = accountName ?: return
        val paths = accountStore.paths(acct)
        transferEngine.resumeTransfer(id, paths.stagingDir, paths.transfersFile) { staged, rel, _ ->
            SafExporter.exportToSafTree(
                context = context,
                treeUriString = committedSettings.exportTreeUri,
                stagedFile = staged,
                relativeSubpath = rel,
                mimeType = PlaybackDecisionPolicy.guessMimeType(rel)
            )
        }
        transferSnapshot = transferEngine.snapshot()
    }

    fun deleteTransfer(id: String) {
        val acct = accountName ?: return
        val paths = accountStore.paths(acct)
        transferEngine.deleteTransfer(id, paths.stagingDir, paths.transfersFile)
        transferSnapshot = transferEngine.snapshot()
    }

    private fun startTransferPolling() {
        transferPollJob?.cancel()
        transferPollJob = viewModelScope.launch {
            while (isActive) {
                delay(850L)
                transferSnapshot = transferEngine.snapshot()
                cacheManager?.let { cacheUsageBytes = it.usageBytes() }
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
        cm.setProtectedTrackIds(setOf(activeId, next.id))
        viewModelScope.launch {
            runCatching {
                transferEngine.downloadTrackToCache(
                    track = next,
                    cacheManager = cm,
                    parallelThreads = committedSettings.cacheThreads,
                    cacheLimitBytes = committedSettings.cacheLimitBytes,
                    kind = "prefetch"
                )
            }.onSuccess {
                prefetchedTrackId = next.id
            }
            if (prefetchingTrackId == next.id) {
                prefetchingTrackId = null
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

    override fun onCleared() {
        PlaybackSessionBridge.onSkipNext = null
        PlaybackSessionBridge.onSkipPrevious = null
        streamServer?.close()
        mediaController?.release()
        super.onCleared()
    }
}
