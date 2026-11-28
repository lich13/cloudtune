package com.gosu.cloudtune.core

import com.gosu.cloudtune.data.AccountStore
import com.gosu.cloudtune.data.CredentialStore
import com.gosu.cloudtune.media.PlaybackSessionBridge
import com.gosu.cloudtune.ui.CloudTuneAppRuntime
import com.gosu.cloudtune.ui.CloudTuneViewModel
import com.gosu.cloudtune.ui.StatusKind
import com.gosu.cloudtune.ui.fixture
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URI
import java.net.URL
import java.nio.file.Files
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class Cloud189ProtocolAndProxyTest {
    private fun locateContractsFile(name: String): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").canonicalFile
        while (dir != null) {
            val candidate = File(dir, "contracts/$name")
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        error("Could not locate contracts/$name from ${System.getProperty("user.dir")}")
    }

    @Test
    fun verifySharedProtocolVectors() {
        val root = JSONObject(locateContractsFile("protocol-vectors.json").readText(Charsets.UTF_8))

        // 1) HMAC-SHA1
        val hmac = root.getJSONObject("hmacSignature")
        val (reqUri, sig) = Cloud189Protocol.computeSignature(
            sessionKey = hmac.getString("sessionKey"),
            sessionSecret = hmac.getString("sessionSecret"),
            method = hmac.getString("method"),
            urlString = hmac.getString("url"),
            dateHeader = hmac.getString("date")
        )
        assertEquals(hmac.getString("expectedRequestUri"), reqUri)
        assertEquals(hmac.getString("expectedSignature"), sig)

        // 2) Login HTML extraction avoiding alt="二维码登录成功"
        val htmlBlock = root.getJSONObject("loginHtmlExtraction")
        val extracted = Cloud189Protocol.extractLoginParameters(htmlBlock.getString("html"))
        assertEquals(htmlBlock.getString("expectedLt"), extracted.lt)
        assertEquals(htmlBlock.getString("expectedParamId"), extracted.paramId)
        assertEquals(htmlBlock.getString("expectedReqId"), extracted.reqId)

        // 3) QR poll payloads
        val qrArr = root.getJSONArray("qrPollPayloads")
        for (i in 0 until qrArr.length()) {
            val entry = qrArr.getJSONObject(i)
            val parsed = Cloud189Protocol.parseQrPollPayload(entry.getString("json"), 200)
            assertEquals(entry.getString("expectedState"), parsed.state.wireValue)
            val expectedRedirect = if (entry.isNull("expectedRedirectUrl")) null else entry.getString("expectedRedirectUrl")
            assertEquals(expectedRedirect, parsed.redirectUrl)
        }

        // 4) Strict session split (JSON vs XML)
        val sessArr = root.getJSONArray("sessionPayloads")
        for (i in 0 until sessArr.length()) {
            val entry = sessArr.getJSONObject(i)
            val parsed = Cloud189Protocol.parseSessionResponse(entry.getString("body"), 200)
            assertEquals(entry.getString("expectedAccountName"), parsed.activeSession.loginName)
            assertEquals(entry.getString("expectedSessionKey"), parsed.activeSession.sessionKey)
            assertEquals(entry.getString("expectedSessionSecret"), parsed.activeSession.sessionSecret)
            val expectedRt = if (entry.isNull("expectedPersistedRefreshToken")) null else entry.getString("expectedPersistedRefreshToken")
            assertEquals(expectedRt, parsed.persistedCredential?.refreshToken)
        }

        // 5) Web login callback classifier
        val cbArr = root.getJSONArray("webLoginCallbacks")
        for (i in 0 until cbArr.length()) {
            val entry = cbArr.getJSONObject(i)
            assertEquals(
                entry.getBoolean("shouldIntercept"),
                Cloud189Protocol.isInterceptableWebLoginCallback(entry.getString("url"))
            )
        }

        // 6) Range validation vectors (probe, mid-seek, full-open, initial non-zero, resume, and suffix ranges)
        val rv = root.getJSONObject("rangeValidation")
        val probeHeader = rv.getString("probeRangeHeader")
        val midSeekHeader = rv.getString("midSeekRangeHeader")
        val fullOpenHeader = rv.getString("fullOpenRangeHeader")
        val partialCrHeader = rv.getString("partialContentRangeHeader")
        val expectedTotalFromCr = rv.getLong("expectedTotalFromContentRange")
        assertEquals(ParsedByteRange(0L, 1L), RangeHeaderValidator.parseRequestRange(probeHeader))
        assertFalse(RangeHeaderValidator.canWriteThroughToCache(probeHeader))
        assertEquals(ParsedByteRange(65536L, null), RangeHeaderValidator.parseRequestRange(midSeekHeader))
        assertFalse(RangeHeaderValidator.canWriteThroughToCache(midSeekHeader))
        assertEquals(ParsedByteRange(0L, null), RangeHeaderValidator.parseRequestRange(fullOpenHeader))
        assertTrue(RangeHeaderValidator.canWriteThroughToCache(fullOpenHeader))
        assertTrue(RangeHeaderValidator.canWriteThroughToCache(null))
        assertEquals(
            expectedTotalFromCr,
            RangeHeaderValidator.extractFullAssetLength(206, true, partialCrHeader, "2")
        )

        val resumeOffset = rv.getLong("resumeOffset")
        val validResumeCr = rv.getString("validResumeContentRange")
        val mismatchedResumeCr = rv.getString("mismatchedResumeContentRange")
        RangeHeaderValidator.validateResumeResponse(resumeOffset, 206, validResumeCr)
        assertThrows(CloudTuneException::class.java) {
            RangeHeaderValidator.validateResumeResponse(resumeOffset, 206, mismatchedResumeCr)
        }
        assertThrows(CloudTuneException::class.java) {
            RangeHeaderValidator.validateResumeResponse(resumeOffset, 200, validResumeCr)
        }

        val initialNonZeroOffset = rv.getLong("initialNonZeroOffset")
        val validInitialNonZeroCr = rv.getString("validInitialNonZeroContentRange")
        val mismatchedInitialNonZeroCr = rv.getString("mismatchedInitialNonZeroContentRange")
        RangeHeaderValidator.validateResumeResponse(initialNonZeroOffset, 206, validInitialNonZeroCr)
        assertThrows(CloudTuneException::class.java) {
            RangeHeaderValidator.validateResumeResponse(initialNonZeroOffset, 206, mismatchedInitialNonZeroCr)
        }
        assertThrows(CloudTuneException::class.java) {
            RangeHeaderValidator.validateResumeResponse(initialNonZeroOffset, 200, validInitialNonZeroCr)
        }

        val suffixHeader = rv.getString("suffixRangeHeader")
        val suffixTotal = rv.getLong("suffixTotalLength")
        val expectedSuffixStart = rv.getLong("expectedSuffixStart")
        val expectedSuffixEnd = rv.getLong("expectedSuffixEnd")
        val validSuffixCr = rv.getString("validSuffixContentRange")
        val mismatchedSuffixCr = rv.getString("mismatchedSuffixContentRange")
        val parsedSuffix = RangeHeaderValidator.parseRequestRange(suffixHeader)
        assertNotNull(parsedSuffix)
        assertTrue(parsedSuffix!!.isSuffix)
        assertEquals(suffixHeader, parsedSuffix.headerValue)
        assertFalse(RangeHeaderValidator.canWriteThroughToCache(suffixHeader))
        assertEquals(expectedSuffixStart to expectedSuffixEnd, parsedSuffix.resolve(suffixTotal))
        val validatedSuffixCr = RangeHeaderValidator.validateSuffixResponse(
            parsedSuffix.suffixLength!!,
            206,
            validSuffixCr
        )
        assertEquals(expectedSuffixStart, validatedSuffixCr.start)
        assertEquals(expectedSuffixEnd, validatedSuffixCr.end)
        assertEquals(suffixTotal, validatedSuffixCr.totalLength)
        assertThrows(CloudTuneException::class.java) {
            RangeHeaderValidator.validateSuffixResponse(parsedSuffix.suffixLength!!, 206, mismatchedSuffixCr)
        }
        assertThrows(CloudTuneException::class.java) {
            RangeHeaderValidator.validateSuffixResponse(parsedSuffix.suffixLength!!, 200, validSuffixCr)
        }
        assertNull(RangeHeaderValidator.parseRequestRange("bytes=-0"))

        // 7) Account SHA-256 bucket isolation
        val acctArr = root.getJSONArray("accountIsolation")
        for (i in 0 until acctArr.length()) {
            val entry = acctArr.getJSONObject(i)
            assertEquals(
                entry.getString("expectedBucketHash"),
                Cloud189Protocol.accountBucketHash(entry.getString("rawAccountId"))
            )
        }

        // 7) Unified media format table (.aiff/.aif/.dsf/.dff lossless parity & MIME types) + AtomicFileIO
        for ((name, expectedMime) in listOf(
            "Studio Master.aiff" to "audio/aiff",
            "Archive.AIF" to "audio/aiff",
            "SACD Layer.dsf" to "audio/dsf",
            "DirectStream.DFF" to "audio/dff",
            "Concert.flac" to "audio/flac",
            "Album.alac" to "audio/mp4"
        )) {
            assertTrue("Expected audio file for $name", Cloud189Protocol.isAudioFile(name))
            assertFalse("Expected non-video file for $name", Cloud189Protocol.isVideoFile(name))
            assertTrue("Expected lossless audio for $name", TrackSummary("id", name, "Music", 1024L).isLosslessAudio)
            assertEquals(expectedMime, Cloud189Protocol.guessMimeType(name))
        }
        assertTrue(Cloud189Protocol.isVideoFile("Live.mkv"))
        assertFalse(Cloud189Protocol.isAudioFile("Live.mkv"))
        assertEquals("video/x-matroska", Cloud189Protocol.guessMimeType("Live.mkv"))
        assertEquals("application/octet-stream", Cloud189Protocol.guessMimeType("notes.pdf"))

        val atomicRoot = Files.createTempDirectory("cloudtune-atomic-io").toFile()
        try {
            val target = File(atomicRoot, "nested/state.json")
            AtomicFileIO.writeText(target, """{"v":1}""")
            assertEquals("""{"v":1}""", target.readText(Charsets.UTF_8))
            AtomicFileIO.writeText(target, """{"v":2}""")
            assertEquals("""{"v":2}""", target.readText(Charsets.UTF_8))
            assertTrue(target.parentFile.list().orEmpty().none { it.endsWith(".tmp") })
        } finally {
            atomicRoot.deleteRecursively()
        }
    }

    @Test
    fun verifyLocalStreamServerProbeResumeAndRevocation(): Unit = runBlocking {
        val tempRoot = Files.createTempDirectory("cloudtune-stream-test").toFile()
        try {
            val cacheManager = CacheManager(tempRoot)
            val fullPayload = ByteArray(8192) { (it and 0xFF).toByte() }
            val didDropOnce = AtomicBoolean(false)

            val limiter = GlobalTransferLimiter(8)
            LocalStreamServer(
                limiter = limiter,
                opener = { _, rangeHeader ->
                    when {
                        rangeHeader == "bytes=0-1" -> OpenedUpstreamStream(
                            statusCode = 206,
                            headers = mapOf("content-length" to "2", "content-range" to "bytes 0-1/${fullPayload.size}"),
                            bodyStream = ByteArrayInputStream(fullPayload.copyOfRange(0, 2))
                        )
                        rangeHeader != null && (RangeHeaderValidator.parseRequestRange(rangeHeader)?.start ?: 0L) > 0L -> {
                            val start = RangeHeaderValidator.parseRequestRange(rangeHeader)!!.start.toInt()
                            val slice = fullPayload.copyOfRange(start, fullPayload.size)
                            OpenedUpstreamStream(
                                statusCode = 206,
                                headers = mapOf(
                                    "content-length" to slice.size.toString(),
                                    "content-range" to "bytes $start-${fullPayload.size - 1}/${fullPayload.size}"
                                ),
                                bodyStream = ByteArrayInputStream(slice)
                            )
                        }
                        didDropOnce.compareAndSet(false, true) -> {
                            val failingStream = object : InputStream() {
                                private var pos = 0
                                override fun read(): Int {
                                    if (pos >= 3000) throw java.io.IOException("simulated mid-stream drop")
                                    return fullPayload[pos++].toInt() and 0xFF
                                }
                            }
                            OpenedUpstreamStream(
                                statusCode = 200,
                                headers = mapOf("content-length" to fullPayload.size.toString()),
                                bodyStream = failingStream
                            )
                        }
                        else -> OpenedUpstreamStream(
                            statusCode = 200,
                            headers = mapOf("content-length" to fullPayload.size.toString()),
                            bodyStream = ByteArrayInputStream(fullPayload)
                        )
                    }
                }
            ).use { server ->
                val dest = cacheManager.cacheFile("track-1", "aria.flac")
                val streamUrl = server.registerSource(
                    StreamSourceRegistration(
                        accountHash = "acctA",
                        trackId = "track-1",
                        remoteUrl = "https://media.example.invalid/aria.flac",
                        cacheDestination = dest,
                        expectedSize = fullPayload.size.toLong(),
                        fileName = "aria.flac",
                        cacheLimitBytes = 256L * 1024L * 1024L
                    ),
                    cacheManager = cacheManager
                )

                // 1) bytes=0-1 probe MUST NOT cache 2 bytes
                val probeConn = (URL(streamUrl).openConnection() as HttpURLConnection).apply {
                    setRequestProperty("Range", "bytes=0-1")
                }
                assertEquals(206, probeConn.responseCode)
                assertEquals(2, probeConn.inputStream.use { it.readBytes().size })
                delay(50L)
                assertNull(cacheManager.existingCachedFile("track-1"))

                // 2) Full stream drops at 3000 bytes, resumes cleanly via 206, and writes full cache
                val fullConn = URL(streamUrl).openConnection() as HttpURLConnection
                assertEquals(200, fullConn.responseCode)
                val received = fullConn.inputStream.use { it.readBytes() }
                assertArrayEquals(fullPayload, received)
                delay(60L)
                val cached = cacheManager.existingCachedFile("track-1")
                assertNotNull(cached)
                assertArrayEquals(fullPayload, cached!!.readBytes())

                // 3) Upstream returning 200 OK or wrong start offset on non-zero resume MUST throw
                assertThrows(CloudTuneException::class.java) {
                    RangeHeaderValidator.validateResumeResponse(4096L, 200, null)
                }
                assertThrows(CloudTuneException::class.java) {
                    RangeHeaderValidator.validateResumeResponse(4096L, 206, "bytes 0-8191/8192")
                }

                // 4) Account logout revokes stream URL -> 404
                server.revokeAllSources("acctA")
                val revokedConn = URL(streamUrl).openConnection() as HttpURLConnection
                assertEquals(404, revokedConn.responseCode)
            }
        } finally {
            tempRoot.deleteRecursively()
        }
    }

    @Test
    fun verifyGlobalConcurrencyCapAccountIsolationAndDraftSafety(): Unit = runBlocking {
        // 1) GlobalTransferLimiter <= 8 peak concurrency
        val limiter = GlobalTransferLimiter(maxPermits = 8)
        val jobs = (0 until 24).map {
            async {
                limiter.withPermit {
                    delay(15L)
                }
            }
        }
        jobs.awaitAll()
        assertTrue(limiter.peakObservedPermits in 1..8)
        assertEquals(0, limiter.activePermits)

        // 2) 16 MiB timeout bypass + immediate stop on unsupported local codec
        val largeBytes = 48L * 1024L * 1024L
        assertTrue(PlaybackDecisionPolicy.shouldDownloadBeforePlayback(PlaybackMode.STREAM_CACHE, largeBytes, forceStreamProxy = false))
        assertFalse(PlaybackDecisionPolicy.shouldDownloadBeforePlayback(PlaybackMode.STREAM_CACHE, largeBytes, forceStreamProxy = true))

        val unsupported = PlaybackDecisionPolicy.classifyPlaybackFailure(
            fileName = "archive.ape",
            wasLoopbackStream = false,
            wasDownloadPhaseTimeout = false,
            isDecodeOrFormatUnsupported = true,
            priorAttemptCount = 0
        )
        assertTrue(unsupported is PlaybackFailureAction.StopImmediatelyUnsupportedCodec)

        // 3) Account A/B isolation
        val root = Files.createTempDirectory("cloudtune-acct-store").toFile()
        try {
            val store = AccountStore(root)
            val tA = listOf(TrackSummary("a1", "Alice.flac", "A", 100L))
            val tB = listOf(TrackSummary("b1", "Bob.flac", "B", 200L))
            store.saveLibrary("alice@example.invalid", tA)
            store.saveLibrary("bob@example.invalid", tB)
            assertEquals(tA, store.loadLibrary("alice@example.invalid"))
            assertEquals(tB, store.loadLibrary("bob@example.invalid"))
        } finally {
            root.deleteRecursively()
        }

        // 4) Draft settings isolation across module switches & converged theme state
        val fixture = RepresentativeFixture.fromJsonString(locateContractsFile("representative-state.json").readText(Charsets.UTF_8))
        val runtime = CloudTuneAppRuntime.fixture(SnapshotScene.MUSIC, fixture)
        assertEquals(2048L, runtime.committedSettings.cacheLimitMb)
        runtime.cacheLimitDraft = "64"
        runtime.activeModule = ModuleTab.VIDEO
        runtime.activeModule = ModuleTab.SETTINGS
        assertEquals("64", runtime.cacheLimitDraft)
        assertEquals(2048L, runtime.committedSettings.cacheLimitMb)
        assertFalse(runtime.commitCacheLimitDraftAsync())
        assertNotNull(runtime.settingsValidationError)
        assertEquals(runtime.settingsValidationError, runtime.statusMessage)
        assertEquals(2048L, runtime.committedSettings.cacheLimitMb)

        runtime.cacheLimitDraft = "4096"
        runtime.downloadThreadsDraft = "12"
        runtime.cacheThreadsDraft = "6"
        runtime.noteDraftEdited()
        assertNull(runtime.settingsValidationError)
        assertNull(runtime.statusMessage)
        assertTrue(runtime.commitCacheLimitDraftAsync())
        assertEquals(4096L, runtime.committedSettings.cacheLimitMb)
        assertEquals("12", runtime.downloadThreadsDraft)
        assertEquals("6", runtime.cacheThreadsDraft)
        assertTrue(runtime.commitTransferThreadsDraftAsync())
        assertEquals(12, runtime.committedSettings.downloadThreads)
        assertEquals(6, runtime.committedSettings.cacheThreads)

        runtime.updateAppearanceMode(AppearanceMode.DARK)
        runtime.updateDynamicColorEnabled(true)
        assertEquals(AppearanceMode.DARK, runtime.themeMode)
        assertEquals(AppearanceMode.DARK, runtime.committedSettings.appearanceMode)
        assertTrue(runtime.dynamicColorEnabled)
        assertTrue(runtime.committedSettings.dynamicColorEnabled)
        runtime.logout()
        assertEquals(AppearanceMode.DARK, runtime.themeMode)
        assertTrue(runtime.dynamicColorEnabled)

        // 5) PlaybackQueueResolver.upcomingPreview anchors library continuation on upNextQueue.last ?? currentTrack
        val qa = TrackSummary("qa", "01.flac", "A", 100L)
        val qb = TrackSummary("qb", "02.flac", "A", 100L)
        val qc = TrackSummary("qc", "03.flac", "A", 100L)
        val libABC = listOf(qa, qb, qc)
        val previewOff = PlaybackQueueResolver.upcomingPreview(
            currentTrack = qa,
            libraryTracks = libABC,
            upNextQueue = listOf(qc),
            shuffle = false,
            shuffleOrderIds = emptyList(),
            loopMode = LoopMode.OFF
        )
        assertEquals(listOf("qc"), previewOff.map { it.id })

        val previewAll = PlaybackQueueResolver.upcomingPreview(
            currentTrack = qa,
            libraryTracks = libABC,
            upNextQueue = listOf(qc),
            shuffle = false,
            shuffleOrderIds = emptyList(),
            loopMode = LoopMode.ALL
        )
        assertEquals(listOf("qc", "qb"), previewAll.map { it.id })
    }

    @Test
    fun verifyCrossRestartResumeAndMultiOriginWebCookieSync(): Unit = runBlocking {
        // 1) Multi-origin WebView cookies must reach api.cloud.189.cn during actual exchangeRedirectForSession
        var capturedApiCookieHeader: String? = null
        val innerTransport = HttpUrlConnectionTransport()
        val client = Cloud189Client(
            transport = object : CloudHttpTransport {
                override suspend fun send(
                    url: String,
                    method: String,
                    headers: Map<String, String>,
                    formBody: List<Pair<String, String>>?
                ): CloudHttpResponse {
                    val outgoingCookies = innerTransport.cookieHeaderFor(URI(url))
                    if (url.startsWith(Cloud189Constants.API_URL)) {
                        capturedApiCookieHeader = outgoingCookies
                    }
                    val body = """{"res_code":0,"loginName":"alice@example.invalid","sessionKey":"sk_web","sessionSecret":"ss_web","refreshToken":"rt_web"}"""
                    return CloudHttpResponse(200, emptyMap(), body.toByteArray(Charsets.UTF_8))
                }

                override fun importCookieHeader(domainUrl: String, cookieHeader: String?) {
                    innerTransport.importCookieHeader(domainUrl, cookieHeader)
                }

                override fun clearCookies() {
                    innerTransport.clearCookies()
                }
            }
        )
        client.importWebCookies("https://open.e.189.cn", "SONORK=sonork_01")
        client.importWebCookies("https://cloud.189.cn", "SESSIONID=sess_cloud_01")
        val exchanged = client.exchangeRedirectForSession(
            "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=CB_01"
        )
        assertEquals("sk_web", exchanged.activeSession.sessionKey)
        assertEquals("alice@example.invalid", client.accountName)
        assertNotNull(capturedApiCookieHeader)
        assertTrue(capturedApiCookieHeader!!.contains("SESSIONID=sess_cloud_01"))
        assertEquals("sonork_01", innerTransport.cookieHeaderFor(URI("https://open.e.189.cn/api/logbox")).substringAfter("SONORK=").substringBefore(";"))

        // 2) Cross-restart partial multi-part download restoration & resume
        val tempRoot = Files.createTempDirectory("cloudtune-resume-test").toFile()
        try {
            val store = AccountStore(tempRoot)
            val accountId = "alice@example.invalid"
            val paths = store.paths(accountId)
            val totalBytes = 600_000
            val fullData = ByteArray(totalBytes) { ((it * 13) and 0xFF).toByte() }
            val taskId = "download:android-resume-01"
            val safeKey = Cloud189Protocol.sanitizeFileName(taskId)
            val partsDir = File(paths.stagingDir, "$safeKey.parts").apply { mkdirs() }
            File(partsDir, "00.part").writeBytes(fullData.copyOfRange(0, 300_000))
            File(partsDir, "01.part").writeBytes(fullData.copyOfRange(300_000, 420_000))

            paths.transfersFile.writeText(
                """[{"taskId":"$taskId","accountId":"$accountId","trackId":"t1","fileName":"Concert.flac","relativeSubpath":"Concert.flac","totalSize":$totalBytes,"partCount":2,"state":"running"}]""",
                Charsets.UTF_8
            )

            val observedRanges = Collections.synchronizedList(mutableListOf<String>())
            val limiter = GlobalTransferLimiter(8)
            val engine = TransferEngine(
                limiter = limiter,
                opener = { _, rangeHeader ->
                    if (rangeHeader != null) observedRanges += rangeHeader
                    if (rangeHeader == "bytes=0-0") {
                        OpenedUpstreamStream(
                            statusCode = 206,
                            headers = mapOf("content-range" to "bytes 0-0/$totalBytes", "content-length" to "1"),
                            bodyStream = ByteArrayInputStream(fullData.copyOfRange(0, 1))
                        )
                    } else {
                        val parsed = RangeHeaderValidator.parseRequestRange(rangeHeader)!!
                        val start = parsed.start.toInt()
                        val end = (parsed.end ?: (totalBytes - 1).toLong()).toInt()
                        val slice = fullData.copyOfRange(start, end + 1)
                        OpenedUpstreamStream(
                            statusCode = 206,
                            headers = mapOf("content-range" to "bytes $start-$end/$totalBytes", "content-length" to slice.size.toString()),
                            bodyStream = ByteArrayInputStream(slice)
                        )
                    }
                },
                urlResolver = { "https://media.example.invalid/concert.flac" }
            )

            engine.restorePersistedDownloads(accountId, paths.stagingDir, paths.transfersFile)
            val restored = engine.snapshot().items.first { it.id == taskId }
            assertEquals("paused", restored.state)
            assertTrue(restored.canResume)
            assertEquals(420_000L, restored.transferredBytes)

            val exportedOut = File(tempRoot, "exported-Concert.flac")
            engine.resumeTransfer(taskId, paths.stagingDir, paths.transfersFile) { staged, _, _, _ ->
                staged.copyTo(exportedOut, overwrite = true)
                exportedOut.absolutePath
            }

            repeat(40) {
                if (engine.snapshot().items.firstOrNull { it.id == taskId }?.state == "completed") return@repeat
                delay(40L)
            }
            val finished = engine.snapshot().items.first { it.id == taskId }
            assertEquals("completed", finished.state)
            assertArrayEquals(fullData, exportedOut.readBytes())
            assertTrue(observedRanges.contains("bytes=420000-599999"))
            assertFalse(observedRanges.contains("bytes=0-299999"))
        } finally {
            tempRoot.deleteRecursively()
        }
    }

    @Test
    fun verifyRedirectCredentialGuardAndApiStatusValidation(): Unit = runBlocking {
        assertTrue(Cloud189Protocol.isTrustedTianyiOrigin(URI("https://api.cloud.189.cn/listFiles.action")))
        assertTrue(Cloud189Protocol.isTrustedTianyiOrigin(URI("https://open.e.189.cn/api/oauth2/refreshToken.do")))
        assertFalse(Cloud189Protocol.isTrustedTianyiOrigin(URI("http://api.cloud.189.cn/listFiles.action")))
        assertFalse(Cloud189Protocol.isTrustedTianyiOrigin(URI("https://cloud.189.cn.evil.invalid/steal")))
        assertFalse(Cloud189Protocol.isTrustedTianyiOrigin(URI("https://api.cloud.189.cn:8443/listFiles.action")))

        // Cross-origin 307 redirect on HttpUrlConnectionTransport MUST NOT forward headers, cookies, or POST body
        val evilHits = AtomicInteger(0)
        val evilServer = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val originServer = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val evilThread = Thread {
            runCatching {
                evilServer.accept().use { sock ->
                    evilHits.incrementAndGet()
                    sock.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".toByteArray())
                }
            }
        }.apply { isDaemon = true; start() }
        val originThread = Thread {
            runCatching {
                originServer.accept().use { sock ->
                    val buf = ByteArray(2048)
                    sock.getInputStream().read(buf)
                    val redirect = "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:${evilServer.localPort}/steal\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    sock.getOutputStream().write(redirect.toByteArray())
                }
            }
        }.apply { isDaemon = true; start() }

        try {
            val transport = HttpUrlConnectionTransport()
            transport.importCookieHeader("http://127.0.0.1:${originServer.localPort}", "SESSIONID=secret_sess")
            var threw = false
            try {
                transport.send(
                    url = "http://127.0.0.1:${originServer.localPort}/api/oauth2/refreshToken.do",
                    method = "POST",
                    headers = mapOf("SessionKey" to "sk_secret", "Signature" to "sig_secret"),
                    formBody = listOf("refreshToken" to "rt_super_secret")
                )
            } catch (_: CloudTuneException) {
                threw = true
            }
            assertTrue("Cross-origin untrusted redirect must throw CloudTuneException", threw)
            assertEquals(0, evilHits.get())
        } finally {
            runCatching { originServer.close() }
            runCatching { evilServer.close() }
            originThread.join(200)
            evilThread.join(200)
        }

        // Non-2xx JSON and missing fileListAO MUST throw in Cloud189Client
        fun mockClientReturning(status: Int, body: String): Cloud189Client = Cloud189Client(
            transport = object : CloudHttpTransport {
                override suspend fun send(
                    url: String,
                    method: String,
                    headers: Map<String, String>,
                    formBody: List<Pair<String, String>>?
                ): CloudHttpResponse {
                    if (url.contains("getSessionForPC.action")) {
                        val s = """{"res_code":0,"loginName":"alice@example.invalid","sessionKey":"sk","sessionSecret":"ss","refreshToken":"rt"}"""
                        return CloudHttpResponse(200, emptyMap(), s.toByteArray(Charsets.UTF_8))
                    }
                    return CloudHttpResponse(status, emptyMap(), body.toByteArray(Charsets.UTF_8))
                }
                override fun importCookieHeader(domainUrl: String, cookieHeader: String?) {}
                override fun clearCookies() {}
            }
        )

        val client502 = mockClientReturning(502, "{}")
        client502.exchangeRedirectForSession("https://m.cloud.189.cn/cb?paras=1")
        var threw502 = false
        try {
            client502.listRemoteFolder(null)
        } catch (_: CloudTuneException) {
            threw502 = true
        }
        assertTrue(threw502)

        val clientMissingAo = mockClientReturning(200, """{"res_code":0}""")
        clientMissingAo.exchangeRedirectForSession("https://m.cloud.189.cn/cb?paras=1")
        var threwMissingAo = false
        try {
            clientMissingAo.scanMusicLibrary("f1", "Music")
        } catch (_: CloudTuneException) {
            threwMissingAo = true
        }
        assertTrue(threwMissingAo)
    }

    @Test
    fun verifyCompletedDownloadIsolationZeroPiiCoalescingAndActiveStreamTeardown(): Unit = runBlocking {
        val tempRoot = Files.createTempDirectory("cloudtune-isolation-coalesce").toFile()
        try {
            val store = AccountStore(tempRoot)
            val payload = ByteArray(32_768) { (it and 0xFF).toByte() }
            val probeCalls = AtomicInteger(0)
            val limiter = GlobalTransferLimiter(8)
            val engine = TransferEngine(
                limiter = limiter,
                opener = { _, rangeHeader ->
                    if (rangeHeader == "bytes=0-0") {
                        probeCalls.incrementAndGet()
                        OpenedUpstreamStream(
                            statusCode = 206,
                            headers = mapOf("content-range" to "bytes 0-0/${payload.size}", "content-length" to "1"),
                            bodyStream = ByteArrayInputStream(payload.copyOfRange(0, 1))
                        )
                    } else {
                        delay(50L)
                        OpenedUpstreamStream(
                            statusCode = 200,
                            headers = mapOf("content-length" to payload.size.toString()),
                            bodyStream = ByteArrayInputStream(payload)
                        )
                    }
                },
                urlResolver = { "https://media.example.invalid/shared.flac" }
            )

            // 1) Zero PII in transfers.json and completed download purged on cancelAll
            val aliceId = "alice_private_13800138000@example.invalid"
            val alicePaths = store.paths(aliceId)
            val track = TrackSummary("t-shared", "Shared.flac", "Music", payload.size.toLong())
            val outFile = File(tempRoot, "out-Shared.flac")
            val dlId = engine.enqueueExportDownload(
                accountId = aliceId,
                track = track,
                relativeSubpath = "Shared.flac",
                parallelThreads = 2,
                stagingRootDir = alicePaths.stagingDir,
                manifestsFile = alicePaths.transfersFile
            ) { staged, _, _, _ ->
                staged.copyTo(outFile, overwrite = true)
                outFile.absolutePath
            }
            if (alicePaths.transfersFile.isFile) {
                val raw = alicePaths.transfersFile.readText(Charsets.UTF_8)
                assertFalse(raw.contains("alice_private"))
                assertFalse(raw.contains("13800138000"))
            }
            repeat(40) {
                if (engine.snapshot().items.firstOrNull { it.id == dlId }?.state == "completed") return@repeat
                delay(30L)
            }
            assertEquals("completed", engine.snapshot().items.first { it.id == dlId }.state)
            engine.cancelAll(aliceId)
            assertTrue("Completed downloads for Alice must be cleared on logout", engine.snapshot().items.isEmpty())

            // 2) Concurrent prefetch + playback downloadTrackToCache coalesces onto single upstream download
            probeCalls.set(0)
            val cm = CacheManager(alicePaths.cacheDir)
            val d1 = async {
                engine.downloadTrackToCache(track, cm, 4, 256L * 1024L * 1024L, "prefetch", alicePaths.bucketHash)
            }
            delay(15L)
            val d2 = async {
                engine.downloadTrackToCache(track, cm, 8, 256L * 1024L * 1024L, "playback", alicePaths.bucketHash)
            }
            val f1 = d1.await()
            val f2 = d2.await()
            assertEquals(f1.canonicalPath, f2.canonicalPath)
            assertArrayEquals(payload, f1.readBytes())
            assertEquals(1, probeCalls.get())

            // Cancelling prefetch right before starting playback MUST NOT delete active .parts shards
            val cancelRaceTrack = TrackSummary("t-cancel-race", "CancelRace.flac", "Music", payload.size.toLong())
            val isolatedScope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO)
            val cancelledPrefetch = isolatedScope.async {
                engine.downloadTrackToCache(cancelRaceTrack, cm, 2, 256L * 1024L * 1024L, "prefetch", alicePaths.bucketHash)
            }
            delay(15L)
            cancelledPrefetch.cancel()
            val freshPlaybackFile = engine.downloadTrackToCache(
                cancelRaceTrack,
                cm,
                4,
                256L * 1024L * 1024L,
                "playback",
                alicePaths.bucketHash
            )
            runCatching { cancelledPrefetch.await() }
            assertArrayEquals(payload, freshPlaybackFile.readBytes())

            // 3) LocalStreamServer accept-loop isolation on opener error + immediate active stream teardown on revokeAllSources
            val failNextOpen = AtomicBoolean(true)
            val firstChunkRead = AtomicBoolean(false)
            LocalStreamServer(
                limiter = limiter,
                opener = { _, _ ->
                    if (failNextOpen.compareAndSet(true, false)) {
                        throw IOException("upstream connect failure")
                    }
                    OpenedUpstreamStream(
                        statusCode = 200,
                        headers = mapOf("content-length" to payload.size.toString()),
                        bodyStream = object : InputStream() {
                            private var idx = 0
                            override fun read(): Int {
                                if (idx < 4096) {
                                    val b = payload[idx++].toInt() and 0xFF
                                    if (idx == 4096) firstChunkRead.set(true)
                                    return b
                                }
                                Thread.sleep(8_000L)
                                return if (idx < payload.size) (payload[idx++].toInt() and 0xFF) else -1
                            }
                        }
                    )
                }
            ).use { server ->
                val liveDest = cm.cacheFile("live-2", "live2.flac")
                val liveUrl = server.registerSource(
                    StreamSourceRegistration(
                        accountHash = "acctLive",
                        trackId = "live-2",
                        remoteUrl = "https://media.example.invalid/live2.flac",
                        cacheDestination = liveDest,
                        expectedSize = payload.size.toLong(),
                        fileName = "live2.flac",
                        cacheLimitBytes = 256L * 1024L * 1024L
                    ),
                    cacheManager = cm
                )
                // First request hits IOException -> 502 without killing accept loop
                val errConn = URL(liveUrl).openConnection() as HttpURLConnection
                assertEquals(502, errConn.responseCode)

                // Second request streams 4096 bytes then blocks; revokeAllSources tears it down immediately without caching
                val readerJob = async(kotlinx.coroutines.Dispatchers.IO) {
                    runCatching {
                        (URL(liveUrl).openConnection() as HttpURLConnection).inputStream.use { it.readBytes().size }
                    }.getOrDefault(0)
                }
                repeat(50) {
                    if (firstChunkRead.get()) return@repeat
                    delay(20L)
                }
                val t0 = System.currentTimeMillis()
                server.revokeAllSources("acctLive")
                val received = readerJob.await()
                val elapsedMs = System.currentTimeMillis() - t0
                assertTrue("Active stream should tear down promptly (elapsed=${elapsedMs}ms)", elapsedMs < 2000L)
                assertTrue(received < payload.size)
                delay(50L)
                assertNull(cm.existingCachedFile("live-2"))
            }
        } finally {
            tempRoot.deleteRecursively()
        }
    }

    @Test
    fun verifyAnonymousAccountKeySubfolderExportRetryCapAndServiceSurvival(): Unit = runBlocking {
        val tempRoot = Files.createTempDirectory("cloudtune-vm-android").toFile()
        try {
            val sessionIdx = AtomicInteger(1)
            val failDownloadUrl = AtomicBoolean(false)
            val downloadUrlCalls = AtomicInteger(0)

            val mockTransport = object : CloudHttpTransport {
                override suspend fun send(
                    url: String,
                    method: String,
                    headers: Map<String, String>,
                    formBody: List<Pair<String, String>>?
                ): CloudHttpResponse {
                    return when {
                        url.contains("getSessionForPC.action") -> {
                            val idx = sessionIdx.get()
                            val b = """{"res_code":0,"accessToken":"at_$idx","refreshToken":"rt_$idx","sessionKey":"sk_$idx","sessionSecret":"ss_$idx"}"""
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        url.contains("listFiles.action") -> {
                            val b = when {
                                url.contains("folderId=cd1") ->
                                    """{"res_code":0,"fileListAO":{"count":1,"folderList":[],"fileList":[{"id":"t-cd1","name":"01. Song.flac","size":1024}]}}"""
                                url.contains("folderId=cd2") ->
                                    """{"res_code":0,"fileListAO":{"count":1,"folderList":[],"fileList":[{"id":"t-cd2","name":"01. Song.flac","size":1024}]}}"""
                                else ->
                                    """{"res_code":0,"fileListAO":{"count":2,"folderList":[{"id":"cd1","name":"CD 1"},{"id":"cd2","name":"CD 2"}],"fileList":[]}}"""
                            }
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        url.contains("getFileDownloadUrl.action") -> {
                            if (url.contains("fileId=t-fail")) {
                                downloadUrlCalls.incrementAndGet()
                                if (failDownloadUrl.get()) {
                                    throw CloudTuneException("transient network glitch")
                                }
                            }
                            val b = """{"res_code":0,"fileDownloadUrl":"https://media.example.invalid/song.mp3"}"""
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        else -> CloudHttpResponse(200, emptyMap(), "{}".toByteArray(Charsets.UTF_8))
                    }
                }
                override fun importCookieHeader(domainUrl: String, cookieHeader: String?) {}
                override fun clearCookies() {}
            }

            val store = AccountStore(tempRoot)
            val runtime = CloudTuneAppRuntime(
                appContext = null,
                cloudClient = Cloud189Client(mockTransport),
                accountStore = store,
                limiter = GlobalTransferLimiter(8),
                enableLiveLoops = true
            )
            runtime.retryBaseDelayMs = 5L
            val primaryVm = CloudTuneViewModel(runtime = runtime)

            // 1) Two accounts omitting loginName get display "天翼云盘用户" with distinct storage keys
            sessionIdx.set(1)
            runtime.completeEmbeddedWebLogin("https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=1", emptyMap())
            repeat(40) { if (runtime.isAuthenticated && runtime.browser != null) return@repeat; delay(15L) }
            assertEquals("天翼云盘用户", runtime.accountName)
            val key1 = runtime.accountStorageKey
            assertNotNull("key1 should be assigned", key1)
            assertFalse("key1 should not be default display name", key1 == "天翼云盘用户")
            store.saveLibrary(key1!!, listOf(TrackSummary("u1", "User1.flac", "CD 1", 100L)))

            runtime.logout()
            sessionIdx.set(2)
            runtime.completeEmbeddedWebLogin("https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=2", emptyMap())
            repeat(40) { if (runtime.isAuthenticated && runtime.browser != null) return@repeat; delay(15L) }
            val key2 = runtime.accountStorageKey
            assertNotNull("key2 should be assigned", key2)
            assertFalse("key1 and key2 must differ: $key1 vs $key2", key1 == key2)
            assertTrue("Account 2 library must be empty, got ${runtime.tracks}", runtime.tracks.isEmpty())

            // 2) Real subfolder names & distinct relative export subpaths
            runtime.browseTo("cd1", listOf(BreadcrumbItem.ROOT, BreadcrumbItem("cd1", "CD 1")))
            repeat(40) { if (runtime.browser?.currentFolderId == "cd1") return@repeat; delay(15L) }
            assertEquals("CD 1", runtime.browser?.currentFolderName)
            assertEquals("CD 1", runtime.browser?.audioFiles?.firstOrNull()?.folderPath)

            runtime.enqueueCurrentFolderDownloadWithExporter { _, subpath, _, _ -> subpath }
            repeat(40) {
                if (runtime.downloadTransfers.any { it.path == "CD 1/01. Song.flac" }) return@repeat
                delay(20L)
            }
            runtime.browseTo("cd2", listOf(BreadcrumbItem.ROOT, BreadcrumbItem("cd2", "CD 2")))
            repeat(40) { if (runtime.browser?.currentFolderId == "cd2") return@repeat; delay(15L) }
            assertEquals("CD 2", runtime.browser?.currentFolderName)
            runtime.enqueueCurrentFolderDownloadWithExporter { _, subpath, _, _ -> subpath }
            repeat(40) {
                if (runtime.downloadTransfers.any { it.path == "CD 2/01. Song.flac" }) return@repeat
                delay(20L)
            }
            val queuedPaths = runtime.downloadTransfers.mapNotNull { it.path }.toSet()
            assertTrue("Expected CD 1 subpath in $queuedPaths", queuedPaths.contains("CD 1/01. Song.flac"))
            assertTrue("Expected CD 2 subpath in $queuedPaths", queuedPaths.contains("CD 2/01. Song.flac"))

            // 3) Retry cap enforcement (1 initial + 6 retries = 7 total, never infinite)
            runtime.updatePlaybackMode(PlaybackMode.STREAM_CACHE)
            failDownloadUrl.set(true)
            downloadUrlCalls.set(0)
            val transientTrack = TrackSummary("t-fail", "Transient.mp3", "CD 2", 1024L)
            runtime.playTrack(transientTrack)
            repeat(80) {
                if (runtime.statusMessage?.contains("已停止自动重试") == true) return@repeat
                delay(20L)
            }
            assertEquals(1 + PlaybackDecisionPolicy.MAX_RECOVERY_ATTEMPTS, downloadUrlCalls.get())
            assertTrue("Expected retry stop status, got: ${runtime.statusMessage}", runtime.statusMessage?.contains("已停止自动重试") == true)

            // ExoPlayer network "Source error" MUST NOT be misclassified as unsupported local codec
            runtime.handlePlaybackError(TrackSummary("t-src", "Network.flac", "CD 1", 1024L), "Source error", wasLoopback = false)
            assertFalse("Source error must not claim codec unsupported: ${runtime.statusMessage}", runtime.statusMessage?.contains("不受系统解码器支持") == true)
            runtime.openVideoInApp(TrackSummary("v-1", "Clip.mp4", "CD 1", 2048L))

            // 4) Multi-ViewModel attach/detach ref-counting + ViewModel.onCleared() survival
            val secondaryVm = CloudTuneViewModel(runtime = runtime)
            secondaryVm.onCleared()
            failDownloadUrl.set(false)
            val q1 = TrackSummary("q1", "Queue1.mp3", "CD 1", 1024L)
            val q2 = TrackSummary("q2", "Queue2.mp3", "CD 1", 1024L)
            runtime.tracks = listOf(q1, q2)
            runtime.shuffle = false
            runtime.playTrack(q1)
            repeat(40) { if (runtime.currentTrackId == "q1") return@repeat; delay(15L) }

            primaryVm.onCleared()
            assertNotNull("SkipNext callback must survive ViewModel.onCleared()", PlaybackSessionBridge.onSkipNext)
            assertNotNull("LocalStreamServer must remain open after ViewModel.onCleared()", runtime.streamServer)
            // Verify LocalStreamServer port is still actively accepting TCP connections after onCleared()
            val probeAfterClear = URL("http://127.0.0.1:${runtime.streamServer!!.port}/not-a-token").openConnection() as HttpURLConnection
            assertEquals(404, probeAfterClear.responseCode)

            PlaybackSessionBridge.onSkipNext?.invoke()
            repeat(40) { if (runtime.currentTrackId == "q2") return@repeat; delay(15L) }
            assertEquals("q2", runtime.currentTrackId)
            assertTrue(
                "Expected loopback URL, got ${runtime.lastPreparedPlaybackUrl}",
                runtime.lastPreparedPlaybackUrl?.startsWith("http://127.0.0.1:${runtime.streamServer!!.port}/stream/") == true
            )

            runtime.logout()
            runtime.streamServer?.close()
            Unit
        } finally {
            tempRoot.deleteRecursively()
        }
    }

    @Test
    fun verifyBootstrapSingleFlightDecoupledBrowsersActiveTrackAndCheckedSettings(): Unit = runBlocking {
        val tempRoot = Files.createTempDirectory("cloudtune-s1b-contract").toFile()
        try {
            val refreshCalls = AtomicInteger(0)
            val transport = object : CloudHttpTransport {
                override suspend fun send(
                    url: String,
                    method: String,
                    headers: Map<String, String>,
                    formBody: List<Pair<String, String>>?
                ): CloudHttpResponse {
                    return when {
                        url.contains("refreshToken.do") -> {
                            refreshCalls.incrementAndGet()
                            delay(40L)
                            val b = """{"res_code":0,"accessToken":"at_boot","refreshToken":"rt_boot_2"}"""
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        url.contains("getSessionForPC.action") -> {
                            val b = """{"res_code":0,"loginName":"audiophile@example.invalid","sessionKey":"sk_boot","sessionSecret":"ss_boot","refreshToken":"rt_boot_2"}"""
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        url.contains("listFiles.action") -> {
                            val b = when {
                                url.contains("folderId=jazz") ->
                                    """{"res_code":0,"fileListAO":{"count":1,"folderList":[],"fileList":[{"id":"cloud-jazz","name":"Solo.flac","size":2048}]}}"""
                                url.contains("folderId=video") ->
                                    """{"res_code":0,"fileListAO":{"count":1,"folderList":[],"fileList":[{"id":"vid-live","name":"Live.mp4","size":4096}]}}"""
                                else ->
                                    """{"res_code":0,"fileListAO":{"count":2,"folderList":[{"id":"jazz","name":"Jazz"},{"id":"video","name":"Video"}],"fileList":[]}}"""
                            }
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        url.contains("getFileDownloadUrl.action") -> {
                            val b = """{"res_code":0,"fileDownloadUrl":"https://media.example.invalid/solo.flac"}"""
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        else -> CloudHttpResponse(200, emptyMap(), "{}".toByteArray(Charsets.UTF_8))
                    }
                }
                override fun importCookieHeader(domainUrl: String, cookieHeader: String?) {}
                override fun clearCookies() {}
            }

            var savedCred = PersistedRefreshCredential.createOrNull("rt_boot_1", "audiophile@example.invalid")
            val memCredStore = object : CredentialStore {
                override fun loadCredential(): PersistedRefreshCredential? = savedCred
                override fun saveCredential(credential: PersistedRefreshCredential) { savedCred = credential }
                override fun clearCredential() { savedCred = null }
            }

            val store = AccountStore(tempRoot)
            val runtime = CloudTuneAppRuntime(
                appContext = null,
                cloudClient = Cloud189Client(transport),
                accountStore = store,
                credentialStore = memCredStore,
                limiter = GlobalTransferLimiter(8),
                enableLiveLoops = true
            )

            // 1) Concurrent cold-start bootstrap() from MainActivity + PlaybackService exchanges token ONCE
            listOf(
                runtime.bootstrap(),
                runtime.bootstrap(),
                runtime.bootstrap(),
                runtime.bootstrap()
            ).awaitAll()
            assertEquals("Concurrent bootstrap must refresh token only once", 1, refreshCalls.get())
            assertTrue(runtime.isAuthenticated)

            // 2) Cloud & Video browsers stay decoupled; playing ad-hoc cloud track survives folder changes and NEVER uses accountName as artist
            runtime.browseTo(BrowserScope.CLOUD, "jazz", listOf(BreadcrumbItem.ROOT, BreadcrumbItem("jazz", "Jazz")))
            runtime.browseTo(BrowserScope.VIDEO, "video", listOf(BreadcrumbItem.ROOT, BreadcrumbItem("video", "Video")))
            repeat(40) {
                if (runtime.cloudBrowser.payload?.currentFolderId == "jazz" && runtime.videoBrowser.payload?.currentFolderId == "video") return@repeat
                delay(15L)
            }
            val jazzTrack = runtime.cloudBrowser.payload!!.audioFiles.first()
            runtime.updatePlaybackMode(PlaybackMode.STREAM_CACHE)
            runtime.playTrack(jazzTrack)
            repeat(40) { if (runtime.currentTrackId == "cloud-jazz") return@repeat; delay(15L) }
            assertEquals("cloud-jazz", runtime.currentTrack?.id)
            assertNull("Account email must never be used as artist fallback", runtime.nowPlayingArtist)

            runtime.browseTo(BrowserScope.CLOUD, null, listOf(BreadcrumbItem.ROOT))
            repeat(40) { if (runtime.cloudBrowser.payload?.isRoot == true) return@repeat; delay(15L) }
            assertEquals("Active track must survive cloud folder navigation", "cloud-jazz", runtime.currentTrack?.id)
            assertEquals("Video browser must stay on video folder", "video", runtime.videoBrowser.payload?.currentFolderId)

            // 3) Queue availability syncs with LoopMode.OFF vs Play Next queue
            val s1 = TrackSummary("s1", "01.flac", "Album", 100L)
            val s2 = TrackSummary("s2", "02.flac", "Album", 100L)
            runtime.tracks = listOf(s1, s2)
            runtime.shuffle = false
            runtime.loopMode = LoopMode.OFF
            runtime.playTrack(s2)
            repeat(40) { if (runtime.currentTrackId == "s2") return@repeat; delay(15L) }
            assertFalse("End of queue with LoopMode.OFF must disable skip next", PlaybackSessionBridge.canSkipNext)
            assertTrue("Second item must allow skip previous", PlaybackSessionBridge.canSkipPrevious)
            runtime.playNext(s1)
            assertTrue("Enqueuing Play Next must enable skip next immediately", PlaybackSessionBridge.canSkipNext)

            // 4) Settings write failure keeps draft & committedSettings intact and reports error instead of claiming success
            val acctPaths = store.paths(runtime.accountStorageKey!!)
            acctPaths.settingsFile.delete()
            acctPaths.settingsFile.mkdirs()
            val prevLimit = runtime.committedSettings.cacheLimitMb
            runtime.cacheLimitDraft = "4096"
            runtime.commitCacheLimitDraft()
            assertTrue(runtime.statusMessage?.contains("保存设置失败") == true)
            runtime.statusMessage = null
            assertFalse("Async write failure must return false", runtime.commitCacheLimitDraftAsync())
            assertEquals(prevLimit, runtime.committedSettings.cacheLimitMb)
            assertEquals("4096", runtime.cacheLimitDraft)
            assertTrue(runtime.statusMessage?.contains("保存设置失败") == true)
            runtime.downloadThreadsDraft = "10"
            runtime.cacheThreadsDraft = "5"
            assertFalse("Async thread write failure must return false", runtime.commitTransferThreadsDraftAsync())
            assertEquals("传输中", TransferStatus("d1", "a.flac", "download", "running").localizedStateLabel)
            assertEquals("已暂停", TransferStatus("d2", "a.flac", "download", "paused").localizedStateLabel)

            // 5) No-proxy external video never leaks raw https:// URL, and logout resets UI dialog/module state
            val noProxyRuntime = CloudTuneAppRuntime(
                appContext = null,
                cloudClient = Cloud189Client(transport),
                accountStore = store,
                credentialStore = memCredStore,
                limiter = GlobalTransferLimiter(8),
                enableLiveLoops = false,
                ioDispatcher = Dispatchers.IO
            )
            noProxyRuntime.bootstrap().await()
            noProxyRuntime.cacheLimitDraft = "8192"
            assertFalse("Dispatchers.IO write failure must return false", noProxyRuntime.commitCacheLimitDraftAsync())

            runtime.activeModule = ModuleTab.SETTINGS
            runtime.isShowingWebLoginDialog = true
            runtime.logout()
            assertEquals(ModuleTab.MUSIC, runtime.activeModule)
            assertFalse(runtime.isShowingWebLoginDialog)
            runtime.streamServer?.close()
            Unit
        } finally {
            tempRoot.deleteRecursively()
        }
    }

    @Test
    fun verifyLogoutBootstrapRaceBrowserGenerationLoginWarningWriteThroughAndQueueConsumption(): Unit = runBlocking {
        val tempRoot = Files.createTempDirectory("cloudtune-r14-android").toFile()
        try {
            var slowFolderEntered = CompletableDeferred<Unit>()
            var slowFolderRelease = CompletableDeferred<Unit>()
            val transport = object : CloudHttpTransport {
                override suspend fun send(
                    url: String,
                    method: String,
                    headers: Map<String, String>,
                    formBody: List<Pair<String, String>>?
                ): CloudHttpResponse {
                    return when {
                        url.contains("refreshToken.do") -> {
                            val b = """{"res_code":0,"accessToken":"at_r14","refreshToken":"rt_r14_next"}"""
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        url.contains("getSessionForPC.action") -> {
                            val b = """{"res_code":0,"loginName":"r14@example.invalid","sessionKey":"sk_r14","sessionSecret":"ss_r14","refreshToken":"rt_r14_next"}"""
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        url.contains("listFiles.action") -> {
                            when {
                                url.contains("folderId=slow-a") -> {
                                    slowFolderEntered.complete(Unit)
                                    slowFolderRelease.await()
                                    val b = """{"res_code":0,"fileListAO":{"count":1,"folderList":[],"fileList":[{"id":"slow-1","name":"Slow.flac","size":1024}]}}"""
                                    CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                                }
                                url.contains("folderId=fast-b") -> {
                                    val b = """{"res_code":0,"fileListAO":{"count":1,"folderList":[],"fileList":[{"id":"fast-1","name":"Fast.flac","size":1024}]}}"""
                                    CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                                }
                                else -> {
                                    val b = """{"res_code":0,"fileListAO":{"count":0,"folderList":[],"fileList":[]}}"""
                                    CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                                }
                            }
                        }
                        url.contains("getFileDownloadUrl.action") -> {
                            val b = """{"res_code":0,"fileDownloadUrl":"https://media.example.invalid/track.flac"}"""
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8))
                        }
                        else -> CloudHttpResponse(200, emptyMap(), "{}".toByteArray(Charsets.UTF_8))
                    }
                }
                override fun importCookieHeader(domainUrl: String, cookieHeader: String?) {}
                override fun clearCookies() {}
            }

            val savedCred = java.util.concurrent.atomic.AtomicReference(
                PersistedRefreshCredential.createOrNull("rt_r14_init", "r14@example.invalid")
            )
            val failSave = AtomicBoolean(false)
            val delayClearMs = AtomicInteger(0)
            val gatedCredStore = object : CredentialStore {
                override fun loadCredential(): PersistedRefreshCredential? = savedCred.get()
                override fun saveCredential(credential: PersistedRefreshCredential) {
                    if (failSave.get()) {
                        throw CloudTuneException("Keystore 写入受阻")
                    }
                    savedCred.set(credential)
                }
                override fun clearCredential() {
                    val waitMs = delayClearMs.get()
                    if (waitMs > 0) {
                        Thread.sleep(waitMs.toLong())
                    }
                    savedCred.set(null)
                }
            }

            val store = AccountStore(tempRoot)
            val ioRuntime = CloudTuneAppRuntime(
                appContext = null,
                cloudClient = Cloud189Client(transport),
                accountStore = store,
                credentialStore = gatedCredStore,
                limiter = GlobalTransferLimiter(8),
                enableLiveLoops = false,
                ioDispatcher = Dispatchers.IO
            )

            // Issue 2a: logout() followed immediately by bootstrap() awaits cookieCleanupDeferred and NEVER restores logged-out session
            ioRuntime.bootstrap().await()
            assertTrue(ioRuntime.isAuthenticated)
            delayClearMs.set(80)
            ioRuntime.logout()
            val racingBoot = ioRuntime.bootstrap()
            racingBoot.await()
            ioRuntime.cookieCleanupDeferred?.await()
            assertFalse("Immediate bootstrap() after logout() must not resurrect session", ioRuntime.isAuthenticated)
            assertNull(savedCred.get())

            // Issue 2b: logout() with slow cookieCleanupDeferred followed immediately by completeEmbeddedWebLogin()
            // MUST NOT let stale cookieCleanupDeferred wipe the newly saved login credential or let bootstrap() race
            savedCred.set(PersistedRefreshCredential.createOrNull("rt_r14_seed2", "r14@example.invalid"))
            delayClearMs.set(0)
            ioRuntime.bootstrap().await()
            assertTrue(ioRuntime.isAuthenticated)
            delayClearMs.set(80)
            ioRuntime.logout()
            val supersededBoot = ioRuntime.bootstrap()
            ioRuntime.completeEmbeddedWebLogin(
                "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=relogin",
                emptyMap()
            )
            repeat(60) { if (ioRuntime.isAuthenticated) return@repeat; delay(20L) }
            runCatching { supersededBoot.await() }
            ioRuntime.cookieCleanupDeferred?.await()
            assertTrue("Rapid re-login after logout must stay authenticated", ioRuntime.isAuthenticated)
            assertNotNull("Prior logout cleanup must NOT delete newly saved login credential", savedCred.get())
            delayClearMs.set(0)

            // Issue 8: Credential save warning preserved in completeEmbeddedWebLogin statusMessage
            val rt = CloudTuneAppRuntime(
                appContext = null,
                cloudClient = Cloud189Client(transport),
                accountStore = store,
                credentialStore = gatedCredStore,
                limiter = GlobalTransferLimiter(8),
                enableLiveLoops = false
            )
            failSave.set(true)
            rt.completeEmbeddedWebLogin(
                "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=warn",
                emptyMap()
            )
            repeat(40) { if (rt.isAuthenticated) return@repeat; delay(15L) }
            assertTrue(rt.isAuthenticated)
            assertTrue("Expected login success prefix, got: ${rt.statusMessage}", rt.statusMessage?.contains("天翼官方网页一键登录成功") == true)
            assertTrue("Expected credential warning in statusMessage, got: ${rt.statusMessage}", rt.statusMessage?.contains("登录凭据保存异常") == true)
            failSave.set(false)

            // Issue 3: Out-of-order browseTo keeps newer folder, and post-logout completion does not mutate state
            rt.browseTo(BrowserScope.CLOUD, "slow-a", listOf(BreadcrumbItem.ROOT, BreadcrumbItem("slow-a", "SlowA")))
            withTimeout(5000L) { slowFolderEntered.await() }
            rt.browseTo(BrowserScope.CLOUD, "fast-b", listOf(BreadcrumbItem.ROOT, BreadcrumbItem("fast-b", "FastB")))
            assertEquals("fast-b", rt.cloudBrowser.payload?.currentFolderId)
            slowFolderRelease.complete(Unit)
            delay(30L)
            assertEquals("Older folder response must not overwrite newer folder", "fast-b", rt.cloudBrowser.payload?.currentFolderId)
            assertNull(rt.busyLabel)

            slowFolderEntered = CompletableDeferred()
            slowFolderRelease = CompletableDeferred()
            rt.browseTo(BrowserScope.VIDEO, "slow-a", listOf(BreadcrumbItem.ROOT, BreadcrumbItem("slow-a", "SlowA")))
            withTimeout(5000L) { slowFolderEntered.await() }
            rt.logout()
            slowFolderRelease.complete(Unit)
            rt.cookieCleanupDeferred?.await()
            delay(30L)
            assertNull(rt.videoBrowser.payload)
            assertNull(rt.busyLabel)

            // Re-login for write-through and queue consumption checks
            rt.completeEmbeddedWebLogin(
                "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=ok",
                emptyMap()
            )
            repeat(40) { if (rt.isAuthenticated) return@repeat; delay(15L) }
            val acctKey = rt.accountStorageKey!!

            // Issue 5: handleWriteThroughCompleted refreshes cacheUsageBytes & metadata for active track, and rejects stale track/generation
            val songA = TrackSummary("wt-a", "SongA.flac", "AlbumA", 128L)
            val songB = TrackSummary("wt-b", "CurrentSongB.flac", "AlbumB", 1024L)
            rt.updatePlaybackMode(PlaybackMode.STREAM_CACHE)
            rt.playTrack(songA)
            repeat(40) { if (rt.currentTrackId == "wt-a") return@repeat; delay(15L) }
            rt.cacheUsageBytes = 999_999L
            val missingOrRawFile = File(tempRoot, "wt-a.flac")
            rt.handleWriteThroughCompleted(
                accountHash = Cloud189Protocol.accountBucketHash(acctKey),
                trackId = "wt-a",
                localFile = missingOrRawFile
            )
            assertEquals(0L, rt.cacheUsageBytes)
            assertEquals("SongA.flac", rt.nowPlayingTitle)

            rt.playTrack(songB)
            repeat(40) { if (rt.currentTrackId == "wt-b") return@repeat; delay(15L) }
            rt.handleWriteThroughCompleted(
                accountHash = Cloud189Protocol.accountBucketHash(acctKey),
                trackId = "wt-a",
                localFile = missingOrRawFile
            )
            assertEquals("CurrentSongB.flac", rt.nowPlayingTitle)

            // Issue 12 & 13: togglePlayback() consumes upNextQueue first when currentTrack == null; playFromUpcomingQueue removes manual item
            rt.activeTrack = null
            rt.currentTrackId = null
            val lib1 = TrackSummary("lib-1", "Lib1.flac", "Music", 512L)
            val lib2 = TrackSummary("lib-2", "Lib2.flac", "Music", 512L)
            val queuedCloud = TrackSummary("q-cloud", "QueuedCloud.flac", "Cloud", 512L)
            val manual2 = TrackSummary("manual-2", "Manual2.flac", "Cloud", 512L)
            rt.tracks = listOf(lib1, lib2)
            rt.shuffle = false
            rt.loopMode = LoopMode.OFF
            rt.playNext(manual2)
            rt.playNext(queuedCloud)
            assertEquals(listOf("q-cloud", "manual-2"), rt.upNextQueue.map { it.id })

            rt.togglePlayback()
            repeat(40) { if (rt.currentTrackId == "q-cloud") return@repeat; delay(15L) }
            assertEquals("q-cloud", rt.currentTrack?.id)
            assertEquals(listOf("manual-2"), rt.upNextQueue.map { it.id })

            rt.playFromUpcomingQueue(manual2)
            repeat(40) { if (rt.currentTrackId == "manual-2") return@repeat; delay(15L) }
            assertEquals("manual-2", rt.currentTrack?.id)
            assertTrue(rt.upNextQueue.isEmpty())

            rt.playAdjacent(1)
            repeat(40) { if (rt.currentTrackId == "lib-1") return@repeat; delay(15L) }
            assertEquals("lib-1", rt.currentTrack?.id)
            Unit
        } finally {
            tempRoot.deleteRecursively()
        }
    }

    @Test
    fun verifySessionEpochGuardSingleSourceRevokeAndPinnedExportTreeUri(): Unit = runBlocking {
        val tempRoot = Files.createTempDirectory("cloudtune-slice0-parity").toFile()
        try {
            // 1) Cloud189Client sessionEpoch guard prevents stale expectedEpoch cleanup from wiping a newer session
            val currentLogin = java.util.concurrent.atomic.AtomicReference("alice@example.invalid")
            val epochClient = Cloud189Client(
                transport = object : CloudHttpTransport {
                    override suspend fun send(
                        url: String,
                        method: String,
                        headers: Map<String, String>,
                        formBody: List<Pair<String, String>>?
                    ): CloudHttpResponse {
                        val user = currentLogin.get()
                        val body = """{"res_code":0,"loginName":"$user","sessionKey":"sk_$user","sessionSecret":"ss_$user","refreshToken":"rt_$user"}"""
                        return CloudHttpResponse(200, emptyMap(), body.toByteArray(Charsets.UTF_8))
                    }
                    override fun importCookieHeader(domainUrl: String, cookieHeader: String?) {}
                    override fun clearCookies() {}
                }
            )
            epochClient.exchangeRedirectForSession("https://m.cloud.189.cn/cb?paras=alice")
            val aliceEpoch = epochClient.sessionEpoch
            assertTrue(epochClient.isAuthenticated)
            assertEquals("alice@example.invalid", epochClient.accountName)

            currentLogin.set("bob@example.invalid")
            epochClient.exchangeRedirectForSession("https://m.cloud.189.cn/cb?paras=bob")
            val bobEpoch = epochClient.sessionEpoch
            assertTrue(bobEpoch > aliceEpoch)
            assertEquals("bob@example.invalid", epochClient.accountName)

            // Stale cleanup for aliceEpoch MUST NOT clear Bob's active session
            epochClient.clearSessionImmediate(expectedEpoch = aliceEpoch)
            assertTrue("Stale expectedEpoch must not wipe newer session", epochClient.isAuthenticated)
            assertEquals("bob@example.invalid", epochClient.accountName)
            assertEquals(bobEpoch, epochClient.sessionEpoch)

            // Matching expectedEpoch clears Bob's session cleanly
            epochClient.clearSessionImmediate(expectedEpoch = bobEpoch)
            assertFalse(epochClient.isAuthenticated)
            assertNull(epochClient.activeSession)
            assertTrue(epochClient.sessionEpoch > bobEpoch)

            // 2) LocalStreamServer.revokeSource revokes only the superseded token without disturbing sibling streams
            val limiter = GlobalTransferLimiter(8)
            val cm = CacheManager(File(tempRoot, "stream-cache"))
            val sampleBytes = ByteArray(1024) { (it and 0x7F).toByte() }
            LocalStreamServer(
                limiter = limiter,
                opener = { _, _ ->
                    OpenedUpstreamStream(
                        statusCode = 200,
                        headers = mapOf("content-length" to sampleBytes.size.toString()),
                        bodyStream = ByteArrayInputStream(sampleBytes)
                    )
                }
            ).use { server ->
                val regA = StreamSourceRegistration(
                    accountHash = "sameAcct",
                    trackId = "t-a",
                    remoteUrl = "https://media.example.invalid/a.flac",
                    cacheDestination = cm.cacheFile("t-a", "a.flac"),
                    expectedSize = sampleBytes.size.toLong(),
                    fileName = "a.flac",
                    cacheLimitBytes = 64L * 1024L * 1024L
                )
                val regB = StreamSourceRegistration(
                    accountHash = "sameAcct",
                    trackId = "t-b",
                    remoteUrl = "https://media.example.invalid/b.flac",
                    cacheDestination = cm.cacheFile("t-b", "b.flac"),
                    expectedSize = sampleBytes.size.toLong(),
                    fileName = "b.flac",
                    cacheLimitBytes = 64L * 1024L * 1024L
                )
                val urlA = server.registerSource(regA, cm)
                val urlB = server.registerSource(regB, cm)
                server.revokeSource(regA.token)
                assertEquals(404, (URL(urlA).openConnection() as HttpURLConnection).responseCode)
                assertEquals(200, (URL(urlB).openConnection() as HttpURLConnection).responseCode)
            }

            // 3) Pinned exportTreeUri in StagedDownloadManifest survives transfers.json persistence & resumeTransfer
            val store = AccountStore(tempRoot)
            val accountId = "bob@example.invalid"
            val paths = store.paths(accountId)
            val pinnedUri = "content://com.android.externalstorage.documents/tree/primary%3APinnedMusicExport"
            val changedDefaultUri = "content://com.android.externalstorage.documents/tree/primary%3AChangedLaterFolder"
            val filePayload = ByteArray(64_000) { ((it * 7) and 0xFF).toByte() }
            val holdDownload = CompletableDeferred<Unit>()
            val enteredDownload = CompletableDeferred<Unit>()

            val engine1 = TransferEngine(
                limiter = limiter,
                opener = { _, rangeHeader ->
                    if (rangeHeader == "bytes=0-0") {
                        OpenedUpstreamStream(
                            statusCode = 206,
                            headers = mapOf("content-range" to "bytes 0-0/${filePayload.size}", "content-length" to "1"),
                            bodyStream = ByteArrayInputStream(filePayload.copyOfRange(0, 1))
                        )
                    } else {
                        enteredDownload.complete(Unit)
                        holdDownload.await()
                        OpenedUpstreamStream(
                            statusCode = 200,
                            headers = mapOf("content-length" to filePayload.size.toString()),
                            bodyStream = ByteArrayInputStream(filePayload)
                        )
                    }
                },
                urlResolver = { "https://media.example.invalid/pinned.flac" }
            )

            val track = TrackSummary("trk-pin", "Pinned.flac", "Lossless", filePayload.size.toLong())
            val taskId = engine1.enqueueExportDownload(
                accountId = accountId,
                track = track,
                relativeSubpath = "Lossless/Pinned.flac",
                parallelThreads = 1,
                stagingRootDir = paths.stagingDir,
                manifestsFile = paths.transfersFile,
                exportTreeUri = pinnedUri
            ) { _, _, _, uri -> uri ?: "missing" }

            withTimeout(5000L) { enteredDownload.await() }
            engine1.pauseTransfer(taskId, paths.transfersFile)
            holdDownload.complete(Unit)

            val persistedJson = paths.transfersFile.readText(Charsets.UTF_8)
            assertTrue("transfers.json must persist exportTreeUri", persistedJson.contains(pinnedUri))

            // Simulate app restart with a new TransferEngine and a changed default SAF export folder
            val engine2 = TransferEngine(
                limiter = limiter,
                opener = { _, rangeHeader ->
                    if (rangeHeader == "bytes=0-0") {
                        OpenedUpstreamStream(
                            statusCode = 206,
                            headers = mapOf("content-range" to "bytes 0-0/${filePayload.size}", "content-length" to "1"),
                            bodyStream = ByteArrayInputStream(filePayload.copyOfRange(0, 1))
                        )
                    } else {
                        OpenedUpstreamStream(
                            statusCode = 200,
                            headers = mapOf("content-length" to filePayload.size.toString()),
                            bodyStream = ByteArrayInputStream(filePayload)
                        )
                    }
                },
                urlResolver = { "https://media.example.invalid/pinned.flac" }
            )
            engine2.restorePersistedDownloads(accountId, paths.stagingDir, paths.transfersFile)
            val observedUri = java.util.concurrent.atomic.AtomicReference<String?>(null)
            val exportedFile = File(tempRoot, "resumed-Pinned.flac")
            engine2.resumeTransfer(taskId, paths.stagingDir, paths.transfersFile) { staged, _, _, manifestTreeUri ->
                val effective = manifestTreeUri ?: changedDefaultUri
                observedUri.set(effective)
                staged.copyTo(exportedFile, overwrite = true)
                effective
            }

            var waitAttempts = 0
            while (waitAttempts < 50 && engine2.snapshot().items.firstOrNull { it.id == taskId }?.state != "completed") {
                delay(30L)
                waitAttempts += 1
            }
            assertEquals("completed", engine2.snapshot().items.first { it.id == taskId }.state)
            assertEquals("Resumed task must keep its pinned exportTreeUri", pinnedUri, observedUri.get())
            assertArrayEquals(filePayload, exportedFile.readBytes())
        } finally {
            tempRoot.deleteRecursively()
        }
    }

    @Test
    fun verifyProxyNonZeroRangeRejectionSuffixStreamingAndDirectLocalCache(): Unit = runBlocking {
        val tempRoot = Files.createTempDirectory("cloudtune-slice2-proxy").toFile()
        try {
            val cacheManager = CacheManager(File(tempRoot, "cache"))
            val fullPayload = ByteArray(10_000) { ((it * 31 + 7) and 0xFF).toByte() }
            val limiter = GlobalTransferLimiter(1)
            val observedRanges = Collections.synchronizedList(mutableListOf<String?>())
            val nonZeroMode = AtomicInteger(0) // 0 -> 200 OK, 1 -> mismatched 206, 2 -> valid 206
            val suffixStep = AtomicInteger(0)

            LocalStreamServer(
                limiter = limiter,
                opener = { _, rangeHeader ->
                    observedRanges += rangeHeader
                    when {
                        rangeHeader == "bytes=65536-" -> when (nonZeroMode.get()) {
                            0 -> OpenedUpstreamStream(
                                statusCode = 200,
                                headers = mapOf("content-length" to fullPayload.size.toString()),
                                bodyStream = ByteArrayInputStream(fullPayload)
                            )
                            else -> OpenedUpstreamStream(
                                statusCode = 206,
                                headers = mapOf(
                                    "content-length" to fullPayload.size.toString(),
                                    "content-range" to "bytes 0-9999/48234496"
                                ),
                                bodyStream = ByteArrayInputStream(fullPayload)
                            )
                        }
                        rangeHeader == "bytes=-512" -> {
                            val step = suffixStep.getAndIncrement()
                            if (step == 0) {
                                // Fail before S is resolved -> proxy MUST retry bytes=-512 (never bytes=0-)!
                                throw IOException("transient upstream open drop before S resolved")
                            }
                            val slice = fullPayload.copyOfRange(9488, 10_000)
                            OpenedUpstreamStream(
                                statusCode = 206,
                                headers = mapOf(
                                    "content-length" to slice.size.toString(),
                                    "content-range" to "bytes 9488-9999/10000"
                                ),
                                bodyStream = object : InputStream() {
                                    private var pos = 0
                                    override fun read(): Int {
                                        if (pos >= 200) throw IOException("mid-suffix drop")
                                        return slice[pos++].toInt() and 0xFF
                                    }
                                }
                            )
                        }
                        rangeHeader == "bytes=9688-9999" -> {
                            val tail = fullPayload.copyOfRange(9688, 10_000)
                            OpenedUpstreamStream(
                                statusCode = 206,
                                headers = mapOf(
                                    "content-length" to tail.size.toString(),
                                    "content-range" to "bytes 9688-9999/10000"
                                ),
                                bodyStream = ByteArrayInputStream(tail)
                            )
                        }
                        else -> error("Unexpected upstream range call: $rangeHeader")
                    }
                },
                maxRegisteredSources = 4
            ).use { server ->
                val remoteTrackUrl = server.registerSource(
                    StreamSourceRegistration(
                        accountHash = "acctS2",
                        trackId = "track-remote",
                        remoteUrl = "https://media.example.invalid/remote.flac",
                        cacheDestination = cacheManager.cacheFile("track-remote", "remote.flac"),
                        expectedSize = fullPayload.size.toLong(),
                        fileName = "remote.flac",
                        cacheLimitBytes = 64L * 1024L * 1024L
                    ),
                    cacheManager = cacheManager
                )

                // 1a) Initial non-zero Range returning 200 OK MUST be rejected with 502 Bad Gateway
                nonZeroMode.set(0)
                val seek200Conn = (URL(remoteTrackUrl).openConnection() as HttpURLConnection).apply {
                    setRequestProperty("Range", "bytes=65536-")
                }
                assertEquals(502, seek200Conn.responseCode)

                // 1b) Initial non-zero Range returning mismatched Content-Range bytes 0-... MUST be rejected with 502
                nonZeroMode.set(1)
                val seekMismatchConn = (URL(remoteTrackUrl).openConnection() as HttpURLConnection).apply {
                    setRequestProperty("Range", "bytes=65536-")
                }
                assertEquals(502, seekMismatchConn.responseCode)

                // 1c) Invalid suffix bytes=-0 rejected with 416 without touching opener
                val beforeInvalidCount = observedRanges.size
                val invalidSuffixConn = (URL(remoteTrackUrl).openConnection() as HttpURLConnection).apply {
                    setRequestProperty("Range", "bytes=-0")
                }
                assertEquals(416, invalidSuffixConn.responseCode)
                assertEquals(beforeInvalidCount, observedRanges.size)

                // 2) Suffix bytes=-512 retries bytes=-512 on pre-S failure, resumes at 9488+200=9688, and never caches
                observedRanges.clear()
                val suffixConn = (URL(remoteTrackUrl).openConnection() as HttpURLConnection).apply {
                    setRequestProperty("Range", "bytes=-512")
                }
                assertEquals(206, suffixConn.responseCode)
                assertEquals("bytes 9488-9999/10000", suffixConn.getHeaderField("Content-Range"))
                val suffixReceived = suffixConn.inputStream.use { it.readBytes() }
                assertArrayEquals(fullPayload.copyOfRange(9488, 10_000), suffixReceived)
                assertEquals(listOf<String?>("bytes=-512", "bytes=-512", "bytes=9688-9999"), observedRanges.toList())
                assertFalse(observedRanges.contains("bytes=0-"))
                delay(40L)
                assertNull(cacheManager.existingCachedFile("track-remote"))

                // 3) Direct local-cache serving (200, explicit 206, suffix 206, 416, HEAD) without opener or remote permit!
                val cachedFile = cacheManager.cacheFile("track-cached", "cached.flac").apply {
                    writeBytes(fullPayload)
                }
                cacheManager.recordCompletedFile(
                    trackId = "track-cached",
                    file = cachedFile,
                    sizeBytes = fullPayload.size.toLong(),
                    limitBytes = 64L * 1024L * 1024L
                )
                val cachedStreamUrl = server.registerSource(
                    StreamSourceRegistration(
                        accountHash = "acctS2",
                        trackId = "track-cached",
                        remoteUrl = "https://media.example.invalid/never-open.flac",
                        cacheDestination = cachedFile,
                        expectedSize = fullPayload.size.toLong(),
                        fileName = "cached.flac",
                        cacheLimitBytes = 64L * 1024L * 1024L
                    ),
                    cacheManager = cacheManager
                )
                observedRanges.clear()
                // Hold the ONLY remote permit in limiter(1) to prove local cache serving acquires 0 permits
                limiter.withPermit {
                    val fullCachedConn = URL(cachedStreamUrl).openConnection() as HttpURLConnection
                    assertEquals(200, fullCachedConn.responseCode)
                    assertArrayEquals(fullPayload, fullCachedConn.inputStream.use { it.readBytes() })

                    val explicitCachedConn = (URL(cachedStreamUrl).openConnection() as HttpURLConnection).apply {
                        setRequestProperty("Range", "bytes=100-299")
                    }
                    assertEquals(206, explicitCachedConn.responseCode)
                    assertArrayEquals(fullPayload.copyOfRange(100, 300), explicitCachedConn.inputStream.use { it.readBytes() })

                    val suffixCachedConn = (URL(cachedStreamUrl).openConnection() as HttpURLConnection).apply {
                        setRequestProperty("Range", "bytes=-512")
                    }
                    assertEquals(206, suffixCachedConn.responseCode)
                    assertEquals("bytes 9488-9999/10000", suffixCachedConn.getHeaderField("Content-Range"))
                    assertArrayEquals(fullPayload.copyOfRange(9488, 10_000), suffixCachedConn.inputStream.use { it.readBytes() })

                    val oobCachedConn = (URL(cachedStreamUrl).openConnection() as HttpURLConnection).apply {
                        setRequestProperty("Range", "bytes=10000-")
                    }
                    assertEquals(416, oobCachedConn.responseCode)

                    val headCachedConn = (URL(cachedStreamUrl).openConnection() as HttpURLConnection).apply {
                        requestMethod = "HEAD"
                    }
                    assertEquals(200, headCachedConn.responseCode)
                    assertEquals(fullPayload.size.toString(), headCachedConn.getHeaderField("Content-Length"))
                }
                assertTrue("Direct local-cache serving must never invoke upstream opener", observedRanges.isEmpty())

                // 4) Bounded sources map evicts oldest inactive tokens beyond maxRegisteredSources (4)
                val urls = (0 until 5).map { idx ->
                    server.registerSource(
                        StreamSourceRegistration(
                            token = "tok-$idx",
                            accountHash = "acctCap",
                            trackId = "track-cached",
                            remoteUrl = "https://media.example.invalid/$idx.flac",
                            cacheDestination = cachedFile,
                            expectedSize = fullPayload.size.toLong(),
                            fileName = "$idx.flac",
                            cacheLimitBytes = 64L * 1024L * 1024L
                        ),
                        cacheManager = cacheManager
                    )
                }
                assertEquals(4, server.registeredSourceCount())
                assertEquals(404, (URL(urls[0]).openConnection() as HttpURLConnection).responseCode)
                assertEquals(200, (URL(urls[4]).openConnection() as HttpURLConnection).responseCode)
            }

            // 5) HttpUrlConnectionTransport propagates IOException on truncated 2xx response body instead of ByteArray(0)
            ServerSocket(0, 4, InetAddress.getByName("127.0.0.1")).use { truncServer ->
                val serverThread = Thread {
                    runCatching {
                        truncServer.accept().use { sock ->
                            val reqBuf = ByteArray(1024)
                            sock.getInputStream().read(reqBuf)
                            val partial = "HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n{\"res_code\":0"
                            sock.getOutputStream().write(partial.toByteArray(Charsets.UTF_8))
                            sock.getOutputStream().flush()
                        }
                    }
                }.apply { isDaemon = true; start() }

                val transport = HttpUrlConnectionTransport()
                var caughtIo = false
                try {
                    transport.send("http://127.0.0.1:${truncServer.localPort}/listFiles.action")
                } catch (_: IOException) {
                    caughtIo = true
                }
                serverThread.join(500)
                assertTrue("Truncated 200 OK body must throw IOException, never return empty ByteArray", caughtIo)
            }
        } finally {
            tempRoot.deleteRecursively()
        }
    }

    @Test
    fun verifyPrematureZeroByteEofRetryCapCorruptIndexRebuildAndResilientLibrary(): Unit = runBlocking {
        val tempRoot = Files.createTempDirectory("cloudtune-slice2-engines").toFile()
        try {
            // 1) Premature 0-byte EOF retry cap in TransferEngine (1 initial + 4 retries = 5 part opens, never infinite)
            val partOpens = AtomicInteger(0)
            val limiter = GlobalTransferLimiter(4)
            val eofEngine = TransferEngine(
                limiter = limiter,
                opener = { _, rangeHeader ->
                    if (rangeHeader == "bytes=0-0") {
                        OpenedUpstreamStream(
                            statusCode = 206,
                            headers = mapOf("content-range" to "bytes 0-0/4096", "content-length" to "1"),
                            bodyStream = ByteArrayInputStream(byteArrayOf(0x11))
                        )
                    } else {
                        partOpens.incrementAndGet()
                        // Immediate EOF (-1) with 0 bytes read while current <= endInclusive!
                        OpenedUpstreamStream(
                            statusCode = 206,
                            headers = mapOf("content-range" to "bytes 0-4095/4096", "content-length" to "4096"),
                            bodyStream = ByteArrayInputStream(ByteArray(0))
                        )
                    }
                },
                urlResolver = { "https://media.example.invalid/eof.flac" }
            ).also { it.retryDelayBaseMs = 2L }

            val eofCache = CacheManager(File(tempRoot, "eof-cache"))
            var failedCleanly = false
            withTimeout(5_000L) {
                try {
                    eofEngine.downloadTrackToCache(
                        track = TrackSummary("trk-eof", "Eof.flac", "Music", 4096L),
                        cacheManager = eofCache,
                        parallelThreads = 1,
                        cacheLimitBytes = 64L * 1024L * 1024L
                    )
                } catch (_: IOException) {
                    failedCleanly = true
                }
            }
            assertTrue("Premature 0-byte EOF must fail cleanly after retry cap", failedCleanly)
            assertEquals(1 + TransferEngine.MAX_PART_RETRIES, partOpens.get())
            assertNull(eofCache.existingCachedFile("trk-eof"))

            // 2) Corrupt index.json rebuild preserving valid cached tracks + throttled index.json flushes
            val rebuildDir = File(tempRoot, "rebuild-cache")
            val fakeClock = AtomicLong(1_700_000_000_000L)
            val cmSeed = CacheManager(rebuildDir, clockMs = { fakeClock.get() })
            val bytesA = ByteArray(2048) { 0x3A }
            val bytesB = ByteArray(3072) { 0x5B }
            val fileA = cmSeed.cacheFile("track-1", "Aria - Take 1.flac").apply { writeBytes(bytesA) }
            val fileB = cmSeed.cacheFile("31384910", "Waltz.wav").apply { writeBytes(bytesB) }
            cmSeed.recordCompletedFile("track-1", fileA, bytesA.size.toLong(), 64L * 1024L * 1024L)
            cmSeed.recordCompletedFile("31384910", fileB, bytesB.size.toLong(), 64L * 1024L * 1024L)

            val strayPart = File(rebuildDir, "orphan.flac.part").apply { writeBytes(byteArrayOf(1, 2, 3)) }
            val strayTmp = File(rebuildDir, ".index.json.stale.tmp").apply { writeText("stale") }
            cmSeed.indexFile.writeText("{corrupt-json-payload", Charsets.UTF_8)

            val cmRebuilt = CacheManager(rebuildDir, clockMs = { fakeClock.get() })
            assertFalse(strayPart.exists())
            assertFalse(strayTmp.exists())
            assertEquals((bytesA.size + bytesB.size).toLong(), cmRebuilt.usageBytes())
            val repairedJson = JSONObject(cmRebuilt.indexFile.readText(Charsets.UTF_8))
            assertEquals(2, repairedJson.length())
            assertArrayEquals(bytesA, cmRebuilt.existingCachedFile("track-1")!!.readBytes())
            assertArrayEquals(bytesB, cmRebuilt.existingCachedFile("31384910")!!.readBytes())

            // Throttled flush check: < 16 hits within < 5_000ms does NOT rewrite index.json; >= 5_000ms flushes
            cmRebuilt.flushIndexIfDirty()
            val baselineIndexText = cmRebuilt.indexFile.readText(Charsets.UTF_8)
            fakeClock.addAndGet(200L)
            repeat(5) {
                assertNotNull(cmRebuilt.existingCachedFile("31384910"))
            }
            assertEquals("Under-threshold hits must throttle index.json disk writes", baselineIndexText, cmRebuilt.indexFile.readText(Charsets.UTF_8))
            fakeClock.addAndGet(CacheManager.DIRTY_FLUSH_INTERVAL_MS + 10L)
            assertNotNull(cmRebuilt.existingCachedFile("31384910"))
            val flushedJson = JSONObject(cmRebuilt.indexFile.readText(Charsets.UTF_8))
            assertEquals(fakeClock.get(), flushedJson.getJSONObject("31384910").getLong("lastAccessedMs"))

            // 3) Resilient per-item AccountStore.loadLibrary decoding + .migrated-v2 marker
            val storeRoot = File(tempRoot, "acct-store")
            val store = AccountStore(storeRoot)
            assertTrue(File(storeRoot, AccountStore.MIGRATED_V2_MARKER).isFile)
            val acct = "resilient@example.invalid"
            val acctPaths = store.paths(acct)
            acctPaths.libraryFile.writeText(
                """[
                    {"id":"ok-1","name":"First.flac","folderPath":"Disc 1","sizeBytes":1024,"modifiedAt":"2026-11-01"},
                    null,
                    "not-an-object",
                    {"name":"MissingId.flac","sizeBytes":512},
                    {"id":"","name":"BlankId.flac","sizeBytes":512},
                    {"id":"ok-2","name":"Second.wav","folderPath":"Disc 2","sizeBytes":2048,"modifiedAt":null}
                ]""",
                Charsets.UTF_8
            )
            val loadedTracks = store.loadLibrary(acct)
            assertEquals(listOf("ok-1", "ok-2"), loadedTracks.map { it.id })
            assertEquals("2026-11-01", loadedTracks[0].modifiedAt)
            assertNull(loadedTracks[1].modifiedAt)

            // 4) Orphaned staging/ cleanup AFTER loading manifests + batch enqueueExportDownloads without .merged
            val refTaskId = "download:keep-01"
            val refPartsDir = File(acctPaths.stagingDir, "${Cloud189Protocol.sanitizeFileName(refTaskId)}.parts").apply { mkdirs() }
            File(refPartsDir, "0000.part").writeBytes(byteArrayOf(1, 2, 3, 4))
            val orphanPartsDir = File(acctPaths.stagingDir, "download_orphan-99.parts").apply { mkdirs() }
            File(orphanPartsDir, "0000.part").writeBytes(byteArrayOf(9, 9))
            val staleMerged = File(acctPaths.stagingDir, "download_old.merged").apply { writeBytes(byteArrayOf(7)) }
            acctPaths.transfersFile.writeText(
                """[{"taskId":"$refTaskId","trackId":"t-keep","fileName":"Keep.flac","relativeSubpath":"Keep.flac","totalSize":16,"partCount":1,"state":"paused"}]""",
                Charsets.UTF_8
            )

            val batchPayload = ByteArray(1024) { (it and 0x7F).toByte() }
            val batchEngine = TransferEngine(
                limiter = GlobalTransferLimiter(8),
                opener = { _, rangeHeader ->
                    if (rangeHeader == "bytes=0-0") {
                        OpenedUpstreamStream(
                            statusCode = 206,
                            headers = mapOf("content-range" to "bytes 0-0/${batchPayload.size}", "content-length" to "1"),
                            bodyStream = ByteArrayInputStream(batchPayload.copyOfRange(0, 1))
                        )
                    } else {
                        OpenedUpstreamStream(
                            statusCode = 200,
                            headers = mapOf("content-length" to batchPayload.size.toString()),
                            bodyStream = ByteArrayInputStream(batchPayload)
                        )
                    }
                },
                urlResolver = { "https://media.example.invalid/$it.flac" }
            )
            batchEngine.restorePersistedDownloads(acct, acctPaths.stagingDir, acctPaths.transfersFile)
            assertTrue("Referenced .parts directory must survive staging cleanup", refPartsDir.isDirectory)
            assertFalse("Unreferenced .parts directory must be cleaned up", orphanPartsDir.exists())
            assertFalse("Stale .merged file must be cleaned up", staleMerged.exists())

            val exportedFiles = ConcurrentHashMap<String, ByteArray>()
            val batchIds = batchEngine.enqueueExportDownloads(
                accountId = acct,
                items = (1..3).map { idx ->
                    ExportDownloadItem(
                        track = TrackSummary("b-$idx", "Batch$idx.flac", "Batch", batchPayload.size.toLong()),
                        relativeSubpath = "Batch/Batch$idx.flac"
                    )
                },
                parallelThreads = 2,
                stagingRootDir = acctPaths.stagingDir,
                manifestsFile = acctPaths.transfersFile,
                exporter = object : StagedFileExporter {
                    override suspend fun export(stagedFile: File, relativeSubpath: String, accountId: String, exportTreeUri: String?): String {
                        exportedFiles[relativeSubpath] = stagedFile.readBytes()
                        return relativeSubpath
                    }
                    override suspend fun exportParts(
                        partFiles: List<File>,
                        expectedTotalBytes: Long,
                        relativeSubpath: String,
                        accountId: String,
                        exportTreeUri: String?
                    ): String {
                        val combined = ByteArray(expectedTotalBytes.toInt())
                        var pos = 0
                        for (p in partFiles) {
                            val b = p.readBytes()
                            System.arraycopy(b, 0, combined, pos, b.size)
                            pos += b.size
                        }
                        exportedFiles[relativeSubpath] = combined
                        return relativeSubpath
                    }
                }
            )
            assertEquals(3, batchIds.size)
            repeat(50) {
                if (batchIds.all { id -> batchEngine.snapshot().items.firstOrNull { it.id == id }?.state == "completed" }) return@repeat
                delay(25L)
            }
            assertEquals(3, exportedFiles.size)
            exportedFiles.values.forEach { assertArrayEquals(batchPayload, it) }
            assertTrue(acctPaths.stagingDir.list().orEmpty().none { it.endsWith(".merged") })

            // 5) Explicit StatusKind (never guessing from "失败" in song titles)
            val fixture = RepresentativeFixture.fromJsonString(locateContractsFile("representative-state.json").readText(Charsets.UTF_8))
            val errFixtureRt = CloudTuneAppRuntime.fixture(SnapshotScene.ERROR_BANNER, fixture)
            assertEquals(StatusKind.ERROR, errFixtureRt.statusKind)
            val musicFixtureRt = CloudTuneAppRuntime.fixture(SnapshotScene.MUSIC, fixture)
            assertEquals(StatusKind.INFO, musicFixtureRt.statusKind)
            musicFixtureRt.playNext(TrackSummary("song-fail-word", "失败者的飞翔.flac", "Music", 1024L))
            assertEquals(StatusKind.INFO, musicFixtureRt.statusKind)
            musicFixtureRt.cacheLimitDraft = "10"
            assertFalse(musicFixtureRt.commitCacheLimitDraftAsync())
            assertEquals(StatusKind.ERROR, musicFixtureRt.statusKind)
        } finally {
            tempRoot.deleteRecursively()
        }
    }
}
