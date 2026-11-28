package com.gosu.cloudtune.ui

import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.os.Looper
import android.view.View
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.documentfile.provider.DocumentFile
import androidx.lifecycle.Lifecycle
import com.gosu.cloudtune.MainActivity
import com.gosu.cloudtune.core.AppearanceMode
import com.gosu.cloudtune.core.CloudTuneException
import com.gosu.cloudtune.core.RepresentativeFixture
import com.gosu.cloudtune.core.SnapshotScene
import com.gosu.cloudtune.data.SafExporter
import com.gosu.cloudtune.media.AudioMetadataHelper
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import kotlin.math.abs
import kotlin.math.sqrt
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
class CloudTuneSnapshotTest {
    private fun locateFixture(): RepresentativeFixture {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").canonicalFile
        while (dir != null) {
            val f = File(dir, "contracts/representative-state.json")
            if (f.isFile) return RepresentativeFixture.fromJsonString(f.readText(Charsets.UTF_8))
            dir = dir.parentFile
        }
        error("Could not locate contracts/representative-state.json")
    }

    private fun renderAndAssertAllScenes(formFactor: String, widthPx: Int, heightPx: Int) {
        assumeTrue(System.getenv("CLOUDTUNE_RENDER_SNAPSHOTS") == "1")
        val fixture = locateFixture()
        val outBase = File("build/outputs/snapshots/$formFactor")

        for ((themeFolder, themeMode, expectDark) in listOf(
            Triple("light", AppearanceMode.LIGHT, false),
            Triple("dark", AppearanceMode.DARK, true)
        )) {
            val targetDir = File(outBase, themeFolder).apply { mkdirs() }
            for (scene in SnapshotScene.entries) {
                val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
                val activity = controller.get()
                activity.enableEdgeToEdge()
                val vm = CloudTuneViewModel.fixture(scene, fixture).apply {
                    this.themeMode = themeMode
                }
                activity.setContent {
                    CloudTuneRootApp(viewModel = vm)
                }

                val decor = activity.window.decorView
                repeat(3) {
                    Shadows.shadowOf(Looper.getMainLooper()).idle()
                    decor.measure(
                        View.MeasureSpec.makeMeasureSpec(widthPx, View.MeasureSpec.EXACTLY),
                        View.MeasureSpec.makeMeasureSpec(heightPx, View.MeasureSpec.EXACTLY)
                    )
                    decor.layout(0, 0, widthPx, heightPx)
                }
                Shadows.shadowOf(Looper.getMainLooper()).idle()

                val bitmap = Bitmap.createBitmap(widthPx, heightPx, Bitmap.Config.ARGB_8888)
                decor.draw(Canvas(bitmap))

                val outFile = File(targetDir, "${scene.fileStem}.png")
                FileOutputStream(outFile).use { out ->
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                }
                assertTrue("PNG file must exist and be non-trivial", outFile.length() > 4096L)

                // Analyze luminance & glyph contrast edges
                val pixels = IntArray(widthPx * heightPx)
                bitmap.getPixels(pixels, 0, widthPx, 0, 0, widthPx, heightPx)
                var count = 0
                var sum = 0.0
                var sumSq = 0.0
                var edges = 0
                for (y in 0 until heightPx step 2) {
                    val row = y * widthPx
                    var prev: Double? = null
                    for (x in 0 until widthPx step 2) {
                        val c = pixels[row + x]
                        val r = ((c shr 16) and 0xFF) / 255.0
                        val g = ((c shr 8) and 0xFF) / 255.0
                        val b = (c and 0xFF) / 255.0
                        val lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                        count += 1
                        sum += lum
                        sumSq += lum * lum
                        if (prev != null && abs(lum - prev) >= 0.20) edges += 1
                        prev = lum
                    }
                }
                val mean = sum / count
                val stdDev = sqrt((sumSq / count - mean * mean).coerceAtLeast(0.0))
                assertTrue("$formFactor $themeFolder ${scene.fileStem} stdDev=$stdDev too flat", stdDev > 0.03)
                assertTrue("$formFactor $themeFolder ${scene.fileStem} edges=$edges too low", edges > 250)
                if (expectDark) {
                    assertTrue("$formFactor dark ${scene.fileStem} mean=$mean too bright", mean < 0.40)
                } else {
                    assertTrue("$formFactor light ${scene.fileStem} mean=$mean too dark", mean > 0.55)
                }

                controller.pause().stop().destroy()
            }
        }
    }

