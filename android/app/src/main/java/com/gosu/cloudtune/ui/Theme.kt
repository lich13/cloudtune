package com.gosu.cloudtune.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

@Immutable
data class CloudTuneColors(
    val isDark: Boolean,
    val bgTop: Color,
    val bgBottom: Color,
    val cardSurface: Color,
    val cardStrong: Color,
    val rowSurface: Color,
    val rowActiveSurface: Color,
    val rowActiveBorder: Color,
    val inputSurface: Color,
    val cardBorder: Color,
    val accentBorder: Color,
    val inkPrimary: Color,
    val inkSecondary: Color,
    val inkTertiary: Color,
    val primaryStart: Color,
    val primaryEnd: Color,
    val primaryForeground: Color,
    val warmGold: Color,
    val noticeBackground: Color,
    val qrSubstrate: Color = Color(0xFFF6F1E8),
    val qrForeground: Color = Color(0xFF13271F)
)

val LightCloudTuneColors = CloudTuneColors(
    isDark = false,
    bgTop = Color(0xFFF7F2E9),
    bgBottom = Color(0xFFEFE7DA),
    cardSurface = Color(0xE8FFFBF4),
    cardStrong = Color(0xFFFFF8EC),
    rowSurface = Color(0xC2FFFFFF),
    rowActiveSurface = Color(0x24184F3C),
    rowActiveBorder = Color(0x47184F3C),
    inputSurface = Color(0xCCFFFFFF),
    cardBorder = Color(0x1A13271F),
    accentBorder = Color(0x2E184F3C),
    inkPrimary = Color(0xFF13271F),
    inkSecondary = Color(0xFF486152),
    inkTertiary = Color(0xFF6F7F75),
    primaryStart = Color(0xFF163F31),
    primaryEnd = Color(0xFF265F4A),
    primaryForeground = Color(0xFFF7F5EF),
    warmGold = Color(0xFFE6AA5A),
    noticeBackground = Color(0x17184F3C)
)

val DarkCloudTuneColors = CloudTuneColors(
    isDark = true,
    bgTop = Color(0xFF0E1714),
    bgBottom = Color(0xFF0A110E),
    cardSurface = Color(0xE616241E),
    cardStrong = Color(0xFF1C2D26),
    rowSurface = Color(0xDB1A2A23),
    rowActiveSurface = Color(0x422F7D60),
    rowActiveBorder = Color(0x8C439E7C),
    inputSurface = Color(0xFF121E19),
    cardBorder = Color(0x1AFFFFFF),
    accentBorder = Color(0x52439E7C),
    inkPrimary = Color(0xFFECF5F0),
    inkSecondary = Color(0xFFB4C8BD),
    inkTertiary = Color(0xFF82A393),
    primaryStart = Color(0xFF22644C),
    primaryEnd = Color(0xFF2F7D60),
    primaryForeground = Color(0xFFF5FBF8),
    warmGold = Color(0xFFE6AA5A),
    noticeBackground = Color(0x332F7D60)
)

val LocalCloudTuneColors = staticCompositionLocalOf { LightCloudTuneColors }

private val LightMaterialScheme = lightColorScheme(
    primary = Color(0xFF184F3C),
    onPrimary = Color(0xFFF7F5EF),
    secondary = Color(0xFF184F3C),
    onSecondary = Color(0xFFF7F5EF),
    secondaryContainer = Color(0x24184F3C),
    onSecondaryContainer = Color(0xFF13271F),
    background = Color(0xFFF7F2E9),
    surface = Color(0xFFFFFBF4),
    surfaceVariant = Color(0xFFEFE7DA),
    onSurfaceVariant = Color(0xFF486152),
    onBackground = Color(0xFF13271F),
    onSurface = Color(0xFF13271F)
)

private val DarkMaterialScheme = darkColorScheme(
    primary = Color(0xFF2F7D60),
    onPrimary = Color(0xFFF5FBF8),
    secondary = Color(0xFFE6AA5A),
    onSecondary = Color(0xFF13271F),
    secondaryContainer = Color(0x422F7D60),
    onSecondaryContainer = Color(0xFFECF5F0),
    background = Color(0xFF0E1714),
    surface = Color(0xFF16241E),
    surfaceVariant = Color(0xFF1C2D26),
    onSurfaceVariant = Color(0xFFB4C8BD),
    onBackground = Color(0xFFECF5F0),
    onSurface = Color(0xFFECF5F0)
)

@Composable
fun CloudTuneTheme(
    darkTheme: Boolean,
    content: @Composable () -> Unit
) {
    val palette = if (darkTheme) DarkCloudTuneColors else LightCloudTuneColors
    val material = if (darkTheme) DarkMaterialScheme else LightMaterialScheme
    CompositionLocalProvider(LocalCloudTuneColors provides palette) {
        MaterialTheme(
            colorScheme = material,
            content = content
        )
    }
}
