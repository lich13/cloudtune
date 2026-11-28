import CryptoKit
import Foundation

package enum LoopMode: String, Codable, CaseIterable, Sendable {
    case off
    case all
    case one
}

package enum StatusKind: String, Codable, Equatable, Sendable {
    case info
    case error
}

package enum AppearanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "system"
        self = AppearanceMode(rawValue: raw) ?? .system
    }
}

package enum PlaybackMode: String, Codable, CaseIterable, Sendable {
    case downloadFirst = "download_first"
    case streamCache = "stream_cache"

    package var displayTitle: String {
        switch self {
        case .downloadFirst: return "优先缓存"
        case .streamCache: return "边播边缓存"
        }
    }
}

package enum ModuleTab: String, Codable, CaseIterable, Identifiable, Sendable {
    case music
    case video
    case cloud
    case transfers
    case settings

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .music: return "曲库"
        case .video: return "视频"
        case .cloud: return "云盘"
        case .transfers: return "传输"
        case .settings: return "设置"
        }
    }

    package var systemImage: String {
        switch self {
        case .music: return "music.note.list"
        case .video: return "film"
        case .cloud: return "icloud"
        case .transfers: return "arrow.up.arrow.down.circle"
        case .settings: return "gearshape"
        }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "music"
        if raw == "download" {
            self = .transfers
        } else {
            self = ModuleTab(rawValue: raw) ?? .music
        }
    }
}

/// Active authenticated session with non-empty signing keys for the current process run.
package struct ActiveCloudSession: Equatable, Sendable {
    package let accessToken: String
    package let sessionKey: String
    package let sessionSecret: String
    package let loginName: String?

    package init?(
        accessToken: String = "",
        sessionKey: String,
        sessionSecret: String,
        loginName: String?
    ) {
        let trimmedKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = sessionSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedSecret.isEmpty else { return nil }
        self.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionKey = trimmedKey
        self.sessionSecret = trimmedSecret
        self.loginName = loginName?.trimmedNilIfEmpty
    }
}

/// Persisted cold-start refresh credential. Only created when a non-empty refreshToken exists.
package struct PersistedRefreshCredential: Codable, Equatable, Sendable {
    package let refreshToken: String
    package let accountName: String?
    package let accountKey: String?

    package init?(refreshToken: String, accountName: String?, accountKey: String? = nil) {
        let trimmed = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.refreshToken = trimmed
        let normalizedName = accountName?.trimmedNilIfEmpty
        self.accountName = normalizedName
        let normalizedKey = accountKey?.trimmedNilIfEmpty
        self.accountKey = normalizedKey ?? normalizedName
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawToken = (try c.decodeIfPresent(String.self, forKey: .refreshToken) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawToken.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .refreshToken, in: c, debugDescription: "Empty refreshToken")
        }
        self.refreshToken = rawToken
        let decodedName = (try c.decodeIfPresent(String.self, forKey: .accountName))?.trimmedNilIfEmpty
        self.accountName = decodedName
        self.accountKey = (try c.decodeIfPresent(String.self, forKey: .accountKey))?.trimmedNilIfEmpty ?? decodedName
    }

    package func withAccountKey(_ key: String) -> PersistedRefreshCredential {
        PersistedRefreshCredential(refreshToken: refreshToken, accountName: accountName, accountKey: key) ?? self
    }
}

package struct FolderSelection: Codable, Equatable, Hashable, Sendable {
    package var id: String
    package var name: String

    package init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? Cloud189Constants.rootFolderId
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? Cloud189Constants.rootFolderName
    }
}

package struct RemoteFolder: Codable, Equatable, Identifiable, Sendable {
    package var id: String
    package var name: String
    package var parentId: String?

    package init(id: String, name: String, parentId: String? = nil) {
        self.id = id
        self.name = name
        self.parentId = parentId
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
    }
}

package struct BreadcrumbItem: Codable, Equatable, Hashable, Sendable {
    package var id: String?
    package var name: String

    package init(id: String?, name: String) {
        self.id = id
        self.name = name
    }

    package static let root = BreadcrumbItem(id: nil, name: Cloud189Constants.rootFolderName)
}