    @Test
    @Config(qualifiers = "w412dp-h915dp-xxhdpi")
    fun renderPhoneLightAndDarkSnapshots() {
        renderAndAssertAllScenes(formFactor = "phone", widthPx = 1080, heightPx = 2400)
    }

    @Test
    @Config(qualifiers = "w1024dp-h768dp-mdpi")
    fun renderTabletLightAndDarkSnapshots() {
        renderAndAssertAllScenes(formFactor = "tablet", widthPx = 1024, heightPx = 768)
    }

    @Test
    fun verifySafExporterTargetSafety() {
        val tempRoot = Files.createTempDirectory("cloudtune-saf-export").toFile()
        try {
            val exportRoot = File(tempRoot, "exports").apply { mkdirs() }
            val staged = File(tempRoot, "staged.flac")
            val newBytes = "new-staged-flac-payload".toByteArray(Charsets.UTF_8)
            staged.writeBytes(newBytes)

            val docRoot = DocumentFile.fromFile(exportRoot)

            // 1) Directory collision MUST throw and keep directory + children intact
            val collidingDir = File(exportRoot, "Collision.flac").apply { mkdirs() }
            val childInside = File(collidingDir, "keep.txt").apply { writeText("precious") }
            assertThrows(CloudTuneException::class.java) {
                SafExporter.exportToDocumentDirectory(
                    dir = docRoot,
                    targetName = "Collision.flac",
                    stagedFile = staged,
                    mimeType = "audio/flac",
                    openOutputStream = { d -> FileOutputStream(File(d.uri.path!!)) }
                )
            }
            assertTrue(childInside.isFile)

            // 2) Copy/open stream failure MUST preserve existing target file intact
            val existingFile = File(exportRoot, "Existing.flac")
            val oldBytes = "original-precious-audio".toByteArray(Charsets.UTF_8)
            existingFile.writeBytes(oldBytes)
            assertThrows(CloudTuneException::class.java) {
                SafExporter.exportToDocumentDirectory(
                    dir = docRoot,
                    targetName = "Existing.flac",
                    stagedFile = staged,
                    mimeType = "audio/flac",
                    openOutputStream = { null }
                )
            }
            assertArrayEquals(oldBytes, existingFile.readBytes())

            // 3) Valid replacement writes via sibling temp document and replaces cleanly
            SafExporter.exportToDocumentDirectory(
                dir = docRoot,
                targetName = "Existing.flac",
                stagedFile = staged,
                mimeType = "audio/flac",
                openOutputStream = { d -> FileOutputStream(File(d.uri.path!!)) }
            )
            assertArrayEquals(newBytes, existingFile.readBytes())
            assertTrue(exportRoot.list().orEmpty().none { it.contains(".tmp") })

            // 4) sanitizeFileName blocks "." and ".." traversal names
            assertTrue(com.gosu.cloudtune.core.Cloud189Protocol.sanitizeFileName("..") == "_")
            assertTrue(com.gosu.cloudtune.core.Cloud189Protocol.sanitizeFileName(".") == "_")
        } finally {
            tempRoot.deleteRecursively()
        }
    }

