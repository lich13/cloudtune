import AVFoundation
@preconcurrency import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

package enum QRCodeGenerator {
    nonisolated(unsafe) private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Fixed warm-parchment `#F6F1E8` substrate and deep-pine `#13271F` modules across light & dark themes.
    package static func generatePNGData(content: String, dimension: Int = 512) -> Data? {
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

        return ciContext.pngRepresentation(of: scaled, format: .RGBA8, colorSpace: sRGBColorSpace)
    }
}

package enum AudioMetadataReader {
    package static func readMetadata(
        from fileURL: URL,
        fallbackTitle: String,
        fallbackAlbum: String
    ) async -> NowPlayingMetadata {
        var resolvedTitle = fallbackTitle.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : fallbackTitle
        var resolvedArtist: String?
        var resolvedAlbum: String? = fallbackAlbum.isEmpty ? "CloudTune" : fallbackAlbum
        var rawArtwork: Data?

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let asset = AVURLAsset(url: fileURL)
            if let metadata = try? await asset.load(.commonMetadata) {
                for item in metadata {
                    guard let key = item.commonKey else { continue }
                    switch key {
                    case .commonKeyTitle:
                        if let title = try? await item.load(.stringValue),
                           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            resolvedTitle = title
                        }
                    case .commonKeyArtist:
                        if let artist = try? await item.load(.stringValue),
                           !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            resolvedArtist = artist
                        }
                    case .commonKeyAlbumName:
                        if let album = try? await item.load(.stringValue),
                           !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            resolvedAlbum = album
                        }
                    case .commonKeyArtwork:
                        if let data = try? await item.load(.dataValue), !data.isEmpty {
                            rawArtwork = data
                        }
                    default:
                        break
                    }
                }
            }
        }

        let compactArtwork = rawArtwork.map { compactArtworkData($0) }
        return NowPlayingMetadata(
            title: resolvedTitle,
            artist: resolvedArtist,
            album: resolvedAlbum,
            artworkData: compactArtwork
        )
    }

    package static func compactArtworkData(_ rawArtwork: Data, maxPixelSize: Int = 1024) -> Data {
        guard !rawArtwork.isEmpty,
              let source = CGImageSourceCreateWithData(
                  rawArtwork as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            return rawArtwork
        }

        var originalMaxDimension: Int?
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           width > 0,
           height > 0 {
            let maxDim = max(width, height)
            originalMaxDimension = maxDim
            if maxDim <= maxPixelSize && rawArtwork.count <= 256 * 1024 {
                return rawArtwork
            }
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return rawArtwork
        }
        if originalMaxDimension == nil,
           max(cgImage.width, cgImage.height) < maxPixelSize,
           rawArtwork.count <= 256 * 1024 {
            return rawArtwork
        }

        let hasAlpha: Bool = switch cgImage.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            true
        case .none, .noneSkipFirst, .noneSkipLast:
            false
        @unknown default:
            false
        }

        let output = NSMutableData()
        let typeIdentifier = (hasAlpha ? UTType.png.identifier : UTType.jpeg.identifier) as CFString
        guard let destination = CGImageDestinationCreateWithData(output, typeIdentifier, 1, nil) else {
            return rawArtwork
        }
        let properties: CFDictionary? = hasAlpha
            ? nil
            : ([kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationAddImage(destination, cgImage, properties)
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            return rawArtwork
        }
        return output as Data
    }
}

