package com.gosu.cloudtune.core

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.net.URLEncoder
import java.util.Locale
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class StreamSourceRegistration(
    val token: String = UUID.randomUUID().toString(),
    val accountHash: String,
    val trackId: String,
    @Volatile var remoteUrl: String,
    val cacheDestination: File,
    val expectedSize: Long,
    val fileName: String,
    val cacheLimitBytes: Long
)

data class OpenedUpstreamStream(
    val statusCode: Int,
    val headers: Map<String, String>,
    val bodyStream: InputStream,
    val onClose: () -> Unit = {}
)

fun interface UpstreamStreamOpener {
    suspend fun open(url: String, rangeHeader: String?): OpenedUpstreamStream
}

class HttpUrlConnectionStreamOpener : UpstreamStreamOpener {
    override suspend fun open(url: String, rangeHeader: String?): OpenedUpstreamStream =
        withContext(Dispatchers.IO) {
            val conn = (URL(url).openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = true
                requestMethod = "GET"
                connectTimeout = 20_000
                readTimeout = 25_000
                setRequestProperty("Accept", "*/*")
                setRequestProperty("Referer", Cloud189Constants.REFERER)
                setRequestProperty("User-Agent", Cloud189Constants.USER_AGENT)
                if (rangeHeader != null) {
                    setRequestProperty("Range", rangeHeader)
                }
            }
            try {
                val status = conn.responseCode
                val headers = mutableMapOf<String, String>()
                for ((k, v) in conn.headerFields) {
                    if (k != null && !v.isNullOrEmpty()) {
                        headers[k.lowercase(Locale.US)] = v.last()
                    }
                }
                val contentLength = headers["content-length"]?.trim()?.toLongOrNull()
                val rawStream: InputStream? = if (status in 200..299) {
                    conn.inputStream
                } else {
                    conn.errorStream
                }
                val reachedEof = AtomicBoolean(rawStream == null || contentLength == 0L)
                val stream: InputStream = if (rawStream != null) {
                    BufferedInputStream(
                        object : FilterInputStream(rawStream) {
                            private var rawBytesRead = 0L

                            override fun read(): Int {
                                return try {
                                    val b = super.read()
                                    if (b < 0) {
                                        reachedEof.set(true)
                                    } else {
                                        rawBytesRead += 1L
                                        if (contentLength != null && contentLength >= 0L && rawBytesRead >= contentLength) {
                                            reachedEof.set(true)
                                        }
                                    }
                                    b
                                } catch (t: Throwable) {
                                    runCatching { conn.disconnect() }
                                    throw t
                                }
                            }

                            override fun read(b: ByteArray, off: Int, len: Int): Int {
                                return try {
                                    val n = super.read(b, off, len)
                                    if (n < 0) {
                                        reachedEof.set(true)
                                    } else if (n > 0) {
                                        rawBytesRead += n.toLong()
                                        if (contentLength != null && contentLength >= 0L && rawBytesRead >= contentLength) {
                                            reachedEof.set(true)
                                        }
                                    }
                                    n
                                } catch (t: Throwable) {
                                    runCatching { conn.disconnect() }
                                    throw t
                                }
                            }
                        },
                        32_768
                    )
                } else {
                    ByteArrayInputStream(ByteArray(0))
                }
                OpenedUpstreamStream(
                    statusCode = status,
                    headers = headers,
                    bodyStream = stream,
                    onClose = {
                        if (!reachedEof.get()) {
                            runCatching { conn.disconnect() }
                        }
                    }
                )
            } catch (t: Throwable) {
                runCatching { conn.disconnect() }
                throw t
            }
        }
}

/**
 * Localhost (`127.0.0.1:0`) HTTP/1.1 Range streaming proxy with direct local-cache serving,
 * strict write-through, RFC 9110 suffix/non-zero Range validation, and `206` resume verification.
 */
