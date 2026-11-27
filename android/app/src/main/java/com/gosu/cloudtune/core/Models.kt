package com.gosu.cloudtune.core

import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

enum class LoopMode(val wireValue: String) {
    OFF("off"),
    ALL("all"),
    ONE("one");

    companion object {
        fun fromWire(raw: String?): LoopMode = entries.firstOrNull { it.wireValue == raw } ?: ALL
    }
}

enum class PlaybackMode(val wireValue: String, val displayTitle: String) {
    DOWNLOAD_FIRST("download_first", "优先缓存"),
    STREAM_CACHE("stream_cache", "边播边缓存");

    companion object {
        fun fromWire(raw: String?): PlaybackMode =
            entries.firstOrNull { it.wireValue == raw } ?: DOWNLOAD_FIRST
    }
}

enum class ModuleTab(val title: String) {
    MUSIC("音乐"),
    VIDEO("视频"),
    DOWNLOAD("下载"),
    SETTINGS("设置")
}

enum class AppThemeMode(val title: String) {
    SYSTEM("跟随系统"),
    LIGHT("暖羊皮纸"),
    DARK("松林暗夜")
}

enum class SnapshotScene(val fileStem: String) {
    AUTH_IDLE("01-auth-idle"),
    AUTH_QR("02-auth-qr"),
    MUSIC("03-music"),
    VIDEO("04-video"),
    DOWNLOAD("05-download"),
    ERROR_BANNER("06-error-banner")
}

/** Active online session holding non-empty signing keys for the current process run. */
data class ActiveCloudSession(
    val accessToken: String,
    val sessionKey: String,
    val sessionSecret: String,
    val loginName: String?
) {
    companion object {
        fun createOrNull(
            accessToken: String = "",
            sessionKey: String,
            sessionSecret: String,
            loginName: String?
        ): ActiveCloudSession? {
            val k = sessionKey.trim()
            val s = sessionSecret.trim()
            if (k.isEmpty() || s.isEmpty()) return null
            return ActiveCloudSession(
                accessToken = accessToken.trim(),
                sessionKey = k,
                sessionSecret = s,
                loginName = loginName?.trim()?.takeIf { it.isNotEmpty() }
            )
        }
    }
}

/** Cold-start persisted credential. Only created when a non-empty refreshToken is present. */
data class PersistedRefreshCredential(
    val refreshToken: String,
    val accountName: String?
) {
    companion object {
        fun createOrNull(refreshToken: String?, accountName: String?): PersistedRefreshCredential? {
            val rt = refreshToken?.trim().orEmpty()
            if (rt.isEmpty()) return null
            return PersistedRefreshCredential(
                refreshToken = rt,
                accountName = accountName?.trim()?.takeIf { it.isNotEmpty() }
            )
        }
    }
}

data class FolderSelection(val id: String, val name: String)

data class RemoteFolder(val id: String, val name: String, val parentId: String? = null)

data class BreadcrumbItem(val id: String?, val name: String) {
    companion object {
        val ROOT = BreadcrumbItem(id = null, name = "我的云盘")
    }
}

data class TrackSummary(
    val id: String,
    val name: String,
    val folderPath: String,
    val sizeBytes: Long,
    val modifiedAt: String? = null
)

data class FolderBrowsePayload(
    val currentFolderId: String,
    val currentFolderName: String,
    val parentFolderId: String?,
    val isRoot: Boolean,
    val folders: List<RemoteFolder>,
    val audioFiles: List<TrackSummary>,
    val videoFiles: List<TrackSummary>,
    val otherFiles: List<TrackSummary>
)

data class AccountSettings(
    val musicFolder: FolderSelection? = null,
    val cacheLimitMb: Long = 1024L,
    val downloadThreads: Int = 8,
    val cacheThreads: Int = 4,
    val playbackMode: PlaybackMode = PlaybackMode.DOWNLOAD_FIRST,
    val exportTreeUri: String? = null,
    val exportFolderDisplayName: String? = null
) {
    val cacheLimitBytes: Long get() = cacheLimitMb.coerceAtLeast(MIN_CACHE_LIMIT_MB) * 1024L * 1024L

    companion object {
        const val MIN_CACHE_LIMIT_MB = 256L
        const val MAX_DOWNLOAD_THREADS = 16
        const val MAX_CACHE_THREADS = 8
    }
}

