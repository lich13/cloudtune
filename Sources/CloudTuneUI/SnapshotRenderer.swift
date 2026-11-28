import CloudTuneCore
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
#if os(iOS)
import UIKit
#endif

public struct SnapshotPixelMetrics: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let meanLuminance: Double
    public let luminanceStdDev: Double
    public let highContrastPixelCount: Int

    public var isNonBlankAndLegible: Bool {
        width >= 300 && height >= 500 && luminanceStdDev > 0.035 && highContrastPixelCount > 1200
    }
}

public enum SnapshotRenderer {
    public static func analyzePNGData(_ pngData: Data) throws -> SnapshotPixelMetrics {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CloudTuneError.storageError("无法解码快照 PNG")
        }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CloudTuneError.storageError("无法创建像素分析上下文")
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sampleCount = 0
        var sum = 0.0
        var sumSq = 0.0
        var edgeCount = 0

        pixels.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var y = 0
            while y < height {
                let rowOffset = y * bytesPerRow
                var prevLum = -1.0
                var x = 0
                while x < width {
                    let idx = rowOffset + (x << 2)
                    let r = Double(base[idx]) * (1.0 / 255.0)
                    let g = Double(base[idx + 1]) * (1.0 / 255.0)
                    let b = Double(base[idx + 2]) * (1.0 / 255.0)
                    let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    sampleCount += 1
                    sum += lum
                    sumSq += lum * lum
                    if prevLum >= 0, abs(lum - prevLum) >= 0.22 {
                        edgeCount += 1
                    }
                    prevLum = lum
                    x += 4
                }
                y += 4
            }
        }

        let denom = Double(max(1, sampleCount))
        let mean = sum / denom
        let variance = max(0, (sumSq / denom) - (mean * mean))
        return SnapshotPixelMetrics(
            width: width,
            height: height,
            meanLuminance: mean,
            luminanceStdDev: sqrt(variance),
            highContrastPixelCount: edgeCount * 16
        )
    }

    #if os(macOS)
    @MainActor
    public static func renderMacScenePNG(
        scene: SnapshotScene,
        fixture: RepresentativeFixture,
        isDark: Bool,
        size: CGSize = CGSize(width: 1460, height: 930)
    ) throws -> Data {
        let vm = CloudTuneViewModel.fixture(scene: scene, fixture: fixture)
        vm.appearancePreference = isDark ? .dark : .light
        let rootView = MacWorkspaceView(viewModel: vm)
            .environment(\.colorScheme, isDark ? .dark : .light)
            .frame(width: size.width, height: size.height)

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CloudTuneError.storageError("无法创建 macOS 离屏位图")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CloudTuneError.storageError("无法编码 macOS PNG")
        }
        return png
    }
    #elseif os(iOS)
    @MainActor
    public static func renderIOSScenePNG(
        scene: SnapshotScene,
        fixture: RepresentativeFixture,
        isDark: Bool,
        isIPad: Bool
    ) throws -> Data {
        let size = isIPad ? CGSize(width: 1194, height: 834) : CGSize(width: 393, height: 852)
        let palette = CloudTunePalette(isDark: isDark)
        IOSTabBarAppearanceHelper.applyGlobalDefaults(palette: palette)

        let vm = CloudTuneViewModel.fixture(scene: scene, fixture: fixture)
        vm.appearancePreference = isDark ? .dark : .light
        let rootView = IOSRootView(viewModel: vm)
            .environment(\.colorScheme, isDark ? .dark : .light)
            .environment(\.horizontalSizeClass, isIPad ? .regular : .compact)

        let controller = UIHostingController(rootView: rootView)
        controller.overrideUserInterfaceStyle = isDark ? .dark : .light
        controller.traitOverrides.horizontalSizeClass = isIPad ? .regular : .compact

        let window: UIWindow
        if let activeScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: activeScene)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = isDark ? .dark : .light
        window.traitOverrides.horizontalSizeClass = isIPad ? .regular : .compact
        window.rootViewController = controller
        window.isHidden = false
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        window.setNeedsLayout()
        window.layoutIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        IOSTabBarAppearanceHelper.applyRecursively(in: controller, view: window, palette: palette)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        window.setNeedsLayout()
        window.layoutIfNeeded()
        IOSTabBarAppearanceHelper.applyRecursively(in: controller, view: window, palette: palette)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            window.layer.render(in: ctx.cgContext)
        }
        window.isHidden = true
        window.rootViewController = nil
        guard let png = image.pngData() else {
            throw CloudTuneError.storageError("无法编码 iOS PNG")
        }
        return png
    }
    #endif
}