class LocalStreamServer(
    private val limiter: GlobalTransferLimiter,
    private val opener: UpstreamStreamOpener = HttpUrlConnectionStreamOpener(),
    private val onAccountStreamStatusUpdate: ((String, String, TransferStatus?) -> Unit)? = null,
    private val onWriteThroughCompleted: ((String, String, File) -> Unit)? = null,
    private val urlRefresher: (suspend (String) -> String)? = null,
    private val maxRegisteredSources: Int = MAX_REGISTERED_SOURCES
) : AutoCloseable {
    private class ActiveClientSession(
        val id: UUID = UUID.randomUUID(),
        val accountHash: String,
        val token: String,
        val socket: Socket,
        val job: Job?
    ) {
        val revoked = AtomicBoolean(false)
        @Volatile var activeUpstream: OpenedUpstreamStream? = null

        fun revoke() {
            revoked.set(true)
            runCatching { socket.close() }
            val upstream = activeUpstream
            if (upstream != null) {
                runCatching { upstream.onClose() }
                runCatching { upstream.bodyStream.close() }
            }
            job?.cancel()
        }
    }

    private val serverSocket = ServerSocket(0, 64, InetAddress.getByName("127.0.0.1"))
    val port: Int = serverSocket.localPort
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val stateLock = Any()
    private val sources = LinkedHashMap<String, Pair<StreamSourceRegistration, CacheManager>>()
    private val activeSessions = HashMap<UUID, ActiveClientSession>()

    init {
        scope.launch {
            while (isActive && !serverSocket.isClosed) {
                val client = try {
                    serverSocket.accept()
                } catch (_: Throwable) {
                    if (serverSocket.isClosed || !isActive) break
                    continue
                }
                // Launch directly on supervisor `scope` (never as child of accept job) so client errors isolate cleanly
                scope.launch {
                    val clientJob = currentCoroutineContext()[Job]
                    try {
                        handleClient(client, clientJob)
                    } catch (ce: CancellationException) {
                        throw ce
                    } catch (_: Throwable) {
                        // Isolated per-connection failure
                    } finally {
                        runCatching { client.close() }
                    }
                }
            }
        }
    }

    fun registerSource(reg: StreamSourceRegistration, cacheManager: CacheManager): String {
        synchronized(stateLock) {
            sources.remove(reg.token)
            sources[reg.token] = reg to cacheManager
            evictInactiveSourcesLocked()
        }
        val encoded = URLEncoder.encode(Cloud189Protocol.sanitizeFileName(reg.fileName), "UTF-8")
            .replace("+", "%20")
        return "http://127.0.0.1:$port/stream/${reg.token}/$encoded"
    }

    private fun evictInactiveSourcesLocked() {
        val cap = maxRegisteredSources.coerceAtLeast(1)
        if (sources.size <= cap) return
        val activeTokens = HashSet<String>(activeSessions.size)
        for (sess in activeSessions.values) {
            activeTokens.add(sess.token)
        }
        val iter = sources.entries.iterator()
        while (sources.size > cap && iter.hasNext()) {
            val entry = iter.next()
            if (entry.key !in activeTokens) {
                iter.remove()
            }
        }
    }

    fun revokeSource(token: String) {
        val sessionsToRevoke: List<ActiveClientSession>
        synchronized(stateLock) {
            sources.remove(token)
            val collected = ArrayList<ActiveClientSession>()
            val sessIter = activeSessions.entries.iterator()
            while (sessIter.hasNext()) {
                val entry = sessIter.next()
                if (entry.value.token == token) {
                    collected.add(entry.value)
                    sessIter.remove()
                }
            }
            sessionsToRevoke = collected
        }
        for (session in sessionsToRevoke) {
            session.revoke()
        }
    }

    fun revokeAllSources(accountHash: String) {
        val sessionsToRevoke: List<ActiveClientSession>
        synchronized(stateLock) {
            val sourceIter = sources.entries.iterator()
            while (sourceIter.hasNext()) {
                if (sourceIter.next().value.first.accountHash == accountHash) {
                    sourceIter.remove()
                }
            }
            val collected = ArrayList<ActiveClientSession>()
            val sessIter = activeSessions.entries.iterator()
            while (sessIter.hasNext()) {
                val entry = sessIter.next()
                if (entry.value.accountHash == accountHash) {
                    collected.add(entry.value)
                    sessIter.remove()
                }
            }
            sessionsToRevoke = collected
        }
        for (session in sessionsToRevoke) {
            session.revoke()
        }
    }

    override fun close() {
        val sessionsToRevoke: List<ActiveClientSession>
        synchronized(stateLock) {
            sources.clear()
            sessionsToRevoke = activeSessions.values.toList()
            activeSessions.clear()
        }
        for (session in sessionsToRevoke) {
            session.revoke()
        }
        runCatching { serverSocket.close() }
        scope.cancel()
    }

    private fun acquireSession(
        token: String,
        socket: Socket,
        job: Job?
    ): Triple<StreamSourceRegistration, CacheManager, ActiveClientSession>? = synchronized(stateLock) {
        val pair = sources[token] ?: return null
        val session = ActiveClientSession(
            accountHash = pair.first.accountHash,
            token = token,
            socket = socket,
            job = job
        )
        activeSessions[session.id] = session
        Triple(pair.first, pair.second, session)
    }

    private fun releaseSession(id: UUID) {
        synchronized(stateLock) {
            activeSessions.remove(id)
            evictInactiveSourcesLocked()
        }
    }

    private fun isSourceStillRegistered(token: String, accountHash: String): Boolean = synchronized(stateLock) {
        sources[token]?.first?.accountHash == accountHash
    }

    internal fun registeredSourceCount(): Int = synchronized(stateLock) {
        sources.size
    }

    private fun publishStatus(id: String, accountHash: String, status: TransferStatus?) {
        onAccountStreamStatusUpdate?.invoke(id, accountHash, status)
    }

    private fun serveFromLocalCacheIfPresent(
        source: StreamSourceRegistration,
        cacheManager: CacheManager,
        session: ActiveClientSession,
        isHead: Boolean,
        hasRangeHeader: Boolean,
        requestedRange: ParsedByteRange?,
        out: OutputStream
    ): Boolean {
        val cachedFile = cacheManager.existingCachedFile(source.trackId) ?: return false
        val raf = runCatching { RandomAccessFile(cachedFile, "r") }.getOrNull() ?: return false
        raf.use { fileHandle ->
            val totalLen = runCatching { fileHandle.length() }.getOrDefault(0L)
            if (totalLen <= 0L) return false

            val mime = Cloud189Protocol.guessMimeType(source.fileName)
            val sliceStart: Long
            val sliceEnd: Long
            val isPartial: Boolean

            if (!hasRangeHeader) {
                sliceStart = 0L
                sliceEnd = totalLen - 1L
                isPartial = false
            } else {
                val resolved = requestedRange?.resolve(totalLen)
                if (resolved == null) {
                    val hdr416 = "HTTP/1.1 416 Range Not Satisfiable\r\n" +
                        "Content-Range: bytes */$totalLen\r\n" +
                        "Content-Length: 0\r\n" +
                        "Connection: close\r\n\r\n"
                    runCatching {
                        out.write(hdr416.toByteArray(Charsets.UTF_8))
                        out.flush()
                    }
                    return true
                }
                sliceStart = resolved.first
                sliceEnd = resolved.second
                isPartial = true
            }

            val sliceLen = sliceEnd - sliceStart + 1L
            val statusLine = if (isPartial) "HTTP/1.1 206 Partial Content" else "HTTP/1.1 200 OK"
            val headerBuf = StringBuilder("$statusLine\r\nContent-Type: $mime\r\nAccept-Ranges: bytes\r\nConnection: close\r\n")
            if (isPartial) {
                headerBuf.append("Content-Range: bytes $sliceStart-$sliceEnd/$totalLen\r\n")
            }
            headerBuf.append("Content-Length: $sliceLen\r\n\r\n")
            if (session.revoked.get()) return true
            val wroteHeaders = runCatching {
                out.write(headerBuf.toString().toByteArray(Charsets.UTF_8))
                out.flush()
            }.isSuccess
            if (!wroteHeaders || isHead || session.revoked.get()) return true

            if (sliceStart > 0L) {
                fileHandle.seek(sliceStart)
            }
            val buf = ByteArray(LOCAL_CACHE_BUFFER_BYTES)
            var remaining = sliceLen
            while (remaining > 0L && !session.revoked.get()) {
                val toRead = minOf(buf.size.toLong(), remaining).toInt()
                val n = fileHandle.read(buf, 0, toRead)
                if (n <= 0) break
                try {
                    out.write(buf, 0, n)
                } catch (_: Exception) {
                    break
                }
                remaining -= n.toLong()
            }
            runCatching { out.flush() }
            return true
        }
    }

    private suspend fun handleClient(socket: Socket, clientJob: Job?) {
        socket.use { client ->
            runCatching {
                client.tcpNoDelay = true
                client.soTimeout = HEADER_READ_TIMEOUT_MS
            }
            val req = runCatching { readHttpRequest(client.getInputStream()) }.getOrNull() ?: return
            runCatching {
                client.soTimeout = 0
            }

            val segments = req.path.trim('/').split('/')
            val out = client.getOutputStream()
            if (segments.size < 2 || segments[0] != "stream") {
                runCatching {
                    out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                }
                return
            }
            val acquired = acquireSession(segments[1], client, clientJob) ?: run {
                runCatching {
                    out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                }
                return
            }
            val (source, cacheManager, session) = acquired
            try {
                if (session.revoked.get()) return
                val isHead = req.method.equals("HEAD", ignoreCase = true)
                val clientRangeRaw = req.headers["range"]?.trim()?.takeIf { it.isNotEmpty() }
                val hasRangeHeader = clientRangeRaw != null
                val requestedRange = if (hasRangeHeader) RangeHeaderValidator.parseRequestRange(clientRangeRaw) else null

                if (serveFromLocalCacheIfPresent(source, cacheManager, session, isHead, hasRangeHeader, requestedRange, out)) {
                    return
                }

                if (hasRangeHeader && requestedRange == null) {
                    val crLine = if (source.expectedSize > 0L) "Content-Range: bytes */${source.expectedSize}\r\n" else ""
                    runCatching {
                        out.write("HTTP/1.1 416 Range Not Satisfiable\r\n${crLine}Content-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                    }
                    return
                }

                val upstreamRange = when {
                    isHead -> "bytes=0-0"
                    requestedRange != null -> requestedRange.headerValue
                    else -> null
                }

                limiter.withPermit {
                    if (session.revoked.get()) return@withPermit
                    var initialOpenRetries = 0
                    var opened: OpenedUpstreamStream? = null
                    while (opened == null) {
                        if (session.revoked.get()) return@withPermit
                        try {
                            // If suffix Range fails before S is resolved, retry bytes=-N (never bytes=0-)
                            opened = openWithRefreshIfNeeded(source, upstreamRange)
                        } catch (ce: CancellationException) {
                            throw ce
                        } catch (_: Throwable) {
                            if (requestedRange?.isSuffix == true && !isHead && initialOpenRetries < MAX_STREAM_RETRIES) {
                                initialOpenRetries += 1
                                delay(50L * initialOpenRetries)
                                continue
                            }
                            if (!session.revoked.get()) {
                                runCatching {
                                    out.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                                }
                            }
                            return@withPermit
                        }
                    }

                    var currentUpstream: OpenedUpstreamStream = opened
                    session.activeUpstream = currentUpstream
                    try {
                        if (session.revoked.get()) return@withPermit
                        if (currentUpstream.statusCode == 416 && !isHead) {
                            val crHdr = currentUpstream.headers["content-range"]?.let { "Content-Range: $it\r\n" }.orEmpty()
                            runCatching {
                                out.write("HTTP/1.1 416 Range Not Satisfiable\r\n${crHdr}Content-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                            }
                            return@withPermit
                        }
                        if (currentUpstream.statusCode != 200 && currentUpstream.statusCode != 206) {
                            runCatching {
                                out.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                            }
                            return@withPermit
                        }

                        val mime = Cloud189Protocol.guessMimeType(source.fileName)
                        val fullLength = RangeHeaderValidator.extractFullAssetLength(
                            statusCode = currentUpstream.statusCode,
                            requestHadRange = upstreamRange != null,
                            contentRangeHeader = currentUpstream.headers["content-range"],
                            contentLengthHeader = currentUpstream.headers["content-length"]
                        ) ?: source.expectedSize.takeIf { it > 0L }

                        if (isHead) {
                            if (currentUpstream.statusCode == 206 && currentUpstream.headers["content-length"]?.trim() == "1") {
                                runCatching { while (currentUpstream.bodyStream.read() >= 0) { /* drain 1-byte probe for keep-alive */ } }
                            }
                            val sb = StringBuilder("HTTP/1.1 200 OK\r\nContent-Type: $mime\r\nAccept-Ranges: bytes\r\nConnection: close\r\n")
                            if (fullLength != null) sb.append("Content-Length: $fullLength\r\n")
                            sb.append("\r\n")
                            runCatching { out.write(sb.toString().toByteArray()) }
                            return@withPermit
                        }

                        var resolvedStart: Long?
                        var resolvedEnd: Long?
                        val parsedCr = RangeHeaderValidator.parseContentRange(currentUpstream.headers["content-range"])
                        try {
                            when {
                                requestedRange?.isSuffix == true -> {
                                    val cr = RangeHeaderValidator.validateSuffixResponse(
                                        suffixLength = requestedRange.suffixLength!!,
                                        statusCode = currentUpstream.statusCode,
                                        contentRangeHeader = currentUpstream.headers["content-range"]
                                    )
                                    resolvedStart = cr.start
                                    resolvedEnd = cr.end
                                }
                                requestedRange != null && requestedRange.start > 0L -> {
                                    RangeHeaderValidator.validateResumeResponse(
                                        expectedStartOffset = requestedRange.start,
                                        statusCode = currentUpstream.statusCode,
                                        contentRangeHeader = currentUpstream.headers["content-range"]
                                    )
                                    resolvedStart = requestedRange.start
                                    resolvedEnd = parsedCr?.end ?: requestedRange.end ?: fullLength?.let { it - 1L }
                                }
                                else -> {
                                    resolvedStart = 0L
                                    resolvedEnd = parsedCr?.end ?: requestedRange?.end ?: fullLength?.let { it - 1L }
                                }
                            }
                        } catch (_: CloudTuneException) {
                            runCatching {
                                out.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                            }
                            return@withPermit
                        }

                        val clHeader = currentUpstream.headers["content-length"]?.trim()?.toLongOrNull()
                        val expectedSliceBytes: Long? = clHeader
                            ?: if (resolvedStart != null && resolvedEnd != null && resolvedEnd >= resolvedStart) {
                                resolvedEnd - resolvedStart + 1L
                            } else {
                                fullLength
                            }

                        val statusLine = if (currentUpstream.statusCode == 206) "HTTP/1.1 206 Partial Content" else "HTTP/1.1 200 OK"
                        val headerBuf = StringBuilder("$statusLine\r\nContent-Type: $mime\r\nAccept-Ranges: bytes\r\nConnection: close\r\n")
                        if (expectedSliceBytes != null) {
                            headerBuf.append("Content-Length: $expectedSliceBytes\r\n")
                        }
                        currentUpstream.headers["content-range"]?.let { headerBuf.append("Content-Range: $it\r\n") }
                        headerBuf.append("\r\n")
                        if (session.revoked.get()) return@withPermit
                        val wroteHeaders = runCatching {
                            out.write(headerBuf.toString().toByteArray())
                            out.flush()
                        }.isSuccess
                        if (!wroteHeaders || session.revoked.get()) return@withPermit

                        val eligibleForCache = !session.revoked.get() &&
                            RangeHeaderValidator.canWriteThroughToCache(clientRangeRaw) &&
                            cacheManager.beginWriteThroughIfIdle(source.trackId)
                        val partFile = File(source.cacheDestination.parentFile, "${source.cacheDestination.name}.part")
                        var partFileOut: FileOutputStream? = null
                        var partOut: BufferedOutputStream? = null

                        if (eligibleForCache) {
                            partFile.delete()
                            val fos = runCatching { FileOutputStream(partFile) }.getOrNull()
                            if (fos != null) {
                                partFileOut = fos
                                partOut = BufferedOutputStream(fos, WRITE_THROUGH_BUFFER_BYTES)
                            }
                        }

                        val baseStartForStatus = resolvedStart ?: 0L
                        val isTinyProbe = (hasRangeHeader && requestedRange?.isSuffix != true && baseStartForStatus == 0L && (requestedRange?.end ?: Long.MAX_VALUE) <= 1L)
                        val streamTaskId = "stream:${source.trackId}"
                        val hasStatusCallback = onAccountStreamStatusUpdate != null
                        var didPublishStreamStatus = false
                        var delivered = 0L
                        var completedCleanly = false
                        var resumeAttempts = initialOpenRetries
                        val buf = ByteArray(32_768)
                        var windowBytes = 0L
                        var windowStartNs = System.nanoTime()

                        try {
                            streamLoop@ while (true) {
                                try {
                                    while (true) {
                                        if (session.revoked.get()) {
                                            completedCleanly = false
                                            break@streamLoop
                                        }
                                        val n = currentUpstream.bodyStream.read(buf)
                                        if (session.revoked.get()) {
                                            completedCleanly = false
                                            break@streamLoop
                                        }
                                        if (n < 0) {
                                            if (expectedSliceBytes != null && delivered < expectedSliceBytes) {
                                                throw IOException("Premature upstream EOF at $delivered / $expectedSliceBytes")
                                            }
                                            break
                                        }
                                        if (n == 0) continue
                                        val toDeliver = if (expectedSliceBytes != null) {
                                            minOf(n.toLong(), (expectedSliceBytes - delivered).coerceAtLeast(0L)).toInt()
                                        } else {
                                            n
                                        }
                                        if (toDeliver <= 0) break
                                        try {
                                            out.write(buf, 0, toDeliver)
                                        } catch (_: Exception) {
                                            completedCleanly = false
                                            break@streamLoop
                                        }
                                        if (session.revoked.get()) {
                                            completedCleanly = false
                                            break@streamLoop
                                        }
                                        if (partOut != null) {
                                            runCatching { partOut!!.write(buf, 0, toDeliver) }.onFailure {
                                                runCatching { partOut?.close() }
                                                runCatching { partFileOut?.close() }
                                                partOut = null
                                                partFileOut = null
                                            }
                                        }
                                        delivered += toDeliver.toLong()
                                        windowBytes += toDeliver.toLong()
                                        if (!isTinyProbe && hasStatusCallback && !session.revoked.get()) {
                                            val elapsedMs = (System.nanoTime() - windowStartNs) / 1_000_000L
                                            if (!didPublishStreamStatus || elapsedMs >= 300L) {
                                                val speed = if (didPublishStreamStatus) {
                                                    (windowBytes * 1000L) / elapsedMs.coerceAtLeast(1L)
                                                } else {
                                                    toDeliver.toLong()
                                                }
                                                didPublishStreamStatus = true
                                                windowBytes = 0L
                                                windowStartNs = System.nanoTime()
                                                val currentAbsOffset = (resolvedStart ?: 0L) + delivered
                                                publishStatus(
                                                    streamTaskId,
                                                    source.accountHash,
                                                    TransferStatus(
                                                        id = streamTaskId,
                                                        label = source.fileName,
                                                        kind = "stream",
                                                        state = "running",
                                                        bytesPerSecond = speed,
                                                        transferredBytes = fullLength?.let { minOf(currentAbsOffset, it) } ?: currentAbsOffset,
                                                        totalBytes = fullLength
                                                    )
                                                )
                                            }
                                        }
                                        // Only reset retry counter when > 0 bytes were actually read & delivered
                                        resumeAttempts = 0
                                        if (expectedSliceBytes != null && delivered >= expectedSliceBytes) {
                                            break
                                        }
                                    }
                                    out.flush()
                                    completedCleanly = !session.revoked.get()
                                    break@streamLoop
                                } catch (ce: CancellationException) {
                                    completedCleanly = false
                                    throw ce
                                } catch (_: Exception) {
                                    if (session.revoked.get()) {
                                        completedCleanly = false
                                        break@streamLoop
                                    }
                                    resumeAttempts += 1
                                    if (resumeAttempts > MAX_STREAM_RETRIES) {
                                        completedCleanly = false
                                        break@streamLoop
                                    }
                                    val startBase = resolvedStart
                                    val resumeRange: String
                                    val expectedResumeStart: Long?
                                    if (startBase != null) {
                                        val resumeOffset = startBase + delivered
                                        if (resolvedEnd != null && resumeOffset > resolvedEnd!!) {
                                            completedCleanly = !session.revoked.get()
                                            break@streamLoop
                                        }
                                        resumeRange = ParsedByteRange(resumeOffset, resolvedEnd).headerValue
                                        expectedResumeStart = resumeOffset
                                    } else if (requestedRange?.isSuffix == true) {
                                        resumeRange = requestedRange.headerValue
                                        expectedResumeStart = null
                                    } else {
                                        val resumeOffset = (requestedRange?.start ?: 0L) + delivered
                                        resumeRange = ParsedByteRange(resumeOffset, requestedRange?.end).headerValue
                                        expectedResumeStart = resumeOffset
                                    }
                                    runCatching { currentUpstream.bodyStream.close(); currentUpstream.onClose() }
                                    val nextOpened = try {
                                        openWithRefreshIfNeeded(source, resumeRange)
                                    } catch (ce: CancellationException) {
                                        completedCleanly = false
                                        throw ce
                                    } catch (_: Throwable) {
                                        null
                                    } ?: run {
                                        completedCleanly = false
                                        break@streamLoop
                                    }
                                    val valid = runCatching {
                                        if (expectedResumeStart != null) {
                                            RangeHeaderValidator.validateResumeResponse(
                                                expectedStartOffset = expectedResumeStart,
                                                statusCode = nextOpened.statusCode,
                                                contentRangeHeader = nextOpened.headers["content-range"]
                                            )
                                        } else if (requestedRange?.isSuffix == true) {
                                            val cr = RangeHeaderValidator.validateSuffixResponse(
                                                suffixLength = requestedRange.suffixLength!!,
                                                statusCode = nextOpened.statusCode,
                                                contentRangeHeader = nextOpened.headers["content-range"]
                                            )
                                            resolvedStart = cr.start
                                            resolvedEnd = cr.end
                                        }
                                    }.isSuccess
                                    if (!valid || session.revoked.get()) {
                                        runCatching { nextOpened.bodyStream.close(); nextOpened.onClose() }
                                        completedCleanly = false
                                        break@streamLoop
                                    }
                                    currentUpstream = nextOpened
                                    session.activeUpstream = nextOpened
                                }
                            }
                        } finally {
                            if (didPublishStreamStatus) {
                                publishStatus(streamTaskId, source.accountHash, null)
                            }
                            var syncedCleanly = false
                            if (partOut != null && partFileOut != null) {
                                syncedCleanly = runCatching {
                                    if (completedCleanly) {
                                        partOut!!.flush()
                                        partFileOut!!.fd.sync()
                                    }
                                    partOut!!.close()
                                }.isSuccess
                                if (!syncedCleanly) {
                                    runCatching { partOut?.close() }
                                    runCatching { partFileOut?.close() }
                                }
                            } else {
                                runCatching { partOut?.close() }
                                runCatching { partFileOut?.close() }
                            }
                            if (eligibleForCache) {
                                val expectedTotal = fullLength ?: 0L
                                val matchesExpected = (source.expectedSize == 0L) || (delivered == source.expectedSize)
                                val stillAuthorized = !session.revoked.get() &&
                                    isSourceStillRegistered(source.token, source.accountHash)
                                if (stillAuthorized && completedCleanly && syncedCleanly && expectedTotal > 0L && delivered == expectedTotal && matchesExpected) {
                                    val promoted = runCatching {
                                        AtomicFileIO.replaceAtomically(partFile, source.cacheDestination)
                                    }.isSuccess
                                    if (promoted) {
                                        val recorded = runCatching {
                                            cacheManager.recordCompletedFile(
                                                trackId = source.trackId,
                                                file = source.cacheDestination,
                                                sizeBytes = delivered,
                                                limitBytes = source.cacheLimitBytes
                                            )
                                        }.isSuccess
                                        if (recorded) {
                                            if (!session.revoked.get() && isSourceStillRegistered(source.token, source.accountHash)) {
                                                onWriteThroughCompleted?.invoke(
                                                    source.accountHash,
                                                    source.trackId,
                                                    source.cacheDestination
                                                )
                                            }
                                        } else {
                                            source.cacheDestination.delete()
                                        }
                                    } else {
                                        partFile.delete()
                                    }
                                } else {
                                    partFile.delete()
                                }
                                cacheManager.finishWriteThrough(source.trackId)
                            }
                        }
                    } finally {
                        session.activeUpstream = null
                        runCatching { currentUpstream.bodyStream.close(); currentUpstream.onClose() }
                    }
                }
            } finally {
                releaseSession(session.id)
            }
        }
    }

    private suspend fun openWithRefreshIfNeeded(
        source: StreamSourceRegistration,
        rangeHeader: String?
    ): OpenedUpstreamStream {
        val initial = opener.open(source.remoteUrl, rangeHeader)
        if (initial.statusCode in listOf(403, 404, 410) && urlRefresher != null) {
            runCatching { initial.bodyStream.close(); initial.onClose() }
            val refreshed = urlRefresher.invoke(source.trackId)
            source.remoteUrl = refreshed
            return opener.open(refreshed, rangeHeader)
        }
        return initial
    }

    private data class ParsedHttpRequest(val method: String, val path: String, val headers: Map<String, String>)

    private fun readHttpRequest(input: InputStream): ParsedHttpRequest? {
        val accum = ByteArrayOutputStream(512)
        val chunk = ByteArray(4096)
        var terminatorIdx = -1
        while (accum.size() < MAX_HTTP_HEADER_BYTES) {
            val maxToRead = minOf(chunk.size, MAX_HTTP_HEADER_BYTES - accum.size())
            val prevSize = accum.size()
            val n = input.read(chunk, 0, maxToRead)
            if (n < 0) break
            if (n == 0) continue
            accum.write(chunk, 0, n)
            val snapshot = accum.toByteArray()
            val found = indexOfHeaderTerminator(snapshot, snapshot.size, prevSize - 3)
            if (found >= 0) {
                terminatorIdx = found
                break
            }
        }
        if (accum.size() == 0 || terminatorIdx < 0) return null
        val rawBytes = accum.toByteArray()
        val rawText = String(rawBytes, 0, terminatorIdx, Charsets.UTF_8)
        val lines = rawText.split("\r\n")
        val firstParts = lines.firstOrNull()?.split(' ') ?: return null
        if (firstParts.size < 2) return null
        val headers = mutableMapOf<String, String>()
        for (line in lines.drop(1)) {
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            if (colon > 0) {
                headers[line.substring(0, colon).trim().lowercase(Locale.US)] = line.substring(colon + 1).trim()
            }
        }
        val cleanPath = firstParts[1].substringBefore('?')
        return ParsedHttpRequest(firstParts[0], cleanPath, headers)
    }

    private fun indexOfHeaderTerminator(buf: ByteArray, length: Int, startSearchAt: Int): Int {
        val from = startSearchAt.coerceAtLeast(0)
        val limit = length - 4
        for (i in from..limit) {
            if (buf[i] == '\r'.code.toByte() &&
                buf[i + 1] == '\n'.code.toByte() &&
                buf[i + 2] == '\r'.code.toByte() &&
                buf[i + 3] == '\n'.code.toByte()
            ) {
                return i
            }
        }
        return -1
    }

    companion object {
        const val MAX_REGISTERED_SOURCES = 128
        const val MAX_STREAM_RETRIES = 4
        private const val HEADER_READ_TIMEOUT_MS = 15_000
        private const val MAX_HTTP_HEADER_BYTES = 16_384
        private const val LOCAL_CACHE_BUFFER_BYTES = 65_536
        private const val WRITE_THROUGH_BUFFER_BYTES = 131_072
    }
}
