import Foundation

#if DEBUG
public struct RepresentativeFixture: Codable, Equatable, Sendable {
    package struct QrLoginFixture: Codable, Equatable, Sendable {
        package var qrContent: String
        package var message: String
        package var host: String
    }

    package struct SettingsFixture: Codable, Equatable, Sendable {
        package var cacheLimitMb: UInt64
        package var downloadThreads: Int
        package var cacheThreads: Int
        package var playbackMode: PlaybackMode
        package var cacheUsageBytes: UInt64
        package var appearanceMode: AppearanceMode?
        package var dynamicColorEnabled: Bool?
    }

    package struct NowPlayingFixture: Codable, Equatable, Sendable {
        package var trackId: String
        package var title: String
        package var artist: String
        package var album: String
        package var isPlaying: Bool
        package var currentTimeSeconds: Double
        package var durationSeconds: Double
        package var shuffle: Bool
        package var loopMode: LoopMode
        package var statusMessage: String
    }

    package struct ErrorBannerFixture: Codable, Equatable, Sendable {
        package var statusMessage: String
    }

    package var accountName: String
    package var currentFolder: FolderSelection
    package var settings: SettingsFixture
    package var qrLogin: QrLoginFixture
    package var breadcrumbs: [BreadcrumbItem]
    package var browser: FolderBrowsePayload
    package var libraryTracks: [TrackSummary]
    package var nowPlaying: NowPlayingFixture
    package var transferSnapshot: TransferSnapshotPayload
    package var errorBanner: ErrorBannerFixture

    public static func load(from url: URL) throws -> RepresentativeFixture {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RepresentativeFixture.self, from: data)
    }
}
#endif

package enum CloudTuneFormatters {
    package static func formatBytes(_ value: UInt64) -> String {
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

    package static func formatClock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    package static func formatPercent(transferred: UInt64, total: UInt64?) -> Double? {
        guard let total, total > 0 else { return nil }
        return min(100.0, (Double(transferred) / Double(total)) * 100.0)
    }
}
