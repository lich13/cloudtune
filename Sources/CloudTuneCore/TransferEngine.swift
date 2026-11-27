import Foundation

public struct StagedDownloadManifest: Codable, Equatable, Sendable {
    public var taskId: String
    public var accountId: String
    public var trackId: String
    public var fileName: String
    public var relativeExportSubpath: String
    public var totalSize: UInt64
    public var partCount: Int
    public var state: String

    public init(
        taskId: String,
        accountId: String,
        trackId: String,
        fileName: String,
        relativeExportSubpath: String,
        totalSize: UInt64,
        partCount: Int,
        state: String
    ) {
        self.taskId = taskId
        self.accountId = accountId
        self.trackId = trackId
        self.fileName = fileName
        self.relativeExportSubpath = relativeExportSubpath
        self.totalSize = totalSize
        self.partCount = partCount
        self.state = state
    }
}

public actor TransferEngine {
    private let semaphore: GlobalTransferSemaphore
    private let fetcher: UpstreamStreamFetcher
    private let urlResolver: @Sendable (String) async throws -> URL
    private var statuses: [String: TransferStatus] = [:]
    private var manifests: [String: StagedDownloadManifest] = [:]
    private var runningTasks: [String: Task<Void, Error>] = [:]
    private let fm = FileManager.default

    public init(
        semaphore: GlobalTransferSemaphore,
        fetcher: UpstreamStreamFetcher = URLSessionUpstreamStreamFetcher(),
        urlResolver: @escaping @Sendable (String) async throws -> URL
    ) {
        self.semaphore = semaphore
        self.fetcher = fetcher
        self.urlResolver = urlResolver
    }

    public func restorePersistedDownloads(for accountId: String, accountStore: AccountScopedStore) async {
        guard let paths = try? await accountStore.paths(for: accountId),
              let data = try? Data(contentsOf: paths.transfersURL),
              let saved = try? JSONDecoder().decode([StagedDownloadManifest].self, from: data) else {
            return
        }
        for var item in saved {
            if item.state == "running" {
                item.state = "paused"
            }
            manifests[item.taskId] = item
            let completed = completedBytesForManifest(item, stagingDir: paths.stagingDir)
            statuses[item.taskId] = TransferStatus(
                id: item.taskId,
                label: item.fileName,
                kind: "download",
                state: item.state,
                path: item.relativeExportSubpath,
                canPause: false,
                canResume: item.state == "paused",
                canDelete: true,
                bytesPerSecond: 0,
                transferredBytes: completed,
                totalBytes: item.totalSize > 0 ? item.totalSize : nil
            )
        }
    }

    public func snapshot() -> TransferSnapshotPayload {
        let items = statuses.values.sorted { $0.id < $1.id }
        let speed = items
            .filter { $0.state == "running" || $0.state == "streaming" }
            .reduce(UInt64(0)) { $0 + $1.bytesPerSecond }
        return TransferSnapshotPayload(totalSpeedBytesPerSecond: speed, items: items)
    }

    public func updateExternalTransferStatus(id: String, status: TransferStatus?) {
        if let status {
            statuses[id] = status
        } else {
            statuses.removeValue(forKey: id)
        }
    }

    public func cancelAll(forAccountId accountId: String) {
        for (id, manifest) in manifests where manifest.accountId == accountId {
            runningTasks[id]?.cancel()
            runningTasks.removeValue(forKey: id)
            statuses.removeValue(forKey: id)
            manifests.removeValue(forKey: id)
        }
        for key in statuses.keys where key.hasPrefix("stream:") || key.hasPrefix("prefetch:") || key.hasPrefix("playback:") {
            statuses.removeValue(forKey: key)
        }
    }

    /// Downloads a track directly into private cache (`download_first` or background `prefetch`) using the shared 8-permit limiter.
    @discardableResult
    public func downloadTrackToCache(
        track: TrackSummary,
        cacheStore: CacheStore,
        parallelThreads: Int,
        cacheLimitBytes: UInt64,
        kind: String = "playback"
    ) async throws -> URL {
        if let existing = await cacheStore.existingCachedFile(trackId: track.id) {
            return existing
        }
        let destination = await cacheStore.cacheFileURL(trackId: track.id, originalFileName: track.name)
        let partsDir = destination.appendingPathExtension("parts")
        let tempMerged = destination.appendingPathExtension("part")
        let taskId = "\(kind):\(track.id)"

        statuses[taskId] = TransferStatus(
            id: taskId,
            label: track.name,
            kind: kind,
            state: "running",
            canPause: false,
            canResume: false,
            canDelete: false,
            bytesPerSecond: 0,
            transferredBytes: 0,
            totalBytes: track.sizeBytes > 0 ? track.sizeBytes : nil
        )
        defer { statuses.removeValue(forKey: taskId) }

        let remoteURL = try await urlResolver(track.id)
        let probe = try await probeTarget(url: remoteURL, fallbackSize: track.sizeBytes)
        let totalSize = probe.totalSize
        let partCount = (probe.supportsRange && totalSize >= 1_048_576) ? min(max(1, parallelThreads), 8) : 1

        try fm.createDirectory(at: partsDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: partsDir)
            try? fm.removeItem(at: tempMerged)
        }

        try await downloadParts(
            taskId: taskId,
            trackId: track.id,
            initialURL: probe.finalURL,
            totalSize: totalSize,
            partCount: partCount,
            partsDir: partsDir
        )
        try mergeParts(partsDir: partsDir, partCount: partCount, into: tempMerged, expectedTotal: totalSize)
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempMerged, to: destination)
        _ = try await cacheStore.recordCompletedFile(
            trackId: track.id,
            fileURL: destination,
            sizeBytes: totalSize > 0 ? totalSize : track.sizeBytes,
            limitBytes: cacheLimitBytes
        )
        return destination
    }

    /// Enqueues a resumable multi-part export download staged in private storage and exported upon verification.
    @discardableResult
    public func enqueueExportDownload(
        accountId: String,
        track: TrackSummary,
        relativeExportSubpath: String,
        parallelThreads: Int,
        explicitDirectoryURL: URL? = nil,
        accountStore: AccountScopedStore
    ) async throws -> String {
        let taskId = "download:\(UUID().uuidString.lowercased())"
        let partCount = min(max(1, parallelThreads), 16)
        let manifest = StagedDownloadManifest(
            taskId: taskId,
            accountId: accountId,
            trackId: track.id,
            fileName: track.name,
            relativeExportSubpath: relativeExportSubpath,
            totalSize: track.sizeBytes,
            partCount: partCount,
            state: "running"
        )
        manifests[taskId] = manifest
        statuses[taskId] = TransferStatus(
            id: taskId,
            label: track.name,
            kind: "download",
            state: "running",
            path: relativeExportSubpath,
            canPause: true,
            canResume: false,
            canDelete: true,
            bytesPerSecond: 0,
            transferredBytes: 0,
            totalBytes: track.sizeBytes > 0 ? track.sizeBytes : nil
        )
        await persistManifests(for: accountId, accountStore: accountStore)
        spawnExportTask(manifest: manifest, explicitDirectoryURL: explicitDirectoryURL, accountStore: accountStore)
        return taskId
    }

    public func pauseTransfer(id: String, accountStore: AccountScopedStore) async {
        runningTasks[id]?.cancel()
        runningTasks.removeValue(forKey: id)
        if var m = manifests[id] {
            m.state = "paused"
            manifests[id] = m
            if var s = statuses[id] {
                s.state = "paused"
                s.canPause = false
                s.canResume = true
                s.bytesPerSecond = 0
                statuses[id] = s
            }
            await persistManifests(for: m.accountId, accountStore: accountStore)
        }
    }

    public func resumeTransfer(id: String, explicitDirectoryURL: URL? = nil, accountStore: AccountScopedStore) async {
        guard var m = manifests[id] else { return }
        m.state = "running"
        manifests[id] = m
        if var s = statuses[id] {
            s.state = "running"
            s.canPause = true
            s.canResume = false
            statuses[id] = s
        }
        await persistManifests(for: m.accountId, accountStore: accountStore)
        spawnExportTask(manifest: m, explicitDirectoryURL: explicitDirectoryURL, accountStore: accountStore)
    }

    public func deleteTransfer(id: String, accountStore: AccountScopedStore) async {
        runningTasks[id]?.cancel()
        runningTasks.removeValue(forKey: id)
        let accountId = manifests[id]?.accountId
        manifests.removeValue(forKey: id)
        statuses.removeValue(forKey: id)
        if let accountId, let paths = try? await accountStore.paths(for: accountId) {
            let safeKey = Cloud189Protocol.sanitizeFileName(id)
            try? fm.removeItem(at: paths.stagingDir.appendingPathComponent("\(safeKey).parts"))
            try? fm.removeItem(at: paths.stagingDir.appendingPathComponent("\(safeKey).merged"))
            await persistManifests(for: accountId, accountStore: accountStore)
        }
    }

    private func spawnExportTask(
        manifest: StagedDownloadManifest,
        explicitDirectoryURL: URL?,
        accountStore: AccountScopedStore
    ) {
        let id = manifest.taskId
        runningTasks[id]?.cancel()
        runningTasks[id] = Task {
            await self.runExportWorkflow(manifest: manifest, explicitDirectoryURL: explicitDirectoryURL, accountStore: accountStore)
        }
    }

    private func runExportWorkflow(
        manifest: StagedDownloadManifest,
        explicitDirectoryURL: URL?,
        accountStore: AccountScopedStore
    ) async {
        let id = manifest.taskId
        do {
            let paths = try await accountStore.paths(for: manifest.accountId)
            let safeKey = Cloud189Protocol.sanitizeFileName(id)
            let partsDir = paths.stagingDir.appendingPathComponent("\(safeKey).parts", isDirectory: true)
            let mergedURL = paths.stagingDir.appendingPathComponent("\(safeKey).merged")
            try fm.createDirectory(at: partsDir, withIntermediateDirectories: true)

            let remoteURL = try await urlResolver(manifest.trackId)
            let probe = try await probeTarget(url: remoteURL, fallbackSize: manifest.totalSize)
            let totalSize = max(probe.totalSize, manifest.totalSize)
            let effectiveParts = (probe.supportsRange && totalSize >= 524_288) ? manifest.partCount : 1

            var updatedManifest = manifest
            updatedManifest.totalSize = totalSize
            updatedManifest.partCount = effectiveParts
            manifests[id] = updatedManifest
            await persistManifests(for: manifest.accountId, accountStore: accountStore)

            let resumedCompleted = completedBytesForManifest(updatedManifest, stagingDir: paths.stagingDir)
            if var s = statuses[id] {
                s.transferredBytes = resumedCompleted
                s.totalBytes = totalSize > 0 ? totalSize : nil
                statuses[id] = s
            }

            try await downloadParts(
                taskId: id,
                trackId: manifest.trackId,
                initialURL: probe.finalURL,
                totalSize: totalSize,
                partCount: effectiveParts,
                partsDir: partsDir
            )
            try Task.checkCancellation()
            try mergeParts(partsDir: partsDir, partCount: effectiveParts, into: mergedURL, expectedTotal: totalSize)
            let exportedURL = try await accountStore.exportStagedFile(
                stagedFileURL: mergedURL,
                relativeSubpath: manifest.relativeExportSubpath,
                explicitDirectoryURL: explicitDirectoryURL,
                for: manifest.accountId
            )
            try? fm.removeItem(at: mergedURL)
            try? fm.removeItem(at: partsDir)

            manifests.removeValue(forKey: id)
            statuses[id] = TransferStatus(
                id: id,
                label: manifest.fileName,
                kind: "download",
                state: "completed",
                path: exportedURL.path,
                canPause: false,
                canResume: false,
                canDelete: true,
                bytesPerSecond: 0,
                transferredBytes: totalSize,
                totalBytes: totalSize > 0 ? totalSize : nil
            )
            await persistManifests(for: manifest.accountId, accountStore: accountStore)
        } catch is CancellationError {
            return
        } catch {
            if var m = manifests[id] {
                m.state = "paused"
                manifests[id] = m
                await persistManifests(for: m.accountId, accountStore: accountStore)
            }
            if var s = statuses[id] {
                s.state = "failed: \(error.localizedDescription)"
                s.canPause = false
                s.canResume = true
                s.bytesPerSecond = 0
                statuses[id] = s
            }
        }
    }

    private func probeTarget(url: URL, fallbackSize: UInt64) async throws -> (finalURL: URL, totalSize: UInt64, supportsRange: Bool) {
        try await semaphore.acquire()
        defer { Task { await semaphore.release() } }
        let opened = try await fetcher.openStream(url: url, rangeHeader: "bytes=0-0")
        guard opened.statusCode == 200 || opened.statusCode == 206 else {
            throw CloudTuneError.httpStatus(opened.statusCode, "探测媒体长度失败")
        }
        let total = RangeHeaderValidator.extractFullAssetLength(
            statusCode: opened.statusCode,
            requestHadRange: opened.statusCode == 206,
            contentRangeHeader: opened.headers["content-range"],
            contentLengthHeader: opened.headers["content-length"]
        ) ?? fallbackSize
        return (url, max(total, fallbackSize), opened.statusCode == 206)
    }

    private func downloadParts(
        taskId: String,
        trackId: String,
        initialURL: URL,
        totalSize: UInt64,
        partCount: Int,
        partsDir: URL
    ) async throws {
        if partCount <= 1 || totalSize == 0 {
            let partURL = partsDir.appendingPathComponent("00.part")
            try await downloadSingleRange(
                taskId: taskId,
                trackId: trackId,
                url: initialURL,
                start: 0,
                end: totalSize > 0 ? (totalSize - 1) : nil,
                partURL: partURL
            )
            return
        }

        let ranges = RangeHeaderValidator.splitByteRanges(totalSize: totalSize, partCount: partCount)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, span) in ranges.enumerated() {
                let partURL = partsDir.appendingPathComponent(String(format: "%02d.part", index))
                group.addTask {
                    try await self.downloadSingleRange(
                        taskId: taskId,
                        trackId: trackId,
                        url: initialURL,
                        start: span.start,
                        end: span.end,
                        partURL: partURL
                    )
                }
            }
            try await group.waitForAll()
        }
    }

    private func downloadSingleRange(
        taskId: String,
        trackId: String,
        url: URL,
        start: UInt64,
        end: UInt64?,
        partURL: URL
    ) async throws {
        let expectedLen = end.map { $0 - start + 1 }
        var written: UInt64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: partURL.path),
           let size = attrs[.size] as? NSNumber {
            written = expectedLen.map { min(size.uint64Value, $0) } ?? 0
        }
        if let expectedLen, written >= expectedLen {
            return
        }

        var currentURL = url
        var attempt = 0

        while true {
            try Task.checkCancellation()
            if let expectedLen, written >= expectedLen { return }
            let reqStart = start + written
            let rangeSpec = (reqStart == 0 && end == nil) ? nil : ParsedByteRange(start: reqStart, end: end).headerValue

            do {
                try await semaphore.acquire()
                do {
                    let opened = try await fetcher.openStream(url: currentURL, rangeHeader: rangeSpec)
                    if [403, 404, 410].contains(opened.statusCode) {
                        currentURL = try await urlResolver(trackId)
                        throw CloudTuneError.httpStatus(opened.statusCode, "下载地址已刷新")
                    }
                    if reqStart > 0 {
                        try RangeHeaderValidator.validateResumeResponse(
                            expectedStartOffset: reqStart,
                            statusCode: opened.statusCode,
                            contentRangeHeader: opened.headers["content-range"]
                        )
                    } else if opened.statusCode != 200 && opened.statusCode != 206 {
                        throw CloudTuneError.httpStatus(opened.statusCode, "分片响应异常")
                    }

                    if !fm.fileExists(atPath: partURL.path) || written == 0 {
                        fm.createFile(atPath: partURL.path, contents: nil)
                    }
                    let fh = try FileHandle(forWritingTo: partURL)
                    defer { try? fh.close() }
                    try fh.seek(toOffset: written)

                    var windowBytes: UInt64 = 0
                    var windowStart = ContinuousClock.now
                    for try await chunk in opened.chunks {
                        try Task.checkCancellation()
                        guard !chunk.isEmpty else { continue }
                        let slice: Data
                        if let expectedLen {
                            let remaining = Int(expectedLen - written)
                            if remaining <= 0 { break }
                            slice = chunk.count > remaining ? chunk.prefix(remaining) : chunk
                        } else {
                            slice = chunk
                        }
                        try fh.write(contentsOf: slice)
                        written += UInt64(slice.count)
                        windowBytes += UInt64(slice.count)
                        let elapsed = windowStart.duration(to: .now)
                        if elapsed >= .milliseconds(300) {
                            let secs = max(0.05, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                            let speed = UInt64(Double(windowBytes) / secs)
                            recordProgressDelta(taskId: taskId, deltaBytes: windowBytes, speed: speed)
                            windowBytes = 0
                            windowStart = .now
                        }
                    }
                    if windowBytes > 0 {
                        recordProgressDelta(taskId: taskId, deltaBytes: windowBytes, speed: windowBytes)
                    }
                    await semaphore.release()
                } catch {
                    await semaphore.release()
                    throw error
                }
                if expectedLen == nil || written >= (expectedLen ?? 0) {
                    return
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                if attempt >= 5 {
                    throw error
                }
                try await Task.sleep(for: .milliseconds(250 * attempt))
            }
        }
    }

    private func recordProgressDelta(taskId: String, deltaBytes: UInt64, speed: UInt64) {
        guard var status = statuses[taskId] else { return }
        status.transferredBytes += deltaBytes
        if let total = status.totalBytes, status.transferredBytes > total {
            status.transferredBytes = total
        }
        status.bytesPerSecond = speed
        statuses[taskId] = status
    }

    private func mergeParts(partsDir: URL, partCount: Int, into destination: URL, expectedTotal: UInt64) throws {
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        fm.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }

        var totalWritten: UInt64 = 0
        for index in 0..<max(1, partCount) {
            let partURL = partsDir.appendingPathComponent(String(format: "%02d.part", index))
            let inHandle = try FileHandle(forReadingFrom: partURL)
            defer { try? inHandle.close() }
            while let chunk = try inHandle.read(upToCount: 262_144), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
                totalWritten += UInt64(chunk.count)
            }
        }
        if expectedTotal > 0 && totalWritten != expectedTotal {
            throw CloudTuneError.storageError("分片合并校验失败：实际 \(totalWritten) 字节，预期 \(expectedTotal) 字节")
        }
    }

    private func completedBytesForManifest(_ manifest: StagedDownloadManifest, stagingDir: URL) -> UInt64 {
        let safeKey = Cloud189Protocol.sanitizeFileName(manifest.taskId)
        let partsDir = stagingDir.appendingPathComponent("\(safeKey).parts", isDirectory: true)
        let ranges = (manifest.partCount > 1 && manifest.totalSize > 0)
            ? RangeHeaderValidator.splitByteRanges(totalSize: manifest.totalSize, partCount: manifest.partCount)
            : []
        var sum: UInt64 = 0
        for idx in 0..<max(1, manifest.partCount) {
            let p = partsDir.appendingPathComponent(String(format: "%02d.part", idx))
            if let attrs = try? fm.attributesOfItem(atPath: p.path),
               let size = attrs[.size] as? NSNumber {
                let raw = size.uint64Value
                if ranges.indices.contains(idx) {
                    let spanLen = ranges[idx].end - ranges[idx].start + 1
                    sum += min(raw, spanLen)
                } else {
                    sum += raw
                }
            }
        }
        return manifest.totalSize > 0 ? min(sum, manifest.totalSize) : sum
    }

    private func persistManifests(for accountId: String, accountStore: AccountScopedStore) async {
        guard let paths = try? await accountStore.paths(for: accountId) else { return }
        let items = manifests.values.filter { $0.accountId == accountId }.sorted { $0.taskId < $1.taskId }
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: paths.transfersURL, options: .atomic)
        }
    }
}