package struct TrackSummary: Codable, Equatable, Identifiable, Hashable, Sendable {
    package var id: String
    package var name: String
    package var folderPath: String
    package var sizeBytes: UInt64
    package var modifiedAt: String?

    package init(
        id: String,
        name: String,
        folderPath: String,
        sizeBytes: UInt64,
        modifiedAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath) ?? ""
        self.sizeBytes = try c.decodeIfPresent(UInt64.self, forKey: .sizeBytes) ?? 0
        self.modifiedAt = try c.decodeIfPresent(String.self, forKey: .modifiedAt)
    }

    package var fileExtensionUpper: String {
        let ext = (name as NSString).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return ext.uppercased()
    }

    package var isLosslessAudio: Bool {
        Cloud189Protocol.isLosslessAudioFile(name)
    }
}

package struct FolderBrowsePayload: Codable, Equatable, Sendable {
    package var currentFolderId: String
    package var currentFolderName: String
    package var parentFolderId: String?
    package var isRoot: Bool
    package var folders: [RemoteFolder]
    package var audioFiles: [TrackSummary]
    package var videoFiles: [TrackSummary]
    package var otherFiles: [TrackSummary]

    package init(
        currentFolderId: String,
        currentFolderName: String,
        parentFolderId: String? = nil,
        isRoot: Bool,
        folders: [RemoteFolder],
        audioFiles: [TrackSummary],
        videoFiles: [TrackSummary],
        otherFiles: [TrackSummary]
    ) {
        self.currentFolderId = currentFolderId
        self.currentFolderName = currentFolderName
        self.parentFolderId = parentFolderId
        self.isRoot = isRoot
        self.folders = folders
        self.audioFiles = audioFiles
        self.videoFiles = videoFiles
        self.otherFiles = otherFiles
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.currentFolderId = try c.decodeIfPresent(String.self, forKey: .currentFolderId) ?? Cloud189Constants.rootFolderId
        self.currentFolderName = try c.decodeIfPresent(String.self, forKey: .currentFolderName) ?? Cloud189Constants.rootFolderName
        self.parentFolderId = try c.decodeIfPresent(String.self, forKey: .parentFolderId)
        self.isRoot = try c.decodeIfPresent(Bool.self, forKey: .isRoot) ?? false
        self.folders = try c.decodeIfPresent([RemoteFolder].self, forKey: .folders) ?? []
        self.audioFiles = try c.decodeIfPresent([TrackSummary].self, forKey: .audioFiles) ?? []
        self.videoFiles = try c.decodeIfPresent([TrackSummary].self, forKey: .videoFiles) ?? []
        self.otherFiles = try c.decodeIfPresent([TrackSummary].self, forKey: .otherFiles) ?? []
    }
}

