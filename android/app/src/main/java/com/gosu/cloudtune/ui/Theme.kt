package com.gosu.cloudtune.ui

import android.app.Activity
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

@Immutable
data class CloudTuneColors(
    val isDark: Boolean,
    val canvas: Color,
    val surface: Color,
    val surfaceSecondary: Color,
    val surfaceElevated: Color,
    val rowHover: Color,
    val rowActiveSurface: Color,
    val rowActiveBorder: Color,
    val separator: Color,
    val accent: Color,
    val accentSoft: Color,
    val accentForeground: Color,
    val inkPrimary: Color,
    val inkSecondary: Color,
    val inkTertiary: Color,
    val destructive: Color,
    val noticeBackground: Color,
    val qrSubstrate: Color = Color(0xFFF6F1E8),
    val qrForeground: Color = Color(0xFF13271F)
)

val LightCloudTuneColors = CloudTuneColors(
    isDark = false,
    canvas = Color(0xFFF7F8FA),
    surface = Color(0xFFFFFFFF),
    surfaceSecondary = Color(0xFFF0F2F5),
    surfaceElevated = Color(0xFFFFFFFF),
    rowHover = Color(0x0A000000),
    rowActiveSurface = Color(0x1A2A6F5B),
    rowActiveBorder = Color(0x472A6F5B),
    separator = Color(0xFFE3E7ED),
    accent = Color(0xFF2A6F5B),
    accentSoft = Color(0x1A2A6F5B),
    accentForeground = Color(0xFFFFFFFF),
    inkPrimary = Color(0xFF16191D),
    inkSecondary = Color(0xFF4E5661),
    inkTertiary = Color(0xFF7B8491),
    destructive = Color(0xFFC93B3B),
    noticeBackground = Color(0x142A6F5B)
)

val DarkCloudTuneColors = CloudTuneColors(
    isDark = true,
    canvas = Color(0xFF111315),
    surface = Color(0xFF181B1F),
    surfaceSecondary = Color(0xFF20242A),
    surfaceElevated = Color(0xFF22272E),
    rowHover = Color(0x0DFFFFFF),
    rowActiveSurface = Color(0x2E58A88F),
    rowActiveBorder = Color(0x6B58A88F),
    separator = Color(0x17FFFFFF),
    accent = Color(0xFF58A88F),
    accentSoft = Color(0x2958A88F),
    accentForeground = Color(0xFF0E1D18),
    inkPrimary = Color(0xFFF1F3F5),
    inkSecondary = Color(0xFFAAB2BD),
    inkTertiary = Color(0xFF78818E),
    destructive = Color(0xFFE56B6F),
    noticeBackground = Color(0x2458A88F)
)

val LocalCloudTuneColors = staticCompositionLocalOf { LightCloudTuneColors }

private val LightNeutralPineScheme = lightColorScheme(
    primary = Color(0xFF2A6F5B),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFD9EDE6),
    onPrimaryContainer = Color(0xFF0E3328),
    secondary = Color(0xFF4A635B),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFDEECE7),
    onSecondaryContainer = Color(0xFF1A2E28),
    background = Color(0xFFF7F8FA),
    onBackground = Color(0xFF16191D),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF16191D),
    surfaceVariant = Color(0xFFF0F2F5),
    onSurfaceVariant = Color(0xFF4E5661),
    outline = Color(0xFFD5DCE4),
    outlineVariant = Color(0xFFE3E7ED),
    error = Color(0xFFC93B3B)
)

private val DarkNeutralPineScheme = darkColorScheme(
    primary = Color(0xFF58A88F),
    onPrimary = Color(0xFF0A241C),
    primaryContainer = Color(0xFF1E4D3E),
    onPrimaryContainer = Color(0xFFD5F2E8),
    secondary = Color(0xFF9EBAB0),
    onSecondary = Color(0xFF172B24),
    secondaryContainer = Color(0xFF283B34),
    onSecondaryContainer = Color(0xFFD7EAE3),
    background = Color(0xFF111315),
    onBackground = Color(0xFFF1F3F5),
    surface = Color(0xFF181B1F),
    onSurface = Color(0xFFF1F3F5),
    surfaceVariant = Color(0xFF20242A),
    onSurfaceVariant = Color(0xFFAAB2BD),
    outline = Color(0xFF343B45),
    outlineVariant = Color(0xFF262B33),
    error = Color(0xFFE56B6F)
)

private fun deriveDynamicCloudTuneColors(scheme: ColorScheme, isDark: Boolean): CloudTuneColors {
    val base = if (isDark) DarkCloudTuneColors else LightCloudTuneColors
    return base.copy(
        canvas = scheme.background,
        surface = scheme.surface,
        surfaceSecondary = scheme.surfaceVariant,
        surfaceElevated = scheme.surfaceVariant,
        rowActiveSurface = scheme.secondaryContainer.copy(alpha = if (isDark) 0.55f else 0.70f),
        rowActiveBorder = scheme.primary.copy(alpha = 0.45f),
        separator = scheme.outlineVariant,
        accent = scheme.primary,
        accentSoft = scheme.primaryContainer.copy(alpha = if (isDark) 0.55f else 0.75f),
        accentForeground = scheme.onPrimary,
        inkPrimary = scheme.onSurface,
        inkSecondary = scheme.onSurfaceVariant,
        inkTertiary = scheme.onSurfaceVariant.copy(alpha = 0.72f),
        noticeBackground = scheme.secondaryContainer.copy(alpha = if (isDark) 0.45f else 0.65f)
    )
}

@Composable
fun CloudTuneTheme(
    darkTheme: Boolean,
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit
) {
    val context = LocalContext.current
    val scheme = if (dynamicColor) {
        if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    } else {
        if (darkTheme) DarkNeutralPineScheme else LightNeutralPineScheme
    }
    val palette = if (dynamicColor) {
        deriveDynamicCloudTuneColors(scheme, darkTheme)
    } else {
        if (darkTheme) DarkCloudTuneColors else LightCloudTuneColors
    }

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            (view.context as? Activity)?.window?.let { window ->
                val controller = WindowCompat.getInsetsController(window, view)
                controller.isAppearanceLightStatusBars = !darkTheme
                controller.isAppearanceLightNavigationBars = !darkTheme
            }
        }
    }

    CompositionLocalProvider(LocalCloudTuneColors provides palette) {
        MaterialTheme(
            colorScheme = scheme,
            content = content
        )
    }
}
