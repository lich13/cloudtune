package com.gosu.cloudtune.core

import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.sync.Semaphore

/**
 * Shared global remote request limiter (`maxPermits = 8`) governing loopback stream proxy,
 * background next-track prefetch, full-track playback cache, and user export downloads.
 */
class GlobalTransferLimiter(val maxPermits: Int = 8) {
    private val semaphore = Semaphore(maxPermits.coerceAtLeast(1))
    private val active = AtomicInteger(0)
    private val peak = AtomicInteger(0)

    val activePermits: Int get() = active.get()
    val peakObservedPermits: Int get() = peak.get()

    suspend fun <T> withPermit(block: suspend () -> T): T {
        semaphore.acquire()
        val nowActive = active.incrementAndGet()
        peak.updateAndGet { prev -> maxOf(prev, nowActive) }
        return try {
            block()
        } finally {
            active.decrementAndGet()
            semaphore.release()
        }
    }
}

data class ParsedByteRange(
    val start: Long,
    val end: Long?,
    val suffixLength: Long? = null
) {
    val isSuffix: Boolean get() = suffixLength != null

    val headerValue: String
        get() = when {
            suffixLength != null -> "bytes=-$suffixLength"
            end != null -> "bytes=$start-$end"
            else -> "bytes=$start-"
        }

    fun resolve(totalLength: Long): Pair<Long, Long>? {
        if (totalLength <= 0L) return null
        val sfx = suffixLength
        if (sfx != null) {
            if (sfx <= 0L) return null
            val resolvedStart = if (totalLength > sfx) totalLength - sfx else 0L
            return resolvedStart to (totalLength - 1L)
        }
        if (start < 0L || start >= totalLength) return null
        val resolvedEnd = end?.let { minOf(it, totalLength - 1L) } ?: (totalLength - 1L)
        if (resolvedEnd < start) return null
        return start to resolvedEnd
    }
}

data class ParsedContentRange(val start: Long, val end: Long, val totalLength: Long?)

object RangeHeaderValidator {
    fun parseRequestRange(rawHeader: String?): ParsedByteRange? {
        val raw = rawHeader?.trim() ?: return null
        if (!raw.lowercase(Locale.US).startsWith("bytes=") || raw.contains(",")) return null
        val spec = raw.substring("bytes=".length).trim()
        val dash = spec.indexOf('-')
        if (dash < 0) return null
        if (dash == 0) {
            val suffixPart = spec.substring(1)
            if (suffixPart.isEmpty() || !suffixPart.all { it.isDigit() }) return null
            val suffixLen = suffixPart.toLongOrNull() ?: return null
            if (suffixLen <= 0L) return null
            return ParsedByteRange(start = 0L, end = null, suffixLength = suffixLen)
        }
        val startPart = spec.substring(0, dash)
        if (startPart.isEmpty() || !startPart.all { it.isDigit() }) return null
        val start = startPart.toLongOrNull() ?: return null
        val endPart = spec.substring(dash + 1)
        val end = if (endPart.isEmpty()) {
            null
        } else {
            if (!endPart.all { it.isDigit() }) return null
            endPart.toLongOrNull() ?: return null
        }
        if (start < 0L || (end != null && end < start)) return null
        return ParsedByteRange(start = start, end = end, suffixLength = null)
    }

    /**
     * Write-through cache is ONLY permitted when `Range` is absent OR `Range: bytes=0-` (no upper bound).
     * Probes (`bytes=0-1`), suffix ranges (`bytes=-512`), or mid-stream seeks (`bytes=65536-`) NEVER write through to cache.
     */
    fun canWriteThroughToCache(rangeHeader: String?): Boolean {
        val raw = rangeHeader?.trim().orEmpty()
        if (raw.isEmpty()) return true
        val parsed = parseRequestRange(raw) ?: return false
        return !parsed.isSuffix && parsed.start == 0L && parsed.end == null
    }

    fun parseContentRange(rawHeader: String?): ParsedContentRange? {
        val raw = rawHeader?.trim() ?: return null
        if (!raw.lowercase(Locale.US).startsWith("bytes ")) return null
        val rest = raw.substring("bytes ".length).trim()
        val slash = rest.indexOf('/')
        if (slash <= 0) return null
        val span = rest.substring(0, slash)
        val totalPart = rest.substring(slash + 1)
        val dash = span.indexOf('-')
        if (dash <= 0) return null
        val startPart = span.substring(0, dash)
        val endPart = span.substring(dash + 1)
        if (!startPart.all { it.isDigit() } || !endPart.all { it.isDigit() }) return null
        val start = startPart.toLongOrNull() ?: return null
        val end = endPart.toLongOrNull() ?: return null
        if (start < 0L || end < start) return null
        val total = if (totalPart == "*") {
            null
        } else {
            if (!totalPart.all { it.isDigit() }) return null
            val parsedTotal = totalPart.toLongOrNull() ?: return null
            if (parsedTotal <= end) return null
            parsedTotal
        }
        return ParsedContentRange(start, end, total)
    }

