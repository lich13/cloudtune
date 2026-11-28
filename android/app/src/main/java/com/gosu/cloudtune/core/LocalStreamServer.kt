package com.gosu.cloudtune.core

import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.net.URLEncoder
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
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
                setRequestProperty("Connection", "close")
                if (rangeHeader != null) {
                    setRequestProperty("Range", rangeHeader)
                }
            }
            try {
                val status = conn.responseCode
                val headers = mutableMapOf<String, String>()
                for ((k, v) in conn.headerFields) {
                    if (k != null && !v.isNullOrEmpty()) {
                        headers[k.lowercase()] = v.last()
                    }
                }
                val stream = if (status in 200..299) {
                    BufferedInputStream(conn.inputStream, 32_768)
                } else {
                    conn.errorStream ?: ByteArrayInputStream(ByteArray(0))
                }
                OpenedUpstreamStream(
                    statusCode = status,
                    headers = headers,
                    bodyStream = stream,
                    onClose = { runCatching { conn.disconnect() } }
                )
            } catch (t: Throwable) {
                runCatching { conn.disconnect() }
                throw t
            }
        }
}

/**
 * Localhost (`127.0.0.1:0`) HTTP/1.1 Range streaming proxy with strict write-through & `206` resume verification.
 */
class LocalStreamServer(
    private val limiter: GlobalTransferLimiter,
    private val opener: UpstreamStreamOpener = HttpUrlConnectionStreamOpener(),
    private val onAccountStreamStatusUpdate: ((String, String, TransferStatus?) -> Unit)? = null,
    private val onWriteThroughCompleted: ((String, String, File) -> Unit)? = null,
    private val urlRefresher: (suspend (String) -> String)? = null
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
                runCatching { upstream.bodyStream.close() }
                runCatching { upstream.onClose() }
            }
            job?.cancel()
        }
    }

    private val serverSocket = ServerSocket(0, 64, InetAddress.getByName("127.0.0.1"))
    val port: Int = serverSocket.localPort
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val stateLock = Any()
    private val sources = HashMap<String, Pair<StreamSourceRegistration, CacheManager>>()
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
            sources[reg.token] = reg to cacheManager
        }
        val encoded = URLEncoder.encode(Cloud189Protocol.sanitizeFileName(reg.fileName), "UTF-8")
            .replace("+", "%20")
        return "http://127.0.0.1:$port/stream/${reg.token}/$encoded"
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
        }
    }

    private fun isSourceStillRegistered(token: String, accountHash: String): Boolean = synchronized(stateLock) {
        sources[token]?.first?.accountHash == accountHash
    }

    private fun publishStatus(id: String, accountHash: String, status: TransferStatus?) {
        onAccountStreamStatusUpdate?.invoke(id, accountHash, status)
    }

    private suspend fun handleClient(socket: Socket, clientJob: Job?) {
        socket.use { client ->
            val req = runCatching { readHttpRequest(client.getInputStream()) }.getOrNull() ?: return
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
                val clientRangeRaw = req.headers["range"]
                val requestedRange = RangeHeaderValidator.parseRequestRange(clientRangeRaw)
                val upstreamRange = if (isHead) "bytes=0-0" else clientRangeRaw

                limiter.withPermit {
                    if (session.revoked.get()) return@withPermit
                    var opened = try {
                        openWithRefreshIfNeeded(source, upstreamRange)
                    } catch (ce: CancellationException) {
                        throw ce
                    } catch (_: Throwable) {
                        if (!session.revoked.get()) {
                            runCatching {
                                out.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                            }
                        }
                        return@withPermit
                    }
                    session.activeUpstream = opened
                    try {
                        if (session.revoked.get()) return@withPermit
                        if (opened.statusCode != 200 && opened.statusCode != 206) {
                            runCatching {
                                out.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                            }
                            return@withPermit
                        }

                        val mime = PlaybackDecisionPolicy.guessMimeType(source.fileName)
                        val fullLength = RangeHeaderValidator.extractFullAssetLength(
                            statusCode = opened.statusCode,
                            requestHadRange = upstreamRange != null,
                            contentRangeHeader = opened.headers["content-range"],
                            contentLengthHeader = opened.headers["content-length"]
                        ) ?: source.expectedSize.takeIf { it > 0L }

                        if (isHead) {
                            val sb = StringBuilder("HTTP/1.1 200 OK\r\nContent-Type: $mime\r\nAccept-Ranges: bytes\r\nConnection: close\r\n")
                            if (fullLength != null) sb.append("Content-Length: $fullLength\r\n")
                            sb.append("\r\n")
                            runCatching { out.write(sb.toString().toByteArray()) }
                            return@withPermit
                        }

                        val statusLine = if (opened.statusCode == 206) "HTTP/1.1 206 Partial Content" else "HTTP/1.1 200 OK"
                        val headerBuf = StringBuilder("$statusLine\r\nContent-Type: $mime\r\nAccept-Ranges: bytes\r\nConnection: close\r\n")
                        val cl = opened.headers["content-length"]
                        if (cl != null) {
                            headerBuf.append("Content-Length: $cl\r\n")
                        } else if (opened.statusCode == 200 && fullLength != null) {
                            headerBuf.append("Content-Length: $fullLength\r\n")
                        }
                        opened.headers["content-range"]?.let { headerBuf.append("Content-Range: $it\r\n") }
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
                        var partOut: FileOutputStream? = null

                        if (eligibleForCache) {
                            partFile.delete()
                            partOut = runCatching { FileOutputStream(partFile) }.getOrNull()
                        }

                        val reqStart = requestedRange?.start ?: 0L
                        val reqEnd = requestedRange?.end
                        val isTinyProbe = (reqStart == 0L && (reqEnd ?: Long.MAX_VALUE) <= 1L)
                        val streamTaskId = "stream:${source.trackId}"
                        val hasStatusCallback = onAccountStreamStatusUpdate != null
                        var didPublishStreamStatus = false
                        var delivered = 0L
                        var completedCleanly = false
                        var resumeAttempts = 0
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
                                        val n = opened.bodyStream.read(buf)
                                        if (session.revoked.get()) {
                                            completedCleanly = false
                                            break@streamLoop
                                        }
                                        if (n < 0) break
                                        if (n == 0) continue
                                        try {
                                            out.write(buf, 0, n)
                                        } catch (_: Exception) {
                                            completedCleanly = false
                                            break@streamLoop
                                        }
                                        if (session.revoked.get()) {
                                            completedCleanly = false
                                            break@streamLoop
                                        }
                                        if (partOut != null) {
                                            runCatching { partOut!!.write(buf, 0, n) }.onFailure {
                                                runCatching { partOut?.close() }
                                                partOut = null
                                            }
                                        }
                                        delivered += n.toLong()
                                        windowBytes += n.toLong()
                                        if (!isTinyProbe && hasStatusCallback && !session.revoked.get()) {
                                            val elapsedMs = (System.nanoTime() - windowStartNs) / 1_000_000L
                                            if (!didPublishStreamStatus || elapsedMs >= 300L) {
                                                val speed = if (didPublishStreamStatus) {
                                                    (windowBytes * 1000L) / elapsedMs.coerceAtLeast(1L)
                                                } else {
                                                    n.toLong()
                                                }
                                                didPublishStreamStatus = true
                                                windowBytes = 0L
                                                windowStartNs = System.nanoTime()
                                                publishStatus(
                                                    streamTaskId,
                                                    source.accountHash,
                                                    TransferStatus(
                                                        id = streamTaskId,
                                                        label = source.fileName,
                                                        kind = "stream",
                                                        state = "running",
                                                        bytesPerSecond = speed,
                                                        transferredBytes = fullLength?.let { minOf(reqStart + delivered, it) } ?: (reqStart + delivered),
                                                        totalBytes = fullLength
                                                    )
                                                )
                                            }
                                        }
                                        resumeAttempts = 0
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
                                    if (resumeAttempts > 4) {
                                        completedCleanly = false
                                        break@streamLoop
                                    }
                                    val resumeOffset = reqStart + delivered
                                    if (reqEnd != null && resumeOffset > reqEnd) {
                                        completedCleanly = !session.revoked.get()
                                        break@streamLoop
                                    }
                                    runCatching { opened.bodyStream.close(); opened.onClose() }
                                    val resumeRange = ParsedByteRange(resumeOffset, reqEnd).headerValue
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
                                        RangeHeaderValidator.validateResumeResponse(
                                            expectedStartOffset = resumeOffset,
                                            statusCode = nextOpened.statusCode,
                                            contentRangeHeader = nextOpened.headers["content-range"]
                                        )
                                    }.isSuccess
                                    if (!valid || session.revoked.get()) {
                                        runCatching { nextOpened.bodyStream.close(); nextOpened.onClose() }
                                        completedCleanly = false
                                        break@streamLoop
                                    }
                                    opened = nextOpened
                                    session.activeUpstream = nextOpened
                                }
                            }
                        } finally {
                            if (didPublishStreamStatus) {
                                publishStatus(streamTaskId, source.accountHash, null)
                            }
                            runCatching { partOut?.flush(); partOut?.close() }
                            if (eligibleForCache) {
                                val expectedTotal = fullLength ?: 0L
                                val matchesExpected = (source.expectedSize == 0L) || (delivered == source.expectedSize)
                                val stillAuthorized = !session.revoked.get() &&
                                    isSourceStillRegistered(source.token, source.accountHash)
                                if (stillAuthorized && completedCleanly && partOut != null && expectedTotal > 0L && delivered == expectedTotal && matchesExpected) {
                                    val promoted = try {
                                        Files.move(
                                            partFile.toPath(),
                                            source.cacheDestination.toPath(),
                                            StandardCopyOption.REPLACE_EXISTING,
                                            StandardCopyOption.ATOMIC_MOVE
                                        )
                                        true
                                    } catch (_: AtomicMoveNotSupportedException) {
                                        runCatching {
                                            Files.move(
                                                partFile.toPath(),
                                                source.cacheDestination.toPath(),
                                                StandardCopyOption.REPLACE_EXISTING
                                            )
                                        }.isSuccess
                                    } catch (_: Exception) {
                                        false
                                    }
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
                        runCatching { opened.bodyStream.close(); opened.onClose() }
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
        val headerBytes = ArrayList<Byte>(512)
        var matched = 0
        val endSeq = byteArrayOf('\r'.code.toByte(), '\n'.code.toByte(), '\r'.code.toByte(), '\n'.code.toByte())
        while (headerBytes.size < 16_384) {
            val b = input.read()
            if (b < 0) break
            val byteVal = b.toByte()
            headerBytes.add(byteVal)
            if (byteVal == endSeq[matched]) {
                matched += 1
                if (matched == 4) break
            } else {
                matched = if (byteVal == endSeq[0]) 1 else 0
            }
        }
        if (headerBytes.isEmpty()) return null
        val rawText = ByteArray(headerBytes.size) { headerBytes[it] }.toString(Charsets.UTF_8)
        val lines = rawText.split("\r\n")
        val firstParts = lines.firstOrNull()?.split(' ') ?: return null
        if (firstParts.size < 2) return null
        val headers = mutableMapOf<String, String>()
        for (line in lines.drop(1)) {
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            if (colon > 0) {
                headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
            }
        }
        val cleanPath = firstParts[1].substringBefore('?')
        return ParsedHttpRequest(firstParts[0], cleanPath, headers)
    }
}
