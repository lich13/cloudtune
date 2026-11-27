import AVFoundation
import CoreImage
import CryptoKit
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
    public var onInterruptionBegan: @Sendable () -> Void
    public var onInterruptionEndedShouldResume: @Sendable () -> Void
    public var onOldAudioDeviceUnavailable: @Sendable () -> Void

    public init(
        onPlay: @escaping @Sendable () -> Void,
        onPause: @escaping @Sendable () -> Void,
        onTogglePlayPause: @escaping @Sendable () -> Void,
        onNextTrack: @escaping @Sendable () -> Void,
        onPreviousTrack: @escaping @Sendable () -> Void,
        onSeekDelta: @escaping @Sendable (TimeInterval) -> Void,
        onSeekToPosition: @escaping @Sendable (TimeInterval) -> Void,
        onInterruptionBegan: @escaping @Sendable () -> Void = {},
        onInterruptionEndedShouldResume: @escaping @Sendable () -> Void = {},
        onOldAudioDeviceUnavailable: @escaping @Sendable () -> Void = {}
    ) {
        self.onPlay = onPlay
        self.onPause = onPause
        self.onTogglePlayPause = onTogglePlayPause
        self.onNextTrack = onNextTrack
        self.onPreviousTrack = onPreviousTrack
        self.onSeekDelta = onSeekDelta
        self.onSeekToPosition = onSeekToPosition
        self.onInterruptionBegan = onInterruptionBegan
        self.onInterruptionEndedShouldResume = onInterruptionEndedShouldResume
        self.onOldAudioDeviceUnavailable = onOldAudioDeviceUnavailable
    }
}

/// Shared system media-center coordinator for BOTH macOS (Control Center / media keys while window hidden)
/// and iOS/iPadOS (Lock Screen / Dynamic Island).
@MainActor
public final class NowPlayingCoordinator {
    private struct PublishedNowPlayingKey: Equatable {
        let title: String
        let artist: String?
        let album: String?
        let artworkDigest: SHA256Digest?
        let isPlaying: Bool
        let roundedDurationTenths: Int
    }

    private var registeredTargets: [(MPRemoteCommand, Any)] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var cachedArtworkDigest: SHA256Digest?
    #if canImport(MediaPlayer)
    private var cachedArtwork: MPMediaItemArtwork?
    #endif
    private var lastPublishedKey: PublishedNowPlayingKey?
    private var lastPublishedElapsed: TimeInterval = 0
    private var lastPublishedUptime: TimeInterval = 0
    private var lastCommandAvailability: (next: Bool, prev: Bool, seek: Bool)?

    public init() {}

    @discardableResult
    public func configureAudioSessionIfNeeded() -> String? {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            return nil
        } catch {
            return "音频会话配置失败：\(error.localizedDescription)"
        }
        #else
        return nil
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

        #if os(iOS)
        let nc = NotificationCenter.default
        let interruptionToken = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
            switch type {
            case .began:
                callbacks.onInterruptionBegan()
            case .ended:
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                if options.contains(.shouldResume) {
                    callbacks.onInterruptionEndedShouldResume()
                }
            @unknown default:
                break
            }
        }
        let routeToken = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { note in
            guard let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
            if reason == .oldDeviceUnavailable {
                callbacks.onOldAudioDeviceUnavailable()
            }
        }
        notificationObservers = [interruptionToken, routeToken]
        #endif
        #endif
    }

    public func unregisterRemoteCommands() {
        #if canImport(MediaPlayer)
        for (cmd, target) in registeredTargets {
            cmd.removeTarget(target)
        }
        registeredTargets.removeAll()
        #endif
        for obs in notificationObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        notificationObservers.removeAll()
        lastCommandAvailability = nil
    }

    public func updateCommandAvailability(canSkipNext: Bool, canSkipPrevious: Bool, hasActiveTrack: Bool) {
        #if canImport(MediaPlayer)
        let nextTuple = (next: canSkipNext, prev: canSkipPrevious, seek: hasActiveTrack)
        if let prev = lastCommandAvailability,
           prev.next == nextTuple.next,
           prev.prev == nextTuple.prev,
           prev.seek == nextTuple.seek {
            return
        }
        lastCommandAvailability = nextTuple
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = canSkipNext
        center.previousTrackCommand.isEnabled = canSkipPrevious
        center.changePlaybackPositionCommand.isEnabled = hasActiveTrack
        center.skipForwardCommand.isEnabled = hasActiveTrack
        center.skipBackwardCommand.isEnabled = hasActiveTrack
        #endif
    }

    public func updateNowPlaying(
        metadata: NowPlayingMetadata?,
        isPlaying: Bool,
        elapsedSeconds: TimeInterval,
        durationSeconds: TimeInterval,
        forceUpdate: Bool = false
    ) {
        #if canImport(MediaPlayer)
        let center = MPNowPlayingInfoCenter.default()
        guard let metadata else {
            if lastPublishedKey != nil || center.nowPlayingInfo != nil {
                center.nowPlayingInfo = nil
                lastPublishedKey = nil
                lastPublishedElapsed = 0
                lastPublishedUptime = 0
                #if os(macOS)
                center.playbackState = .stopped
                #endif
            }
            return
        }

        let digest = metadata.artworkData.map { SHA256.hash(data: $0) }
        let safeDuration = (durationSeconds > 0 && durationSeconds.isFinite) ? durationSeconds : 0
        let safeElapsed = max(0, elapsedSeconds.isFinite ? elapsedSeconds : 0)
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let key = PublishedNowPlayingKey(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            artworkDigest: digest,
            isPlaying: isPlaying,
            roundedDurationTenths: Int((safeDuration * 10).rounded())
        )

        if !forceUpdate, let prevKey = lastPublishedKey, prevKey == key {
            let expectedElapsed = lastPublishedElapsed + (isPlaying ? max(0, nowUptime - lastPublishedUptime) : 0)
            if abs(safeElapsed - expectedElapsed) < 1.5 {
                return
            }
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: safeElapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artist = metadata.artist, !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = metadata.album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if safeDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = safeDuration
        }
        if let artworkData = metadata.artworkData,
           let digest,
           let artwork = resolvedArtwork(from: artworkData, digest: digest) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        center.nowPlayingInfo = info
        lastPublishedKey = key
        lastPublishedElapsed = safeElapsed
        lastPublishedUptime = nowUptime
        #if os(macOS)
        center.playbackState = isPlaying ? .playing : .paused
        #endif
        #endif
    }

    #if canImport(MediaPlayer)
    private func resolvedArtwork(from data: Data, digest: SHA256Digest) -> MPMediaItemArtwork? {
        if cachedArtworkDigest == digest, let cachedArtwork {
            return cachedArtwork
        }
        let created = makeMediaArtwork(from: data)
        cachedArtworkDigest = digest
        cachedArtwork = created
        return created
    }

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
