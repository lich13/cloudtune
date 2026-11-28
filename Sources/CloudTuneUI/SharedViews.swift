import AVKit
import CloudTuneCore
import CryptoKit
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

private final class DecodedImageCache: @unchecked Sendable {
    static let shared = DecodedImageCache()

    #if os(macOS)
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 96
        return c
    }()
    #elseif os(iOS)
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 96
        return c
    }()
    #endif

    func image(for data: Data) -> Image? {
        guard !data.isEmpty else { return nil }
        let digest = SHA256.hash(data: data)
        var hex = ""
        hex.reserveCapacity(72)
        for byte in digest {
            let hi = Int(byte >> 4)
            let lo = Int(byte & 0x0F)
            hex.append(Character(UnicodeScalar(hi < 10 ? 48 + hi : 87 + hi)!))
            hex.append(Character(UnicodeScalar(lo < 10 ? 48 + lo : 87 + lo)!))
        }
        let key = "\(data.count):\(hex)" as NSString
        #if os(macOS)
        if let cached = cache.object(forKey: key) {
            return Image(nsImage: cached)
        }
        guard let decoded = NSImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: key, cost: data.count)
        return Image(nsImage: decoded)
        #elseif os(iOS)
        if let cached = cache.object(forKey: key) {
            return Image(uiImage: cached)
        }
        guard let decoded = UIImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: key, cost: data.count)
        return Image(uiImage: decoded)
        #else
        return nil
        #endif
    }
}

private func decodePlatformImage(_ data: Data) -> Image? {
    DecodedImageCache.shared.image(for: data)
}

package struct InteractiveSurfaceButtonStyle: ButtonStyle {
    package var hoverOverlayColor: Color?
    package var cornerRadius: CGFloat
    package var pressScale: CGFloat

    package init(
        hoverOverlayColor: Color? = Color.primary.opacity(0.05),
        cornerRadius: CGFloat = 8,
        pressScale: CGFloat = 0.985
    ) {
        self.hoverOverlayColor = hoverOverlayColor
        self.cornerRadius = cornerRadius
        self.pressScale = pressScale
    }

    package func makeBody(configuration: Configuration) -> some View {
        InteractiveSurfaceButtonBody(
            configuration: configuration,
            hoverOverlayColor: hoverOverlayColor,
            cornerRadius: cornerRadius,
            pressScale: pressScale
        )
    }

    private struct InteractiveSurfaceButtonBody: View {
        let configuration: Configuration
        let hoverOverlayColor: Color?
        let cornerRadius: CGFloat
        let pressScale: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background {
                    if isHovered, isEnabled, let hoverOverlayColor {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(hoverOverlayColor)
                    }
                }
                .opacity(configuration.isPressed ? 0.78 : 1.0)
                .scaleEffect(configuration.isPressed ? pressScale : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                #if os(macOS)
                .onHover { hovering in
                    isHovered = hovering
                }
                #endif
        }
    }
}

