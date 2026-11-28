package com.gosu.cloudtune.ui

import android.Manifest
import android.content.pm.ProviderInfo
import android.content.res.Configuration
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.os.CancellationSignal
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import android.view.View
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
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
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
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
                val vm = CloudTuneViewModel(
                    runtime = CloudTuneAppRuntime.fixture(scene, fixture, appearanceMode = themeMode)
                )
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
    @Config(qualifiers = "w360dp-h780dp-mdpi")
    fun verifyNarrow360dpAdaptiveRenderWithoutTruncationOrCrash() {
        val fixture = locateFixture()
        val widthPx = 360
        val heightPx = 780

        fun assertBitmapContrast(bitmap: Bitmap, label: String, expectDark: Boolean) {
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
            assertTrue("narrow360 $label stdDev=$stdDev too flat", stdDev > 0.03)
            assertTrue("narrow360 $label edges=$edges too low", edges > 80)
            if (expectDark) {
                assertTrue("narrow360 dark $label mean=$mean too bright", mean < 0.42)
            } else {
                assertTrue("narrow360 light $label mean=$mean too dark", mean > 0.52)
            }
        }

        for ((themeName, themeMode, expectDark) in listOf(
            Triple("light", AppearanceMode.LIGHT, false),
            Triple("dark", AppearanceMode.DARK, true)
        )) {
            for (scene in SnapshotScene.entries) {
                val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
                try {
                    val activity = controller.get()
                    activity.enableEdgeToEdge()
                    val rt = CloudTuneAppRuntime.fixture(scene, fixture, appearanceMode = themeMode)
                    if (scene == SnapshotScene.SETTINGS) {
                        rt.cacheLimitDraft = "4096"
                        rt.downloadThreadsDraft = "12"
                        assertTrue(rt.hasUncommittedCacheDraft)
                        assertTrue(rt.hasUncommittedThreadDrafts)
                    } else if (scene == SnapshotScene.DOWNLOAD) {
                        val completedItem = rt.transferSnapshot.items.first().copy(
                            state = "completed",
                            transferredBytes = 62_914_560L,
                            totalBytes = 62_914_560L,
                            canPause = false,
                            canResume = false,
                            canDelete = true
                        )
                        rt.transferSnapshot = rt.transferSnapshot.copy(
                            items = listOf(completedItem) + rt.transferSnapshot.items.drop(1)
                        )
                    }
                    val vm = CloudTuneViewModel(runtime = rt)
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
                    assertBitmapContrast(bitmap, "$themeName-${scene.fileStem}", expectDark)
                    bitmap.recycle()
                } finally {
                    controller.pause().stop().destroy()
                }
            }
        }
    }

    class MockSafDocumentsProvider : DocumentsProvider() {
        override fun onCreate(): Boolean = true

        override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean {
            return documentId == parentDocumentId || documentId.startsWith("$parentDocumentId/")
        }

        override fun queryRoots(projection: Array<out String>?): Cursor {
            val cols = projection?.map { it }?.toTypedArray() ?: arrayOf(
                DocumentsContract.Root.COLUMN_ROOT_ID,
                DocumentsContract.Root.COLUMN_DOCUMENT_ID,
                DocumentsContract.Root.COLUMN_TITLE,
                DocumentsContract.Root.COLUMN_FLAGS
            )
            return MatrixCursor(cols)
        }

        override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
            val file = resolveFile(documentId)
            if (!file.exists()) throw FileNotFoundException("Missing document: $documentId")
            val cursor = MatrixCursor(resolveColumns(projection))
            appendRow(cursor, documentId, file)
            return cursor
        }

        override fun queryChildDocuments(
            parentDocumentId: String,
            projection: Array<out String>?,
            sortOrder: String?
        ): Cursor {
            val dir = resolveFile(parentDocumentId)
            if (!dir.isDirectory) throw FileNotFoundException("Not a directory: $parentDocumentId")
            val cursor = MatrixCursor(resolveColumns(projection))
            val children = dir.listFiles()?.sortedBy { it.name }.orEmpty()
            for (child in children) {
                appendRow(cursor, docIdForFile(child), child)
            }
            return cursor
        }

        override fun createDocument(
            parentDocumentId: String,
            mimeType: String,
            displayName: String
        ): String {
            val parent = resolveFile(parentDocumentId)
            if (!parent.isDirectory) throw FileNotFoundException("Parent not a directory: $parentDocumentId")
            val target = File(parent, displayName)
            if (target.exists()) throw IllegalStateException("Already exists: $displayName")
            if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                if (!target.mkdirs() && !target.isDirectory) {
                    throw FileNotFoundException("Unable to create directory $displayName")
                }
            } else if (!target.createNewFile()) {
                throw FileNotFoundException("Unable to create file $displayName")
            }
            return docIdForFile(target)
        }

        override fun renameDocument(documentId: String, displayName: String): String {
            if (failRenames) {
                throw UnsupportedOperationException("Simulated provider without rename support")
            }
            val source = resolveFile(documentId)
            if (!source.exists()) throw FileNotFoundException("Missing document: $documentId")
            val dest = File(source.parentFile, displayName)
            if (dest.exists()) throw IllegalStateException("Target exists: $displayName")
            if (!source.renameTo(dest)) {
                throw FileNotFoundException("Rename failed for $documentId -> $displayName")
            }
            return docIdForFile(dest)
        }

        override fun deleteDocument(documentId: String) {
            val target = resolveFile(documentId)
            if (!target.exists()) throw FileNotFoundException("Missing document: $documentId")
            if (!target.deleteRecursively()) {
                throw FileNotFoundException("Delete failed: $documentId")
            }
        }

        override fun openDocument(
            documentId: String,
            mode: String,
            signal: CancellationSignal?
        ): ParcelFileDescriptor {
            val file = resolveFile(documentId)
            if (!file.exists()) throw FileNotFoundException("Missing document: $documentId")
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.parseMode(mode))
        }

        private fun resolveColumns(projection: Array<out String>?): Array<String> =
            projection?.map { it }?.toTypedArray() ?: DEFAULT_COLUMNS

        private fun appendRow(cursor: MatrixCursor, docId: String, file: File) {
            val mime = if (file.isDirectory) {
                DocumentsContract.Document.MIME_TYPE_DIR
            } else {
                "application/octet-stream"
            }
            val flags = if (file.isDirectory) {
                DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE or
                    DocumentsContract.Document.FLAG_SUPPORTS_DELETE or
                    DocumentsContract.Document.FLAG_SUPPORTS_RENAME
            } else {
                DocumentsContract.Document.FLAG_SUPPORTS_WRITE or
                    DocumentsContract.Document.FLAG_SUPPORTS_DELETE or
                    DocumentsContract.Document.FLAG_SUPPORTS_RENAME
            }
            val names = cursor.columnNames
            val values = Array<Any?>(names.size) { idx ->
                when (names[idx]) {
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID -> docId
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME -> file.name
                    DocumentsContract.Document.COLUMN_MIME_TYPE -> mime
                    DocumentsContract.Document.COLUMN_SIZE -> if (file.isFile) file.length() else 0L
                    DocumentsContract.Document.COLUMN_FLAGS -> flags
                    else -> null
                }
            }
            cursor.addRow(values)
        }

        companion object {
            const val AUTHORITY = "com.gosu.cloudtune.test.saf"
            @Volatile var failRenames: Boolean = false
            private val DEFAULT_COLUMNS = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_FLAGS
            )
            @Volatile var backingRoot: File? = null

            fun resolveFile(documentId: String): File {
                val root = backingRoot ?: throw FileNotFoundException("backingRoot unset")
                if (documentId == "root") return root
                if (!documentId.startsWith("root/")) throw FileNotFoundException("Invalid docId: $documentId")
                val rel = documentId.removePrefix("root/")
                return File(root, rel)
            }

            fun docIdForFile(file: File): String {
                val root = backingRoot!!.canonicalFile
                val target = file.canonicalFile
                if (target == root) return "root"
                val rel = root.toPath().relativize(target.toPath()).toString().replace(File.separatorChar, '/')
                return "root/$rel"
            }
        }
    }

    @Test
    fun verifySafExporterTargetSafety() {
        val tempRoot = Files.createTempDirectory("cloudtune-saf-export").toFile()
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        try {
            val activity = controller.get()
            val exportRoot = File(tempRoot, "exports").apply { mkdirs() }
            MockSafDocumentsProvider.backingRoot = exportRoot
            val providerInfo = ProviderInfo().apply {
                authority = MockSafDocumentsProvider.AUTHORITY
                packageName = activity.packageName
                exported = true
                grantUriPermissions = true
                readPermission = Manifest.permission.MANAGE_DOCUMENTS
                writePermission = Manifest.permission.MANAGE_DOCUMENTS
            }
            Robolectric.buildContentProvider(MockSafDocumentsProvider::class.java).create(providerInfo)

            val treeUri = DocumentsContract.buildTreeDocumentUri(MockSafDocumentsProvider.AUTHORITY, "root")
            val treeUriStr = treeUri.toString()
            assertEquals("exports", SafExporter.persistTreePermission(activity, treeUri))

            val part0 = File(tempRoot, "0000.part")
            val part1 = File(tempRoot, "0001.part")
            val newBytes = ByteArray(100_000) { ((it * 19 + 3) and 0xFF).toByte() }
            part0.writeBytes(newBytes.copyOfRange(0, 50_000))
            part1.writeBytes(newBytes.copyOfRange(50_000, 100_000))

            // 1) Directory collision MUST throw and keep directory + children intact
            val collidingDir = File(exportRoot, "Collision.flac").apply { mkdirs() }
            val childInside = File(collidingDir, "keep.txt").apply { writeText("precious") }
            assertThrows(CloudTuneException::class.java) {
                SafExporter.exportPartsToSafTree(
                    context = activity,
                    treeUriString = treeUriStr,
                    partFiles = listOf(part0, part1),
                    expectedTotalBytes = newBytes.size.toLong(),
                    relativeSubpath = "Collision.flac",
                    mimeType = "audio/flac"
                )
            }
            assertTrue(childInside.isFile)

            // 2) Mid-stream write failure during SAF overwrite MUST preserve existing target file intact & clean up temp sibling
            val albumDir = File(exportRoot, "CD 1").apply { mkdirs() }
            val existingFile = File(albumDir, "Existing.flac")
            val oldBytes = "original-precious-audio-intact".toByteArray(Charsets.UTF_8)
            existingFile.writeBytes(oldBytes)

            assertThrows(CloudTuneException::class.java) {
                SafExporter.exportPartsToSafTree(
                    context = activity,
                    treeUriString = treeUriStr,
                    partFiles = listOf(part0, part1),
                    expectedTotalBytes = newBytes.size.toLong(),
                    relativeSubpath = "CD 1/Existing.flac",
                    mimeType = "audio/flac",
                    openOutputStreamOverride = { docUri ->
                        val backing = MockSafDocumentsProvider.resolveFile(DocumentsContract.getDocumentId(docUri))
                        val rawOut = FileOutputStream(backing)
                        object : OutputStream() {
                            private var written = 0
                            override fun write(b: Int) {
                                if (written >= 40_000) throw IOException("simulated mid-stream SAF drop")
                                rawOut.write(b)
                                written += 1
                            }
                            override fun write(b: ByteArray, off: Int, len: Int) {
                                if (written + len > 40_000) {
                                    val partial = (40_000 - written).coerceAtLeast(0)
                                    if (partial > 0) {
                                        rawOut.write(b, off, partial)
                                        written += partial
                                    }
                                    throw IOException("simulated mid-stream SAF drop")
                                }
                                rawOut.write(b, off, len)
                                written += len
                            }
                            override fun close() {
                                rawOut.close()
                            }
                        }
                    }
                )
            }
            assertArrayEquals("Pre-existing SAF file must remain 100% intact on mid-stream failure", oldBytes, existingFile.readBytes())
            assertEquals("Sibling temp document must be deleted on failure", listOf("Existing.flac"), albumDir.list().orEmpty().sorted())

            // 2b) Consecutive renameDocument failure + fallback backup/overwrite failure MUST still preserve existing target file intact
            MockSafDocumentsProvider.failRenames = true
            try {
                assertThrows(CloudTuneException::class.java) {
                    SafExporter.exportPartsToSafTree(
                        context = activity,
                        treeUriString = treeUriStr,
                        partFiles = listOf(part0, part1),
                        expectedTotalBytes = newBytes.size.toLong(),
                        relativeSubpath = "CD 1/Existing.flac",
                        mimeType = "audio/flac",
                        openOutputStreamOverride = { docUri ->
                            val backing = MockSafDocumentsProvider.resolveFile(DocumentsContract.getDocumentId(docUri))
                            if (!backing.name.startsWith(".cloudtune-tmp-")) {
                                throw IOException("simulated fallback/backup stream failure after temp staged")
                            }
                            FileOutputStream(backing)
                        }
                    )
                }
                assertArrayEquals(
                    "Pre-existing SAF file must survive when both renameDocument and fallback writes fail",
                    oldBytes,
                    existingFile.readBytes()
                )
                assertEquals(listOf("Existing.flac"), albumDir.list().orEmpty().sorted())
            } finally {
                MockSafDocumentsProvider.failRenames = false
            }

            // 3) Valid multi-part replacement writes via sibling temp document, verifies byte count, and replaces cleanly
            SafExporter.exportPartsToSafTree(
                context = activity,
                treeUriString = treeUriStr,
                partFiles = listOf(part0, part1),
                expectedTotalBytes = newBytes.size.toLong(),
                relativeSubpath = "CD 1/Existing.flac",
                mimeType = "audio/flac"
            )
            assertArrayEquals(newBytes, existingFile.readBytes())
            assertEquals(listOf("Existing.flac"), albumDir.list().orEmpty().sorted())

            // 4) Nested subpath creation via DocumentsContract single-projection child queries
            SafExporter.exportToSafTree(
                context = activity,
                treeUriString = treeUriStr,
                stagedFile = part0,
                relativeSubpath = "Jazz/2026 Live/Part0.flac",
                mimeType = "audio/flac"
            )
            assertArrayEquals(newBytes.copyOfRange(0, 50_000), File(exportRoot, "Jazz/2026 Live/Part0.flac").readBytes())

            // 5) sanitizeFileName blocks "." and ".." traversal names
            assertTrue(com.gosu.cloudtune.core.Cloud189Protocol.sanitizeFileName("..") == "_")
            assertTrue(com.gosu.cloudtune.core.Cloud189Protocol.sanitizeFileName(".") == "_")
        } finally {
            MockSafDocumentsProvider.backingRoot = null
            controller.pause().stop().destroy()
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
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        url.contains("getSessionForPC.action") -> {
                            val b = """{"res_code":0,"loginName":"guard@example.invalid","sessionKey":"sk","sessionSecret":"ss","refreshToken":"rt_1"}"""
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        url.contains("listFiles.action") -> {
                            val b = """{"res_code":0,"fileListAO":{"count":0,"folderList":[],"fileList":[]}}"""
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        url.contains("getFileDownloadUrl.action") -> {
                            enteredResolve.complete(Unit)
                            releaseResolve.await()
                            val b = """{"res_code":0,"fileDownloadUrl":"https://media.example.invalid/concert.mp4"}"""
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        else -> com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), "{}".toByteArray(Charsets.UTF_8))
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
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        url.contains("getSessionForPC.action") -> {
                            val b = """{"res_code":0,"loginName":"saf@example.invalid","sessionKey":"sk","sessionSecret":"ss","refreshToken":"rt_1"}"""
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        url.contains("listFiles.action") -> {
                            val b = """{"res_code":0,"fileListAO":{"count":0,"folderList":[],"fileList":[]}}"""
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
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
                            com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        else -> com.gosu.cloudtune.core.CloudHttpResponse(200, emptyMap(), "{}".toByteArray(Charsets.UTF_8))
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
