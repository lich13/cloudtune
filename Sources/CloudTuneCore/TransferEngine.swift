import Foundation

package struct StagedDownloadManifest: Codable, Equatable, Sendable {
    package var taskId: String
    package var accountHash: String
    package var trackId: String
    package var fileName: String
    package var relativeExportSubpath: String
    package var totalSize: UInt64
    package var partCount: Int
    package var state: String
    package var exportBookmarkData: Data? = nil

    private enum CodingKeys: String, CodingKey {
        case taskId
        case accountId
        case accountHash
        case trackId
        case fileName
        case relativeExportSubpath
        case totalSize
        case partCount
        case state
        case exportBookmarkData
    }

    package init(
        taskId: String,
        accountHash: String,
        trackId: String,
        fileName: String,
        relativeExportSubpath: String,
        totalSize: UInt64,
        partCount: Int,
        state: String,
        exportBookmarkData: Data? = nil
    ) {
        self.taskId = taskId
        self.accountHash = accountHash
        self.trackId = trackId
        self.fileName = fileName
        self.relativeExportSubpath = relativeExportSubpath
        self.totalSize = totalSize
        self.partCount = partCount
        self.state = state
        self.exportBookmarkData = exportBookmarkData
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.taskId = try c.decode(String.self, forKey: .taskId)
        if let hash = try c.decodeIfPresent(String.self, forKey: .accountHash), !hash.isEmpty {
            self.accountHash = hash
        } else if let legacyAccountId = try c.decodeIfPresent(String.self, forKey: .accountId), !legacyAccountId.isEmpty {
            self.accountHash = Cloud189Protocol.accountBucketHash(for: legacyAccountId)
        } else {
            self.accountHash = ""
        }
        self.trackId = try c.decode(String.self, forKey: .trackId)
        self.fileName = try c.decode(String.self, forKey: .fileName)
        self.relativeExportSubpath = try c.decodeIfPresent(String.self, forKey: .relativeExportSubpath) ?? self.fileName
        self.totalSize = try c.decodeIfPresent(UInt64.self, forKey: .totalSize) ?? 0
        self.partCount = max(1, try c.decodeIfPresent(Int.self, forKey: .partCount) ?? 1)
        self.state = try c.decodeIfPresent(String.self, forKey: .state) ?? "paused"
        self.exportBookmarkData = try c.decodeIfPresent(Data.self, forKey: .exportBookmarkData)
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(taskId, forKey: .taskId)
        try c.encode(trackId, forKey: .trackId)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(relativeExportSubpath, forKey: .relativeExportSubpath)
        try c.encode(totalSize, forKey: .totalSize)
        try c.encode(partCount, forKey: .partCount)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(exportBookmarkData, forKey: .exportBookmarkData)
    }
}

private final class ActiveTaskCancellationBag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellers: [UUID: @Sendable () -> Void] = [:]

    func register(_ cancel: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.withLock {
            cancellers[id] = cancel
        }
        return id
    }

    func unregister(_ id: UUID) {
        _ = lock.withLock {
            cancellers.removeValue(forKey: id)
        }
    }

    func cancelAll() {
        let active = lock.withLock { () -> [@Sendable () -> Void] in
            let all = Array(cancellers.values)
            cancellers.removeAll()
            return all
        }
        for cancel in active {
            cancel()
        }
    }
}