data class TransferStatus(
    val id: String,
    val label: String,
    val kind: String,
    val state: String,
    val path: String? = null,
    val canPause: Boolean = false,
    val canResume: Boolean = false,
    val canDelete: Boolean = false,
    val bytesPerSecond: Long = 0L,
    val transferredBytes: Long = 0L,
    val totalBytes: Long? = null
)

data class TransferSnapshotPayload(
    val totalSpeedBytesPerSecond: Long = 0L,
    val items: List<TransferStatus> = emptyList()
)

data class QrLoginStart(val qrContent: String, val message: String)

enum class QrLoginState(val wireValue: String) {
    WAITING_SCAN("waiting_scan"),
    WAITING_CONFIRM("waiting_confirm"),
    AUTHENTICATED("authenticated"),
    EXPIRED("expired")
}

data class QrPollResponse(
    val state: QrLoginState,
    val message: String,
    val accountName: String? = null,
    val redirectUrl: String? = null
)

data class RepresentativeFixture(
    val accountName: String,
    val currentFolder: FolderSelection,
    val cacheLimitMb: Long,
    val downloadThreads: Int,
    val cacheThreads: Int,
    val playbackMode: PlaybackMode,
    val cacheUsageBytes: Long,
    val qrContent: String,
    val qrMessage: String,
    val qrHost: String,
    val breadcrumbs: List<BreadcrumbItem>,
    val browser: FolderBrowsePayload,
    val libraryTracks: List<TrackSummary>,
    val nowPlayingTrackId: String,
    val nowPlayingTitle: String,
    val nowPlayingArtist: String,
    val nowPlayingAlbum: String,
    val isPlaying: Boolean,
    val currentTimeSeconds: Double,
    val durationSeconds: Double,
    val shuffle: Boolean,
    val loopMode: LoopMode,
    val statusMessage: String,
    val transferSnapshot: TransferSnapshotPayload,
    val errorBannerMessage: String
) {
    companion object {
        fun fromJsonString(jsonText: String): RepresentativeFixture {
            val root = JSONObject(jsonText)
            val cf = root.getJSONObject("currentFolder")
            val settings = root.getJSONObject("settings")
            val qr = root.getJSONObject("qrLogin")
            val browserObj = root.getJSONObject("browser")
            val np = root.getJSONObject("nowPlaying")
            val ts = root.getJSONObject("transferSnapshot")

            fun parseTracks(arr: JSONArray): List<TrackSummary> =
                (0 until arr.length()).map { i ->
                    val o = arr.getJSONObject(i)
                    TrackSummary(
                        id = o.optString("id"),
                        name = o.optString("name"),
                        folderPath = o.optString("folderPath"),
                        sizeBytes = o.optLong("sizeBytes", 0L),
                        modifiedAt = o.optString("modifiedAt").takeIf { it.isNotEmpty() }
                    )
                }

            val crumbsArr = root.getJSONArray("breadcrumbs")
            val crumbs = (0 until crumbsArr.length()).map { i ->
                val o = crumbsArr.getJSONObject(i)
                BreadcrumbItem(
                    id = if (o.isNull("id")) null else o.optString("id"),
                    name = o.optString("name")
                )
            }

            val foldersArr = browserObj.getJSONArray("folders")
            val folders = (0 until foldersArr.length()).map { i ->
                val o = foldersArr.getJSONObject(i)
                RemoteFolder(
                    id = o.optString("id"),
                    name = o.optString("name"),
                    parentId = if (o.isNull("parentId")) null else o.optString("parentId")
                )
            }

            val itemsArr = ts.getJSONArray("items")
            val transfers = (0 until itemsArr.length()).map { i ->
                val o = itemsArr.getJSONObject(i)
                TransferStatus(
                    id = o.optString("id"),
                    label = o.optString("label"),
                    kind = o.optString("kind"),
                    state = o.optString("state"),
                    path = if (o.isNull("path")) null else o.optString("path"),
                    canPause = o.optBoolean("canPause"),
                    canResume = o.optBoolean("canResume"),
                    canDelete = o.optBoolean("canDelete"),
                    bytesPerSecond = o.optLong("bytesPerSecond", 0L),
                    transferredBytes = o.optLong("transferredBytes", 0L),
                    totalBytes = if (o.isNull("totalBytes")) null else o.optLong("totalBytes")
                )
            }

            return RepresentativeFixture(
                accountName = root.getString("accountName"),
                currentFolder = FolderSelection(cf.getString("id"), cf.getString("name")),
                cacheLimitMb = settings.getLong("cacheLimitMb"),
                downloadThreads = settings.getInt("downloadThreads"),
                cacheThreads = settings.getInt("cacheThreads"),
                playbackMode = PlaybackMode.fromWire(settings.optString("playbackMode")),
                cacheUsageBytes = settings.getLong("cacheUsageBytes"),
                qrContent = qr.getString("qrContent"),
                qrMessage = qr.getString("message"),
                qrHost = qr.getString("host"),
                breadcrumbs = crumbs,
                browser = FolderBrowsePayload(
                    currentFolderId = browserObj.getString("currentFolderId"),
                    currentFolderName = browserObj.getString("currentFolderName"),
                    parentFolderId = if (browserObj.isNull("parentFolderId")) null else browserObj.optString("parentFolderId"),
                    isRoot = browserObj.optBoolean("isRoot"),
                    folders = folders,
                    audioFiles = parseTracks(browserObj.getJSONArray("audioFiles")),
                    videoFiles = parseTracks(browserObj.getJSONArray("videoFiles")),
                    otherFiles = parseTracks(browserObj.getJSONArray("otherFiles"))
                ),
                libraryTracks = parseTracks(root.getJSONArray("libraryTracks")),
                nowPlayingTrackId = np.getString("trackId"),
                nowPlayingTitle = np.getString("title"),
                nowPlayingArtist = np.getString("artist"),
                nowPlayingAlbum = np.getString("album"),
                isPlaying = np.getBoolean("isPlaying"),
                currentTimeSeconds = np.getDouble("currentTimeSeconds"),
                durationSeconds = np.getDouble("durationSeconds"),
                shuffle = np.getBoolean("shuffle"),
                loopMode = LoopMode.fromWire(np.optString("loopMode")),
                statusMessage = np.getString("statusMessage"),
                transferSnapshot = TransferSnapshotPayload(
                    totalSpeedBytesPerSecond = ts.getLong("totalSpeedBytesPerSecond"),
                    items = transfers
                ),
                errorBannerMessage = root.getJSONObject("errorBanner").getString("statusMessage")
            )
        }
    }
}

object CloudTuneFormatters {
    fun formatBytes(bytes: Long): String {
        if (bytes <= 0L) return "0 MB"
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        var size = bytes.toDouble()
        var idx = 0
        while (size >= 1024.0 && idx < units.lastIndex) {
            size /= 1024.0
            idx += 1
        }
        return if (idx > 1) {
            String.format(Locale.US, "%.1f %s", size, units[idx])
        } else {
            String.format(Locale.US, "%.0f %s", size, units[idx])
        }
    }

    fun formatClock(seconds: Double): String {
        if (!seconds.isFinite() || seconds < 0.0) return "00:00"
        val total = seconds.toInt()
        val m = total / 60
        val s = total % 60
        return String.format(Locale.US, "%02d:%02d", m, s)
    }

    fun formatPercent(transferred: Long, total: Long?): Double? {
        if (total == null || total <= 0L) return null
        return ((transferred.toDouble() / total.toDouble()) * 100.0).coerceIn(0.0, 100.0)
    }
}
