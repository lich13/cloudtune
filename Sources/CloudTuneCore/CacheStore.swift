import Foundation

public struct CacheEntry: Codable, Equatable, Sendable {
    public var fileName: String
    public var sizeBytes: UInt64
    public var lastAccessedMs: Int64

    public init(fileName: String, sizeBytes: UInt64, lastAccessedMs: Int64) {
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.lastAccessedMs = lastAccessedMs
    }
}

public actor CacheStore {
    private static let flushDirtyThreshold = 16
    private static let flushInterval: Duration = .seconds(5)

    public let cacheDirectory: URL
    public let indexURL: URL
    private var entries: [String: CacheEntry] = [:]
    private var totalBytes: UInt64 = 0
    private var dirtyAccessCount: Int = 0
    private var lastIndexFlushTime: ContinuousClock.Instant = .now
    private var protectedTrackIDs: Set<String> = []
    private var activeWriters: Set<String> = []
    private let fm = FileManager.default

    public init(cacheDirectory: URL, indexURL: URL? = nil) throws {
        self.cacheDirectory = cacheDirectory
        let resolvedIndexURL = indexURL ?? cacheDirectory.appendingPathComponent("index.json")
        self.indexURL = resolvedIndexURL
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let indexExistsOnDisk = fm.fileExists(atPath: resolvedIndexURL.path)
        var shouldPersistRepairedIndex = false

        if indexExistsOnDisk,
           let data = try? Data(contentsOf: resolvedIndexURL),
           let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) {
            var verified: [String: CacheEntry] = [:]
            var sum: UInt64 = 0
            for (trackId, var entry) in decoded {
                let fileURL = cacheDirectory.appendingPathComponent(entry.fileName)
                if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                   let sizeNum = attrs[.size] as? NSNumber,
                   sizeNum.uint64Value > 0 {
                    let diskSize = sizeNum.uint64Value
                    if entry.sizeBytes != diskSize {
                        entry.sizeBytes = diskSize
                        shouldPersistRepairedIndex = true
                    }
                    verified[trackId] = entry
                    sum += diskSize
                } else {
                    shouldPersistRepairedIndex = true
                }
            }
            self.entries = verified
            self.totalBytes = sum
        } else if indexExistsOnDisk {
            let rebuilt = Self.rebuildIndexFromDisk(
                in: cacheDirectory,
                indexFileName: resolvedIndexURL.lastPathComponent
            )
            self.entries = rebuilt.entries
            self.totalBytes = rebuilt.totalBytes
            shouldPersistRepairedIndex = true
        }

        Self.cleanupOrphanedTemporaryFiles(
            in: cacheDirectory,
            indexFileName: resolvedIndexURL.lastPathComponent,
            validNames: Set(self.entries.values.map(\.fileName))
        )

        if shouldPersistRepairedIndex {
            try? Self.writeIndex(self.entries, to: resolvedIndexURL)
        }
    }

    public func beginWriteThroughIfIdle(trackId: String) -> Bool {
        guard !activeWriters.contains(trackId) else { return false }
        activeWriters.insert(trackId)
        return true
    }

    public func finishWriteThrough(trackId: String) {
        activeWriters.remove(trackId)
    }

    public func setProtectedTrackIDs(_ ids: Set<String>) {
        protectedTrackIDs = ids
    }

    public func cacheFileURL(trackId: String, originalFileName: String) -> URL {
        let safe = Cloud189Protocol.sanitizeFileName(originalFileName)
        return cacheDirectory.appendingPathComponent("\(trackId)-\(safe)")
    }

    public func existingCachedFile(trackId: String) -> URL? {
        guard var entry = entries[trackId] else { return nil }
        let path = cacheDirectory.appendingPathComponent(entry.fileName)
        guard let attrs = try? fm.attributesOfItem(atPath: path.path),
              let fileSize = attrs[.size] as? NSNumber,
              fileSize.uint64Value > 0 else {
            entries.removeValue(forKey: trackId)
            totalBytes = totalBytes >= entry.sizeBytes ? (totalBytes - entry.sizeBytes) : 0
            try? flushIndexNow()
            return nil
        }
        let diskSize = fileSize.uint64Value
        if diskSize != entry.sizeBytes {
            totalBytes = (totalBytes >= entry.sizeBytes ? (totalBytes - entry.sizeBytes) : 0) + diskSize
            entry.sizeBytes = diskSize
        }
        entry.lastAccessedMs = Self.nowMs()
        entries[trackId] = entry
        dirtyAccessCount += 1

        let now = ContinuousClock.now
        if dirtyAccessCount >= Self.flushDirtyThreshold
            || lastIndexFlushTime.duration(to: now) >= Self.flushInterval {
            try? flushIndexNow(at: now)
        }
        return path
    }

    @discardableResult
    public func recordCompletedFile(
        trackId: String,
        fileURL: URL,
        sizeBytes: UInt64,
        limitBytes: UInt64
    ) throws -> UInt64 {
        let resolvedSize: UInt64
        if sizeBytes > 0 {
            resolvedSize = sizeBytes
        } else if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                  let diskNum = attrs[.size] as? NSNumber {
            resolvedSize = diskNum.uint64Value
        } else {
            resolvedSize = 0
        }

        if let previous = entries[trackId] {
            totalBytes = totalBytes >= previous.sizeBytes ? (totalBytes - previous.sizeBytes) : 0
        }
        entries[trackId] = CacheEntry(
            fileName: fileURL.lastPathComponent,
            sizeBytes: resolvedSize,
            lastAccessedMs: Self.nowMs()
        )
        totalBytes += resolvedSize
        let usage = evictIfNeededInternal(limitBytes: limitBytes, extraProtected: [trackId])
        try flushIndexNow()
        return usage
    }

    public func usageBytes() -> UInt64 {
        totalBytes
    }

    @discardableResult
    public func evictIfNeeded(limitBytes: UInt64, extraProtected: Set<String> = []) throws -> UInt64 {
        let usage = evictIfNeededInternal(limitBytes: limitBytes, extraProtected: extraProtected)
        try flushIndexNow()
        return usage
    }

    @discardableResult
    public func pruneToLimit(limitBytes: UInt64, extraProtected: Set<String> = []) throws -> UInt64 {
        try evictIfNeeded(limitBytes: limitBytes, extraProtected: extraProtected)
    }

    public func clearAll() throws {
        var retained: [String: CacheEntry] = [:]
        var retainedBytes: UInt64 = 0
        for (trackId, entry) in entries {
            if activeWriters.contains(trackId) {
                retained[trackId] = entry
                retainedBytes += entry.sizeBytes
                continue
            }
            let target = cacheDirectory.appendingPathComponent(entry.fileName)
            try? fm.removeItem(at: target)
        }
        entries = retained
        totalBytes = retainedBytes
        Self.cleanupOrphanedTemporaryFiles(
            in: cacheDirectory,
            indexFileName: indexURL.lastPathComponent,
            validNames: Set(entries.values.map(\.fileName))
        )
        try flushIndexNow()
    }

    private func evictIfNeededInternal(limitBytes: UInt64, extraProtected: Set<String>) -> UInt64 {
        guard totalBytes > limitBytes else { return totalBytes }
        let protectedAll = protectedTrackIDs.union(extraProtected)
        let candidates = entries.sorted { $0.value.lastAccessedMs < $1.value.lastAccessedMs }
        for (trackId, entry) in candidates {
            if totalBytes <= limitBytes { break }
            if protectedAll.contains(trackId) || activeWriters.contains(trackId) { continue }
            let target = cacheDirectory.appendingPathComponent(entry.fileName)
            try? fm.removeItem(at: target)
            entries.removeValue(forKey: trackId)
            totalBytes = totalBytes >= entry.sizeBytes ? (totalBytes - entry.sizeBytes) : 0
        }
        return totalBytes
    }

    private static func rebuildIndexFromDisk(
        in cacheDirectory: URL,
        indexFileName: String
    ) -> (entries: [String: CacheEntry], totalBytes: UInt64) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        ) else {
            return ([:], 0)
        }

        var rebuilt: [String: CacheEntry] = [:]
        var sum: UInt64 = 0
        let fallbackNow = nowMs()

        for url in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            if name == indexFileName || name.hasPrefix(".") { continue }
            if name.hasSuffix(".part") || name.hasSuffix(".parts") || name.hasSuffix(".tmp") {
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let sizeNum = attrs[.size] as? NSNumber,
                  sizeNum.uint64Value > 0,
                  let trackId = parseTrackId(fromCachedFileName: name) else {
                continue
            }
            let size = sizeNum.uint64Value
            let modMs = (attrs[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970 * 1000) } ?? fallbackNow
            if let existing = rebuilt[trackId] {
                if modMs >= existing.lastAccessedMs {
                    sum = (sum >= existing.sizeBytes ? (sum - existing.sizeBytes) : 0) + size
                    rebuilt[trackId] = CacheEntry(fileName: name, sizeBytes: size, lastAccessedMs: modMs)
                }
            } else {
                rebuilt[trackId] = CacheEntry(fileName: name, sizeBytes: size, lastAccessedMs: modMs)
                sum += size
            }
        }
        return (rebuilt, sum)
    }

    private static func parseTrackId(fromCachedFileName fileName: String) -> String? {
        guard let firstDash = fileName.firstIndex(of: "-"),
              firstDash > fileName.startIndex,
              fileName.index(after: firstDash) < fileName.endIndex else {
            return nil
        }
        let firstPrefix = fileName[..<firstDash]
        guard let lastDash = fileName.lastIndex(of: "-"),
              fileName.index(after: lastDash) < fileName.endIndex else {
            return nil
        }
        if firstDash == lastDash || firstPrefix.allSatisfy(\.isNumber) {
            return String(firstPrefix)
        }
        let lastPrefix = fileName[..<lastDash]
        if !lastPrefix.contains(" ") && !lastPrefix.contains(".") {
            return String(lastPrefix)
        }
        return String(firstPrefix)
    }

    private static func cleanupOrphanedTemporaryFiles(
        in cacheDirectory: URL,
        indexFileName: String,
        validNames: Set<String>
    ) {
        guard let children = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in children {
            let name = url.lastPathComponent
            if name == indexFileName || validNames.contains(name) { continue }
            if name.hasSuffix(".part") || name.hasSuffix(".parts") || name.hasSuffix(".tmp") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func writeIndex(_ entries: [String: CacheEntry], to indexURL: URL) throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: indexURL, options: .atomic)
    }

    private func flushIndexNow(at instant: ContinuousClock.Instant = .now) throws {
        try Self.writeIndex(entries, to: indexURL)
        dirtyAccessCount = 0
        lastIndexFlushTime = instant
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
