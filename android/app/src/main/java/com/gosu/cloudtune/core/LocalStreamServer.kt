package com.gosu.cloudtune.core

import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.net.URLEncoder
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

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
    override suspend fun open(url: String, rangeHeader: String?): OpenedUpstreamStream {
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
            conn.errorStream ?: java.io.ByteArrayInputStream(ByteArray(0))
        }
        return OpenedUpstreamStream(
            statusCode = status,
            headers = headers,
            bodyStream = stream,
            onClose = { runCatching { conn.disconnect() } }
        )
    }
}

/**
 * Localhost (`127.0.0.1:0`) HTTP/1.1 Range streaming proxy with strict write-through & `206` resume verification.
 */
class LocalStreamServer(
    private val limiter: GlobalTransferLimiter,
    private val opener: UpstreamStreamOpener = HttpUrlConnectionStreamOpener(),
    private val onStreamStatusUpdate: ((String, TransferStatus?) -> Unit)? = null,
    private val urlRefresher: (suspend (String) -> String)? = null
) : AutoCloseable {
    private val serverSocket = ServerSocket(0, 64, InetAddress.getByName("127.0.0.1"))
    val port: Int = serverSocket.localPort
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val sources = ConcurrentHashMap<String, Pair<StreamSourceRegistration, CacheManager>>()

    init {
        scope.launch {
            while (isActive && !serverSocket.isClosed) {
                val client = runCatching { serverSocket.accept() }.getOrNull() ?: break
                launch { handleClient(client) }
            }
        }
    }

    fun registerSource(reg: StreamSourceRegistration, cacheManager: CacheManager): String {
        sources[reg.token] = reg to cacheManager
        val encoded = URLEncoder.encode(Cloud189Protocol.sanitizeFileName(reg.fileName), "UTF-8")
            .replace("+", "%20")
        return "http://127.0.0.1:$port/stream/${reg.token}/$encoded"
    }

    fun revokeAllSources(accountHash: String) {
        val iterator = sources.entries.iterator()
        while (iterator.hasNext()) {
            if (iterator.next().value.first.accountHash == accountHash) {
                iterator.remove()
            }
        }
    }

    override fun close() {
        sources.clear()
        runCatching { serverSocket.close() }
        scope.cancel()
    }

    private suspend fun handleClient(socket: Socket) {
        socket.use { client ->
            val req = readHttpRequest(client.getInputStream()) ?: return
            val segments = req.path.trim('/').split('/')
            val out = client.getOutputStream()
            if (segments.size < 2 || segments[0] != "stream") {
                out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                return
            }
            val (source, cacheManager) = sources[segments[1]] ?: run {
                out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                return
            }

            val isHead = req.method.equals("HEAD", ignoreCase = true)
            val clientRangeRaw = req.headers["range"]
            val requestedRange = RangeHeaderValidator.parseRequestRange(clientRangeRaw)
            val upstreamRange = if (isHead) "bytes=0-0" else clientRangeRaw

            limiter.withPermit {
                var opened = openWithRefreshIfNeeded(source, upstreamRange)
                try {
                    if (opened.statusCode != 200 && opened.statusCode != 206) {
                        out.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
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
                        out.write(sb.toString().toByteArray())
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
                    out.write(headerBuf.toString().toByteArray())
                    out.flush()

                    val eligibleForCache = RangeHeaderValidator.canWriteThroughToCache(clientRangeRaw) &&
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
                                    val n = opened.bodyStream.read(buf)
                                    if (n < 0) break
                                    if (n == 0) continue
                                    try {
                                        out.write(buf, 0, n)
                                    } catch (_: Exception) {
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
                                    if (!isTinyProbe && onStreamStatusUpdate != null) {
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
                                            onStreamStatusUpdate.invoke(
                                                streamTaskId,
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
                                completedCleanly = true
                                break@streamLoop
                            } catch (_: Exception) {
                                resumeAttempts += 1
                                if (resumeAttempts > 4) {
                                    completedCleanly = false
                                    break@streamLoop
                                }
                                val resumeOffset = reqStart + delivered
                                if (reqEnd != null && resumeOffset > reqEnd) {
                                    completedCleanly = true
                                    break@streamLoop
                                }
                                runCatching { opened.bodyStream.close(); opened.onClose() }
                                val resumeRange = ParsedByteRange(resumeOffset, reqEnd).headerValue
                                val nextOpened = runCatching { openWithRefreshIfNeeded(source, resumeRange) }.getOrNull() ?: run {
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
                                if (!valid) {
                                    runCatching { nextOpened.bodyStream.close(); nextOpened.onClose() }
                                    completedCleanly = false
                                    break@streamLoop
                                }
                                opened = nextOpened
                            }
                        }
                    } finally {
                        if (didPublishStreamStatus) {
                            onStreamStatusUpdate?.invoke(streamTaskId, null)
                        }
                    }

                    runCatching { partOut?.flush(); partOut?.close() }
                    if (eligibleForCache) {
                        val expectedTotal = fullLength ?: 0L
                        val matchesExpected = (source.expectedSize == 0L) || (delivered == source.expectedSize)
                        if (completedCleanly && partOut != null && expectedTotal > 0L && delivered == expectedTotal && matchesExpected) {
                            source.cacheDestination.delete()
                            if (partFile.renameTo(source.cacheDestination)) {
                                cacheManager.recordCompletedFile(
                                    trackId = source.trackId,
                                    file = source.cacheDestination,
                                    sizeBytes = delivered,
                                    limitBytes = source.cacheLimitBytes
                                )
                            } else {
                                partFile.delete()
                            }
                        } else {
                            partFile.delete()
                        }
                        cacheManager.finishWriteThrough(source.trackId)
                    }
                } finally {
                    runCatching { opened.bodyStream.close(); opened.onClose() }
                }
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
