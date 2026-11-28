import Foundation

/// Global remote request concurrency limiter (`maxPermits = 8`) shared across stream proxy,
/// background next-track prefetch, full-track playback cache, and user export downloads.
public actor GlobalTransferSemaphore {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    public let maxPermits: Int
    public private(set) var activePermits: Int = 0
    public private(set) var peakObservedPermits: Int = 0
    private var waiters: [Waiter] = []

    public init(maxPermits: Int = 8) {
        self.maxPermits = max(1, maxPermits)
    }

    public func acquire() async throws {
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

    public func release() {
        guard activePermits > 0 else { return }
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: ())
            return
        }
        activePermits -= 1
    }
}

public struct ParsedByteRange: Equatable, Sendable {
    public let start: UInt64
    public let end: UInt64?

    public init(start: UInt64, end: UInt64?) {
        self.start = start
        self.end = end
    }

    public var headerValue: String {
        if let end {
            return "bytes=\(start)-\(end)"
        }
        return "bytes=\(start)-"
    }
}

public struct ParsedContentRange: Equatable, Sendable {
    public let start: UInt64
    public let end: UInt64
    public let totalLength: UInt64?
}

public enum RangeHeaderValidator {
    /// Parse single-range `bytes=start-[end]`. Returns `nil` when absent or invalid.
    public static func parseRequestRange(_ rawHeader: String?) -> ParsedByteRange? {
        guard let raw = rawHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.lowercased().hasPrefix("bytes="),
              !raw.contains(",") else {
            return nil
        }
        let spec = raw.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = UInt64(parts[0]),
              parts[1].isEmpty || UInt64(parts[1]) != nil else {
            return nil
        }
        let end = parts[1].isEmpty ? nil : UInt64(parts[1])
        if let end, end < start { return nil }
        return ParsedByteRange(start: start, end: end)
    }

    /// Write-through cache is ONLY permitted when `Range` is absent OR `Range: bytes=0-` (no upper bound).
    /// Probes like `bytes=0-1` or mid-stream seeks like `bytes=65536-` NEVER write through to cache.
    public static func canWriteThroughToCache(rangeHeader: String?) -> Bool {
        guard let raw = rangeHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return true
        }
        guard let parsed = parseRequestRange(raw) else {
            return false
        }
        return parsed.start == 0 && parsed.end == nil
    }

    public static func parseContentRange(_ rawHeader: String?) -> ParsedContentRange? {
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
        let total = slashParts[1] == "*" ? nil : UInt64(slashParts[1])
        return ParsedContentRange(start: start, end: end, totalLength: total)
    }

    /// Extracts authoritative full asset byte length ONLY from `Content-Range` `/total` on `206`
    /// or `Content-Length` on un-ranged `200 OK`.
    public static func extractFullAssetLength(
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

    /// Validates an upstream resume response at `expectedStartOffset`.
    /// When `expectedStartOffset > 0`, upstream MUST return `206 Partial Content` with matching `Content-Range` start!
    public static func validateResumeResponse(
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

    public static func splitByteRanges(totalSize: UInt64, partCount: Int) -> [(start: UInt64, end: UInt64)] {
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

public enum PlaybackFailureAction: Equatable, Sendable {
    case fallbackToStreamProxyOnce
    case fallbackToFullDownloadOnce
    case stopImmediatelyUnsupportedCodec(String)
    case retryTransientAfterDelay(attempt: Int)
    case stopAfterMaxRetries
}

public enum PlaybackDecisionPolicy {
    public static let largeTrackThresholdBytes: UInt64 = 16 * 1024 * 1024
    public static let maxRecoveryAttempts: Int = 6

    /// Determines whether a track should be downloaded in full before playback starts.
    /// `forceStreamProxy = true` (triggered by `download-timeout-fallback`) bypasses the 16 MiB guard once.
    public static func shouldDownloadBeforePlayback(
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

    public static func classifyPlaybackFailure(
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