    @Test
    fun verifyExternalVideoLogoutGuard(): Unit = kotlinx.coroutines.runBlocking {
        val tempRoot = Files.createTempDirectory("cloudtune-ext-guard").toFile()
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        try {
            val activity = controller.get()
            var enteredResolve = kotlinx.coroutines.CompletableDeferred<Unit>()
            var releaseResolve = kotlinx.coroutines.CompletableDeferred<Unit>()
            val transport = object : com.gosu.cloudtune.core.CloudHttpTransport {
                override suspend fun send(
                    url: String,
                    method: String,
                    headers: Map<String, String>,
                    formBody: List<Pair<String, String>>?
                ): com.gosu.cloudtune.core.CloudHttpResponse {
                    return when {
                        url.contains("refreshToken.do") -> {
                            val b = """{"res_code":0,"accessToken":"at_1","refreshToken":"rt_1"}"""
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8), url)
                        }
                        url.contains("getSessionForPC.action") -> {
                            val b = """{"res_code":0,"loginName":"guard@example.invalid","sessionKey":"sk","sessionSecret":"ss","refreshToken":"rt_1"}"""
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8), url)
                        }
                        url.contains("listFiles.action") -> {
                            val b = """{"res_code":0,"fileListAO":{"count":0,"folderList":[],"fileList":[]}}"""
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8), url)
                        }
                        url.contains("getFileDownloadUrl.action") -> {
                            enteredResolve.complete(Unit)
                            releaseResolve.await()
                            val b = """{"res_code":0,"fileDownloadUrl":"https://media.example.invalid/concert.mp4"}"""
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8), url)
                        }
                        else -> com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), "{}".toByteArray(Charsets.UTF_8), url)
                    }
                }
                override fun importCookieHeader(domainUrl: String, cookieHeader: String?) {}
                override fun clearCookies() {}
            }
            var savedCred = com.gosu.cloudtune.core.PersistedRefreshCredential.createOrNull("rt_init", "guard@example.invalid")
            val memCredStore = object : com.gosu.cloudtune.data.CredentialStore {
                override fun loadCredential() = savedCred
                override fun saveCredential(credential: com.gosu.cloudtune.core.PersistedRefreshCredential) { savedCred = credential }
                override fun clearCredential() { savedCred = null }
            }
            val runtime = CloudTuneAppRuntime(
                appContext = activity.applicationContext,
                cloudClient = com.gosu.cloudtune.core.Cloud189Client(transport),
                accountStore = com.gosu.cloudtune.data.AccountStore(tempRoot),
                credentialStore = memCredStore,
                limiter = com.gosu.cloudtune.core.GlobalTransferLimiter(8),
                enableLiveLoops = false,
                dispatcher = kotlinx.coroutines.Dispatchers.Unconfined,
                ioDispatcher = kotlinx.coroutines.Dispatchers.Unconfined
            )
            runtime.bootstrap().await()
            assertTrue(runtime.isAuthenticated)

            // 1) openVideoExternally completing/cancelled across logout() must not set pendingExternalVideoAction, launch intent, or leave busyLabel stuck
            val video = com.gosu.cloudtune.core.TrackSummary("vid-race", "Concert.mp4", "Videos", 4096L)
            runtime.openVideoExternally(activity, video)
            val extJob1 = runtime.lastExternalVideoJob
            kotlinx.coroutines.withTimeout(5000L) { enteredResolve.await() }
            assertTrue(runtime.busyLabel != null)
            runtime.logout()
            assertTrue(runtime.busyLabel == null)
            releaseResolve.complete(Unit)
            extJob1?.join()
            runtime.cookieCleanupDeferred?.await()
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertTrue("External video preparation completing after logout must not set pendingExternalVideoAction", runtime.pendingExternalVideoAction == null)
            assertTrue("External video preparation completing after logout must not launch intent", Shadows.shadowOf(activity as android.app.Activity).nextStartedActivity == null)
            assertTrue("busyLabel must remain null after logout", runtime.busyLabel == null)

            // 2) downloadVideoAndOpenExternally racing against logout() must not launch intent, overwrite logout statusMessage, or leave busyLabel stuck
            enteredResolve = kotlinx.coroutines.CompletableDeferred()
            releaseResolve = kotlinx.coroutines.CompletableDeferred()
            savedCred = com.gosu.cloudtune.core.PersistedRefreshCredential.createOrNull("rt_init_2", "guard@example.invalid")
            runtime.bootstrap().await()
            assertTrue(runtime.isAuthenticated)

            val dlVideo = com.gosu.cloudtune.core.TrackSummary("vid-dl-race", "Clip.mp4", "Videos", 128L)
            runtime.downloadVideoAndOpenExternally(activity, dlVideo)
            val extJob2 = runtime.lastExternalVideoJob
            kotlinx.coroutines.withTimeout(5000L) { enteredResolve.await() }
            assertTrue(runtime.busyLabel != null)
            runtime.logout()
            assertTrue(runtime.busyLabel == null)
            releaseResolve.complete(Unit)
            extJob2?.join()
            runtime.cookieCleanupDeferred?.await()
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertTrue("Download-and-open completing after logout must not launch intent", Shadows.shadowOf(activity as android.app.Activity).nextStartedActivity == null)
            assertTrue("busyLabel must remain null after logout", runtime.busyLabel == null)
            assertTrue("statusMessage must keep logout notice", runtime.statusMessage == "已退出登录并清理当前会话")
            Unit
        } finally {
            controller.pause().stop().destroy()
            tempRoot.deleteRecursively()
        }
    }

    @Test
    fun verifySafFirstExportAndDecoupledExternalVideoGeneration(): Unit = kotlinx.coroutines.runBlocking {
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        val activity = controller.get()
        val scopedFilesRoot = File(activity.applicationContext.filesDir, "saf-ext-test").apply {
            deleteRecursively()
            mkdirs()
        }
        val mediaBytes = ByteArray(64) { 0x42 }
        try {
            val store = com.gosu.cloudtune.data.AccountStore(scopedFilesRoot)
            val preseedPaths = store.paths("saf@example.invalid")
            val preseedCache = com.gosu.cloudtune.core.CacheManager(preseedPaths.cacheDir)
            val preseededVideoFile = preseedCache.cacheFile("vid-dl-cached", "CachedShow.mp4").apply {
                parentFile?.mkdirs()
                writeBytes(mediaBytes)
            }
            preseedCache.recordCompletedFile(
                trackId = "vid-dl-cached",
                file = preseededVideoFile,
                sizeBytes = mediaBytes.size.toLong(),
                limitBytes = 16L * 1024L * 1024L
            )

            var videoEntered = kotlinx.coroutines.CompletableDeferred<Unit>()
            var videoRelease = kotlinx.coroutines.CompletableDeferred<Unit>()
            val transport = object : com.gosu.cloudtune.core.CloudHttpTransport {
                override suspend fun send(
                    url: String,
                    method: String,
                    headers: Map<String, String>,
                    formBody: List<Pair<String, String>>?
                ): com.gosu.cloudtune.core.CloudHttpResponse {
                    return when {
                        url.contains("refreshToken.do") -> {
                            val b = """{"res_code":0,"accessToken":"at_1","refreshToken":"rt_1"}"""
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8), url)
                        }
                        url.contains("getSessionForPC.action") -> {
                            val b = """{"res_code":0,"loginName":"saf@example.invalid","sessionKey":"sk","sessionSecret":"ss","refreshToken":"rt_1"}"""
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8), url)
                        }
                        url.contains("listFiles.action") -> {
                            val b = """{"res_code":0,"fileListAO":{"count":0,"folderList":[],"fileList":[]}}"""
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8), url)
                        }
                        url.contains("getFileDownloadUrl.action") -> {
                            if (url.contains("fileId=vid-gated") || url.contains("fileId=vid-dl-gated")) {
                                videoEntered.complete(Unit)
                                videoRelease.await()
                                if (url.contains("fileId=vid-dl-gated")) {
                                    throw com.gosu.cloudtune.core.CloudTuneException("模拟视频缓存源波动")
                                }
                            }
                            val b = """{"res_code":0,"fileDownloadUrl":"https://media.example.invalid/media.mp4"}"""
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8), url)
                        }
                        else -> com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), "{}".toByteArray(Charsets.UTF_8), url)
                    }
                }
                override fun importCookieHeader(domainUrl: String, cookieHeader: String?) {}
                override fun clearCookies() {}
            }
            var savedCred = com.gosu.cloudtune.core.PersistedRefreshCredential.createOrNull("rt_saf", "saf@example.invalid")
            val memCredStore = object : com.gosu.cloudtune.data.CredentialStore {
                override fun loadCredential() = savedCred
                override fun saveCredential(credential: com.gosu.cloudtune.core.PersistedRefreshCredential) { savedCred = credential }
                override fun clearCredential() { savedCred = null }
            }
            val runtime = CloudTuneAppRuntime(
                appContext = activity.applicationContext,
                cloudClient = com.gosu.cloudtune.core.Cloud189Client(transport),
                accountStore = store,
                credentialStore = memCredStore,
                limiter = com.gosu.cloudtune.core.GlobalTransferLimiter(8),
                enableLiveLoops = false,
                dispatcher = kotlinx.coroutines.Dispatchers.Unconfined,
                ioDispatcher = kotlinx.coroutines.Dispatchers.Unconfined
            )
            runtime.bootstrap().await()
            assertTrue(runtime.isAuthenticated)

            // 1) Issue 4: onSafTreeSelected persists exportTreeUri for active account BEFORE invoking onSaved, and ignores logged-out calls
            assertNull(runtime.committedSettings.exportTreeUri)
            val pickedUri = Uri.parse("content://com.android.externalstorage.documents/tree/primary%3ACloudTuneExports")
            var callbackUri: String? = null
            runtime.onSafTreeSelected(activity, pickedUri) { savedTreeUri ->
                callbackUri = savedTreeUri
            }
            assertEquals(pickedUri.toString(), callbackUri)
            assertEquals(pickedUri.toString(), runtime.committedSettings.exportTreeUri)
            assertEquals(
                pickedUri.toString(),
                runtime.accountStore.loadSettingsOrNull(runtime.accountStorageKey!!)?.exportTreeUri
            )

            runtime.logout()
            runtime.cookieCleanupDeferred?.await()
            var postLogoutCallbackInvoked = false
            runtime.onSafTreeSelected(activity, pickedUri) { postLogoutCallbackInvoked = true }
            assertFalse(postLogoutCallbackInvoked)
            assertNull(runtime.committedSettings.exportTreeUri)

            savedCred = com.gosu.cloudtune.core.PersistedRefreshCredential.createOrNull("rt_saf_2", "saf@example.invalid")
            runtime.bootstrap().await()
            assertTrue(runtime.isAuthenticated)

            // 2) Issue 10a: Background audio playTrack (incrementing playbackGeneration) MUST NOT abort openVideoExternally
            val gatedVideo = com.gosu.cloudtune.core.TrackSummary("vid-gated", "Stage4K.mp4", "Videos", mediaBytes.size.toLong())
            runtime.updatePlaybackMode(com.gosu.cloudtune.core.PlaybackMode.STREAM_CACHE)
            runtime.openVideoExternally(activity, gatedVideo)
            val extJob = runtime.lastExternalVideoJob
            kotlinx.coroutines.withTimeout(5000L) { videoEntered.await() }
            runtime.playTrack(com.gosu.cloudtune.core.TrackSummary("audio-bg", "AutoAdvance.flac", "Music", mediaBytes.size.toLong()))
            assertEquals("audio-bg", runtime.currentTrackId)
            videoRelease.complete(Unit)
            extJob?.join()
            assertEquals("vid-gated", runtime.pendingExternalVideoAction?.video?.id)

            // 2b) Issue 10b: downloadVideoAndOpenExternally MUST ALSO survive background audio playTrack (not aborted by playbackGeneration)
            runtime.pendingExternalVideoAction = null
            videoEntered = kotlinx.coroutines.CompletableDeferred()
            videoRelease = kotlinx.coroutines.CompletableDeferred()
            val dlGatedVideo = com.gosu.cloudtune.core.TrackSummary("vid-dl-gated", "GatedShow.mp4", "Videos", mediaBytes.size.toLong())
            runtime.downloadVideoAndOpenExternally(activity, dlGatedVideo)
            val dlExtJob = runtime.lastExternalVideoJob
            kotlinx.coroutines.withTimeout(5000L) { videoEntered.await() }
            runtime.playTrack(com.gosu.cloudtune.core.TrackSummary("audio-bg-2", "AutoAdvance2.flac", "Music", mediaBytes.size.toLong()))
            assertEquals("audio-bg-2", runtime.currentTrackId)
            videoRelease.complete(Unit)
            dlExtJob?.join()
            assertTrue(
                "downloadVideoAndOpenExternally must retain its externalVideoGeneration across playTrack, got: ${runtime.statusMessage}",
                runtime.statusMessage?.contains("模拟视频缓存源波动") == true
            )

            Shadows.shadowOf(activity as android.app.Activity).clearNextStartedActivities()
            val dlCachedVideo = com.gosu.cloudtune.core.TrackSummary("vid-dl-cached", "CachedShow.mp4", "Videos", mediaBytes.size.toLong())
            runtime.downloadVideoAndOpenExternally(activity, dlCachedVideo)
            runtime.lastExternalVideoJob?.join()
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertTrue(runtime.cacheUsageBytes >= mediaBytes.size.toLong())
            assertNotNull(
                "downloadVideoAndOpenExternally must launch FileProvider chooser for cached video",
                Shadows.shadowOf(activity as android.app.Activity).nextStartedActivity
            )

            // Conversely, openVideoInApp MUST cancel/invalidate pending external video handoff
            runtime.pendingExternalVideoAction = null
            videoEntered = kotlinx.coroutines.CompletableDeferred()
            videoRelease = kotlinx.coroutines.CompletableDeferred()
            runtime.openVideoExternally(activity, gatedVideo)
            val extJob2 = runtime.lastExternalVideoJob
            kotlinx.coroutines.withTimeout(5000L) { videoEntered.await() }
            runtime.openVideoInApp(com.gosu.cloudtune.core.TrackSummary("vid-inapp", "InApp.mp4", "Videos", mediaBytes.size.toLong()))
            videoRelease.complete(Unit)
            extJob2?.join()
            assertNull(runtime.pendingExternalVideoAction)
            assertEquals("vid-inapp", runtime.activeVideoTrack?.id)
            runtime.closeVideoPlayer()
            Unit
        } finally {
            controller.pause().stop().destroy()
            scopedFilesRoot.deleteRecursively()
        }
    }

    @Test
    fun verifySampledArtworkDownsamplingAndCompactThumbnail() {
        val width = 2048
        val height = 2048
        val pixels = IntArray(width * height)
        for (y in 0 until height) {
            val row = y * width
            for (x in 0 until width) {
                val r = (x * 13 + y * 5) and 0xFF
                val g = (x * 3 + y * 17) and 0xFF
                val b = ((x xor y) * 29) and 0xFF
                pixels[row + x] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
            }
        }
        val hugeBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply {
            setPixels(pixels, 0, width, 0, 0, width, height)
        }
        val rawPngBytes = ByteArrayOutputStream().use { out ->
            assertTrue(hugeBitmap.compress(Bitmap.CompressFormat.PNG, 100, out))
            out.toByteArray()
        }
        hugeBitmap.recycle()
        assertTrue(
            "Synthetic 2048x2048 PNG should exceed inline threshold, got ${rawPngBytes.size}",
            rawPngBytes.size > AudioMetadataHelper.MAX_INLINE_ARTWORK_BYTES
        )

        val sampled = AudioMetadataHelper.decodeSampledBitmap(rawPngBytes, maxDimensionPx = 512)
        assertNotNull("decodeSampledBitmap must decode valid 2048x2048 PNG", sampled)
        assertTrue("Decoded width must be <= 512, got ${sampled!!.width}", sampled.width <= 512)
        assertTrue("Decoded height must be <= 512, got ${sampled.height}", sampled.height <= 512)
        sampled.recycle()

        val compactBytes = AudioMetadataHelper.compactArtworkBytes(rawPngBytes, maxDimensionPx = 512)
        assertNotNull("compactArtworkBytes must return compact thumbnail bytes", compactBytes)
        assertTrue(
            "Compact bytes (${compactBytes!!.size}) must be much smaller than raw PNG (${rawPngBytes.size})",
            compactBytes.size < rawPngBytes.size / 2
        )
        assertTrue(
            "Compact bytes (${compactBytes.size}) must fit Binder-safe threshold",
            compactBytes.size <= AudioMetadataHelper.MAX_INLINE_ARTWORK_BYTES * 2
        )

        val redecoded = AudioMetadataHelper.decodeSampledBitmap(compactBytes, maxDimensionPx = 512)
        assertNotNull(redecoded)
        assertTrue(redecoded!!.width in 1..512 && redecoded.height in 1..512)
        redecoded.recycle()
    }

    @Test
    fun verifyMainActivityPipCloseClearsOverlayAndAudioResumeDismissesVideo() {
        val tempRoot = Files.createTempDirectory("cloudtune-pip-lifecycle").toFile()
        val bootProbe = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        val appCtx = bootProbe.get().applicationContext
        bootProbe.pause().stop().destroy()

        val runtime = CloudTuneAppRuntime(
            appContext = appCtx,
            accountStore = com.gosu.cloudtune.data.AccountStore(tempRoot),
            credentialStore = null,
            enableLiveLoops = false
        )
        CloudTuneAppRuntime.setSharedInstanceForTest(runtime)
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        try {
            val activity = controller.get()
            assertEquals(runtime, activity.runtimeRef)
            val config = Configuration(activity.resources.configuration)
            val video = com.gosu.cloudtune.core.TrackSummary("vid-pip-1", "StageLive.mp4", "Videos", 8192L)

            runtime.isAuthenticated = true
            runtime.activeVideoTrack = video
            runtime.activeVideoTitle = video.name
            runtime.activeVideoUrl = "http://127.0.0.1:19000/stream/pip/StageLive.mp4"
            runtime.isVideoPlaying = true

            // 1) Enter PiP (Activity paused -> STARTED): video stays alive
            activity.onPictureInPictureModeChanged(true, config)
            controller.pause()
            assertEquals(Lifecycle.State.STARTED, activity.lifecycle.currentState)
            assertTrue(activity.isInPipMode)
            assertNotNull(runtime.activeVideoUrl)

            // 2) Expand PiP back to full screen (Activity RESUMED >= STARTED): video overlay stays open
            controller.resume()
            activity.onPictureInPictureModeChanged(false, config)
            assertFalse(activity.isInPipMode)
            assertNotNull("Expanding PiP back to foreground must keep activeVideoUrl", runtime.activeVideoUrl)

            // 3) Dismiss/close PiP window ('X'): Activity moves to STOPPED (CREATED) then exits PiP -> closes video player!
            activity.onPictureInPictureModeChanged(true, config)
            controller.pause().stop()
            assertEquals(Lifecycle.State.CREATED, activity.lifecycle.currentState)
            activity.onPictureInPictureModeChanged(false, config)
            assertFalse(activity.isInPipMode)
            assertNull("Closing PiP window must clear activeVideoUrl residue", runtime.activeVideoUrl)
            assertNull(runtime.activeVideoTrack)
            assertFalse(runtime.isVideoPlaying)

            // 4) Resuming audio playback dismisses any active in-app video overlay
            runtime.activeVideoTrack = video
            runtime.activeVideoTitle = video.name
            runtime.activeVideoUrl = "http://127.0.0.1:19000/stream/pip2/StageLive.mp4"
            runtime.isVideoPlaying = true
            val song = com.gosu.cloudtune.core.TrackSummary("aud-1", "Symphony.flac", "Music", 2048L)
            runtime.activeTrack = song
            runtime.currentTrackId = song.id
            runtime.isPlaying = false
            runtime.togglePlayback()
            assertTrue(runtime.isPlaying)
            assertNull("Starting/resuming audio playback must close video overlay", runtime.activeVideoUrl)
        } finally {
            runCatching { controller.destroy() }
            CloudTuneAppRuntime.setSharedInstanceForTest(null)
            tempRoot.deleteRecursively()
        }
    }
}
