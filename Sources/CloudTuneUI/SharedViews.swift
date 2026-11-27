import CloudTuneCore
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public struct CloudTuneBackground: View {
    public let palette: CloudTunePalette

    public init(palette: CloudTunePalette) {
        self.palette = palette
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [palette.bgTop, palette.bgBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [palette.warmGlow, .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 420
            )
            RadialGradient(
                colors: [palette.pineGlow, .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
    }
}

public struct GlassCard<Content: View>: View {
    public let palette: CloudTunePalette
    public let padding: CGFloat
    @ViewBuilder public let content: () -> Content

    public init(palette: CloudTunePalette, padding: CGFloat = 15, @ViewBuilder content: @escaping () -> Content) {
        self.palette = palette
        self.padding = padding
        self.content = content
    }

    public var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(palette.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(palette.isDark ? 0.28 : 0.08), radius: 18, x: 0, y: 8)
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

public struct MetricTile: View {
    public let label: String
    public let value: String
    public let isMonospacedDigits: Bool
    public let palette: CloudTunePalette

    public init(label: String, value: String, isMonospacedDigits: Bool = true, palette: CloudTunePalette) {
        self.label = label
        self.value = value
        self.isMonospacedDigits = isMonospacedDigits
        self.palette = palette
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.inkTertiary)
                .lineLimit(1)
            Text(value)
                .font(isMonospacedDigits ? .system(size: 14, weight: .bold).monospacedDigit() : .system(size: 14, weight: .bold))
                .foregroundStyle(palette.inkPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minWidth: 96, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(palette.cardStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(palette.accentBorder, lineWidth: 1)
        )
    }
}

public struct WarmProgressSlider: View {
    public let value: Double
    public let total: Double
    public let palette: CloudTunePalette
    public let onSeek: (Double) -> Void

    public init(value: Double, total: Double, palette: CloudTunePalette, onSeek: @escaping (Double) -> Void) {
        self.value = value
        self.total = total
        self.palette = palette
        self.onSeek = onSeek
    }

    private var ratio: CGFloat {
        guard total > 0, value.isFinite, total.isFinite else { return 0 }
        return CGFloat(min(1.0, max(0.0, value / total)))
    }

    public var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let fillWidth = width * ratio
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.inkPrimary.opacity(0.10))
                    .frame(height: 6)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [palette.onlineStart, palette.warmGold],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(6, fillWidth), height: 6)
                Circle()
                    .fill(palette.warmGold)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .offset(x: min(max(0, fillWidth - 7), max(0, width - 14)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { gesture in
                        guard total > 0 else { return }
                        let pct = min(1.0, max(0.0, Double(gesture.location.x / width)))
                        onSeek(pct * total)
                    }
            )
        }
        .frame(height: 18)
    }
}

public struct TrackRowButton: View {
    public let track: TrackSummary
    public let isActive: Bool
    public let actionLabel: String
    public let palette: CloudTunePalette
    public let action: () -> Void

    public init(
        track: TrackSummary,
        isActive: Bool = false,
        actionLabel: String,
        palette: CloudTunePalette,
        action: @escaping () -> Void
    ) {
        self.track = track
        self.isActive = isActive
        self.actionLabel = actionLabel
        self.palette = palette
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(.system(size: 14, weight: .bold))
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
                        .foregroundStyle(isActive ? palette.onlineEnd : palette.inkSecondary)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isActive ? palette.rowActiveSurface : palette.rowSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(isActive ? palette.rowActiveBorder : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    .foregroundStyle(palette.warmGold)
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.label)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(palette.inkPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.state)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.inkTertiary)
                        .lineLimit(1)
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
                    Text(pct != nil ? "\(item.state) · \(String(format: "%.1f%%", pct!))" : item.state)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(palette.inkSecondary)
                        .lineLimit(1)
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
    }

    @ViewBuilder
    private func progressBar(pct: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.inkPrimary.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(colors: [palette.onlineStart, palette.warmGold], startPoint: .leading, endPoint: .trailing))
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
                    .fill(palette.cardStrong)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.accentBorder, lineWidth: 1)
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
                    .fill(palette.cardStrong.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.accentBorder, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
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
