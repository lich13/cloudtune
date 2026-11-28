package com.gosu.cloudtune.ui

import com.gosu.cloudtune.core.AccountSettings
import com.gosu.cloudtune.core.AppearanceMode
import com.gosu.cloudtune.core.BrowserPaneState
import com.gosu.cloudtune.core.ModuleTab
import com.gosu.cloudtune.core.RepresentativeFixture
import com.gosu.cloudtune.core.SnapshotScene
import com.gosu.cloudtune.data.AccountStore
import com.gosu.cloudtune.media.QrCodeHelper
import java.io.File
import java.util.UUID

fun CloudTuneAppRuntime.Companion.fixture(
    scene: SnapshotScene,
    fixture: RepresentativeFixture,
    appearanceMode: AppearanceMode = fixture.appearanceMode
): CloudTuneAppRuntime {
    val isolatedDir = File(System.getProperty("java.io.tmpdir"), "cloudtune-fixture-${UUID.randomUUID()}")
    val rt = CloudTuneAppRuntime(accountStore = AccountStore(isolatedDir), enableLiveLoops = false)
    rt.committedSettings = AccountSettings(
        musicFolder = fixture.currentFolder,
        cacheLimitMb = fixture.cacheLimitMb,
        downloadThreads = fixture.downloadThreads,
        cacheThreads = fixture.cacheThreads,
        playbackMode = fixture.playbackMode,
        exportFolderDisplayName = "MusicExports",
        appearanceMode = appearanceMode,
        dynamicColorEnabled = fixture.dynamicColorEnabled
    )
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
    return rt
}
