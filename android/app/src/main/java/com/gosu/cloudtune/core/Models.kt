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

enum class ModuleTab(val wireValue: String, val title: String) {
    MUSIC("music", "曲库"),
    VIDEO("video", "视频"),
    CLOUD("cloud", "云盘"),
    TRANSFERS("transfers", "传输"),
    SETTINGS("settings", "设置");

    companion object {
        fun fromWire(raw: String?): ModuleTab {
            val clean = raw?.trim()?.lowercase(Locale.ROOT)
            if (clean == "download") return TRANSFERS
            return entries.firstOrNull { it.wireValue == clean } ?: MUSIC
        }
    }
}

enum class AppearanceMode(val wireValue: String, val title: String) {
    SYSTEM("system", "跟随系统"),
    LIGHT("light", "浅色"),
    DARK("dark", "深色");

    companion object {
        fun fromWire(raw: String?): AppearanceMode {
            val clean = raw?.trim()?.lowercase(Locale.ROOT)
            return entries.firstOrNull { it.wireValue == clean } ?: SYSTEM
        }
    }
}

enum class SnapshotScene(val fileStem: String) {
    AUTH_IDLE("01-auth-idle"),
    AUTH_QR("02-auth-qr"),
    MUSIC("03-music"),
    VIDEO("04-video"),
    DOWNLOAD("05-download"),
    ERROR_BANNER("06-error-banner"),
    CLOUD("07-cloud"),
    SETTINGS("08-settings"),
    NOW_PLAYING("09-now-playing")
}

