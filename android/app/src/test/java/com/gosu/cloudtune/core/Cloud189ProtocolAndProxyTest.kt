package com.gosu.cloudtune.core

import com.gosu.cloudtune.data.AccountStore
import com.gosu.cloudtune.data.CredentialStore
import com.gosu.cloudtune.media.PlaybackSessionBridge
import com.gosu.cloudtune.ui.CloudTuneAppRuntime
import com.gosu.cloudtune.ui.CloudTuneViewModel
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
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
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
        assertEquals(vm.settingsValidationError, vm.statusMessage)
        assertEquals(2048L, vm.committedSettings.cacheLimitMb)

        vm.cacheLimitDraft = "4096"
        vm.noteDraftEdited()
        assertNull(vm.settingsValidationError)
        assertNull(vm.statusMessage)
        assertTrue(vm.commitCacheLimitDraft())
        assertEquals(4096L, vm.committedSettings.cacheLimitMb)
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
                    return CloudHttpResponse(200, emptyMap(), body.toByteArray(Charsets.UTF_8), url)
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
                        return CloudHttpResponse(200, emptyMap(), s.toByteArray(Charsets.UTF_8), url)
                    }
                    return CloudHttpResponse(status, emptyMap(), body.toByteArray(Charsets.UTF_8), url)
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
            ) { staged, _, _ ->
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
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8), url)
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
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8), url)
                        }
                        url.contains("getFileDownloadUrl.action") -> {
                            if (url.contains("fileId=t-fail")) {
                                downloadUrlCalls.incrementAndGet()
                                if (failDownloadUrl.get()) {
                                    throw CloudTuneException("transient network glitch")
                                }
                            }
                            val b = """{"res_code":0,"fileDownloadUrl":"https://media.example.invalid/song.mp3"}"""
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8), url)
                        }
                        else -> CloudHttpResponse(200, emptyMap(), "{}".toByteArray(Charsets.UTF_8), url)
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
            val vm = CloudTuneViewModel(runtime = runtime)

            // 1) Two accounts omitting loginName get display "天翼云盘用户" with distinct storage keys
            sessionIdx.set(1)
            vm.completeEmbeddedWebLogin("https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=1", emptyMap())
            repeat(40) { if (vm.isAuthenticated && vm.browser != null) return@repeat; delay(15L) }
            assertEquals("天翼云盘用户", vm.accountName)
            val key1 = vm.accountStorageKey
            assertNotNull("key1 should be assigned", key1)
            assertFalse("key1 should not be default display name", key1 == "天翼云盘用户")
            store.saveLibrary(key1!!, listOf(TrackSummary("u1", "User1.flac", "CD 1", 100L)))

            vm.logout()
            sessionIdx.set(2)
            vm.completeEmbeddedWebLogin("https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html?paras=2", emptyMap())
            repeat(40) { if (vm.isAuthenticated && vm.browser != null) return@repeat; delay(15L) }
            val key2 = vm.accountStorageKey
            assertNotNull("key2 should be assigned", key2)
            assertFalse("key1 and key2 must differ: $key1 vs $key2", key1 == key2)
            assertTrue("Account 2 library must be empty, got ${vm.tracks}", vm.tracks.isEmpty())

            // 2) Real subfolder names & distinct relative export subpaths
            vm.browseTo("cd1", listOf(BreadcrumbItem.ROOT, BreadcrumbItem("cd1", "CD 1")))
            repeat(40) { if (vm.browser?.currentFolderId == "cd1") return@repeat; delay(15L) }
            assertEquals("CD 1", vm.browser?.currentFolderName)
            assertEquals("CD 1", vm.browser?.audioFiles?.firstOrNull()?.folderPath)

            runtime.enqueueCurrentFolderDownloadWithExporter { _, subpath, _ -> subpath }
            repeat(40) {
                if (vm.downloadTransfers.any { it.path == "CD 1/01. Song.flac" }) return@repeat
                delay(20L)
            }
            vm.browseTo("cd2", listOf(BreadcrumbItem.ROOT, BreadcrumbItem("cd2", "CD 2")))
            repeat(40) { if (vm.browser?.currentFolderId == "cd2") return@repeat; delay(15L) }
            assertEquals("CD 2", vm.browser?.currentFolderName)
            runtime.enqueueCurrentFolderDownloadWithExporter { _, subpath, _ -> subpath }
            repeat(40) {
                if (vm.downloadTransfers.any { it.path == "CD 2/01. Song.flac" }) return@repeat
                delay(20L)
            }
            val queuedPaths = vm.downloadTransfers.mapNotNull { it.path }.toSet()
            assertTrue("Expected CD 1 subpath in $queuedPaths", queuedPaths.contains("CD 1/01. Song.flac"))
            assertTrue("Expected CD 2 subpath in $queuedPaths", queuedPaths.contains("CD 2/01. Song.flac"))

            // 3) Retry cap enforcement (1 initial + 6 retries = 7 total, never infinite)
            vm.updatePlaybackMode(PlaybackMode.STREAM_CACHE)
            failDownloadUrl.set(true)
            downloadUrlCalls.set(0)
            val transientTrack = TrackSummary("t-fail", "Transient.mp3", "CD 2", 1024L)
            vm.playTrack(transientTrack)
            repeat(80) {
                if (vm.statusMessage?.contains("已停止自动重试") == true) return@repeat
                delay(20L)
            }
            assertEquals(1 + PlaybackDecisionPolicy.MAX_RECOVERY_ATTEMPTS, downloadUrlCalls.get())
            assertTrue("Expected retry stop status, got: ${vm.statusMessage}", vm.statusMessage?.contains("已停止自动重试") == true)

            // ExoPlayer network "Source error" MUST NOT be misclassified as unsupported local codec
            vm.handlePlaybackError(TrackSummary("t-src", "Network.flac", "CD 1", 1024L), "Source error", wasLoopback = false)
            assertFalse("Source error must not claim codec unsupported: ${vm.statusMessage}", vm.statusMessage?.contains("不受系统解码器支持") == true)
            vm.openVideoInApp(TrackSummary("v-1", "Clip.mp4", "CD 1", 2048L))

            // 4) Multi-ViewModel attach/detach ref-counting + ViewModel.onCleared() survival
            val vmSecondary = CloudTuneViewModel(runtime = runtime)
            vmSecondary.clearViewModelForTest()
            failDownloadUrl.set(false)
            val q1 = TrackSummary("q1", "Queue1.mp3", "CD 1", 1024L)
            val q2 = TrackSummary("q2", "Queue2.mp3", "CD 1", 1024L)
            vm.tracks = listOf(q1, q2)
            vm.shuffle = false
            vm.playTrack(q1)
            repeat(40) { if (vm.currentTrackId == "q1") return@repeat; delay(15L) }

            vm.clearViewModelForTest()
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

            vm.logout()
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
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8), url)
                        }
                        url.contains("getSessionForPC.action") -> {
                            val b = """{"res_code":0,"loginName":"audiophile@example.invalid","sessionKey":"sk_boot","sessionSecret":"ss_boot","refreshToken":"rt_boot_2"}"""
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8), url)
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
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8), url)
                        }
                        url.contains("getFileDownloadUrl.action") -> {
                            val b = """{"res_code":0,"fileDownloadUrl":"https://media.example.invalid/solo.flac"}"""
                            CloudHttpResponse(200, emptyMap(), b.toByteArray(Charsets.UTF_8), url)
                        }
                        else -> CloudHttpResponse(200, emptyMap(), "{}".toByteArray(Charsets.UTF_8), url)
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
            val ok = runtime.commitCacheLimitDraft()
            assertFalse("Write failure must return false", ok)
            assertEquals(prevLimit, runtime.committedSettings.cacheLimitMb)
            assertEquals("4096", runtime.cacheLimitDraft)
            assertTrue(runtime.statusMessage?.contains("保存设置失败") == true)

            runtime.logout()
            runtime.streamServer?.close()
            Unit
        } finally {
            tempRoot.deleteRecursively()
        }
    }
}