package struct SubtleStatusBanner: View {
    package let message: String
    package let isError: Bool
    package let busyLabel: String?
    package let palette: CloudTunePalette
    package let onDismiss: (() -> Void)?

    package init(
        message: String,
        isError: Bool = false,
        busyLabel: String? = nil,
        palette: CloudTunePalette,
        onDismiss: (() -> Void)? = nil
    ) {
        self.message = message
        self.isError = isError
        self.busyLabel = busyLabel
        self.palette = palette
        self.onDismiss = onDismiss
    }

    package var body: some View {
        let tint = isError ? palette.destructive : palette.accent
        HStack(spacing: 8) {
            if busyLabel != nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(busyLabel ?? message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(palette.inkPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.inkTertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: palette.rowHoverSurface, cornerRadius: 6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isError ? palette.destructive.opacity(palette.isDark ? 0.16 : 0.09) : palette.noticeBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isError ? palette.destructive.opacity(0.32) : palette.rowActiveBorder.opacity(0.45), lineWidth: 1)
        )
    }
}

package struct ArtworkView: View {
    package let artworkData: Data?
    package let seedText: String
    package let size: CGFloat
    package let cornerRadius: CGFloat
    package let palette: CloudTunePalette

    package init(
        artworkData: Data?,
        seedText: String,
        size: CGFloat,
        cornerRadius: CGFloat = 10,
        palette: CloudTunePalette
    ) {
        self.artworkData = artworkData
        self.seedText = seedText
        self.size = size
        self.cornerRadius = cornerRadius
        self.palette = palette
    }

    private var mineralTones: (Color, Color) {
        var hash: UInt64 = 1469598103934665603
        for byte in seedText.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        let bucket = Int(hash % 4)
        if palette.isDark {
            switch bucket {
            case 0: return (Color(red: 0.16, green: 0.27, blue: 0.24), Color(red: 0.12, green: 0.18, blue: 0.19))
            case 1: return (Color(red: 0.18, green: 0.23, blue: 0.28), Color(red: 0.12, green: 0.15, blue: 0.20))
            case 2: return (Color(red: 0.22, green: 0.24, blue: 0.22), Color(red: 0.14, green: 0.16, blue: 0.16))
            default: return (Color(red: 0.19, green: 0.26, blue: 0.25), Color(red: 0.13, green: 0.17, blue: 0.18))
            }
        } else {
            switch bucket {
            case 0: return (Color(red: 0.86, green: 0.92, blue: 0.90), Color(red: 0.80, green: 0.88, blue: 0.86))
            case 1: return (Color(red: 0.87, green: 0.90, blue: 0.94), Color(red: 0.82, green: 0.86, blue: 0.91))
            case 2: return (Color(red: 0.90, green: 0.91, blue: 0.89), Color(red: 0.84, green: 0.86, blue: 0.84))
            default: return (Color(red: 0.85, green: 0.91, blue: 0.90), Color(red: 0.79, green: 0.86, blue: 0.85))
            }
        }
    }

    package var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if let artworkData, let decoded = decodePlatformImage(artworkData) {
            decoded
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(shape)
                .overlay(shape.strokeBorder(palette.separator, lineWidth: 0.5))
        } else {
            let tones = mineralTones
            ZStack {
                LinearGradient(colors: [tones.0, tones.1], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .strokeBorder(palette.accent.opacity(palette.isDark ? 0.28 : 0.22), lineWidth: max(1, size * 0.03))
                    .frame(width: size * 0.64, height: size * 0.64)
                Circle()
                    .strokeBorder(palette.accent.opacity(palette.isDark ? 0.18 : 0.14), lineWidth: 1)
                    .frame(width: size * 0.40, height: size * 0.40)
                Image(systemName: "waveform")
                    .font(.system(size: max(12, size * 0.28), weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(palette.separator, lineWidth: 0.5))
        }
    }
}

package struct LosslessBadge: View {
    package let track: TrackSummary
    package let palette: CloudTunePalette

    package init(track: TrackSummary, palette: CloudTunePalette) {
        self.track = track
        self.palette = palette
    }

    package var body: some View {
        if track.isLosslessAudio {
            let label = track.fileExtensionUpper
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(palette.accentSoft)
                )
        }
    }
}

package struct InteractiveScrubSlider: View {
    package let value: Double
    package let total: Double
    package let palette: CloudTunePalette
    package let touchHeight: CGFloat
    package let onPreviewChange: ((Double?) -> Void)?
    package let onSeek: (Double) -> Void

    @State private var dragFraction: Double?
    @GestureState private var isGestureActive: Bool = false

    #if os(iOS)
    package static let defaultTouchHeight: CGFloat = 32
    #else
    package static let defaultTouchHeight: CGFloat = 20
    #endif

    package init(
        value: Double,
        total: Double,
        palette: CloudTunePalette,
        touchHeight: CGFloat = Self.defaultTouchHeight,
        onPreviewChange: ((Double?) -> Void)? = nil,
        onSeek: @escaping (Double) -> Void
    ) {
        self.value = value
        self.total = total
        self.palette = palette
        self.touchHeight = max(20, touchHeight)
        self.onPreviewChange = onPreviewChange
        self.onSeek = onSeek
    }

    private var committedFraction: Double {
        guard total > 0, value.isFinite, total.isFinite else { return 0 }
        return min(1.0, max(0.0, value / total))
    }

    private var activeFraction: Double {
        dragFraction ?? committedFraction
    }

    package var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let isDragging = dragFraction != nil
            let barHeight: CGFloat = isDragging ? 6 : 4
            let thumbSize: CGFloat = isDragging ? 13 : 10
            let fillWidth = width * CGFloat(activeFraction)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.inkPrimary.opacity(palette.isDark ? 0.14 : 0.10))
                    .frame(height: barHeight)
                Capsule()
                    .fill(palette.accent)
                    .frame(width: max(barHeight, fillWidth), height: barHeight)
                if total > 0 {
                    Circle()
                        .fill(palette.accent)
                        .frame(width: thumbSize, height: thumbSize)
                        .overlay(Circle().strokeBorder(palette.surfacePrimary, lineWidth: 1.5))
                        .offset(x: min(max(0, fillWidth - thumbSize / 2), max(0, width - thumbSize)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isGestureActive) { _, state, _ in
                        state = true
                    }
                    .onChanged { gesture in
                        guard total > 0 else { return }
                        let pct = min(1.0, max(0.0, Double(gesture.location.x / width)))
                        dragFraction = pct
                        onPreviewChange?(pct * total)
                    }
                    .onEnded { gesture in
                        guard total > 0 else {
                            dragFraction = nil
                            onPreviewChange?(nil)
                            return
                        }
                        let pct = min(1.0, max(0.0, Double(gesture.location.x / width)))
                        let targetSeconds = pct * total
                        onSeek(targetSeconds)
                        dragFraction = nil
                    }
            )
            .onChange(of: isGestureActive) { _, active in
                if !active, dragFraction != nil {
                    dragFraction = nil
                    onPreviewChange?(nil)
                }
            }
        }
        .frame(height: touchHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(CloudTuneFormatters.formatClock(activeFraction * max(0, total))) / \(CloudTuneFormatters.formatClock(total))")
        .accessibilityAdjustableAction { direction in
            guard total > 0 else { return }
            let step = max(5.0, total * 0.05)
            switch direction {
            case .increment:
                onSeek(min(total, value + step))
            case .decrement:
                onSeek(max(0, value - step))
            @unknown default:
                break
            }
        }
    }
}

package enum ScrubberLayoutStyle: Sendable {
    case macHorizontal
    case iosStacked(fontSize: CGFloat)
}

/// Isolated leaf scrubber view observing ONLY `PlaybackTimeline` (`currentTime` & `duration`),
/// holding `scrubPreviewSeconds` across in-flight `seekPlayback` calls to prevent release bounce-back flicker.
package struct NowPlayingScrubberView: View {
    package let timeline: PlaybackTimeline
    package let palette: CloudTunePalette
    package let layout: ScrubberLayoutStyle
    package let onSeek: @MainActor (Double) async -> Void

    @State private var scrubPreviewSeconds: Double?
    @State private var inFlightSeekToken: UInt64 = 0

    package init(
        timeline: PlaybackTimeline,
        palette: CloudTunePalette,
        layout: ScrubberLayoutStyle,
        onSeek: @escaping @MainActor (Double) async -> Void
    ) {
        self.timeline = timeline
        self.palette = palette
        self.layout = layout
        self.onSeek = onSeek
    }

    private var displayedSeconds: Double {
        scrubPreviewSeconds ?? timeline.currentTime
    }

    private func commitSeek(_ targetSeconds: Double) {
        scrubPreviewSeconds = targetSeconds
        inFlightSeekToken &+= 1
        let token = inFlightSeekToken
        Task { @MainActor in
            await onSeek(targetSeconds)
            if inFlightSeekToken == token {
                scrubPreviewSeconds = nil
            }
        }
    }

    package var body: some View {
        switch layout {
        case .macHorizontal:
            HStack(spacing: 8) {
                Text(CloudTuneFormatters.formatClock(displayedSeconds))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.inkTertiary)
                    .frame(width: 40, alignment: .trailing)

                InteractiveScrubSlider(
                    value: displayedSeconds,
                    total: timeline.duration,
                    palette: palette,
                    touchHeight: 20,
                    onPreviewChange: { preview in
                        if let preview {
                            scrubPreviewSeconds = preview
                        } else if inFlightSeekToken == 0 {
                            scrubPreviewSeconds = nil
                        }
                    },
                    onSeek: commitSeek
                )

                Text(CloudTuneFormatters.formatClock(timeline.duration))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.inkTertiary)
                    .frame(width: 40, alignment: .leading)
            }

        case let .iosStacked(fontSize):
            VStack(spacing: 2) {
                InteractiveScrubSlider(
                    value: displayedSeconds,
                    total: timeline.duration,
                    palette: palette,
                    touchHeight: 32,
                    onPreviewChange: { preview in
                        if let preview {
                            scrubPreviewSeconds = preview
                        } else if inFlightSeekToken == 0 {
                            scrubPreviewSeconds = nil
                        }
                    },
                    onSeek: commitSeek
                )
                HStack {
                    Text(CloudTuneFormatters.formatClock(displayedSeconds))
                    Spacer()
                    Text(CloudTuneFormatters.formatClock(timeline.duration))
                }
                .font(.system(size: fontSize).monospacedDigit())
                .foregroundStyle(palette.inkTertiary)
            }
        }
    }
}