package struct AccountSettings: Codable, Equatable, Sendable {
    package static let minCacheLimitMB: UInt64 = 256
    package static let maxDownloadThreads: Int = 16
    package static let maxCacheThreads: Int = 8

    package var musicFolder: FolderSelection?
    package var cacheLimitMb: UInt64
    package var downloadThreads: Int
    package var cacheThreads: Int
    package var playbackMode: PlaybackMode
    package var exportFolderDisplayName: String?
    package var appearanceMode: AppearanceMode
    package var dynamicColorEnabled: Bool

    package init(
        musicFolder: FolderSelection? = nil,
        cacheLimitMb: UInt64 = 1024,
        downloadThreads: Int = 8,
        cacheThreads: Int = 4,
        playbackMode: PlaybackMode = .downloadFirst,
        exportFolderDisplayName: String? = nil,
        appearanceMode: AppearanceMode = .system,
        dynamicColorEnabled: Bool = false
    ) {
        self.musicFolder = musicFolder
        self.cacheLimitMb = max(Self.minCacheLimitMB, cacheLimitMb)
        self.downloadThreads = min(max(1, downloadThreads), Self.maxDownloadThreads)
        self.cacheThreads = min(max(1, cacheThreads), Self.maxCacheThreads)
        self.playbackMode = playbackMode
        self.exportFolderDisplayName = exportFolderDisplayName
        self.appearanceMode = appearanceMode
        self.dynamicColorEnabled = dynamicColorEnabled
    }

    package var cacheLimitBytes: UInt64 {
        cacheLimitMb * 1024 * 1024
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.musicFolder = try c.decodeIfPresent(FolderSelection.self, forKey: .musicFolder)
        let rawLimit = try c.decodeIfPresent(UInt64.self, forKey: .cacheLimitMb) ?? 1024
        self.cacheLimitMb = max(Self.minCacheLimitMB, rawLimit)
        let rawDl = try c.decodeIfPresent(Int.self, forKey: .downloadThreads) ?? 8
        self.downloadThreads = min(max(1, rawDl), Self.maxDownloadThreads)
        let rawCache = try c.decodeIfPresent(Int.self, forKey: .cacheThreads) ?? 4
        self.cacheThreads = min(max(1, rawCache), Self.maxCacheThreads)
        self.playbackMode = try c.decodeIfPresent(PlaybackMode.self, forKey: .playbackMode) ?? .downloadFirst
        self.exportFolderDisplayName = try c.decodeIfPresent(String.self, forKey: .exportFolderDisplayName)
        self.appearanceMode = (try? c.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode)) ?? .system
        self.dynamicColorEnabled = try c.decodeIfPresent(Bool.self, forKey: .dynamicColorEnabled) ?? false
    }
}

