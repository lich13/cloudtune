import SwiftUI

public enum AppAppearancePreference: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "暖羊皮浅色"
        case .dark: return "松林暗夜"
        }
    }

    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public struct CloudTunePalette: Sendable {
    public let isDark: Bool
    public let bgTop: Color
    public let bgBottom: Color
    public let warmGlow: Color
    public let pineGlow: Color
    public let cardSurface: Color
    public let cardStrong: Color
    public let rowSurface: Color
    public let rowActiveSurface: Color
    public let rowActiveBorder: Color
    public let inputSurface: Color
    public let cardBorder: Color
    public let accentBorder: Color
    public let inkPrimary: Color
    public let inkSecondary: Color
    public let inkTertiary: Color
    public let primaryStart: Color
    public let primaryEnd: Color
    public let primaryForeground: Color
    public let onlineStart: Color
    public let onlineEnd: Color
    public let warmGold: Color
    public let noticeBackground: Color
    public let busyBackground: Color
    public let busyForeground: Color
    // Fixed across light and dark modes so QR scanners always read dark-on-light reliably
    public let qrSubstrate: Color
    public let qrForeground: Color

    public init(isDark: Bool) {
        self.isDark = isDark
        self.qrSubstrate = Color(red: 0xF6 / 255.0, green: 0xF1 / 255.0, blue: 0xE8 / 255.0)
        self.qrForeground = Color(red: 0x13 / 255.0, green: 0x27 / 255.0, blue: 0x1F / 255.0)
        self.warmGold = Color(red: 0xE6 / 255.0, green: 0xAA / 255.0, blue: 0x5A / 255.0)

        if isDark {
            self.bgTop = Color(red: 0x0E / 255.0, green: 0x17 / 255.0, blue: 0x14 / 255.0)
            self.bgBottom = Color(red: 0x0A / 255.0, green: 0x11 / 255.0, blue: 0x0E / 255.0)
            self.warmGlow = Color(red: 0xE6 / 255.0, green: 0xAA / 255.0, blue: 0x5A / 255.0).opacity(0.14)
            self.pineGlow = Color(red: 0x2F / 255.0, green: 0x7D / 255.0, blue: 0x60 / 255.0).opacity(0.20)
            self.cardSurface = Color(red: 22.0 / 255.0, green: 36.0 / 255.0, blue: 30.0 / 255.0).opacity(0.90)
            self.cardStrong = Color(red: 28.0 / 255.0, green: 45.0 / 255.0, blue: 38.0 / 255.0)
            self.rowSurface = Color(red: 26.0 / 255.0, green: 42.0 / 255.0, blue: 35.0 / 255.0).opacity(0.86)
            self.rowActiveSurface = Color(red: 47.0 / 255.0, green: 125.0 / 255.0, blue: 96.0 / 255.0).opacity(0.26)
            self.rowActiveBorder = Color(red: 67.0 / 255.0, green: 158.0 / 255.0, blue: 124.0 / 255.0).opacity(0.55)
            self.inputSurface = Color(red: 18.0 / 255.0, green: 30.0 / 255.0, blue: 25.0 / 255.0)
            self.cardBorder = Color.white.opacity(0.10)
            self.accentBorder = Color(red: 67.0 / 255.0, green: 158.0 / 255.0, blue: 124.0 / 255.0).opacity(0.32)
            self.inkPrimary = Color(red: 0xEC / 255.0, green: 0xF5 / 255.0, blue: 0xF0 / 255.0)
            self.inkSecondary = Color(red: 0xB4 / 255.0, green: 0xC8 / 255.0, blue: 0xBD / 255.0)
            self.inkTertiary = Color(red: 0x82 / 255.0, green: 0xA3 / 255.0, blue: 0x93 / 255.0)
            self.primaryStart = Color(red: 0x22 / 255.0, green: 0x64 / 255.0, blue: 0x4C / 255.0)
            self.primaryEnd = Color(red: 0x2F / 255.0, green: 0x7D / 255.0, blue: 0x60 / 255.0)
            self.primaryForeground = Color(red: 0xF5 / 255.0, green: 0xFB / 255.0, blue: 0xF8 / 255.0)
            self.onlineStart = Color(red: 0x1F / 255.0, green: 0x66 / 255.0, blue: 0x4C / 255.0)
            self.onlineEnd = Color(red: 0x2F / 255.0, green: 0x7D / 255.0, blue: 0x60 / 255.0)
            self.noticeBackground = Color(red: 47.0 / 255.0, green: 125.0 / 255.0, blue: 96.0 / 255.0).opacity(0.20)
            self.busyBackground = Color(red: 0xE6 / 255.0, green: 0xAA / 255.0, blue: 0x5A / 255.0).opacity(0.20)
            self.busyForeground = Color(red: 0xF7 / 255.0, green: 0xCB / 255.0, blue: 0x88 / 255.0)
        } else {
            self.bgTop = Color(red: 0xF7 / 255.0, green: 0xF2 / 255.0, blue: 0xE9 / 255.0)
            self.bgBottom = Color(red: 0xEF / 255.0, green: 0xE7 / 255.0, blue: 0xDA / 255.0)
            self.warmGlow = Color(red: 0xE6 / 255.0, green: 0xAA / 255.0, blue: 0x5A / 255.0).opacity(0.28)
            self.pineGlow = Color(red: 0x18 / 255.0, green: 0x4F / 255.0, blue: 0x3C / 255.0).opacity(0.16)
            self.cardSurface = Color(red: 1.0, green: 251.0 / 255.0, blue: 244.0 / 255.0).opacity(0.90)
            self.cardStrong = Color(red: 1.0, green: 248.0 / 255.0, blue: 236.0 / 255.0)
            self.rowSurface = Color.white.opacity(0.74)
            self.rowActiveSurface = Color(red: 24.0 / 255.0, green: 79.0 / 255.0, blue: 60.0 / 255.0).opacity(0.14)
            self.rowActiveBorder = Color(red: 24.0 / 255.0, green: 79.0 / 255.0, blue: 60.0 / 255.0).opacity(0.28)
            self.inputSurface = Color.white.opacity(0.80)
            self.cardBorder = Color(red: 19.0 / 255.0, green: 39.0 / 255.0, blue: 31.0 / 255.0).opacity(0.10)
            self.accentBorder = Color(red: 24.0 / 255.0, green: 79.0 / 255.0, blue: 60.0 / 255.0).opacity(0.18)
            self.inkPrimary = Color(red: 0x13 / 255.0, green: 0x27 / 255.0, blue: 0x1F / 255.0)
            self.inkSecondary = Color(red: 0x48 / 255.0, green: 0x61 / 255.0, blue: 0x52 / 255.0)
            self.inkTertiary = Color(red: 0x6F / 255.0, green: 0x7F / 255.0, blue: 0x75 / 255.0)
            self.primaryStart = Color(red: 0x16 / 255.0, green: 0x3F / 255.0, blue: 0x31 / 255.0)
            self.primaryEnd = Color(red: 0x26 / 255.0, green: 0x5F / 255.0, blue: 0x4A / 255.0)
            self.primaryForeground = Color(red: 0xF7 / 255.0, green: 0xF5 / 255.0, blue: 0xEF / 255.0)
            self.onlineStart = Color(red: 0x1A / 255.0, green: 0x59 / 255.0, blue: 0x43 / 255.0)
            self.onlineEnd = Color(red: 0x2F / 255.0, green: 0x7D / 255.0, blue: 0x60 / 255.0)
            self.noticeBackground = Color(red: 24.0 / 255.0, green: 79.0 / 255.0, blue: 60.0 / 255.0).opacity(0.09)
            self.busyBackground = Color(red: 230.0 / 255.0, green: 170.0 / 255.0, blue: 90.0 / 255.0).opacity(0.18)
            self.busyForeground = Color(red: 0x6D / 255.0, green: 0x4C / 255.0, blue: 0x18 / 255.0)
        }
    }

    public var primaryGradient: LinearGradient {
        LinearGradient(colors: [primaryStart, primaryEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    public var onlineGradient: LinearGradient {
        LinearGradient(colors: [onlineStart, onlineEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

public enum SnapshotScene: String, CaseIterable, Sendable {
    case authIdle = "01-auth-idle"
    case authQr = "02-auth-qr"
    case music = "03-music"
    case video = "04-video"
    case download = "05-download"
    case errorBanner = "06-error-banner"
}
