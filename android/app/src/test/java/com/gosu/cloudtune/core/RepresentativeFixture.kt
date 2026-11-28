package com.gosu.cloudtune.core

import org.json.JSONArray
import org.json.JSONObject

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