    fun extractFullAssetLength(
        statusCode: Int,
        requestHadRange: Boolean,
        contentRangeHeader: String?,
        contentLengthHeader: String?
    ): Long? {
        if (statusCode == 206) {
            return parseContentRange(contentRangeHeader)?.totalLength
        }
        if (statusCode == 200 && !requestHadRange) {
            return contentLengthHeader?.trim()?.toLongOrNull()?.takeIf { it > 0L }
        }
        return null
    }

    fun validateResumeResponse(
        expectedStartOffset: Long,
        statusCode: Int,
        contentRangeHeader: String?
    ) {
        if (expectedStartOffset == 0L) {
            if (statusCode != 200 && statusCode != 206) {
                throw CloudTuneException("上游流响应状态异常 (HTTP $statusCode)")
            }
            return
        }
        if (statusCode != 206) {
            throw CloudTuneException("断点续传要求 HTTP 206，但上游返回 $statusCode，已中止以防缓存错位拼接")
        }
        val cr = parseContentRange(contentRangeHeader)
        if (cr == null || cr.start != expectedStartOffset) {
            throw CloudTuneException("上游 Content-Range 起点与续传偏移 $expectedStartOffset 不匹配")
        }
    }

    fun validateSuffixResponse(
        suffixLength: Long,
        statusCode: Int,
        contentRangeHeader: String?
    ): ParsedContentRange {
        if (suffixLength <= 0L) {
            throw CloudTuneException("无效的后缀 Range 长度: $suffixLength")
        }
        if (statusCode != 206) {
            throw CloudTuneException("后缀 Range 请求要求 HTTP 206，但上游返回 $statusCode")
        }
        val cr = parseContentRange(contentRangeHeader)
            ?: throw CloudTuneException("上游缺少有效的 Content-Range 响应头")
        val total = cr.totalLength
            ?: throw CloudTuneException("上游后缀 Range 响应缺少总字节长度")
        if (total <= 0L || cr.end + 1L != total) {
            throw CloudTuneException("上游后缀 Content-Range 终点不匹配: $contentRangeHeader")
        }
        val expectedStart = if (total > suffixLength) total - suffixLength else 0L
        if (cr.start != expectedStart) {
            throw CloudTuneException("上游后缀 Content-Range 起点与期望偏移 $expectedStart 不匹配")
        }
        return cr
    }

    fun splitByteRanges(totalSize: Long, partCount: Int): List<Pair<Long, Long>> {
        if (totalSize <= 0L) return emptyList()
        val parts = partCount.coerceAtLeast(1)
        val partSize = (totalSize + parts - 1L) / parts
        val out = mutableListOf<Pair<Long, Long>>()
        var start = 0L
        while (start < totalSize) {
            val end = minOf(start + partSize - 1L, totalSize - 1L)
            out += start to end
            start = end + 1L
        }
        return out
    }
}

sealed interface PlaybackFailureAction {
    data object FallbackToStreamProxyOnce : PlaybackFailureAction
    data object FallbackToFullDownloadOnce : PlaybackFailureAction
    data class StopImmediatelyUnsupportedCodec(val userMessage: String) : PlaybackFailureAction
    data class RetryTransientAfterDelay(val attempt: Int) : PlaybackFailureAction
    data object StopAfterMaxRetries : PlaybackFailureAction
}

object PlaybackDecisionPolicy {
    const val LARGE_TRACK_THRESHOLD_BYTES: Long = 16L * 1024L * 1024L
    const val MAX_RECOVERY_ATTEMPTS: Int = 6

    fun shouldDownloadBeforePlayback(
        mode: PlaybackMode,
        sizeBytes: Long,
        forceStreamProxy: Boolean
    ): Boolean {
        if (forceStreamProxy) return false
        if (mode == PlaybackMode.DOWNLOAD_FIRST) return true
        return sizeBytes >= LARGE_TRACK_THRESHOLD_BYTES
    }

    fun classifyPlaybackFailure(
        fileName: String,
        wasLoopbackStream: Boolean,
        wasDownloadPhaseTimeout: Boolean,
        isDecodeOrFormatUnsupported: Boolean,
        priorAttemptCount: Int
    ): PlaybackFailureAction {
        if (wasDownloadPhaseTimeout && !wasLoopbackStream && priorAttemptCount == 0) {
            return PlaybackFailureAction.FallbackToStreamProxyOnce
        }
        if (isDecodeOrFormatUnsupported) {
            if (wasLoopbackStream && priorAttemptCount == 0) {
                return PlaybackFailureAction.FallbackToFullDownloadOnce
            }
            val dot = fileName.lastIndexOf('.')
            val ext = if (dot >= 0) fileName.substring(dot).lowercase(Locale.ROOT) else "当前格式"
            return PlaybackFailureAction.StopImmediatelyUnsupportedCodec(
                "本地完整文件编码不受系统解码器支持（$ext），已停止自动重试，请使用外部播放器打开。"
            )
        }
        if (priorAttemptCount >= MAX_RECOVERY_ATTEMPTS) {
            return PlaybackFailureAction.StopAfterMaxRetries
        }
        return PlaybackFailureAction.RetryTransientAfterDelay(priorAttemptCount + 1)
    }
}