package struct RemoteCommandCallbacks: Sendable {
    package var onPlay: @Sendable () -> Void
    package var onPause: @Sendable () -> Void
    package var onTogglePlayPause: @Sendable () -> Void
    package var onNextTrack: @Sendable () -> Void
    package var onPreviousTrack: @Sendable () -> Void
    package var onSeekDelta: @Sendable (TimeInterval) -> Void
    package var onSeekToPosition: @Sendable (TimeInterval) -> Void
    package var onInterruptionBegan: @Sendable () -> Void
    package var onInterruptionEndedShouldResume: @Sendable () -> Void
    package var onOldAudioDeviceUnavailable: @Sendable () -> Void

    package init(
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

#if DEBUG
package enum TestableRemoteCommand: Sendable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
    case skipForward(TimeInterval)
    case skipBackward(TimeInterval)
    case changePlaybackPosition(TimeInterval?)
}
private typealias RemoteCommandDebugInvoker = @Sendable (TestableRemoteCommand) -> Bool
#else
private typealias RemoteCommandDebugInvoker = @Sendable (Never) -> Bool
#endif

private final class RegistrationBox: @unchecked Sendable {
    private let lock = NSLock()
    #if canImport(MediaPlayer)
    private var targets: [(MPRemoteCommand, Any)] = []
    #endif
    private var observers: [NSObjectProtocol] = []
    #if DEBUG
    private var debugInvoker: RemoteCommandDebugInvoker?
    #endif

    #if canImport(MediaPlayer)
    func replace(
        targets newTargets: [(MPRemoteCommand, Any)],
        observers newObservers: [NSObjectProtocol],
        debugInvoker newDebugInvoker: RemoteCommandDebugInvoker? = nil
    ) {
        let (oldTargets, oldObservers) = lock.withLock { () -> ([(MPRemoteCommand, Any)], [NSObjectProtocol]) in
            let prevT = targets
            let prevO = observers
            targets = newTargets
            observers = newObservers
            #if DEBUG
            debugInvoker = newDebugInvoker
            #endif
            return (prevT, prevO)
        }
        for (cmd, target) in oldTargets {
            cmd.removeTarget(target)
        }
        for obs in oldObservers {
            NotificationCenter.default.removeObserver(obs)
        }
    }
    #endif

    #if DEBUG
    func invokeForTesting(_ command: TestableRemoteCommand) -> Bool {
        let invoker = lock.withLock { debugInvoker }
        return invoker?(command) ?? false
    }
    #endif

    func clearAll() {
        #if canImport(MediaPlayer)
        let (oldTargets, oldObservers) = lock.withLock { () -> ([(MPRemoteCommand, Any)], [NSObjectProtocol]) in
            let prevT = targets
            let prevO = observers
            targets.removeAll()
            observers.removeAll()
            #if DEBUG
            debugInvoker = nil
            #endif
            return (prevT, prevO)
        }
        for (cmd, target) in oldTargets {
            cmd.removeTarget(target)
        }
        #else
        let oldObservers = lock.withLock { () -> [NSObjectProtocol] in
            let prevO = observers
            observers.removeAll()
            #if DEBUG
            debugInvoker = nil
            #endif
            return prevO
        }
        #endif
        for obs in oldObservers {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}

/// Shared system media-center coordinator for BOTH macOS (Control Center / media keys while window hidden)
/// and iOS/iPadOS (Lock Screen / Dynamic Island).
@MainActor
package final class NowPlayingCoordinator {
    private struct PublishedNowPlayingKey: Equatable {
        let title: String
        let artist: String?
        let album: String?
        let artworkDigest: SHA256Digest?
        let isPlaying: Bool
        let effectiveRateTenths: Int
        let roundedDurationTenths: Int
    }

    private nonisolated let registrations = RegistrationBox()
    private var cachedArtworkDigest: SHA256Digest?
    #if canImport(MediaPlayer)
    private var cachedArtwork: MPMediaItemArtwork?
    #endif
    private var lastPublishedKey: PublishedNowPlayingKey?
    private var lastPublishedElapsed: TimeInterval = 0
    private var lastPublishedRate: Double = 0
    private var lastPublishedUptime: TimeInterval = 0
    private var lastCommandAvailability: (next: Bool, prev: Bool, seek: Bool)?

    package init() {}

    deinit {
        registrations.clearAll()
    }

    @discardableResult
    package func configureAudioSessionIfNeeded() -> String? {
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

    package func registerRemoteCommands(_ callbacks: RemoteCommandCallbacks) {
        #if canImport(MediaPlayer)
        unregisterRemoteCommands()
        let center = MPRemoteCommandCenter.shared()
        let installed = Self.installRemoteHandlers(center: center, callbacks: callbacks)
        registrations.replace(
            targets: installed.targets,
            observers: installed.observers,
            debugInvoker: installed.debugInvoker
        )
        #endif
    }

    #if DEBUG
    package nonisolated func invokeRemoteCommandForTesting(_ command: TestableRemoteCommand) -> Bool {
        registrations.invokeForTesting(command)
    }
    #endif

    #if canImport(MediaPlayer)
    nonisolated private static func installRemoteHandlers(
        center: MPRemoteCommandCenter,
        callbacks: RemoteCommandCallbacks
    ) -> (
        targets: [(MPRemoteCommand, Any)],
        observers: [NSObjectProtocol],
        debugInvoker: RemoteCommandDebugInvoker?
    ) {
        let handlePlay: @Sendable () -> MPRemoteCommandHandlerStatus = {
            callbacks.onPlay()
            return .success
        }
        let handlePause: @Sendable () -> MPRemoteCommandHandlerStatus = {
            callbacks.onPause()
            return .success
        }
        let handleToggle: @Sendable () -> MPRemoteCommandHandlerStatus = {
            callbacks.onTogglePlayPause()
            return .success
        }
        let handleNext: @Sendable () -> MPRemoteCommandHandlerStatus = {
            callbacks.onNextTrack()
            return .success
        }
        let handlePrev: @Sendable () -> MPRemoteCommandHandlerStatus = {
            callbacks.onPreviousTrack()
            return .success
        }
        let handleSkipForward: @Sendable (TimeInterval) -> MPRemoteCommandHandlerStatus = { delta in
            callbacks.onSeekDelta(delta)
            return .success
        }
        let handleSkipBackward: @Sendable (TimeInterval) -> MPRemoteCommandHandlerStatus = { delta in
            callbacks.onSeekDelta(-delta)
            return .success
        }
        let handleSeekPosition: @Sendable (TimeInterval?) -> MPRemoteCommandHandlerStatus = { pos in
            if let pos {
                callbacks.onSeekToPosition(pos)
                return .success
            }
            return .commandFailed
        }

        let playTarget = center.playCommand.addTarget { _ in handlePlay() }
        let pauseTarget = center.pauseCommand.addTarget { _ in handlePause() }
        let toggleTarget = center.togglePlayPauseCommand.addTarget { _ in handleToggle() }
        let nextTarget = center.nextTrackCommand.addTarget { _ in handleNext() }
        let prevTarget = center.previousTrackCommand.addTarget { _ in handlePrev() }
        center.skipForwardCommand.preferredIntervals = [15]
        let skipFwdTarget = center.skipForwardCommand.addTarget { event in
            let delta = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            return handleSkipForward(delta)
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        let skipBackTarget = center.skipBackwardCommand.addTarget { event in
            let delta = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            return handleSkipBackward(delta)
        }
        let seekTarget = center.changePlaybackPositionCommand.addTarget { event in
            handleSeekPosition((event as? MPChangePlaybackPositionCommandEvent)?.positionTime)
        }

        #if DEBUG
        let debugInvoker: @Sendable (TestableRemoteCommand) -> Bool = { command in
            let status: MPRemoteCommandHandlerStatus = switch command {
            case .play:
                handlePlay()
            case .pause:
                handlePause()
            case .togglePlayPause:
                handleToggle()
            case .nextTrack:
                handleNext()
            case .previousTrack:
                handlePrev()
            case let .skipForward(delta):
                handleSkipForward(delta)
            case let .skipBackward(delta):
                handleSkipBackward(delta)
            case let .changePlaybackPosition(pos):
                handleSeekPosition(pos)
            }
            return status == .success
        }
        #else
        let debugInvoker: RemoteCommandDebugInvoker? = nil
        #endif

        let targets: [(MPRemoteCommand, Any)] = [
            (center.playCommand, playTarget),
            (center.pauseCommand, pauseTarget),
            (center.togglePlayPauseCommand, toggleTarget),
            (center.nextTrackCommand, nextTarget),
            (center.previousTrackCommand, prevTarget),
            (center.skipForwardCommand, skipFwdTarget),
            (center.skipBackwardCommand, skipBackTarget),
            (center.changePlaybackPositionCommand, seekTarget)
        ]

        var observers: [NSObjectProtocol] = []
        #if os(iOS)
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let interruptionToken = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
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
            object: session,
            queue: .main
        ) { note in
            guard let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
            if reason == .oldDeviceUnavailable {
                callbacks.onOldAudioDeviceUnavailable()
            }
        }
        observers = [interruptionToken, routeToken]
        #endif
        return (targets: targets, observers: observers, debugInvoker: debugInvoker)
    }
    #endif

    package func unregisterRemoteCommands() {
        registrations.clearAll()
        lastCommandAvailability = nil
    }

    package func updateCommandAvailability(canSkipNext: Bool, canSkipPrevious: Bool, hasActiveTrack: Bool) {
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

    package func updateNowPlaying(
        metadata: NowPlayingMetadata?,
        isPlaying: Bool,
        elapsedSeconds: TimeInterval,
        durationSeconds: TimeInterval,
        playbackRate: Double? = nil,
        forceUpdate: Bool = false
    ) {
        #if canImport(MediaPlayer)
        let center = MPNowPlayingInfoCenter.default()
        guard let metadata else {
            if lastPublishedKey != nil || center.nowPlayingInfo != nil {
                center.nowPlayingInfo = nil
                lastPublishedKey = nil
                lastPublishedElapsed = 0
                lastPublishedRate = 0
                lastPublishedUptime = 0
                #if os(macOS)
                center.playbackState = .stopped
                #endif
            }
            return
        }

        let digest = metadata.artworkDigest
        let safeDuration = (durationSeconds > 0 && durationSeconds.isFinite) ? durationSeconds : 0
        let safeElapsed = max(0, elapsedSeconds.isFinite ? elapsedSeconds : 0)
        let resolvedRate = playbackRate ?? (isPlaying ? 1.0 : 0.0)
        let effectiveRate = resolvedRate.isFinite ? max(0.0, resolvedRate) : (isPlaying ? 1.0 : 0.0)
        let effectiveRateTenths = Int((effectiveRate * 10).rounded())
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let key = PublishedNowPlayingKey(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            artworkDigest: digest,
            isPlaying: isPlaying,
            effectiveRateTenths: effectiveRateTenths,
            roundedDurationTenths: Int((safeDuration * 10).rounded())
        )

        if !forceUpdate, let prevKey = lastPublishedKey, prevKey == key {
            let expectedElapsed = lastPublishedElapsed + max(0, nowUptime - lastPublishedUptime) * lastPublishedRate
            if abs(safeElapsed - expectedElapsed) < 1.5 {
                return
            }
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: safeElapsed,
            MPNowPlayingInfoPropertyPlaybackRate: effectiveRate
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
        lastPublishedRate = effectiveRate
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
        let created = Self.makeMediaArtwork(from: data)
        cachedArtworkDigest = digest
        cachedArtwork = created
        return created
    }

    nonisolated package static func makeMediaArtwork(from data: Data) -> MPMediaItemArtwork? {
        guard !data.isEmpty,
              let src = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(src, 0, nil),
              cgImage.width > 0,
              cgImage.height > 0 else {
            return nil
        }
        let boundsSize = CGSize(width: cgImage.width, height: cgImage.height)
        #if os(macOS)
        return MPMediaItemArtwork(boundsSize: boundsSize) { _ in
            NSImage(cgImage: cgImage, size: boundsSize)
        }
        #elseif os(iOS)
        return MPMediaItemArtwork(boundsSize: boundsSize) { _ in
            UIImage(cgImage: cgImage)
        }
        #else
        return nil
        #endif
    }
    #endif
}
