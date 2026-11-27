import Foundation

public enum LoopMode: String, Codable, CaseIterable, Sendable {
    case off
    case all
    case one
}

public enum PlaybackMode: String, Codable, CaseIterable, Sendable {
    case downloadFirst = "download_first"
    case streamCache = "stream_cache"

    public var displayTitle: String {
        switch self {
        case .downloadFirst: return "优先缓存"
        case .streamCache: return "边播边缓存"
        }
    }
}

public enum ModuleTab: String, Codable, CaseIterable, Identifiable, Sendable {
    case music
    case video
    case download
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .music: return "音乐"
        case .video: return "视频"
        case .download: return "下载"
        case .settings: return "设置"
        }
    }
}

/// Active authenticated session with non-empty signing keys for the current process run.
public struct ActiveCloudSession: Equatable, Sendable {
    public let accessToken: String
    public let sessionKey: String
    public let sessionSecret: String
    public let loginName: String?

    public init?(
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
        self.loginName = loginName?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

/// Persisted cold-start refresh credential. Only created when a non-empty refreshToken exists.
public struct PersistedRefreshCredential: Codable, Equatable, Sendable {
    public let refreshToken: String
    public let accountName: String?

    public init?(refreshToken: String, accountName: String?) {
        let trimmed = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.refreshToken = trimmed
        self.accountName = accountName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public struct FolderSelection: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? "-11"
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "我的云盘"
    }
}

public struct RemoteFolder: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var parentId: String?

    public init(id: String, name: String, parentId: String? = nil) {
        self.id = id
        self.name = name
        self.parentId = parentId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
    }
}

public struct BreadcrumbItem: Codable, Equatable, Hashable, Sendable {
    public var id: String?
    public var name: String

    public init(id: String?, name: String) {
        self.id = id
        self.name = name
    }

    public static let root = BreadcrumbItem(id: nil, name: "我的云盘")
}

public struct TrackSummary: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var folderPath: String
    public var sizeBytes: UInt64
    public var modifiedAt: String?

    public init(
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath) ?? ""
        self.sizeBytes = try c.decodeIfPresent(UInt64.self, forKey: .sizeBytes) ?? 0
        self.modifiedAt = try c.decodeIfPresent(String.self, forKey: .modifiedAt)
    }
}

public struct FolderBrowsePayload: Codable, Equatable, Sendable {
    public var currentFolderId: String
    public var currentFolderName: String
    public var parentFolderId: String?
    public var isRoot: Bool
    public var folders: [RemoteFolder]
    public var audioFiles: [TrackSummary]
    public var videoFiles: [TrackSummary]
    public var otherFiles: [TrackSummary]

    public init(
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.currentFolderId = try c.decodeIfPresent(String.self, forKey: .currentFolderId) ?? "-11"
        self.currentFolderName = try c.decodeIfPresent(String.self, forKey: .currentFolderName) ?? "我的云盘"
        self.parentFolderId = try c.decodeIfPresent(String.self, forKey: .parentFolderId)
        self.isRoot = try c.decodeIfPresent(Bool.self, forKey: .isRoot) ?? false
        self.folders = try c.decodeIfPresent([RemoteFolder].self, forKey: .folders) ?? []
        self.audioFiles = try c.decodeIfPresent([TrackSummary].self, forKey: .audioFiles) ?? []
        self.videoFiles = try c.decodeIfPresent([TrackSummary].self, forKey: .videoFiles) ?? []
        self.otherFiles = try c.decodeIfPresent([TrackSummary].self, forKey: .otherFiles) ?? []
    }
}

public struct AccountSettings: Codable, Equatable, Sendable {
    public static let minCacheLimitMB: UInt64 = 256
    public static let maxDownloadThreads: Int = 16
    public static let maxCacheThreads: Int = 8

    public var musicFolder: FolderSelection?
    public var cacheLimitMb: UInt64
    public var downloadThreads: Int
    public var cacheThreads: Int
    public var playbackMode: PlaybackMode
    public var exportFolderDisplayName: String?

    public init(
        musicFolder: FolderSelection? = nil,
        cacheLimitMb: UInt64 = 1024,
        downloadThreads: Int = 8,
        cacheThreads: Int = 4,
        playbackMode: PlaybackMode = .downloadFirst,
        exportFolderDisplayName: String? = nil
    ) {
        self.musicFolder = musicFolder
        self.cacheLimitMb = max(Self.minCacheLimitMB, cacheLimitMb)
        self.downloadThreads = min(max(1, downloadThreads), Self.maxDownloadThreads)
        self.cacheThreads = min(max(1, cacheThreads), Self.maxCacheThreads)
        self.playbackMode = playbackMode
        self.exportFolderDisplayName = exportFolderDisplayName
    }

    public var cacheLimitBytes: UInt64 {
        cacheLimitMb * 1024 * 1024
    }

    public init(from decoder: Decoder) throws {
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
    }
}

public struct PreparedTrack: Equatable, Sendable {
    public let trackId: String
    public let localURL: URL
    public let playbackURL: URL
    public let isStreaming: Bool
    public let cacheUsageBytes: UInt64

    public init(
        trackId: String,
        localURL: URL,
        playbackURL: URL,
        isStreaming: Bool,
        cacheUsageBytes: UInt64
    ) {
        self.trackId = trackId
        self.localURL = localURL
        self.playbackURL = playbackURL
        self.isStreaming = isStreaming
        self.cacheUsageBytes = cacheUsageBytes
    }
}

public struct TransferStatus: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var kind: String
    public var state: String
    public var path: String?
    public var canPause: Bool
    public var canResume: Bool
    public var canDelete: Bool
    public var bytesPerSecond: UInt64
    public var transferredBytes: UInt64
    public var totalBytes: UInt64?

    public init(
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

    public init(from decoder: Decoder) throws {
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
}

public struct TransferSnapshotPayload: Codable, Equatable, Sendable {
    public var totalSpeedBytesPerSecond: UInt64
    public var items: [TransferStatus]

    public init(totalSpeedBytesPerSecond: UInt64 = 0, items: [TransferStatus] = []) {
        self.totalSpeedBytesPerSecond = totalSpeedBytesPerSecond
        self.items = items
    }
}

public struct QrLoginStart: Codable, Equatable, Sendable {
    public var qrContent: String
    public var message: String

    public init(qrContent: String, message: String) {
        self.qrContent = qrContent
        self.message = message
    }
}

public enum QrLoginState: String, Codable, Equatable, Sendable {
    case waitingScan = "waiting_scan"
    case waitingConfirm = "waiting_confirm"
    case authenticated = "authenticated"
    case expired = "expired"
}

public struct QrPollResponse: Equatable, Sendable {
    public var state: QrLoginState
    public var message: String
    public var accountName: String?
    public var redirectURL: String?

    public init(state: QrLoginState, message: String, accountName: String? = nil, redirectURL: String? = nil) {
        self.state = state
        self.message = message
        self.accountName = accountName
        self.redirectURL = redirectURL
    }
}

public struct NowPlayingMetadata: Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var artworkData: Data?

    public init(title: String, artist: String? = nil, album: String? = nil, artworkData: Data? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkData = artworkData
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