enum class BrowserScope {
    CLOUD,
    VIDEO
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
    val accountName: String?,
    val accountKey: String? = accountName
) {
    fun withAccountKey(key: String): PersistedRefreshCredential =
        copy(accountKey = key.trim().takeIf { it.isNotEmpty() } ?: accountKey)

    companion object {
        fun createOrNull(
            refreshToken: String?,
            accountName: String?,
            accountKey: String? = null
        ): PersistedRefreshCredential? {
            val rt = refreshToken?.trim().orEmpty()
            if (rt.isEmpty()) return null
            val normName = accountName?.trim()?.takeIf { it.isNotEmpty() }
            val normKey = accountKey?.trim()?.takeIf { it.isNotEmpty() } ?: normName
            return PersistedRefreshCredential(
                refreshToken = rt,
                accountName = normName,
                accountKey = normKey
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
) {
    val fileExtensionUpper: String
        get() {
            val dot = name.lastIndexOf('.')
            return if (dot in 0 until name.lastIndex) {
                name.substring(dot + 1).trim().uppercase(Locale.ROOT)
            } else ""
        }

    val isLosslessAudio: Boolean
        get() = fileExtensionUpper in setOf("FLAC", "WAV", "ALAC", "APE", "AIFF", "AIF", "DSF", "DFF")
}

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

data class BrowserPaneState(
    val breadcrumbs: List<BreadcrumbItem> = listOf(BreadcrumbItem.ROOT),
    val payload: FolderBrowsePayload? = null
)

data class AccountSettings(
    val musicFolder: FolderSelection? = null,
    val cacheLimitMb: Long = 1024L,
    val downloadThreads: Int = 8,
    val cacheThreads: Int = 4,
    val playbackMode: PlaybackMode = PlaybackMode.DOWNLOAD_FIRST,
    val exportTreeUri: String? = null,
    val exportFolderDisplayName: String? = null,
    val appearanceMode: AppearanceMode = AppearanceMode.SYSTEM,
    val dynamicColorEnabled: Boolean = false
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
) {
    val hasActiveItems: Boolean
        get() = items.any { it.state == "running" || it.state == "streaming" }
}

data class QueueStepResult(
    val track: TrackSummary?,
    val remainingUpNext: List<TrackSummary>
)

object PlaybackQueueResolver {
    fun buildShuffleOrder(tracks: List<TrackSummary>, anchorTrackId: String?): List<String> {
        if (tracks.isEmpty()) return emptyList()
        val ids = tracks.map { it.id }.toMutableList()
        if (anchorTrackId != null && ids.remove(anchorTrackId)) {
            ids.shuffle()
            return listOf(anchorTrackId) + ids
        }
        ids.shuffle()
        return ids
    }

    fun orderedBaseTracks(
        libraryTracks: List<TrackSummary>,
        shuffle: Boolean,
        shuffleOrderIds: List<String>
    ): List<TrackSummary> {
        if (!shuffle || libraryTracks.size <= 1) return libraryTracks
        val byId = LinkedHashMap<String, TrackSummary>(libraryTracks.size)
        for (track in libraryTracks) {
            byId.putIfAbsent(track.id, track)
        }
        val result = ArrayList<TrackSummary>(libraryTracks.size)
        val seen = HashSet<String>(libraryTracks.size)
        for (id in shuffleOrderIds) {
            val found = byId[id]
            if (found != null && seen.add(id)) {
                result.add(found)
            }
        }
        for (track in libraryTracks) {
            if (seen.add(track.id)) {
                result.add(track)
            }
        }
        return result
    }

    fun insertPlayNext(upNext: List<TrackSummary>, track: TrackSummary): List<TrackSummary> =
        listOf(track) + upNext.filterNot { it.id == track.id }

    fun appendToQueue(upNext: List<TrackSummary>, track: TrackSummary): List<TrackSummary> =
        if (upNext.any { it.id == track.id }) upNext else (upNext + track)

    fun removeFromQueue(upNext: List<TrackSummary>, trackId: String): List<TrackSummary> =
        upNext.filterNot { it.id == trackId }

    fun canSkipNext(
        currentTrack: TrackSummary?,
        libraryTracks: List<TrackSummary>,
        upNextQueue: List<TrackSummary>,
        shuffle: Boolean,
        shuffleOrderIds: List<String>,
        loopMode: LoopMode
    ): Boolean {
        if (upNextQueue.isNotEmpty()) return true
        val ordered = orderedBaseTracks(libraryTracks, shuffle, shuffleOrderIds)
        if (ordered.isEmpty()) return currentTrack != null && loopMode == LoopMode.ONE
        val currentId = currentTrack?.id ?: return true
        val idx = ordered.indexOfFirst { it.id == currentId }
        if (idx < 0) return true
        if (idx + 1 < ordered.size) return true
        return loopMode != LoopMode.OFF
    }

    fun canSkipPrevious(
        currentTrack: TrackSummary?,
        libraryTracks: List<TrackSummary>,
        shuffle: Boolean,
        shuffleOrderIds: List<String>,
        loopMode: LoopMode
    ): Boolean {
        val ordered = orderedBaseTracks(libraryTracks, shuffle, shuffleOrderIds)
        if (ordered.isEmpty()) return currentTrack != null && loopMode == LoopMode.ONE
        val currentId = currentTrack?.id ?: return true
        val idx = ordered.indexOfFirst { it.id == currentId }
        if (idx < 0) return true
        if (idx > 0) return true
        return loopMode != LoopMode.OFF
    }

    fun resolveNext(
        currentTrack: TrackSummary?,
        libraryTracks: List<TrackSummary>,
        upNextQueue: List<TrackSummary>,
        shuffle: Boolean,
        shuffleOrderIds: List<String>,
        loopMode: LoopMode,
        autoAdvanceAtEnd: Boolean = false
    ): QueueStepResult {
        if (autoAdvanceAtEnd && loopMode == LoopMode.ONE) {
            return QueueStepResult(currentTrack, upNextQueue)
        }
        if (upNextQueue.isNotEmpty()) {
            return QueueStepResult(upNextQueue.first(), upNextQueue.drop(1))
        }
        val ordered = orderedBaseTracks(libraryTracks, shuffle, shuffleOrderIds)
        if (ordered.isEmpty()) {
            return QueueStepResult(if (loopMode == LoopMode.ONE) currentTrack else null, upNextQueue)
        }
        val currentId = currentTrack?.id
        val idx = if (currentId != null) ordered.indexOfFirst { it.id == currentId } else -1
        if (idx < 0) {
            return QueueStepResult(ordered.firstOrNull(), upNextQueue)
        }
        if (idx + 1 < ordered.size) {
            return QueueStepResult(ordered[idx + 1], upNextQueue)
        }
        return when (loopMode) {
            LoopMode.ALL -> QueueStepResult(ordered.firstOrNull(), upNextQueue)
            LoopMode.ONE -> QueueStepResult(currentTrack ?: ordered.firstOrNull(), upNextQueue)
            LoopMode.OFF -> QueueStepResult(null, upNextQueue)
        }
    }

    fun resolvePrevious(
        currentTrack: TrackSummary?,
        libraryTracks: List<TrackSummary>,
        upNextQueue: List<TrackSummary>,
        shuffle: Boolean,
        shuffleOrderIds: List<String>,
        loopMode: LoopMode
    ): QueueStepResult {
        val ordered = orderedBaseTracks(libraryTracks, shuffle, shuffleOrderIds)
        if (ordered.isEmpty()) {
            return QueueStepResult(if (loopMode == LoopMode.ONE) currentTrack else null, upNextQueue)
        }
        val currentId = currentTrack?.id
        val idx = if (currentId != null) ordered.indexOfFirst { it.id == currentId } else -1
        if (idx < 0) {
            return QueueStepResult(ordered.lastOrNull() ?: ordered.firstOrNull(), upNextQueue)
        }
        if (idx > 0) {
            return QueueStepResult(ordered[idx - 1], upNextQueue)
        }
        return when (loopMode) {
            LoopMode.ALL -> QueueStepResult(ordered.lastOrNull(), upNextQueue)
            LoopMode.ONE -> QueueStepResult(currentTrack ?: ordered.firstOrNull(), upNextQueue)
            LoopMode.OFF -> QueueStepResult(null, upNextQueue)
        }
    }

    fun peekPrefetchCandidate(
        currentTrack: TrackSummary?,
        libraryTracks: List<TrackSummary>,
        upNextQueue: List<TrackSummary>,
        shuffle: Boolean,
        shuffleOrderIds: List<String>,
        loopMode: LoopMode
    ): TrackSummary? {
        if (loopMode == LoopMode.ONE) return null
        return resolveNext(
            currentTrack = currentTrack,
            libraryTracks = libraryTracks,
            upNextQueue = upNextQueue,
            shuffle = shuffle,
            shuffleOrderIds = shuffleOrderIds,
            loopMode = loopMode,
            autoAdvanceAtEnd = true
        ).track
    }

    fun upcomingPreview(
        currentTrack: TrackSummary?,
        libraryTracks: List<TrackSummary>,
        upNextQueue: List<TrackSummary>,
        shuffle: Boolean,
        shuffleOrderIds: List<String>,
        loopMode: LoopMode,
        limit: Int = 20
    ): List<TrackSummary> {
        if (limit <= 0) return emptyList()
        val out = ArrayList<TrackSummary>(minOf(limit, upNextQueue.size + libraryTracks.size))
        out.addAll(upNextQueue.take(limit))
        if (out.size >= limit) return out

        val ordered = orderedBaseTracks(libraryTracks, shuffle, shuffleOrderIds)
        if (ordered.isEmpty()) return out

        val seen = out.mapTo(HashSet()) { it.id }
        currentTrack?.id?.let { seen.add(it) }

        val startIndex = currentTrack?.id?.let { id ->
            val idx = ordered.indexOfFirst { it.id == id }
            if (idx >= 0) idx + 1 else 0
        } ?: 0

        for (i in startIndex until ordered.size) {
            val item = ordered[i]
            if (seen.add(item.id)) {
                out.add(item)
                if (out.size >= limit) return out
            }
        }
        if (loopMode == LoopMode.ALL && startIndex > 0) {
            for (i in 0 until minOf(startIndex, ordered.size)) {
                val item = ordered[i]
                if (seen.add(item.id)) {
                    out.add(item)
                    if (out.size >= limit) return out
                }
            }
        }
        return out
    }
}

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
    val appearanceMode: AppearanceMode = AppearanceMode.SYSTEM,
    val dynamicColorEnabled: Boolean = false,
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
                appearanceMode = AppearanceMode.fromWire(settings.optString("appearanceMode")),
                dynamicColorEnabled = settings.optBoolean("dynamicColorEnabled", false),
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