package struct PrimaryActionButton: View {
    package let title: String
    package let systemImage: String?
    package let palette: CloudTunePalette
    package let minWidth: CGFloat?
    package let isDisabled: Bool
    package let action: () -> Void

    package init(
        _ title: String,
        systemImage: String? = nil,
        palette: CloudTunePalette,
        minWidth: CGFloat? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.palette = palette
        self.minWidth = minWidth
        self.isDisabled = isDisabled
        self.action = action
    }

    package var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(palette.primaryForeground)
            .frame(minWidth: minWidth)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(palette.primaryGradient)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: Color.white.opacity(0.08), cornerRadius: 13))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1.0)
    }
}

package struct SecondaryActionButton: View {
    package let title: String
    package let systemImage: String?
    package let palette: CloudTunePalette
    package let isDisabled: Bool
    package let action: () -> Void

    package init(
        _ title: String,
        systemImage: String? = nil,
        palette: CloudTunePalette,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.palette = palette
        self.isDisabled = isDisabled
        self.action = action
    }

    package var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(palette.inkPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.rowSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.accentBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: palette.rowHoverSurface, cornerRadius: 12))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}

package struct ToggleChipButton: View {
    package let title: String
    package let systemImage: String?
    package let isActive: Bool
    package let palette: CloudTunePalette
    package let action: () -> Void

    package init(
        _ title: String,
        systemImage: String? = nil,
        isActive: Bool,
        palette: CloudTunePalette,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isActive = isActive
        self.palette = palette
        self.action = action
    }

    package var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? palette.primaryForeground : palette.inkPrimary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isActive ? AnyShapeStyle(palette.primaryGradient) : AnyShapeStyle(palette.rowSurface))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isActive ? Color.clear : palette.accentBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: palette.rowHoverSurface, cornerRadius: 16))
    }
}

