import AVFoundation
import CoreImage
import Foundation
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public enum QRCodeGenerator {
    /// Fixed warm-parchment `#F6F1E8` substrate and deep-pine `#13271F` modules across light & dark themes.
    public static func generatePNGData(content: String, dimension: Int = 512) -> Data? {
        guard !content.isEmpty,
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(Data(content.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let rawImage = filter.outputImage,
              let colorFilter = CIFilter(name: "CIFalseColor") else { return nil }
        colorFilter.setValue(rawImage, forKey: kCIInputImageKey)
        // Dark modules: #13271F, Light substrate: #F6F1E8
        colorFilter.setValue(CIColor(red: 0x13 / 255.0, green: 0x27 / 255.0, blue: 0x1F / 255.0, alpha: 1.0), forKey: "inputColor0")
        colorFilter.setValue(CIColor(red: 0xF6 / 255.0, green: 0xF1 / 255.0, blue: 0xE8 / 255.0, alpha: 1.0), forKey: "inputColor1")

        guard let colored = colorFilter.outputImage else { return nil }
        let scale = max(1.0, CGFloat(dimension) / max(1.0, colored.extent.width))
        let scaled = colored.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return context.pngRepresentation(of: scaled, format: .RGBA8, colorSpace: colorSpace)
    }
}

public enum AudioMetadataReader {
    public static func readMetadata(
        from fileURL: URL,
        fallbackTitle: String,
        fallbackAlbum: String
    ) async -> NowPlayingMetadata {
        var result = NowPlayingMetadata(
            title: fallbackTitle.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : fallbackTitle,
            artist: nil,
            album: fallbackAlbum.isEmpty ? "CloudTune" : fallbackAlbum,
            artworkData: nil
        )
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return result
        }
        let asset = AVURLAsset(url: fileURL)
        guard let metadata = try? await asset.load(.commonMetadata) else {
            return result
        }
        for item in metadata {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle:
                if let title = try? await item.load(.stringValue), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.title = title
                }
            case .commonKeyArtist:
                if let artist = try? await item.load(.stringValue), !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.artist = artist
                }
            case .commonKeyAlbumName:
                if let album = try? await item.load(.stringValue), !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.album = album
                }
            case .commonKeyArtwork:
                if let data = try? await item.load(.dataValue), !data.isEmpty {
                    result.artworkData = data
                }
            default:
                break
            }
        }
        return result
    }
}

public struct RemoteCommandCallbacks: Sendable {
    public var onPlay: @Sendable () -> Void
    public var onPause: @Sendable () -> Void
    public var onTogglePlayPause: @Sendable () -> Void
    public var onNextTrack: @Sendable () -> Void
    public var onPreviousTrack: @Sendable () -> Void
    public var onSeekDelta: @Sendable (TimeInterval) -> Void
    public var onSeekToPosition: @Sendable (TimeInterval) -> Void

    public init(
        onPlay: @escaping @Sendable () -> Void,
        onPause: @escaping @Sendable () -> Void,
        onTogglePlayPause: @escaping @Sendable () -> Void,
        onNextTrack: @escaping @Sendable () -> Void,
        onPreviousTrack: @escaping @Sendable () -> Void,
        onSeekDelta: @escaping @Sendable (TimeInterval) -> Void,
        onSeekToPosition: @escaping @Sendable (TimeInterval) -> Void
    ) {
        self.onPlay = onPlay
        self.onPause = onPause
        self.onTogglePlayPause = onTogglePlayPause
        self.onNextTrack = onNextTrack
        self.onPreviousTrack = onPreviousTrack
        self.onSeekDelta = onSeekDelta
        self.onSeekToPosition = onSeekToPosition
    }
}

/// Shared system media-center coordinator for BOTH macOS (Control Center / media keys while window hidden)
/// and iOS/iPadOS (Lock Screen / Dynamic Island).
@MainActor
public final class NowPlayingCoordinator {
    private var registeredTargets: [(MPRemoteCommand, Any)] = []

    public init() {}

    public func configureAudioSessionIfNeeded() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        #endif
    }

    public func registerRemoteCommands(_ callbacks: RemoteCommandCallbacks) {
        #if canImport(MediaPlayer)
        unregisterRemoteCommands()
        let center = MPRemoteCommandCenter.shared()

        let playTarget = center.playCommand.addTarget { _ in
            callbacks.onPlay()
            return .success
        }
        let pauseTarget = center.pauseCommand.addTarget { _ in
            callbacks.onPause()
            return .success
        }
        let toggleTarget = center.togglePlayPauseCommand.addTarget { _ in
            callbacks.onTogglePlayPause()
            return .success
        }
        let nextTarget = center.nextTrackCommand.addTarget { _ in
            callbacks.onNextTrack()
            return .success
        }
        let prevTarget = center.previousTrackCommand.addTarget { _ in
            callbacks.onPreviousTrack()
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        let skipFwdTarget = center.skipForwardCommand.addTarget { event in
            let delta = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            callbacks.onSeekDelta(delta)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        let skipBackTarget = center.skipBackwardCommand.addTarget { event in
            let delta = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            callbacks.onSeekDelta(-delta)
            return .success
        }
        let seekTarget = center.changePlaybackPositionCommand.addTarget { event in
            if let pos = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime {
                callbacks.onSeekToPosition(pos)
                return .success
            }
            return .commandFailed
        }

        registeredTargets = [
            (center.playCommand, playTarget),
            (center.pauseCommand, pauseTarget),
            (center.togglePlayPauseCommand, toggleTarget),
            (center.nextTrackCommand, nextTarget),
            (center.previousTrackCommand, prevTarget),
            (center.skipForwardCommand, skipFwdTarget),
            (center.skipBackwardCommand, skipBackTarget),
            (center.changePlaybackPositionCommand, seekTarget)
        ]
        #endif
    }

    public func unregisterRemoteCommands() {
        #if canImport(MediaPlayer)
        for (cmd, target) in registeredTargets {
            cmd.removeTarget(target)
        }
        registeredTargets.removeAll()
        #endif
    }

    public func updateNowPlaying(
        metadata: NowPlayingMetadata?,
        isPlaying: Bool,
        elapsedSeconds: TimeInterval,
        durationSeconds: TimeInterval
    ) {
        #if canImport(MediaPlayer)
        let center = MPNowPlayingInfoCenter.default()
        guard let metadata else {
            center.nowPlayingInfo = nil
            #if os(macOS)
            center.playbackState = .stopped
            #endif
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsedSeconds),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artist = metadata.artist, !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = metadata.album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if durationSeconds > 0, durationSeconds.isFinite {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }
        if let artworkData = metadata.artworkData, let artwork = makeMediaArtwork(from: artworkData) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = isPlaying ? .playing : .paused
        #endif
        #endif
    }

    #if canImport(MediaPlayer)
    private func makeMediaArtwork(from data: Data) -> MPMediaItemArtwork? {
        #if os(macOS)
        guard let img = NSImage(data: data) else { return nil }
        let size = img.size.width > 0 ? img.size : NSSize(width: 512, height: 512)
        return MPMediaItemArtwork(boundsSize: size) { _ in img }
        #elseif os(iOS)
        guard let img = UIImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        #else
        return nil
        #endif
    }
    #endif
}
