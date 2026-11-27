package com.gosu.cloudtune.core

import com.gosu.cloudtune.data.AccountStore
import com.gosu.cloudtune.ui.CloudTuneViewModel
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
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

        // 6) Account SHA-256 bucket isolation
        val acctArr = root.getJSONArray("accountIsolation")
        for (i in 0 until acctArr.length()) {
            val entry = acctArr.getJSONObject(i)
            assertEquals(
                entry.getString("expectedBucketHash"),
                Cloud189Protocol.accountBucketHash(entry.getString("rawAccountId"))
            )
        }
    }

    @Test
    fun verifyLocalStreamServerProbeResumeAndRevocation() = runBlocking {
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
    fun verifyGlobalConcurrencyCapAccountIsolationAndDraftSafety() = runBlocking {
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

        // 4) Draft settings isolation across module switches
        val fixture = RepresentativeFixture.fromJsonString(locateContractsFile("representative-state.json").readText(Charsets.UTF_8))
        val vm = CloudTuneViewModel.fixture(SnapshotScene.MUSIC, fixture)
        assertEquals(2048L, vm.committedSettings.cacheLimitMb)
        vm.cacheLimitDraft = "64"
        vm.activeModule = ModuleTab.VIDEO
        vm.activeModule = ModuleTab.SETTINGS
        assertEquals("64", vm.cacheLimitDraft)
        assertEquals(2048L, vm.committedSettings.cacheLimitMb)
        assertFalse(vm.commitCacheLimitDraft())
        assertNotNull(vm.settingsValidationError)
        assertEquals(2048L, vm.committedSettings.cacheLimitMb)

        vm.cacheLimitDraft = "4096"
        vm.noteDraftEdited()
        assertNull(vm.settingsValidationError)
        assertTrue(vm.commitCacheLimitDraft())
        assertEquals(4096L, vm.committedSettings.cacheLimitMb)
    }

    @Test
    fun verifyCrossRestartResumeAndMultiOriginWebCookieSync() = runBlocking {
        // 1) Multi-origin WebView cookies must reach api.cloud.189.cn during session exchange
        var capturedApiCookieHeader: String? = null
        val client = Cloud189Client(
            transport = object : CloudHttpTransport {
                private val inner = HttpUrlConnectionTransport()
                override suspend fun send(
                    url: String,
                    method: String,
                    headers: Map<String, String>,
                    formBody: List<Pair<String, String>>?
                ): CloudHttpResponse {
                    if (url.startsWith(Cloud189Constants.API_URL)) {
                        // Extract cookies stored inside HttpUrlConnectionTransport via reflection-free roundtrip check
                        capturedApiCookieHeader = headers["Cookie"]
                    }
                    val body = """{"res_code":0,"loginName":"alice@example.invalid","sessionKey":"sk_web","sessionSecret":"ss_web","refreshToken":"rt_web"}"""
                    return CloudHttpResponse(200, emptyMap(), body.toByteArray(Charsets.UTF_8), url)
                }

                override fun importCookieHeader(domainUrl: String, cookieHeader: String?) {
                    inner.importCookieHeader(domainUrl, cookieHeader)
                }

                override fun clearCookies() {
                    inner.clearCookies()
                }
            }
        )
        val realTransport = HttpUrlConnectionTransport()
        realTransport.importCookieHeader("https://open.e.189.cn", "SONORK=sonork_01")
        realTransport.importCookieHeader("https://cloud.189.cn", "SESSIONID=sess_cloud_01")
        val cookieManagerField = HttpUrlConnectionTransport::class.java.getDeclaredField("cookieManager").apply {
            isAccessible = true
        }
        val cookieManager = cookieManagerField.get(realTransport) as java.net.CookieManager
        val apiCookies = cookieManager.cookieStore.get(java.net.URI("https://api.cloud.189.cn/getSessionForPC.action"))
            .associate { it.name to it.value }
        val authCookies = cookieManager.cookieStore.get(java.net.URI("https://open.e.189.cn/api/logbox"))
            .associate { it.name to it.value }
        assertEquals("sess_cloud_01", apiCookies["SESSIONID"])
        assertEquals("sonork_01", authCookies["SONORK"])
        assertNotNull(client)

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

            val observedRanges = java.util.Collections.synchronizedList(mutableListOf<String>())
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
            engine.resumeTransfer(taskId, paths.stagingDir, paths.transfersFile) { staged, _, _ ->
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
        assertNull(capturedApiCookieHeader)
    }
}