package struct TrackRowButton<TrailingAccessory: View>: View {
    package let track: TrackSummary
    package let isActive: Bool
    package let actionLabel: String
    package let palette: CloudTunePalette
    package let action: () -> Void
    private let hasTrailingAccessory: Bool
    private let trailingAccessory: TrailingAccessory

    package init(
        track: TrackSummary,
        isActive: Bool = false,
        actionLabel: String,
        palette: CloudTunePalette,
        action: @escaping () -> Void
    ) where TrailingAccessory == EmptyView {
        self.track = track
        self.isActive = isActive
        self.actionLabel = actionLabel
        self.palette = palette
        self.action = action
        self.hasTrailingAccessory = false
        self.trailingAccessory = EmptyView()
    }

    package init(
        track: TrackSummary,
        isActive: Bool = false,
        actionLabel: String,
        palette: CloudTunePalette,
        action: @escaping () -> Void,
        @ViewBuilder trailingAccessory: () -> TrailingAccessory
    ) {
        self.track = track
        self.isActive = isActive
        self.actionLabel = actionLabel
        self.palette = palette
        self.action = action
        self.hasTrailingAccessory = true
        self.trailingAccessory = trailingAccessory()
    }

    package var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.inkPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(track.folderPath)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.inkTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(CloudTuneFormatters.formatBytes(track.sizeBytes))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(palette.inkTertiary)
                        Text(actionLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isActive ? palette.accent : palette.inkSecondary)
                    }
                }
                .padding(.leading, 13)
                .padding(.trailing, hasTrailingAccessory ? 8 : 13)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: palette.rowHoverSurface, cornerRadius: 13, pressScale: 0.992))

            if hasTrailingAccessory {
                trailingAccessory
                    .padding(.trailing, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isActive ? palette.rowActiveSurface : palette.rowSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(isActive ? palette.rowActiveBorder : palette.cardBorder, lineWidth: 1)
        )
    }
}

