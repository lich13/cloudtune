import Foundation

/// Global remote request concurrency limiter (`maxPermits = 8`) shared across stream proxy,
/// background next-track prefetch, full-track playback cache, and user export downloads.
package actor GlobalTransferSemaphore {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    package let maxPermits: Int
    package private(set) var activePermits: Int = 0
    package private(set) var peakObservedPermits: Int = 0
    private var waiters: [Waiter] = []

    package init(maxPermits: Int = 8) {
        self.maxPermits = max(1, maxPermits)
    }

    package func acquire() async throws {
        try Task.checkCancellation()
        if activePermits < maxPermits {
            activePermits += 1
            peakObservedPermits = max(peakObservedPermits, activePermits)
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: waiterID, continuation: cont))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let removed = waiters.remove(at: idx)
        removed.continuation.resume(throwing: CancellationError())
    }

    package func release() {
        guard activePermits > 0 else { return }
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: ())
            return
        }
        activePermits -= 1
    }
}

package struct ParsedByteRange: Equatable, Sendable {
    package let start: UInt64
    package let end: UInt64?
    package let suffixLength: UInt64?

    package init(start: UInt64, end: UInt64?, suffixLength: UInt64? = nil) {
        self.start = start
        self.end = end
        self.suffixLength = suffixLength
    }

    package static func suffix(_ length: UInt64) -> ParsedByteRange {
        ParsedByteRange(start: 0, end: nil, suffixLength: length)
    }

    package var isSuffix: Bool {
        suffixLength != nil
    }

    package var headerValue: String {
        if let suffixLength {
            return "bytes=-\(suffixLength)"
        }
        if let end {
            return "bytes=\(start)-\(end)"
        }
        return "bytes=\(start)-"
    }

    /// Resolves this range against a known `totalLength > 0` into inclusive `(start, end)`.
    /// Returns `nil` when unsatisfiable (`416 Range Not Satisfiable`).
    package func resolve(totalLength: UInt64) -> (start: UInt64, end: UInt64)? {
        guard totalLength > 0 else { return nil }
        if let suffixLength {
            guard suffixLength > 0 else { return nil }
            let resolvedStart = totalLength > suffixLength ? (totalLength - suffixLength) : 0
            return (resolvedStart, totalLength - 1)
        }
        guard start < totalLength else { return nil }
        let resolvedEnd = min(end ?? (totalLength - 1), totalLength - 1)
        guard resolvedEnd >= start else { return nil }
        return (start, resolvedEnd)
    }
}

package struct ParsedContentRange: Equatable, Sendable {
    package let start: UInt64
    package let end: UInt64
    package let totalLength: UInt64?
}

