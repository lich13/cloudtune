import AVKit
import CloudTuneCore
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public struct SubtleStatusBanner: View {
    public let message: String
    public let isError: Bool
    public let busyLabel: String?
    public let palette: CloudTunePalette
    public let onDismiss: (() -> Void)?

    public init(
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

    public var body: some View {
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
                .buttonStyle(.plain)
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

public struct ArtworkView: View {
    public let artworkData: Data?
    public let seedText: String
    public let size: CGFloat
    public let cornerRadius: CGFloat
    public let palette: CloudTunePalette

    public init(
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

    public var body: some View {
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

    private func decodePlatformImage(_ data: Data) -> Image? {
        #if os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #elseif os(iOS)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #else
        return nil
        #endif
    }
}

public struct LosslessBadge: View {
    public let track: TrackSummary
    public let palette: CloudTunePalette

    public init(track: TrackSummary, palette: CloudTunePalette) {
        self.track = track
        self.palette = palette
    }

    public var body: some View {
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

public struct InteractiveScrubSlider: View {
    public let value: Double
    public let total: Double
    public let palette: CloudTunePalette
    public let onPreviewChange: ((Double?) -> Void)?
    public let onSeek: (Double) -> Void

    @State private var dragFraction: Double?

    public init(
        value: Double,
        total: Double,
        palette: CloudTunePalette,
        onPreviewChange: ((Double?) -> Void)? = nil,
        onSeek: @escaping (Double) -> Void
    ) {
        self.value = value
        self.total = total
        self.palette = palette
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

    public var body: some View {
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
                        dragFraction = nil
                        onPreviewChange?(nil)
                        onSeek(pct * total)
                    }
            )
        }
        .frame(height: 20)
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

public struct PrimaryActionButton: View {
    public let title: String
    public let systemImage: String?
    public let palette: CloudTunePalette
    public let minWidth: CGFloat?
    public let isDisabled: Bool
    public let action: () -> Void

    public init(
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

    public var body: some View {
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
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1.0)
    }
}

public struct SecondaryActionButton: View {
    public let title: String
    public let systemImage: String?
    public let palette: CloudTunePalette
    public let isDisabled: Bool
    public let action: () -> Void

    public init(
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

    public var body: some View {
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
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}

public struct ToggleChipButton: View {
    public let title: String
    public let systemImage: String?
    public let isActive: Bool
    public let palette: CloudTunePalette
    public let action: () -> Void

    public init(
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

    public var body: some View {
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
        .buttonStyle(.plain)
    }
}

public struct TrackRowButton<TrailingAccessory: View>: View {
    public let track: TrackSummary
    public let isActive: Bool
    public let actionLabel: String
    public let palette: CloudTunePalette
    public let action: () -> Void
    private let hasTrailingAccessory: Bool
    private let trailingAccessory: TrailingAccessory

    public init(
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

    public init(
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

    public var body: some View {
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
            .buttonStyle(.plain)

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

public struct FolderRowButton: View {
    public let folder: RemoteFolder
    public let palette: CloudTunePalette
    public let action: () -> Void

    public init(folder: RemoteFolder, palette: CloudTunePalette, action: @escaping () -> Void) {
        self.folder = folder
        self.palette = palette
        self.action = action
    }

    public var body: some View {
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
        .buttonStyle(.plain)
    }
}

public struct TransferRowCardView: View {
    public let item: TransferStatus
    public let palette: CloudTunePalette
    public let onPause: () -> Void
    public let onResume: () -> Void
    public let onDelete: () -> Void

    public init(
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

    public var body: some View {
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

public struct QrCodeArtworkView: View {
    public let pngData: Data?
    public let hint: String?
    public let host: String?
    public let palette: CloudTunePalette

    public init(pngData: Data?, hint: String?, host: String?, palette: CloudTunePalette) {
        self.pngData = pngData
        self.hint = hint
        self.host = host
        self.palette = palette
    }

    public var body: some View {
        if let pngData, let image = platformImage(from: pngData) {
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

    private func platformImage(from data: Data) -> Image? {
        #if os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #elseif os(iOS)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #else
        return nil
        #endif
    }
}

#if os(macOS)
public struct AirPlayRoutePicker: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        picker.isRoutePickerButtonBordered = false
        return picker
    }

    public func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVRoutePickerView, context: Context) -> CGSize? {
        CGSize(width: 28, height: 28)
    }
}

public enum MacMenuEntry {
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
public struct MacPopUpMenuButton: NSViewRepresentable {
    public let title: String?
    public let systemImage: String
    public let accessibilityTitle: String
    public let entries: () -> [MacMenuEntry]

    public init(
        title: String? = nil,
        systemImage: String,
        accessibilityTitle: String,
        entries: @escaping () -> [MacMenuEntry]
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessibilityTitle = accessibilityTitle
        self.entries = entries
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(entries: entries)
    }

    public func makeNSView(context: Context) -> PopUpTriggerNSView {
        let view = PopUpTriggerNSView()
        view.configure(title: title, systemImage: systemImage, accessibilityTitle: accessibilityTitle)
        view.onTrigger = { [weak coordinator = context.coordinator] anchor in
            coordinator?.presentMenu(from: anchor)
        }
        return view
    }

    public func updateNSView(_ nsView: PopUpTriggerNSView, context: Context) {
        context.coordinator.entries = entries
        nsView.configure(title: title, systemImage: systemImage, accessibilityTitle: accessibilityTitle)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: PopUpTriggerNSView, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(width: intrinsic.width, height: intrinsic.height)
    }

    @MainActor
    public final class Coordinator: NSObject {
        var entries: () -> [MacMenuEntry]
        private var handlers: [Int: @MainActor () -> Void] = [:]

        init(entries: @escaping () -> [MacMenuEntry]) {
            self.entries = entries
        }

        func presentMenu(from view: NSView) {
            handlers.removeAll()
            let menu = NSMenu()
            menu.autoenablesItems = false
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
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }

        @objc private func handleMenuItem(_ sender: NSMenuItem) {
            handlers[sender.tag]?()
        }
    }

    public final class PopUpTriggerNSView: NSView {
        var onTrigger: ((NSView) -> Void)?
        private var titleText: String?
        private var symbolName: String = "ellipsis.circle"
        private var isHovered = false {
            didSet { needsDisplay = true }
        }
        private var trackingRef: NSTrackingArea?

        override public var intrinsicContentSize: NSSize {
            if let titleText, !titleText.isEmpty {
                let textWidth = (titleText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium)]).width
                return NSSize(width: ceil(textWidth) + 34, height: 28)
            }
            return NSSize(width: 28, height: 28)
        }

        func configure(title: String?, systemImage: String, accessibilityTitle: String) {
            self.titleText = title
            self.symbolName = systemImage
            setAccessibilityLabel(accessibilityTitle)
            setAccessibilityRole(.popUpButton)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }

        override public func updateTrackingAreas() {
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

        override public func mouseEntered(with event: NSEvent) {
            isHovered = true
        }

        override public func mouseExited(with event: NSEvent) {
            isHovered = false
        }

        override public func mouseDown(with event: NSEvent) {
            onTrigger?(self)
        }

        override public func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if isHovered {
                let radius = min(bounds.width, bounds.height) * 0.25
                let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                path.fill()
            }
            let tint = (titleText?.isEmpty == false) ? NSColor.labelColor : NSColor.secondaryLabelColor
            let cfg = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            symbol?.isTemplate = false

            if let titleText, !titleText.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                    .foregroundColor: NSColor.labelColor
                ]
                let textSize = (titleText as NSString).size(withAttributes: attrs)
                var cursorX: CGFloat = 8
                if let symbol {
                    let sSize = symbol.size
                    let iconRect = NSRect(
                        x: cursorX,
                        y: (bounds.height - sSize.height) / 2.0,
                        width: sSize.width,
                        height: sSize.height
                    )
                    symbol.draw(in: iconRect)
                    cursorX += sSize.width + 5
                }
                let textRect = NSRect(
                    x: cursorX,
                    y: (bounds.height - textSize.height) / 2.0,
                    width: textSize.width,
                    height: textSize.height
                )
                (titleText as NSString).draw(in: textRect, withAttributes: attrs)
            } else if let symbol {
                let sSize = symbol.size
                let iconRect = NSRect(
                    x: (bounds.width - sSize.width) / 2.0,
                    y: (bounds.height - sSize.height) / 2.0,
                    width: sSize.width,
                    height: sSize.height
                )
                symbol.draw(in: iconRect)
            }
        }
    }
}
#elseif os(iOS)
public struct AirPlayRoutePicker: UIViewRepresentable {
    public let tint: UIColor

    public init(tint: UIColor = .label) {
        self.tint = tint
    }

    public func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
        picker.prioritizesVideoDevices = false
        picker.tintColor = tint
        picker.activeTintColor = tint
        return picker
    }

    public func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tint
        uiView.activeTintColor = tint
    }
}
#endif