package struct FolderRowButton: View {
    package let folder: RemoteFolder
    package let palette: CloudTunePalette
    package let action: () -> Void

    package init(folder: RemoteFolder, palette: CloudTunePalette, action: @escaping () -> Void) {
        self.folder = folder
        self.palette = palette
        self.action = action
    }

    package var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.accent)
                Text(folder.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text("打开")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.inkTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.rowSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(InteractiveSurfaceButtonStyle(hoverOverlayColor: palette.rowHoverSurface, cornerRadius: 12, pressScale: 0.99))
    }
}

package struct TransferRowCardView: View {
    package let item: TransferStatus
    package let palette: CloudTunePalette
    package let onPause: () -> Void
    package let onResume: () -> Void
    package let onDelete: () -> Void

    package init(
        item: TransferStatus,
        palette: CloudTunePalette,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.item = item
        self.palette = palette
        self.onPause = onPause
        self.onResume = onResume
        self.onDelete = onDelete
    }

    package var body: some View {
        let pct = CloudTuneFormatters.formatPercent(transferred: item.transferredBytes, total: item.totalBytes)
        let stateSummary: String = {
            if let path = item.path, !path.isEmpty {
                return "\(item.localizedStateLabel) · \(path)"
            }
            return item.localizedStateLabel
        }()
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.label)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(palette.inkPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(stateSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let pct {
                        progressBar(pct: pct)
                    }
                }
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text("\(CloudTuneFormatters.formatBytes(item.bytesPerSecond))/s")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(palette.inkTertiary)
                        .lineLimit(1)
                    if let pct {
                        Text(String(format: "%.1f%%", pct))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(palette.inkSecondary)
                            .lineLimit(1)
                    }
                    actionButtons
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(item.label)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(palette.inkPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(CloudTuneFormatters.formatBytes(item.bytesPerSecond))/s")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(palette.inkTertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if let pct {
                    progressBar(pct: pct)
                }
                HStack(spacing: 8) {
                    Text(pct != nil ? "\(stateSummary) · \(String(format: "%.1f%%", pct!))" : stateSummary)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(palette.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    HStack(spacing: 6) {
                        actionButtons
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(palette.rowSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func progressBar(pct: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.inkPrimary.opacity(0.09))
                Capsule()
                    .fill(palette.accent)
                    .frame(width: max(4, geo.size.width * CGFloat(pct / 100.0)))
            }
        }
        .frame(height: 6)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if item.canPause {
            SecondaryActionButton("暂停", palette: palette, action: onPause)
        }
        if item.canResume {
            SecondaryActionButton("继续", palette: palette, action: onResume)
        }
        if item.canDelete {
            SecondaryActionButton("删除", palette: palette, action: onDelete)
        }
    }
}

package struct QrCodeArtworkView: View {
    package let pngData: Data?
    package let hint: String?
    package let host: String?
    package let palette: CloudTunePalette

    package init(pngData: Data?, hint: String?, host: String?, palette: CloudTunePalette) {
        self.pngData = pngData
        self.hint = hint
        self.host = host
        self.palette = palette
    }

    package var body: some View {
        if let pngData, let image = decodePlatformImage(pngData) {
            VStack(spacing: 10) {
                image
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(palette.qrSubstrate)
                    )
                Text("打开天翼云盘 App 扫码")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(palette.inkPrimary)
                if let hint {
                    Text(hint)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.inkTertiary)
                        .multilineTextAlignment(.center)
                }
                if let host {
                    Text(host)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(palette.inkTertiary)
                }
            }
            .padding(18)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(palette.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )
        } else {
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(palette.qrSubstrate)
                    .frame(width: 220, height: 220)
                    .overlay(
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 56, weight: .light))
                            .foregroundStyle(palette.qrForeground.opacity(0.65))
                    )
                Text("二维码会显示在这里")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.inkTertiary)
            }
            .padding(18)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(palette.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.cardBorder, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            )
        }
    }
}

