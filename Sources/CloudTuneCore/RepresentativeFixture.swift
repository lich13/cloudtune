import Foundation

public struct RepresentativeFixture: Codable, Equatable, Sendable {
    public struct QrLoginFixture: Codable, Equatable, Sendable {
        public var qrContent: String
        public var message: String
        public var host: String
    }

    public struct SettingsFixture: Codable, Equatable, Sendable {
        public var cacheLimitMb: UInt64
        public var downloadThreads: Int
        public var cacheThreads: Int
        public var playbackMode: PlaybackMode
        public var cacheUsageBytes: UInt64
    }

    public struct NowPlayingFixture: Codable, Equatable, Sendable {
        public var trackId: String
        public var title: String
        public var artist: String
        public var album: String
        public var isPlaying: Bool
        public var currentTimeSeconds: Double
        public var durationSeconds: Double
        public var shuffle: Bool
        public var loopMode: LoopMode
        public var statusMessage: String
    }

    public struct ErrorBannerFixture: Codable, Equatable, Sendable {
        public var statusMessage: String
    }

    public var accountName: String
    public var currentFolder: FolderSelection
    public var settings: SettingsFixture
    public var qrLogin: QrLoginFixture
    public var breadcrumbs: [BreadcrumbItem]
    public var browser: FolderBrowsePayload
    public var libraryTracks: [TrackSummary]
    public var nowPlaying: NowPlayingFixture
    public var transferSnapshot: TransferSnapshotPayload
    public var errorBanner: ErrorBannerFixture

    public static func load(from url: URL) throws -> RepresentativeFixture {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RepresentativeFixture.self, from: data)
    }
}

public enum CloudTuneFormatters {
    public static func formatBytes(_ value: UInt64) -> String {
        if value == 0 { return "0 MB" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(value)
        var index = 0
        while size >= 1024.0 && index < units.count - 1 {
            size /= 1024.0
            index += 1
        }
        if index > 1 {
            return String(format: "%.1f %@", size, units[index])
        }
        return String(format: "%.0f %@", size, units[index])
    }

    public static func formatClock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    public static func formatPercent(transferred: UInt64, total: UInt64?) -> Double? {
        guard let total, total > 0 else { return nil }
        return min(100.0, (Double(transferred) / Double(total)) * 100.0)
    }
}