package enum RangeHeaderValidator {
    /// Parse single-range `bytes=start-[end]` or RFC 9110 suffix range `bytes=-N` (`N > 0`).
    /// Returns `nil` when absent or invalid (including `bytes=-0`).
    package static func parseRequestRange(_ rawHeader: String?) -> ParsedByteRange? {
        guard let raw = rawHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.lowercased().hasPrefix("bytes="),
              !raw.contains(",") else {
            return nil
        }
        let spec = raw.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }
        if parts[0].isEmpty {
            guard let suffixLen = UInt64(parts[1]), suffixLen > 0 else {
                return nil
            }
            return ParsedByteRange.suffix(suffixLen)
        }
        guard let start = UInt64(parts[0]),
              parts[1].isEmpty || UInt64(parts[1]) != nil else {
            return nil
        }
        let end = parts[1].isEmpty ? nil : UInt64(parts[1])
        if let end, end < start { return nil }
        return ParsedByteRange(start: start, end: end)
    }

    /// Write-through cache is ONLY permitted when `Range` is absent OR `Range: bytes=0-` (no upper bound).
    /// Probes like `bytes=0-1`, suffix ranges `bytes=-N`, or mid-stream seeks like `bytes=65536-` NEVER write through to cache.
    package static func canWriteThroughToCache(rangeHeader: String?) -> Bool {
        guard let raw = rangeHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return true
        }
        guard let parsed = parseRequestRange(raw) else {
            return false
        }
        return !parsed.isSuffix && parsed.start == 0 && parsed.end == nil
    }

    package static func parseContentRange(_ rawHeader: String?) -> ParsedContentRange? {
        guard let raw = rawHeader?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        let lower = raw.lowercased()
        guard lower.hasPrefix("bytes ") else { return nil }
        let rest = raw.dropFirst("bytes ".count).trimmingCharacters(in: .whitespaces)
        let slashParts = rest.split(separator: "/", maxSplits: 1)
        guard slashParts.count == 2 else { return nil }
        let span = slashParts[0].split(separator: "-", maxSplits: 1)
        guard span.count == 2,
              let start = UInt64(span[0]),
              let end = UInt64(span[1]),
              end >= start else {
            return nil
        }
        let total: UInt64?
        if slashParts[1] == "*" {
            total = nil
        } else {
            guard let parsedTotal = UInt64(slashParts[1]), parsedTotal > end else {
                return nil
            }
            total = parsedTotal
        }
        return ParsedContentRange(start: start, end: end, totalLength: total)
    }

    /// Extracts authoritative full asset byte length ONLY from `Content-Range` `/total` on `206`
    /// or `Content-Length` on un-ranged `200 OK`.
    package static func extractFullAssetLength(
        statusCode: Int,
        requestHadRange: Bool,
        contentRangeHeader: String?,
        contentLengthHeader: String?
    ) -> UInt64? {
        if statusCode == 206 {
            return parseContentRange(contentRangeHeader)?.totalLength
        }
        if statusCode == 200 && !requestHadRange {
            if let raw = contentLengthHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
               let val = UInt64(raw), val > 0 {
                return val
            }
        }
        return nil
    }

    /// Validates an upstream non-zero or resume response at `expectedStartOffset`.
    /// When `expectedStartOffset > 0`, upstream MUST return `206 Partial Content` with matching `Content-Range` start!
    package static func validateResumeResponse(
        expectedStartOffset: UInt64,
        statusCode: Int,
        contentRangeHeader: String?
    ) throws {
        if expectedStartOffset == 0 {
            guard statusCode == 200 || statusCode == 206 else {
                throw CloudTuneError.httpStatus(statusCode, "上游流响应状态异常")
            }
            return
        }
        guard statusCode == 206 else {
            throw CloudTuneError.protocolError("断点续传要求 HTTP 206，但上游返回 \(statusCode)，已中止以防缓存错位拼接")
        }
        guard let cr = parseContentRange(contentRangeHeader), cr.start == expectedStartOffset else {
            throw CloudTuneError.protocolError("上游 Content-Range 起点与续传偏移 \(expectedStartOffset) 不匹配")
        }
    }

    /// Validates an upstream response to a suffix range request `bytes=-N` (`N > 0`).
    /// Upstream MUST return `206` with `Content-Range: bytes S-E/T` where `E + 1 == T` and `S == (T > N ? T - N : 0)`.
    @discardableResult
    package static func validateSuffixResponse(
        suffixLength: UInt64,
        statusCode: Int,
        contentRangeHeader: String?
    ) throws -> ParsedContentRange {
        guard suffixLength > 0 else {
            throw CloudTuneError.invalidRequest("无效的后缀 Range 请求长度")
        }
        guard statusCode == 206 else {
            throw CloudTuneError.protocolError("后缀 Range 请求要求 HTTP 206，但上游返回 \(statusCode)")
        }
        guard let cr = parseContentRange(contentRangeHeader),
              let total = cr.totalLength,
              total > 0 else {
            throw CloudTuneError.protocolError("上游后缀 Range 响应缺少有效总长度")
        }
        let expectedStart = total > suffixLength ? (total - suffixLength) : 0
        guard cr.end == total - 1, cr.start == expectedStart else {
            throw CloudTuneError.protocolError(
                "上游后缀 Content-Range (\(cr.start)-\(cr.end)/\(total)) 与 bytes=-\(suffixLength) 不匹配"
            )
        }
        return cr
    }

    package static func splitByteRanges(totalSize: UInt64, partCount: Int) -> [(start: UInt64, end: UInt64)] {
        guard totalSize > 0 else { return [] }
        let parts = max(1, partCount)
        let partSize = (totalSize + UInt64(parts) - 1) / UInt64(parts)
        var result: [(UInt64, UInt64)] = []
        var start: UInt64 = 0
        while start < totalSize {
            let end = min(start + partSize - 1, totalSize - 1)
            result.append((start, end))
            start = end + 1
        }
        return result
    }
}

package enum PlaybackFailureAction: Equatable, Sendable {
    case fallbackToStreamProxyOnce
    case fallbackToFullDownloadOnce
    case stopImmediatelyUnsupportedCodec(String)
    case retryTransientAfterDelay(attempt: Int)
    case stopAfterMaxRetries
}

package enum PlaybackDecisionPolicy {
    package static let largeTrackThresholdBytes: UInt64 = 16 * 1024 * 1024
    package static let maxRecoveryAttempts: Int = 6

    /// Determines whether a track should be downloaded in full before playback starts.
    /// `forceStreamProxy = true` (triggered by `download-timeout-fallback`) bypasses the 16 MiB guard once.
    package static func shouldDownloadBeforePlayback(
        mode: PlaybackMode,
        sizeBytes: UInt64,
        forceStreamProxy: Bool
    ) -> Bool {
        if forceStreamProxy {
            return false
        }
        if mode == .downloadFirst {
            return true
        }
        return sizeBytes >= largeTrackThresholdBytes
    }

    package static func classifyPlaybackFailure(
        fileName: String,
        wasLoopbackStream: Bool,
        wasDownloadPhaseTimeout: Bool,
        isDecodeOrFormatUnsupported: Bool,
        priorAttemptCount: Int
    ) -> PlaybackFailureAction {
        if wasDownloadPhaseTimeout && !wasLoopbackStream && priorAttemptCount == 0 {
            return .fallbackToStreamProxyOnce
        }
        if isDecodeOrFormatUnsupported {
            if wasLoopbackStream && priorAttemptCount == 0 {
                return .fallbackToFullDownloadOnce
            }
            let ext = (fileName as NSString).pathExtension.lowercased()
            let suffix = ext.isEmpty ? "当前格式" : ".\(ext)"
            return .stopImmediatelyUnsupportedCodec(
                "本地完整文件编码不受系统解码器支持（\(suffix)），已停止自动重试，请使用外部播放器打开。"
            )
        }
        if priorAttemptCount >= maxRecoveryAttempts {
            return .stopAfterMaxRetries
        }
        return .retryTransientAfterDelay(attempt: priorAttemptCount + 1)
    }
}
