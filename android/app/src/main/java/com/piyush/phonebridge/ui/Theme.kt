package com.piyush.phonebridge.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// Quiet light theme shared with the Mac app: warm off-white paper, white
// cards with hairline borders, near-black ink, and color only in small
// doses (soft violet accent, muted green/amber status dots).
object Brand {
    val accent = Color(0xFF7C6FDE)
    val accentSoft = Color(0xFFF3EFFB)
    val emerald = Color(0xFF34A76F)
    val emeraldSoft = Color(0xFFE8F5EE)
    val amber = Color(0xFFD97706)
    val amberSoft = Color(0xFFFEF3C7)
    val paper = Color(0xFFF7F7F5)
    val card = Color(0xFFFFFFFF)
    val border = Color(0xFFE8E8E4)
    val ink = Color(0xFF1A1A1A)
    val inkSecondary = Color(0xFF6B6B6B)
}

private val LightColors = lightColorScheme(
    primary = Brand.accent,
    onPrimary = Color.White,
    primaryContainer = Brand.accentSoft,
    onPrimaryContainer = Color(0xFF3B3168),
    secondary = Brand.inkSecondary,
    onSecondary = Color.White,
    tertiary = Brand.emerald,
    error = Color(0xFFD92D20),
    background = Brand.paper,
    onBackground = Brand.ink,
    surface = Brand.paper,
    onSurface = Brand.ink,
    surfaceVariant = Color(0xFFEFEFEC),
    onSurfaceVariant = Brand.inkSecondary,
    surfaceContainerLowest = Brand.card,
    surfaceContainerLow = Brand.card,
    surfaceContainer = Brand.card,
    surfaceContainerHigh = Brand.card,
    surfaceContainerHighest = Brand.card,
    outline = Color(0xFFD8D8D3),
    outlineVariant = Brand.border,
)

@Composable
fun PhoneBridgeTheme(content: @Composable () -> Unit) {
    // Light-only by design: this quiet paper look is the app's identity,
    // matching the Mac side, which is also pinned to light appearance.
    MaterialTheme(colorScheme = LightColors, content = content)
}