#if os(macOS)
package struct AirPlayRoutePicker: NSViewRepresentable {
    package init() {}

    package func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        picker.isRoutePickerButtonBordered = false
        return picker
    }

    package func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}

    package func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVRoutePickerView, context: Context) -> CGSize? {
        CGSize(width: 28, height: 28)
    }
}

package enum MacMenuEntry {
    case item(
        title: String,
        systemImage: String? = nil,
        isChecked: Bool = false,
        isEnabled: Bool = true,
        action: @MainActor () -> Void
    )
    case separator
}

/// Native AppKit `NSView` + `NSMenu.popUp` trigger with full rectangular hit area (never uses SwiftUI `Menu`).
package struct MacPopUpMenuButton: NSViewRepresentable {
    package let systemImage: String
    package let accessibilityTitle: String
    package let entries: () -> [MacMenuEntry]

    package init(
        systemImage: String,
        accessibilityTitle: String,
        entries: @escaping () -> [MacMenuEntry]
    ) {
        self.systemImage = systemImage
        self.accessibilityTitle = accessibilityTitle
        self.entries = entries
    }

    package func makeCoordinator() -> Coordinator {
        Coordinator(entries: entries)
    }

    package func makeNSView(context: Context) -> PopUpTriggerNSView {
        let view = PopUpTriggerNSView()
        view.configure(systemImage: systemImage, accessibilityTitle: accessibilityTitle)
        view.onTrigger = { [weak coordinator = context.coordinator] anchor in
            coordinator?.presentMenu(from: anchor)
        }
        return view
    }

    package func updateNSView(_ nsView: PopUpTriggerNSView, context: Context) {
        context.coordinator.entries = entries
        nsView.configure(systemImage: systemImage, accessibilityTitle: accessibilityTitle)
    }

    package func sizeThatFits(_ proposal: ProposedViewSize, nsView: PopUpTriggerNSView, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(width: intrinsic.width, height: intrinsic.height)
    }

    @MainActor
    package final class Coordinator: NSObject {
        var entries: () -> [MacMenuEntry]
        private var handlers: [Int: @MainActor () -> Void] = [:]

        init(entries: @escaping () -> [MacMenuEntry]) {
            self.entries = entries
        }

        func presentMenu(from view: PopUpTriggerNSView) {
            handlers.removeAll()
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.appearance = view.effectiveAppearance
            var nextTag = 1
            for entry in entries() {
                switch entry {
                case .separator:
                    menu.addItem(.separator())
                case let .item(title, systemImage, isChecked, isEnabled, action):
                    let item = NSMenuItem(title: title, action: #selector(handleMenuItem(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = nextTag
                    item.isEnabled = isEnabled
                    item.state = isChecked ? .on : .off
                    if let systemImage, let img = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) {
                        item.image = img
                    }
                    handlers[nextTag] = action
                    nextTag += 1
                    menu.addItem(item)
                }
            }
            // `PopUpTriggerNSView.isFlipped == true`: y = bounds.height + 4 anchors 4pt BELOW the button's bottom edge.
            let anchorPoint = view.menuPopUpAnchorPoint
            _ = menu.popUp(positioning: nil, at: anchorPoint, in: view)
            view.resetInteractionState()
        }

        @objc private func handleMenuItem(_ sender: NSMenuItem) {
            handlers[sender.tag]?()
        }
    }

    package final class PopUpTriggerNSView: NSView {
        package var onTrigger: ((PopUpTriggerNSView) -> Void)?
        private var symbolName: String = "ellipsis.circle"
        package private(set) var isHovered = false {
            didSet {
                if oldValue != isHovered {
                    needsDisplay = true
                }
            }
        }
        private var isPressed = false {
            didSet {
                if oldValue != isPressed {
                    needsDisplay = true
                }
            }
        }
        private var trackingRef: NSTrackingArea?

        override package var isFlipped: Bool {
            true
        }

        package var menuPopUpAnchorPoint: NSPoint {
            NSPoint(x: 0, y: bounds.height + 4)
        }

        override package var intrinsicContentSize: NSSize {
            NSSize(width: 28, height: 28)
        }

        package func configure(systemImage: String, accessibilityTitle: String) {
            self.symbolName = systemImage
            setAccessibilityElement(true)
            setAccessibilityLabel(accessibilityTitle)
            setAccessibilityRole(.popUpButton)
            needsDisplay = true
        }

        package func resetInteractionState() {
            isPressed = false
            isHovered = false
        }

        override package func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingRef {
                removeTrackingArea(trackingRef)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingRef = area
        }

        override package func mouseEntered(with event: NSEvent) {
            isHovered = true
        }

        override package func mouseExited(with event: NSEvent) {
            resetInteractionState()
        }

        override package func mouseDown(with event: NSEvent) {
            isPressed = true
            onTrigger?(self)
            resetInteractionState()
        }

        override package func accessibilityPerformPress() -> Bool {
            onTrigger?(self)
            resetInteractionState()
            return true
        }

        override package func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if isPressed || isHovered {
                let radius = min(bounds.width, bounds.height) * 0.25
                let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
                NSColor.labelColor.withAlphaComponent(isPressed ? 0.14 : 0.08).setFill()
                path.fill()
            }
            let cfg = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.secondaryLabelColor]))
            guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else {
                return
            }
            symbol.isTemplate = false
            let sSize = symbol.size
            let iconRect = NSRect(
                x: (bounds.width - sSize.width) / 2.0,
                y: (bounds.height - sSize.height) / 2.0,
                width: sSize.width,
                height: sSize.height
            )
            symbol.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        }
    }
}
#elseif os(iOS)
package struct AirPlayRoutePicker: UIViewRepresentable {
    package let tint: UIColor

    package init(tint: UIColor = .label) {
        self.tint = tint
    }

    package func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
        picker.prioritizesVideoDevices = false
        picker.tintColor = tint
        picker.activeTintColor = tint
        return picker
    }

    package func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tint
        uiView.activeTintColor = tint
    }
}
#endif
