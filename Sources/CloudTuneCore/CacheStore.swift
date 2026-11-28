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
    public let cacheDirectory: URL
    public let indexURL: URL
    private var entries: [String: CacheEntry] = [:]
    private var protectedTrackIDs: Set<String> = []
    private var activeWriters: Set<String> = []
    private let fm = FileManager.default

    public init(cacheDirectory: URL, indexURL: URL? = nil) throws {
        self.cacheDirectory = cacheDirectory
        self.indexURL = indexURL ?? cacheDirectory.appendingPathComponent("index.json")
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: self.indexURL),
           let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) {
            self.entries = decoded
        }
        Self.cleanupOrphanedTemporaryFiles(
            in: cacheDirectory,
            validNames: Set(self.entries.values.map(\.fileName))
        )
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
            try? persistIndex()
            return nil
        }
        entry.lastAccessedMs = Self.nowMs()
        entry.sizeBytes = fileSize.uint64Value
        entries[trackId] = entry
        try? persistIndex()
        return path
    }

    @discardableResult
    public func recordCompletedFile(
        trackId: String,
        fileURL: URL,
        sizeBytes: UInt64,
        limitBytes: UInt64
    ) throws -> UInt64 {
        entries[trackId] = CacheEntry(
            fileName: fileURL.lastPathComponent,
            sizeBytes: sizeBytes,
            lastAccessedMs: Self.nowMs()
        )
        let usage = pruneToLimitInternal(limitBytes: limitBytes, extraProtected: [trackId])
        try persistIndex()
        return usage
    }

    public func usageBytes() -> UInt64 {
        var sum: UInt64 = 0
        for (_, entry) in entries {
            let fileURL = cacheDirectory.appendingPathComponent(entry.fileName)
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? NSNumber {
                sum += size.uint64Value
            }
        }
        return sum
    }

    @discardableResult
    public func pruneToLimit(limitBytes: UInt64, extraProtected: Set<String> = []) throws -> UInt64 {
        let usage = pruneToLimitInternal(limitBytes: limitBytes, extraProtected: extraProtected)
        try persistIndex()
        return usage
    }

    private func pruneToLimitInternal(limitBytes: UInt64, extraProtected: Set<String>) -> UInt64 {
        let protectedAll = protectedTrackIDs.union(extraProtected)
        var currentUsage = usageBytes()
        guard currentUsage > limitBytes else { return currentUsage }

        let candidates = entries.sorted { $0.value.lastAccessedMs < $1.value.lastAccessedMs }
        for (trackId, entry) in candidates {
            if currentUsage <= limitBytes { break }
            if protectedAll.contains(trackId) || activeWriters.contains(trackId) { continue }
            let target = cacheDirectory.appendingPathComponent(entry.fileName)
            try? fm.removeItem(at: target)
            entries.removeValue(forKey: trackId)
            currentUsage = currentUsage >= entry.sizeBytes ? (currentUsage - entry.sizeBytes) : 0
        }
        return usageBytes()
    }

    private static func cleanupOrphanedTemporaryFiles(in cacheDirectory: URL, validNames: Set<String>) {
        guard let children = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in children {
            let name = url.lastPathComponent
            if name == "index.json" || validNames.contains(name) { continue }
            if name.hasSuffix(".part") || name.hasSuffix(".parts") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func persistIndex() throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: indexURL, options: .atomic)
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