package struct TransferStatus: Codable, Equatable, Identifiable, Sendable {
    package var id: String
    package var label: String
    package var kind: String
    package var state: String
    package var path: String?
    package var canPause: Bool
    package var canResume: Bool
    package var canDelete: Bool
    package var bytesPerSecond: UInt64
    package var transferredBytes: UInt64
    package var totalBytes: UInt64?

    package init(
        id: String,
        label: String,
        kind: String,
        state: String,
        path: String? = nil,
        canPause: Bool = false,
        canResume: Bool = false,
        canDelete: Bool = false,
        bytesPerSecond: UInt64 = 0,
        transferredBytes: UInt64 = 0,
        totalBytes: UInt64? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.state = state
        self.path = path
        self.canPause = canPause
        self.canResume = canResume
        self.canDelete = canDelete
        self.bytesPerSecond = bytesPerSecond
        self.transferredBytes = transferredBytes
        self.totalBytes = totalBytes
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "download"
        self.state = try c.decodeIfPresent(String.self, forKey: .state) ?? "running"
        self.path = try c.decodeIfPresent(String.self, forKey: .path)
        self.canPause = try c.decodeIfPresent(Bool.self, forKey: .canPause) ?? false
        self.canResume = try c.decodeIfPresent(Bool.self, forKey: .canResume) ?? false
        self.canDelete = try c.decodeIfPresent(Bool.self, forKey: .canDelete) ?? false
        self.bytesPerSecond = try c.decodeIfPresent(UInt64.self, forKey: .bytesPerSecond) ?? 0
        self.transferredBytes = try c.decodeIfPresent(UInt64.self, forKey: .transferredBytes) ?? 0
        self.totalBytes = try c.decodeIfPresent(UInt64.self, forKey: .totalBytes)
    }

    package var localizedStateLabel: String {
        switch state {
        case "running":
            return "传输中"
        case "streaming":
            return "串流中"
        case "paused":
            return "已暂停"
        case "completed":
            return "已完成"
        case "failed":
            return "失败"
        default:
            if state.hasPrefix("failed:") {
                let reason = state.dropFirst("failed:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                return reason.isEmpty ? "失败" : "失败：\(reason)"
            }
            return state
        }
    }
}

package struct TransferSnapshotPayload: Codable, Equatable, Sendable {
    package var totalSpeedBytesPerSecond: UInt64
    package var items: [TransferStatus]

    package init(totalSpeedBytesPerSecond: UInt64 = 0, items: [TransferStatus] = []) {
        self.totalSpeedBytesPerSecond = totalSpeedBytesPerSecond
        self.items = items
    }

    package var hasActiveItems: Bool {
        items.contains { $0.state == "running" || $0.state == "streaming" }
    }
}

package struct QueueStepResult: Equatable, Sendable {
    package let track: TrackSummary?
    package let remainingUpNext: [TrackSummary]

    package init(track: TrackSummary?, remainingUpNext: [TrackSummary]) {
        self.track = track
        self.remainingUpNext = remainingUpNext
    }
}

package enum PlaybackQueueResolver {
    package static func buildShuffleOrder(tracks: [TrackSummary], anchorTrackId: String?) -> [String] {
        guard !tracks.isEmpty else { return [] }
        var rest = tracks.map(\.id)
        if let anchorTrackId, let idx = rest.firstIndex(of: anchorTrackId) {
            rest.remove(at: idx)
            rest.shuffle()
            return [anchorTrackId] + rest
        }
        rest.shuffle()
        return rest
    }

    package static func orderedBaseTracks(
        libraryTracks: [TrackSummary],
        shuffle: Bool,
        shuffleOrderIds: [String],
        tracksById: [String: TrackSummary]? = nil
    ) -> [TrackSummary] {
        guard shuffle, libraryTracks.count > 1 else {
            return libraryTracks
        }
        let lookup: [String: TrackSummary]
        if let tracksById {
            lookup = tracksById
        } else {
            var byId: [String: TrackSummary] = [:]
            byId.reserveCapacity(libraryTracks.count)
            for track in libraryTracks where byId[track.id] == nil {
                byId[track.id] = track
            }
            lookup = byId
        }
        var result: [TrackSummary] = []
        result.reserveCapacity(libraryTracks.count)
        var seen = Set<String>()
        seen.reserveCapacity(libraryTracks.count)
        for id in shuffleOrderIds {
            if let track = lookup[id], seen.insert(id).inserted {
                result.append(track)
            }
        }
        for track in libraryTracks where seen.insert(track.id).inserted {
            result.append(track)
        }
        return result
    }

    package static func insertPlayNext(upNext: [TrackSummary], track: TrackSummary) -> [TrackSummary] {
        [track] + upNext.filter { $0.id != track.id }
    }

    package static func appendToQueue(upNext: [TrackSummary], track: TrackSummary) -> [TrackSummary] {
        if upNext.contains(where: { $0.id == track.id }) {
            return upNext
        }
        return upNext + [track]
    }

    package static func removeFromQueue(upNext: [TrackSummary], trackId: String) -> [TrackSummary] {
        upNext.filter { $0.id != trackId }
    }

    private static func resolveIndex(
        of trackId: String,
        in ordered: [TrackSummary],
        indexById: [String: Int]?
    ) -> Int? {
        if let indexById {
            return indexById[trackId]
        }
        return ordered.firstIndex { $0.id == trackId }
    }

    package static func canSkipNext(
        currentTrack: TrackSummary?,
        libraryTracks: [TrackSummary],
        upNextQueue: [TrackSummary],
        shuffle: Bool,
        shuffleOrderIds: [String],
        loopMode: LoopMode,
        orderedTracks: [TrackSummary]? = nil,
        orderedIndexById: [String: Int]? = nil
    ) -> Bool {
        if !upNextQueue.isEmpty {
            return true
        }
        let ordered = orderedTracks
            ?? orderedBaseTracks(libraryTracks: libraryTracks, shuffle: shuffle, shuffleOrderIds: shuffleOrderIds)
        guard !ordered.isEmpty else {
            return currentTrack != nil && loopMode == .one
        }
        guard let currentId = currentTrack?.id,
              let idx = resolveIndex(of: currentId, in: ordered, indexById: orderedIndexById) else {
            return true
        }
        if idx + 1 < ordered.count {
            return true
        }
        return loopMode != .off
    }

    package static func canSkipPrevious(
        currentTrack: TrackSummary?,
        libraryTracks: [TrackSummary],
        shuffle: Bool,
        shuffleOrderIds: [String],
        loopMode: LoopMode,
        orderedTracks: [TrackSummary]? = nil,
        orderedIndexById: [String: Int]? = nil
    ) -> Bool {
        let ordered = orderedTracks
            ?? orderedBaseTracks(libraryTracks: libraryTracks, shuffle: shuffle, shuffleOrderIds: shuffleOrderIds)
        guard !ordered.isEmpty else {
            return currentTrack != nil && loopMode == .one
        }
        guard let currentId = currentTrack?.id,
              let idx = resolveIndex(of: currentId, in: ordered, indexById: orderedIndexById) else {
            return true
        }
        if idx > 0 {
            return true
        }
        return loopMode != .off
    }

    package static func resolveNext(
        currentTrack: TrackSummary?,
        libraryTracks: [TrackSummary],
        upNextQueue: [TrackSummary],
        shuffle: Bool,
        shuffleOrderIds: [String],
        loopMode: LoopMode,
        autoAdvanceAtEnd: Bool = false,
        orderedTracks: [TrackSummary]? = nil,
        orderedIndexById: [String: Int]? = nil
    ) -> QueueStepResult {
        if autoAdvanceAtEnd && loopMode == .one {
            return QueueStepResult(track: currentTrack, remainingUpNext: upNextQueue)
        }
        if let firstUpNext = upNextQueue.first {
            return QueueStepResult(track: firstUpNext, remainingUpNext: Array(upNextQueue.dropFirst()))
        }
        let ordered = orderedTracks
            ?? orderedBaseTracks(libraryTracks: libraryTracks, shuffle: shuffle, shuffleOrderIds: shuffleOrderIds)
        guard !ordered.isEmpty else {
            let fallback = loopMode == .one ? currentTrack : nil
            return QueueStepResult(track: fallback, remainingUpNext: upNextQueue)
        }
        guard let currentId = currentTrack?.id,
              let idx = resolveIndex(of: currentId, in: ordered, indexById: orderedIndexById) else {
            return QueueStepResult(track: ordered.first, remainingUpNext: upNextQueue)
        }
        if idx + 1 < ordered.count {
            return QueueStepResult(track: ordered[idx + 1], remainingUpNext: upNextQueue)
        }
        switch loopMode {
        case .all:
            return QueueStepResult(track: ordered.first, remainingUpNext: upNextQueue)
        case .one:
            return QueueStepResult(track: currentTrack ?? ordered.first, remainingUpNext: upNextQueue)
        case .off:
            return QueueStepResult(track: nil, remainingUpNext: upNextQueue)
        }
    }

    package static func resolvePrevious(
        currentTrack: TrackSummary?,
        libraryTracks: [TrackSummary],
        upNextQueue: [TrackSummary],
        shuffle: Bool,
        shuffleOrderIds: [String],
        loopMode: LoopMode,
        orderedTracks: [TrackSummary]? = nil,
        orderedIndexById: [String: Int]? = nil
    ) -> QueueStepResult {
        let ordered = orderedTracks
            ?? orderedBaseTracks(libraryTracks: libraryTracks, shuffle: shuffle, shuffleOrderIds: shuffleOrderIds)
        guard !ordered.isEmpty else {
            let fallback = loopMode == .one ? currentTrack : nil
            return QueueStepResult(track: fallback, remainingUpNext: upNextQueue)
        }
        guard let currentId = currentTrack?.id,
              let idx = resolveIndex(of: currentId, in: ordered, indexById: orderedIndexById) else {
            return QueueStepResult(track: ordered.last ?? ordered.first, remainingUpNext: upNextQueue)
        }
        if idx > 0 {
            return QueueStepResult(track: ordered[idx - 1], remainingUpNext: upNextQueue)
        }
        switch loopMode {
        case .all:
            return QueueStepResult(track: ordered.last, remainingUpNext: upNextQueue)
        case .one:
            return QueueStepResult(track: currentTrack ?? ordered.first, remainingUpNext: upNextQueue)
        case .off:
            return QueueStepResult(track: nil, remainingUpNext: upNextQueue)
        }
    }

    package static func peekPrefetchCandidate(
        currentTrack: TrackSummary?,
        libraryTracks: [TrackSummary],
        upNextQueue: [TrackSummary],
        shuffle: Bool,
        shuffleOrderIds: [String],
        loopMode: LoopMode,
        orderedTracks: [TrackSummary]? = nil,
        orderedIndexById: [String: Int]? = nil
    ) -> TrackSummary? {
        guard loopMode != .one else { return nil }
        return resolveNext(
            currentTrack: currentTrack,
            libraryTracks: libraryTracks,
            upNextQueue: upNextQueue,
            shuffle: shuffle,
            shuffleOrderIds: shuffleOrderIds,
            loopMode: loopMode,
            autoAdvanceAtEnd: true,
            orderedTracks: orderedTracks,
            orderedIndexById: orderedIndexById
        ).track
    }

    package static func upcomingPreview(
        currentTrack: TrackSummary?,
        libraryTracks: [TrackSummary],
        upNextQueue: [TrackSummary],
        shuffle: Bool,
        shuffleOrderIds: [String],
        loopMode: LoopMode,
        limit: Int = 20,
        orderedTracks: [TrackSummary]? = nil,
        orderedIndexById: [String: Int]? = nil
    ) -> [TrackSummary] {
        guard limit > 0 else { return [] }
        var out: [TrackSummary] = Array(upNextQueue.prefix(limit))
        if out.count >= limit { return out }

        let ordered = orderedTracks
            ?? orderedBaseTracks(libraryTracks: libraryTracks, shuffle: shuffle, shuffleOrderIds: shuffleOrderIds)
        guard !ordered.isEmpty else { return out }

        var queuedIds = Set(out.map(\.id))
        if let currentId = currentTrack?.id {
            queuedIds.insert(currentId)
        }

        let anchorId = upNextQueue.last?.id ?? currentTrack?.id
        let startIndex: Int
        if let anchorId, let idx = resolveIndex(of: anchorId, in: ordered, indexById: orderedIndexById) {
            startIndex = idx + 1
        } else {
            startIndex = 0
        }

        if startIndex < ordered.count {
            for item in ordered[startIndex...] where queuedIds.insert(item.id).inserted {
                out.append(item)
                if out.count >= limit { return out }
            }
        }
        if loopMode == .all && startIndex > 0 {
            for item in ordered[..<min(startIndex, ordered.count)] where queuedIds.insert(item.id).inserted {
                out.append(item)
                if out.count >= limit { return out }
            }
        }
        return out
    }
}

package struct QrLoginStart: Codable, Equatable, Sendable {
    package var qrContent: String
    package var message: String

    package init(qrContent: String, message: String) {
        self.qrContent = qrContent
        self.message = message
    }
}

package enum QrLoginState: String, Codable, Equatable, Sendable {
    case waitingScan = "waiting_scan"
    case waitingConfirm = "waiting_confirm"
    case authenticated = "authenticated"
    case expired = "expired"
}

package struct QrPollResponse: Equatable, Sendable {
    package var state: QrLoginState
    package var message: String
    package var accountName: String?
    package var redirectURL: String?
    package var sessionEpoch: UInt64?

    package init(
        state: QrLoginState,
        message: String,
        accountName: String? = nil,
        redirectURL: String? = nil,
        sessionEpoch: UInt64? = nil
    ) {
        self.state = state
        self.message = message
        self.accountName = accountName
        self.redirectURL = redirectURL
        self.sessionEpoch = sessionEpoch
    }
}

package struct NowPlayingMetadata: Equatable, Sendable {
    package var title: String
    package var artist: String?
    package var album: String?
    package var artworkData: Data? {
        didSet {
            artworkDigest = artworkData.map { SHA256.hash(data: $0) }
        }
    }
    package private(set) var artworkDigest: SHA256Digest?

    package init(title: String, artist: String? = nil, album: String? = nil, artworkData: Data? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkData = artworkData
        self.artworkDigest = artworkData.map { SHA256.hash(data: $0) }
    }
}

package extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var trimmedNilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var nilIfNotDefaultDisplayName: String? {
        guard let trimmed = trimmedNilIfEmpty,
              trimmed != Cloud189Constants.defaultAccountDisplayName else {
            return nil
        }
        return trimmed
    }
}
