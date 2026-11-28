import CloudTuneCore
import SwiftUI

extension AppearanceMode {
    package var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Pure airy neutral palette paired with low-saturation pine-teal accent (`#2A6F5B` / `#58A88F`)
/// and fixed high-contrast QR substrate (`#F6F1E8` / `#13271F`).
package struct CloudTunePalette: Sendable {
    package let isDark: Bool
    package let canvasBackground: Color
    package let sidebarBackground: Color
    package let surfacePrimary: Color
    package let surfaceSecondary: Color
    package let surfaceElevated: Color
    package let rowSurface: Color
    package let rowHoverSurface: Color
    package let rowActiveSurface: Color
    package let rowActiveBorder: Color
    package let inputSurface: Color
    package let separator: Color
    package let cardBorder: Color
    package let accent: Color
    package let accentSoft: Color
    package let accentBorder: Color
    package let inkPrimary: Color
    package let inkSecondary: Color
    package let inkTertiary: Color
    package let primaryStart: Color
    package let primaryEnd: Color
    package let primaryForeground: Color
    package let destructive: Color
    package let noticeBackground: Color
    // Fixed across light and dark modes so QR scanners always read dark-on-light reliably
    package let qrSubstrate: Color
    package let qrForeground: Color

    package init(isDark: Bool) {
        self.isDark = isDark
        self.qrSubstrate = Color(red: 0xF6 / 255.0, green: 0xF1 / 255.0, blue: 0xE8 / 255.0)
        self.qrForeground = Color(red: 0x13 / 255.0, green: 0x27 / 255.0, blue: 0x1F / 255.0)

        if isDark {
            // Neutral charcoal #111315 / #181B1F + low-saturation pine-mint #58A88F
            let canvas = Color(red: 0x11 / 255.0, green: 0x13 / 255.0, blue: 0x15 / 255.0)
            let surface = Color(red: 0x18 / 255.0, green: 0x1B / 255.0, blue: 0x1F / 255.0)
            let secondary = Color(red: 0x20 / 255.0, green: 0x24 / 255.0, blue: 0x2A / 255.0)
            let elevated = Color(red: 0x24 / 255.0, green: 0x29 / 255.0, blue: 0x30 / 255.0)
            let pine = Color(red: 0x58 / 255.0, green: 0xA8 / 255.0, blue: 0x8F / 255.0)

            self.canvasBackground = canvas
            self.sidebarBackground = Color(red: 0x14 / 255.0, green: 0x17 / 255.0, blue: 0x1A / 255.0)
            self.surfacePrimary = surface
            self.surfaceSecondary = secondary
            self.surfaceElevated = elevated
            self.rowSurface = surface
            self.rowHoverSurface = Color.white.opacity(0.04)
            self.rowActiveSurface = pine.opacity(0.18)
            self.rowActiveBorder = pine.opacity(0.42)
            self.inputSurface = secondary
            self.separator = Color.white.opacity(0.08)
            self.cardBorder = Color.white.opacity(0.08)
            self.accent = pine
            self.accentSoft = pine.opacity(0.16)
            self.accentBorder = Color.white.opacity(0.11)
            self.inkPrimary = Color(red: 0xF1 / 255.0, green: 0xF3 / 255.0, blue: 0xF5 / 255.0)
            self.inkSecondary = Color(red: 0xAA / 255.0, green: 0xB2 / 255.0, blue: 0xBD / 255.0)
            self.inkTertiary = Color(red: 0x78 / 255.0, green: 0x81 / 255.0, blue: 0x8E / 255.0)
            self.primaryStart = Color(red: 0x2D / 255.0, green: 0x7A / 255.0, blue: 0x64 / 255.0)
            self.primaryEnd = Color(red: 0x3A / 255.0, green: 0x8D / 255.0, blue: 0x75 / 255.0)
            self.primaryForeground = Color(red: 0xF8 / 255.0, green: 0xFA / 255.0, blue: 0xF9 / 255.0)
            self.destructive = Color(red: 0xE5 / 255.0, green: 0x6B / 255.0, blue: 0x6F / 255.0)
            self.noticeBackground = pine.opacity(0.14)
        } else {
            // Pure neutral #F7F8FA / #FFFFFF + low-saturation pine-teal #2A6F5B
            let canvas = Color(red: 0xF7 / 255.0, green: 0xF8 / 255.0, blue: 0xFA / 255.0)
            let surface = Color.white
            let secondary = Color(red: 0xF0 / 255.0, green: 0xF2 / 255.0, blue: 0xF5 / 255.0)
            let pine = Color(red: 0x2A / 255.0, green: 0x6F / 255.0, blue: 0x5B / 255.0)

            self.canvasBackground = canvas
            self.sidebarBackground = Color(red: 0xF2 / 255.0, green: 0xF4 / 255.0, blue: 0xF7 / 255.0)
            self.surfacePrimary = surface
            self.surfaceSecondary = secondary
            self.surfaceElevated = surface
            self.rowSurface = surface
            self.rowHoverSurface = Color.black.opacity(0.03)
            self.rowActiveSurface = pine.opacity(0.10)
            self.rowActiveBorder = pine.opacity(0.28)
            self.inputSurface = secondary
            self.separator = Color(red: 0xE3 / 255.0, green: 0xE7 / 255.0, blue: 0xED / 255.0)
            self.cardBorder = Color(red: 0xE4 / 255.0, green: 0xE7 / 255.0, blue: 0xEC / 255.0)
            self.accent = pine
            self.accentSoft = pine.opacity(0.10)
            self.accentBorder = Color(red: 0xDC / 255.0, green: 0xE1 / 255.0, blue: 0xE8 / 255.0)
            self.inkPrimary = Color(red: 0x16 / 255.0, green: 0x19 / 255.0, blue: 0x1D / 255.0)
            self.inkSecondary = Color(red: 0x4E / 255.0, green: 0x56 / 255.0, blue: 0x61 / 255.0)
            self.inkTertiary = Color(red: 0x7B / 255.0, green: 0x84 / 255.0, blue: 0x91 / 255.0)
            self.primaryStart = pine
            self.primaryEnd = Color(red: 0x33 / 255.0, green: 0x80 / 255.0, blue: 0x69 / 255.0)
            self.primaryForeground = Color.white
            self.destructive = Color(red: 0xC9 / 255.0, green: 0x3B / 255.0, blue: 0x3B / 255.0)
            self.noticeBackground = pine.opacity(0.08)
        }
    }

    package var primaryGradient: LinearGradient {
        LinearGradient(colors: [primaryStart, primaryEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

#if DEBUG
public enum SnapshotScene: String, CaseIterable, Sendable {
    case authIdle = "01-auth-idle"
    case authQr = "02-auth-qr"
    case music = "03-music"
    case video = "04-video"
    case download = "05-download"
    case errorBanner = "06-error-banner"
    case cloud = "07-cloud"
    case settings = "08-settings"
    case nowPlaying = "09-now-playing"
}
#endif