package actor TransferEngine {
    private struct InFlightCacheDownload {
        let workerID: UUID
        let cacheKey: String
        let statusId: String
        let accountHash: String?
        var waiterIDs: Set<UUID>
        let task: Task<URL, Error>
    }

    private struct TaskSpeedSample {
        var monotonicBytes: UInt64
        var lastSampleBytes: UInt64
        var lastSampleInstant: ContinuousClock.Instant
        var bytesPerSecond: UInt64
    }

    private let semaphore: GlobalTransferSemaphore
    private let fetcher: UpstreamStreamFetcher
    private let urlResolver: @Sendable (String) async throws -> URL
    private let retryBaseDelayMs: Int
    private nonisolated let cancellationBag = ActiveTaskCancellationBag()
    private var statuses: [String: TransferStatus] = [:]
    private var statusAccountHashes: [String: String] = [:]
    private var manifests: [String: StagedDownloadManifest] = [:]
    private var manifestAccountKeys: [String: String] = [:]
    private var runningTasks: [String: Task<Void, Error>] = [:]
    private var runningTaskTokens: [String: UUID] = [:]
    private var inFlightCacheDownloads: [String: InFlightCacheDownload] = [:]
    private var speedSamples: [String: TaskSpeedSample] = [:]
    private var aggregateMonotonicBytes: UInt64 = 0
    private var aggregateLastSampleBytes: UInt64 = 0
    private var aggregateLastSampleInstant: ContinuousClock.Instant = .now
    private var aggregateBytesPerSecond: UInt64 = 0
    private var onActivityChange: (@Sendable (TransferSnapshotPayload, Bool) -> Void)?
    private var lastNotifiedHasActive: Bool = false
    private let fm = FileManager.default

    package init(
        semaphore: GlobalTransferSemaphore,
        fetcher: UpstreamStreamFetcher = URLSessionUpstreamStreamFetcher(),
        retryBaseDelayMs: Int = 250,
        onActivityChange: (@Sendable (TransferSnapshotPayload, Bool) -> Void)? = nil,
        urlResolver: @escaping @Sendable (String) async throws -> URL
    ) {
        self.semaphore = semaphore
        self.fetcher = fetcher
        self.retryBaseDelayMs = max(1, retryBaseDelayMs)
        self.onActivityChange = onActivityChange
        self.urlResolver = urlResolver
    }

    package func setOnActivityChange(_ callback: (@Sendable (TransferSnapshotPayload, Bool) -> Void)?) {
        self.onActivityChange = callback
        let snap = snapshot()
        let active = snap.hasActiveItems
        self.lastNotifiedHasActive = active
    }

    package func hasInFlightCacheDownload(for cacheFileURL: URL) -> Bool {
        let cacheKey = cacheFileURL.standardizedFileURL.path
        return inFlightCacheDownloads[cacheKey] != nil
    }

    package nonisolated func cancelAllImmediate() {
        cancellationBag.cancelAll()
    }

    private func notifyActivityChanged(force: Bool = false) {
        guard let onActivityChange else { return }
        let snap = snapshot()
        let active = snap.hasActiveItems
        let transitioned = (active != lastNotifiedHasActive)
        lastNotifiedHasActive = active
        if force || transitioned {
            onActivityChange(snap, active)
        }
    }

    package func restorePersistedDownloads(for accountId: String, accountStore: AccountScopedStore) async {
        guard let paths = try? await accountStore.paths(for: accountId) else {
            return
        }
        let targetHash = paths.bucketHash
        let saved: [StagedDownloadManifest]
        if fm.fileExists(atPath: paths.transfersURL.path) {
            guard let data = try? Data(contentsOf: paths.transfersURL),
                  let decoded = try? JSONDecoder().decode([StagedDownloadManifest].self, from: data) else {
                return
            }
            saved = decoded
        } else {
            saved = []
        }

        for var item in saved {
            if !item.accountHash.isEmpty && item.accountHash != targetHash {
                continue
            }
            item.accountHash = targetHash
            if item.state == "running" {
                item.state = "paused"
            }
            manifests[item.taskId] = item
            manifestAccountKeys[item.taskId] = accountId
            statusAccountHashes[item.taskId] = targetHash
            let completed = completedBytesForManifest(item, stagingDir: paths.stagingDir)
            statuses[item.taskId] = TransferStatus(
                id: item.taskId,
                label: item.fileName,
                kind: "download",
                state: item.state,
                path: item.relativeExportSubpath,
                canPause: false,
                canResume: item.state == "paused" || item.state.hasPrefix("failed"),
                canDelete: true,
                bytesPerSecond: 0,
                transferredBytes: completed,
                totalBytes: item.totalSize > 0 ? item.totalSize : nil
            )
        }

        // Clean orphaned staging directories/files AFTER manifests are loaded so referenced partsDir entries survive.
        var referencedStagingNames = Set<String>()
        for manifest in manifests.values where manifest.accountHash == targetHash {
            let safeKey = Cloud189Protocol.sanitizeFileName(manifest.taskId)
            referencedStagingNames.insert("\(safeKey).parts")
        }
        if let children = try? fm.contentsOfDirectory(at: paths.stagingDir, includingPropertiesForKeys: nil) {
            for child in children where !referencedStagingNames.contains(child.lastPathComponent) {
                try? fm.removeItem(at: child)
            }
        }

        if !saved.isEmpty {
            notifyActivityChanged(force: true)
        }
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func ensureSpeedTrackingStarted(for taskId: String, initialBytes: UInt64 = 0, initialSpeed: UInt64 = 0) {
        let now = ContinuousClock.now
        if speedSamples.isEmpty {
            aggregateLastSampleBytes = aggregateMonotonicBytes
            aggregateLastSampleInstant = now
            aggregateBytesPerSecond = 0
        }
        if speedSamples[taskId] == nil {
            speedSamples[taskId] = TaskSpeedSample(
                monotonicBytes: initialBytes,
                lastSampleBytes: initialBytes,
                lastSampleInstant: now,
                bytesPerSecond: initialSpeed
            )
        }
    }

    private func clearSpeedTracking(for taskId: String) {
        speedSamples.removeValue(forKey: taskId)
        if speedSamples.isEmpty {
            aggregateBytesPerSecond = 0
            aggregateLastSampleBytes = aggregateMonotonicBytes
            aggregateLastSampleInstant = .now
        }
    }

    package func snapshot() -> TransferSnapshotPayload {
        let now = ContinuousClock.now
        for (id, var sample) in speedSamples {
            guard var status = statuses[id], status.state == "running" || status.state == "streaming" else {
                speedSamples.removeValue(forKey: id)
                continue
            }
            let elapsed = sample.lastSampleInstant.duration(to: now)
            let secs = Self.durationSeconds(elapsed)
            let pendingDelta = sample.monotonicBytes >= sample.lastSampleBytes
                ? (sample.monotonicBytes - sample.lastSampleBytes)
                : 0
            if pendingDelta > 0 && elapsed >= .milliseconds(200) && secs > 0 {
                sample.bytesPerSecond = UInt64(Double(pendingDelta) / secs)
                sample.lastSampleBytes = sample.monotonicBytes
                sample.lastSampleInstant = now
                speedSamples[id] = sample
                status.bytesPerSecond = sample.bytesPerSecond
                statuses[id] = status
            } else if pendingDelta == 0 && elapsed >= .milliseconds(1500) && sample.monotonicBytes > 0 {
                sample.bytesPerSecond = 0
                sample.lastSampleInstant = now
                speedSamples[id] = sample
                status.bytesPerSecond = 0
                statuses[id] = status
            }
        }

        let items = statuses.values.sorted { $0.id < $1.id }
        let activeItems = items.filter { $0.state == "running" || $0.state == "streaming" }
        guard !activeItems.isEmpty else {
            aggregateBytesPerSecond = 0
            aggregateLastSampleBytes = aggregateMonotonicBytes
            aggregateLastSampleInstant = now
            return TransferSnapshotPayload(totalSpeedBytesPerSecond: 0, items: items)
        }

        let aggElapsed = aggregateLastSampleInstant.duration(to: now)
        let aggSecs = Self.durationSeconds(aggElapsed)
        let aggDelta = aggregateMonotonicBytes >= aggregateLastSampleBytes
            ? (aggregateMonotonicBytes - aggregateLastSampleBytes)
            : 0
        if aggDelta > 0 && aggElapsed >= .milliseconds(200) && aggSecs > 0 {
            aggregateBytesPerSecond = UInt64(Double(aggDelta) / aggSecs)
            aggregateLastSampleBytes = aggregateMonotonicBytes
            aggregateLastSampleInstant = now
        } else if aggDelta == 0 && aggElapsed >= .milliseconds(1500) {
            aggregateBytesPerSecond = 0
            aggregateLastSampleInstant = now
        }

        let summedTaskSpeed = activeItems.reduce(UInt64(0)) { $0 + $1.bytesPerSecond }
        let resolvedTotalSpeed = aggregateBytesPerSecond > 0 ? aggregateBytesPerSecond : summedTaskSpeed
        return TransferSnapshotPayload(totalSpeedBytesPerSecond: resolvedTotalSpeed, items: items)
    }

    package func updateExternalTransferStatus(id: String, accountHash: String? = nil, status: TransferStatus?) {
        let previous = statuses[id]
        if var status {
            if status.state == "running" || status.state == "streaming" {
                let now = ContinuousClock.now
                if var sample = speedSamples[id] {
                    let delta = status.transferredBytes > sample.monotonicBytes
                        ? (status.transferredBytes - sample.monotonicBytes)
                        : 0
                    if delta > 0 {
                        sample.monotonicBytes &+= delta
                        aggregateMonotonicBytes &+= delta
                        let elapsed = sample.lastSampleInstant.duration(to: now)
                        let secs = Self.durationSeconds(elapsed)
                        let windowDelta = sample.monotonicBytes - sample.lastSampleBytes
                        if elapsed >= .milliseconds(200) && secs > 0 {
                            sample.bytesPerSecond = UInt64(Double(windowDelta) / secs)
                            sample.lastSampleBytes = sample.monotonicBytes
                            sample.lastSampleInstant = now
                        } else if sample.bytesPerSecond == 0 && secs > 0.005 {
                            sample.bytesPerSecond = UInt64(Double(windowDelta) / secs)
                        }
                        status.bytesPerSecond = sample.bytesPerSecond
                    } else if status.bytesPerSecond > 0 {
                        sample.bytesPerSecond = status.bytesPerSecond
                    }
                    speedSamples[id] = sample
                } else {
                    ensureSpeedTrackingStarted(
                        for: id,
                        initialBytes: status.transferredBytes,
                        initialSpeed: status.bytesPerSecond
                    )
                }
            } else {
                clearSpeedTracking(for: id)
            }
            statuses[id] = status
            if let accountHash {
                statusAccountHashes[id] = accountHash
            }
            let forceNotify = (previous == nil) || (previous?.state != status.state)
            notifyActivityChanged(force: forceNotify)
        } else {
            clearSpeedTracking(for: id)
            let removed = statuses.removeValue(forKey: id) != nil
            statusAccountHashes.removeValue(forKey: id)
            if removed {
                notifyActivityChanged(force: true)
            }
        }
    }

    package func cancelAll(forAccountId accountId: String) {
        let targetHash = Cloud189Protocol.accountBucketHash(for: accountId)
        for (id, manifest) in manifests where manifest.accountHash == targetHash {
            runningTasks[id]?.cancel()
            runningTasks.removeValue(forKey: id)
            runningTaskTokens.removeValue(forKey: id)
            clearSpeedTracking(for: id)
            statuses.removeValue(forKey: id)
            statusAccountHashes.removeValue(forKey: id)
            manifests.removeValue(forKey: id)
            manifestAccountKeys.removeValue(forKey: id)
        }
        for (cacheKey, inFlight) in inFlightCacheDownloads where inFlight.accountHash == nil || inFlight.accountHash == targetHash {
            inFlight.task.cancel()
            inFlightCacheDownloads.removeValue(forKey: cacheKey)
            clearSpeedTracking(for: inFlight.statusId)
            statuses.removeValue(forKey: inFlight.statusId)
            statusAccountHashes.removeValue(forKey: inFlight.statusId)
        }
        for (id, ownerHash) in statusAccountHashes where ownerHash == targetHash {
            runningTasks[id]?.cancel()
            runningTasks.removeValue(forKey: id)
            runningTaskTokens.removeValue(forKey: id)
            clearSpeedTracking(for: id)
            statuses.removeValue(forKey: id)
            statusAccountHashes.removeValue(forKey: id)
        }
        for key in Array(statuses.keys) where key.hasPrefix("stream:") || key.hasPrefix("prefetch:") || key.hasPrefix("playback:") {
            if statusAccountHashes[key] == nil || statusAccountHashes[key] == targetHash {
                clearSpeedTracking(for: key)
                statuses.removeValue(forKey: key)
                statusAccountHashes.removeValue(forKey: key)
            }
        }
        notifyActivityChanged(force: true)
    }

    /// Downloads a track directly into private cache (`download_first` or background `prefetch`) using the shared 8-permit limiter.
    /// Concurrent `prefetch` and `playback` calls for the same cache destination coalesce onto a single in-flight download.
    @discardableResult
    package func downloadTrackToCache(
        track: TrackSummary,
        cacheStore: CacheStore,
        parallelThreads: Int,
        cacheLimitBytes: UInt64,
        kind: String = "playback",
        accountHash: String? = nil
    ) async throws -> URL {
        if let existing = await cacheStore.existingCachedFile(trackId: track.id) {
            return existing
        }
        let destination = await cacheStore.cacheFileURL(trackId: track.id, originalFileName: track.name)
        if let existingAfterAwait = await cacheStore.existingCachedFile(trackId: track.id) {
            return existingAfterAwait
        }
        let cacheKey = destination.standardizedFileURL.path
        let waiterID = UUID()

        if var existingInFlight = inFlightCacheDownloads[cacheKey] {
            existingInFlight.waiterIDs.insert(waiterID)
            inFlightCacheDownloads[cacheKey] = existingInFlight
            if kind == "playback", var currentStatus = statuses[existingInFlight.statusId] {
                currentStatus.kind = "playback"
                statuses[existingInFlight.statusId] = currentStatus
            }
            let sharedTask = existingInFlight.task
            return try await withTaskCancellationHandler {
                try await sharedTask.value
            } onCancel: {
                Task {
                    await self.detachCacheDownloadWaiter(cacheKey: cacheKey, waiterID: waiterID)
                }
            }
        }

        let workerID = UUID()
        let statusId = "\(kind):\(track.id):\(workerID.uuidString.lowercased())"
        statuses[statusId] = TransferStatus(
            id: statusId,
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
        if let accountHash {
            statusAccountHashes[statusId] = accountHash
        }
        ensureSpeedTrackingStarted(for: statusId)
        notifyActivityChanged(force: true)

        let worker = Task<URL, Error> {
            try await self.performCacheDownload(
                workerID: workerID,
                cacheKey: cacheKey,
                statusId: statusId,
                track: track,
                destination: destination,
                cacheStore: cacheStore,
                parallelThreads: parallelThreads,
                cacheLimitBytes: cacheLimitBytes
            )
        }
        let bagToken = cancellationBag.register { worker.cancel() }
        Task { [cancellationBag] in
            _ = await worker.result
            cancellationBag.unregister(bagToken)
        }
        inFlightCacheDownloads[cacheKey] = InFlightCacheDownload(
            workerID: workerID,
            cacheKey: cacheKey,
            statusId: statusId,
            accountHash: accountHash,
            waiterIDs: [waiterID],
            task: worker
        )

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            Task {
                await self.detachCacheDownloadWaiter(cacheKey: cacheKey, waiterID: waiterID)
            }
        }
    }

    private func detachCacheDownloadWaiter(cacheKey: String, waiterID: UUID) {
        guard var inFlight = inFlightCacheDownloads[cacheKey] else { return }
        inFlight.waiterIDs.remove(waiterID)
        if inFlight.waiterIDs.isEmpty {
            inFlightCacheDownloads.removeValue(forKey: cacheKey)
            clearSpeedTracking(for: inFlight.statusId)
            statuses.removeValue(forKey: inFlight.statusId)
            statusAccountHashes.removeValue(forKey: inFlight.statusId)
            inFlight.task.cancel()
            notifyActivityChanged(force: true)
        } else {
            inFlightCacheDownloads[cacheKey] = inFlight
        }
    }

    private func performCacheDownload(
        workerID: UUID,
        cacheKey: String,
        statusId: String,
        track: TrackSummary,
        destination: URL,
        cacheStore: CacheStore,
        parallelThreads: Int,
        cacheLimitBytes: UInt64
    ) async throws -> URL {
        let parentDir = destination.deletingLastPathComponent()
        let partsDir = parentDir.appendingPathComponent(
            ".\(destination.lastPathComponent).\(workerID.uuidString.lowercased()).parts",
            isDirectory: true
        )
        let tempMerged = parentDir.appendingPathComponent(
            ".\(destination.lastPathComponent).\(workerID.uuidString.lowercased()).merged.part",
            isDirectory: false
        )
        defer {
            if inFlightCacheDownloads[cacheKey]?.workerID == workerID {
                inFlightCacheDownloads.removeValue(forKey: cacheKey)
            }
            clearSpeedTracking(for: statusId)
            statuses.removeValue(forKey: statusId)
            statusAccountHashes.removeValue(forKey: statusId)
            try? fm.removeItem(at: partsDir)
            try? fm.removeItem(at: tempMerged)
            notifyActivityChanged(force: true)
        }

        let remoteURL = try await urlResolver(track.id)
        let probe = try await probeTarget(url: remoteURL, fallbackSize: track.sizeBytes)
        let totalSize = probe.totalSize
        let partCount = (probe.supportsRange && totalSize >= 1_048_576) ? min(max(1, parallelThreads), 8) : 1

        try? fm.removeItem(at: partsDir)
        try fm.createDirectory(at: partsDir, withIntermediateDirectories: true)

        try await downloadParts(
            taskId: statusId,
            trackId: track.id,
            initialURL: probe.finalURL,
            totalSize: totalSize,
            partCount: partCount,
            partsDir: partsDir
        )
        try Task.checkCancellation()

        let recordedSize: UInt64
        if partCount <= 1 {
            let singlePartURL = partsDir.appendingPathComponent("00.part")
            let attrs = try fm.attributesOfItem(atPath: singlePartURL.path)
            let diskSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            if totalSize > 0 && diskSize != totalSize {
                throw CloudTuneError.storageError("缓存单分片校验失败：实际 \(diskSize) 字节，预期 \(totalSize) 字节")
            }
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: singlePartURL)
            } else {
                try fm.moveItem(at: singlePartURL, to: destination)
            }
            recordedSize = totalSize > 0 ? totalSize : diskSize
        } else {
            try mergeParts(partsDir: partsDir, partCount: partCount, into: tempMerged, expectedTotal: totalSize)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: tempMerged)
            } else {
                try fm.moveItem(at: tempMerged, to: destination)
            }
            recordedSize = totalSize > 0 ? totalSize : track.sizeBytes
        }

        _ = try await cacheStore.recordCompletedFile(
            trackId: track.id,
            fileURL: destination,
            sizeBytes: recordedSize,
            limitBytes: cacheLimitBytes
        )
        return destination
    }

    /// Enqueues a batch of resumable export downloads (capturing bookmark once, writing `transfers.json` once, and emitting snapshot once).
    @discardableResult
    package func enqueueExportDownloads(
        accountId: String,
        items: [(track: TrackSummary, relativeExportSubpath: String)],
        parallelThreads: Int,
        explicitDirectoryURL: URL? = nil,
        accountStore: AccountScopedStore
    ) async throws -> [String] {
        guard !items.isEmpty else { return [] }
        let partCount = min(max(1, parallelThreads), 16)
        let accountHash = Cloud189Protocol.accountBucketHash(for: accountId)
        let exportBookmarkData = await accountStore.captureExportBookmarkData(
            explicitDirectoryURL: explicitDirectoryURL,
            for: accountId
        )

        var createdManifests: [StagedDownloadManifest] = []
        createdManifests.reserveCapacity(items.count)
        var taskIds: [String] = []
        taskIds.reserveCapacity(items.count)

        for entry in items {
            let taskId = "download:\(UUID().uuidString.lowercased())"
            let manifest = StagedDownloadManifest(
                taskId: taskId,
                accountHash: accountHash,
                trackId: entry.track.id,
                fileName: entry.track.name,
                relativeExportSubpath: entry.relativeExportSubpath,
                totalSize: entry.track.sizeBytes,
                partCount: partCount,
                state: "running",
                exportBookmarkData: exportBookmarkData
            )
            manifests[taskId] = manifest
            manifestAccountKeys[taskId] = accountId
            statusAccountHashes[taskId] = accountHash
            statuses[taskId] = TransferStatus(
                id: taskId,
                label: entry.track.name,
                kind: "download",
                state: "running",
                path: entry.relativeExportSubpath,
                canPause: true,
                canResume: false,
                canDelete: true,
                bytesPerSecond: 0,
                transferredBytes: 0,
                totalBytes: entry.track.sizeBytes > 0 ? entry.track.sizeBytes : nil
            )
            ensureSpeedTrackingStarted(for: taskId)
            createdManifests.append(manifest)
            taskIds.append(taskId)
        }

        do {
            try await persistManifestsChecked(forAccountKey: accountId, accountHash: accountHash, accountStore: accountStore)
        } catch {
            for taskId in taskIds {
                clearSpeedTracking(for: taskId)
                manifests.removeValue(forKey: taskId)
                manifestAccountKeys.removeValue(forKey: taskId)
                statusAccountHashes.removeValue(forKey: taskId)
                statuses.removeValue(forKey: taskId)
            }
            throw error
        }
        notifyActivityChanged(force: true)
        for manifest in createdManifests {
            spawnExportTask(
                manifest: manifest,
                accountKey: accountId,
                explicitDirectoryURL: explicitDirectoryURL,
                accountStore: accountStore
            )
        }
        return taskIds
    }

    /// Enqueues a resumable multi-part export download staged in private storage and exported upon verification.
    @discardableResult
    package func enqueueExportDownload(
        accountId: String,
        track: TrackSummary,
        relativeExportSubpath: String,
        parallelThreads: Int,
        explicitDirectoryURL: URL? = nil,
        accountStore: AccountScopedStore
    ) async throws -> String {
        let ids = try await enqueueExportDownloads(
            accountId: accountId,
            items: [(track: track, relativeExportSubpath: relativeExportSubpath)],
            parallelThreads: parallelThreads,
            explicitDirectoryURL: explicitDirectoryURL,
            accountStore: accountStore
        )
        return ids[0]
    }

    package func pauseTransfer(id: String, accountStore: AccountScopedStore) async {
        runningTasks[id]?.cancel()
        runningTasks.removeValue(forKey: id)
        runningTaskTokens.removeValue(forKey: id)
        clearSpeedTracking(for: id)
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
            if let accountKey = manifestAccountKeys[id] {
                await persistManifests(forAccountKey: accountKey, accountHash: m.accountHash, accountStore: accountStore)
            }
            notifyActivityChanged(force: true)
        }
    }

    package func resumeTransfer(id: String, explicitDirectoryURL: URL? = nil, accountStore: AccountScopedStore) async {
        guard var m = manifests[id], let accountKey = manifestAccountKeys[id] else { return }
        if let explicitDirectoryURL,
           let refreshedBookmark = await accountStore.captureExportBookmarkData(
               explicitDirectoryURL: explicitDirectoryURL,
               for: accountKey
           ) {
            m.exportBookmarkData = refreshedBookmark
        }
        m.state = "running"
        manifests[id] = m
        statusAccountHashes[id] = m.accountHash
        if var s = statuses[id] {
            s.state = "running"
            s.canPause = true
            s.canResume = false
            statuses[id] = s
        }
        ensureSpeedTrackingStarted(for: id)
        await persistManifests(forAccountKey: accountKey, accountHash: m.accountHash, accountStore: accountStore)
        notifyActivityChanged(force: true)
        spawnExportTask(manifest: m, accountKey: accountKey, explicitDirectoryURL: explicitDirectoryURL, accountStore: accountStore)
    }

    package func deleteTransfer(id: String, accountStore: AccountScopedStore) async {
        runningTasks[id]?.cancel()
        runningTasks.removeValue(forKey: id)
        runningTaskTokens.removeValue(forKey: id)
        clearSpeedTracking(for: id)
        let manifest = manifests.removeValue(forKey: id)
        let accountKey = manifestAccountKeys.removeValue(forKey: id)
        statuses.removeValue(forKey: id)
        statusAccountHashes.removeValue(forKey: id)
        if let accountKey, let manifest, let paths = try? await accountStore.paths(for: accountKey) {
            let safeKey = Cloud189Protocol.sanitizeFileName(id)
            try? fm.removeItem(at: paths.stagingDir.appendingPathComponent("\(safeKey).parts"))
            try? fm.removeItem(at: paths.stagingDir.appendingPathComponent("\(safeKey).merged"))
            await persistManifests(forAccountKey: accountKey, accountHash: manifest.accountHash, accountStore: accountStore)
        }
        notifyActivityChanged(force: true)
    }

    private func spawnExportTask(
        manifest: StagedDownloadManifest,
        accountKey: String,
        explicitDirectoryURL: URL?,
        accountStore: AccountScopedStore
    ) {
        let id = manifest.taskId
        runningTasks[id]?.cancel()
        let runToken = UUID()
        runningTaskTokens[id] = runToken
        let task = Task<Void, Error> {
            await self.runExportWorkflow(
                manifest: manifest,
                runToken: runToken,
                accountKey: accountKey,
                explicitDirectoryURL: explicitDirectoryURL,
                accountStore: accountStore
            )
        }
        let bagToken = cancellationBag.register { task.cancel() }
        Task { [cancellationBag] in
            _ = await task.result
            cancellationBag.unregister(bagToken)
        }
        runningTasks[id] = task
    }

    private func isActiveExportRun(id: String, runToken: UUID) -> Bool {
        runningTaskTokens[id] == runToken && manifests[id]?.state == "running"
    }

    private func runExportWorkflow(
        manifest: StagedDownloadManifest,
        runToken: UUID,
        accountKey: String,
        explicitDirectoryURL: URL?,
        accountStore: AccountScopedStore
    ) async {
        let id = manifest.taskId
        do {
            guard isActiveExportRun(id: id, runToken: runToken) else { return }
            let paths = try await accountStore.paths(for: accountKey)
            let safeKey = Cloud189Protocol.sanitizeFileName(id)
            let partsDir = paths.stagingDir.appendingPathComponent("\(safeKey).parts", isDirectory: true)
            try fm.createDirectory(at: partsDir, withIntermediateDirectories: true)

            let remoteURL = try await urlResolver(manifest.trackId)
            let probe = try await probeTarget(url: remoteURL, fallbackSize: manifest.totalSize)
            let totalSize = max(probe.totalSize, manifest.totalSize)
            let effectiveParts = (probe.supportsRange && totalSize >= 524_288) ? manifest.partCount : 1

            guard isActiveExportRun(id: id, runToken: runToken) else {
                clearSpeedTracking(for: id)
                return
            }
            var updatedManifest = manifests[id] ?? manifest
            updatedManifest.totalSize = totalSize
            updatedManifest.partCount = effectiveParts
            manifests[id] = updatedManifest
            await persistManifests(forAccountKey: accountKey, accountHash: manifest.accountHash, accountStore: accountStore)

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
            guard isActiveExportRun(id: id, runToken: runToken) else {
                clearSpeedTracking(for: id)
                return
            }

            let orderedPartURLs = (0..<max(1, effectiveParts)).map { idx in
                partsDir.appendingPathComponent(String(format: "%02d.part", idx))
            }
            let exportedURL = try await accountStore.exportStagedParts(
                partURLs: orderedPartURLs,
                expectedTotalBytes: totalSize,
                relativeSubpath: updatedManifest.relativeExportSubpath,
                explicitDirectoryURL: explicitDirectoryURL,
                manifestBookmarkData: updatedManifest.exportBookmarkData,
                for: accountKey
            )
            guard isActiveExportRun(id: id, runToken: runToken) else {
                clearSpeedTracking(for: id)
                return
            }
            try? fm.removeItem(at: partsDir)

            runningTasks.removeValue(forKey: id)
            runningTaskTokens.removeValue(forKey: id)
            clearSpeedTracking(for: id)
            manifests.removeValue(forKey: id)
            manifestAccountKeys.removeValue(forKey: id)
            statusAccountHashes[id] = manifest.accountHash
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
            await persistManifests(forAccountKey: accountKey, accountHash: manifest.accountHash, accountStore: accountStore)
            notifyActivityChanged(force: true)
        } catch is CancellationError {
            if runningTaskTokens[id] == runToken {
                clearSpeedTracking(for: id)
            }
            return
        } catch {
            guard isActiveExportRun(id: id, runToken: runToken) else { return }
            runningTasks.removeValue(forKey: id)
            runningTaskTokens.removeValue(forKey: id)
            clearSpeedTracking(for: id)
            if var m = manifests[id] {
                m.state = "paused"
                manifests[id] = m
                await persistManifests(forAccountKey: accountKey, accountHash: m.accountHash, accountStore: accountStore)
            }
            if var s = statuses[id] {
                s.state = "failed: \(error.localizedDescription)"
                s.canPause = false
                s.canResume = true
                s.bytesPerSecond = 0
                statuses[id] = s
                statusAccountHashes[id] = manifest.accountHash
            }
            notifyActivityChanged(force: true)
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
        let maxRetries = 5

        while true {
            try Task.checkCancellation()
            if let expectedLen, written >= expectedLen { return }
            let reqStart = start + written
            let rangeSpec = (reqStart == 0 && end == nil) ? nil : ParsedByteRange(start: reqStart, end: end).headerValue
            var bytesThisAttempt: UInt64 = 0

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
                        let sliceLen = UInt64(slice.count)
                        written += sliceLen
                        bytesThisAttempt += sliceLen
                        windowBytes += sliceLen
                        if windowStart.duration(to: .now) >= .milliseconds(150) {
                            recordProgressDelta(taskId: taskId, deltaBytes: windowBytes)
                            windowBytes = 0
                            windowStart = .now
                        }
                    }
                    if windowBytes > 0 {
                        recordProgressDelta(taskId: taskId, deltaBytes: windowBytes)
                    }
                    await semaphore.release()
                } catch {
                    await semaphore.release()
                    throw error
                }
                if let expectedLen {
                    if written >= expectedLen {
                        return
                    }
                    if bytesThisAttempt > 0 {
                        attempt = 0
                        continue
                    }
                    throw CloudTuneError.protocolError("上游提前关闭连接且未返回任何分片数据")
                } else {
                    return
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if bytesThisAttempt > 0 {
                    attempt = 0
                }
                attempt += 1
                if attempt >= maxRetries {
                    throw error
                }
                try await Task.sleep(for: .milliseconds(retryBaseDelayMs * attempt))
            }
        }
    }

    private func recordProgressDelta(taskId: String, deltaBytes: UInt64) {
        guard deltaBytes > 0, var status = statuses[taskId] else { return }
        status.transferredBytes += deltaBytes
        if let total = status.totalBytes, status.transferredBytes > total {
            status.transferredBytes = total
        }

        let now = ContinuousClock.now
        ensureSpeedTrackingStarted(for: taskId)
        aggregateMonotonicBytes &+= deltaBytes
        if var sample = speedSamples[taskId] {
            sample.monotonicBytes &+= deltaBytes
            let elapsed = sample.lastSampleInstant.duration(to: now)
            let secs = Self.durationSeconds(elapsed)
            let windowDelta = sample.monotonicBytes - sample.lastSampleBytes
            if elapsed >= .milliseconds(200) && secs > 0 {
                sample.bytesPerSecond = UInt64(Double(windowDelta) / secs)
                sample.lastSampleBytes = sample.monotonicBytes
                sample.lastSampleInstant = now
            } else if sample.bytesPerSecond == 0 && secs >= 0.01 {
                sample.bytesPerSecond = UInt64(Double(windowDelta) / secs)
            }
            speedSamples[taskId] = sample
            status.bytesPerSecond = sample.bytesPerSecond
        }
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

    private func persistManifestsChecked(
        forAccountKey accountKey: String,
        accountHash: String,
        accountStore: AccountScopedStore
    ) async throws {
        let paths = try await accountStore.paths(for: accountKey)
        let items = manifests.values.filter { $0.accountHash == accountHash }.sorted { $0.taskId < $1.taskId }
        let data = try JSONEncoder().encode(items)
        try data.write(to: paths.transfersURL, options: .atomic)
    }

    private func persistManifests(forAccountKey accountKey: String, accountHash: String, accountStore: AccountScopedStore) async {
        try? await persistManifestsChecked(forAccountKey: accountKey, accountHash: accountHash, accountStore: accountStore)
    }
}
