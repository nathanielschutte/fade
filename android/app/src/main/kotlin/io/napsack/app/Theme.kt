package io.napsack.app

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** napsack's palette, from the web app (server/static/style.css, :root): always dark, as the web is. */
object Palette {
    val ink = Color(0xFF1B2822) // base
    val deep = Color(0xFF15201B) // recessed: inputs, lists
    val wash = Color(0xFF26372F) // raised: selection
    val paper = Color(0xFFE4ECE6) // primary text
    val fixer = Color(0xFF9DB3A6) // secondary text
    val sage = Color(0xFF93C5A3) // accent: primary actions
    val onSage = Color(0xFF12201A) // text on the accent
    val danger = Color(0xFFE8A598)
    val rule = Color(0x1FE4ECE6) // paper at 12%
}

private val colors = darkColorScheme(
    primary = Palette.sage,
    onPrimary = Palette.onSage,
    secondary = Palette.fixer,
    onSecondary = Palette.ink,
    background = Palette.ink,
    onBackground = Palette.paper,
    surface = Palette.ink,
    onSurface = Palette.paper,
    surfaceVariant = Palette.wash,
    onSurfaceVariant = Palette.fixer,
    surfaceContainer = Palette.deep,
    surfaceContainerLow = Palette.deep,
    surfaceContainerHigh = Palette.wash,
    surfaceContainerHighest = Palette.wash,
    outline = Palette.fixer,
    outlineVariant = Palette.rule,
    error = Palette.danger,
    onError = Palette.ink,
)

@Composable
fun NapsackTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = colors, content = content)
}
