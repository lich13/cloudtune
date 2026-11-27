package com.gosu.cloudtune.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

object AppIcons {
    val Play: ImageVector by lazy {
        ImageVector.Builder("Play", 24.dp, 24.dp, 24f, 24f).apply {
            path(fill = SolidColor(Color.Black)) {
                moveTo(8f, 5.2f)
                lineTo(19f, 12f)
                lineTo(8f, 18.8f)
                close()
            }
        }.build()
    }

    val Pause: ImageVector by lazy {
        ImageVector.Builder("Pause", 24.dp, 24.dp, 24f, 24f).apply {
            path(fill = SolidColor(Color.Black)) {
                moveTo(6.5f, 5f); lineTo(10.5f, 5f); lineTo(10.5f, 19f); lineTo(6.5f, 19f); close()
                moveTo(13.5f, 5f); lineTo(17.5f, 5f); lineTo(17.5f, 19f); lineTo(13.5f, 19f); close()
            }
        }.build()
    }

    val SkipPrevious: ImageVector by lazy {
        ImageVector.Builder("SkipPrev", 24.dp, 24.dp, 24f, 24f).apply {
            path(fill = SolidColor(Color.Black)) {
                moveTo(6f, 6f); lineTo(8.2f, 6f); lineTo(8.2f, 18f); lineTo(6f, 18f); close()
                moveTo(18f, 6f); lineTo(9.8f, 12f); lineTo(18f, 18f); close()
            }
        }.build()
    }

    val SkipNext: ImageVector by lazy {
        ImageVector.Builder("SkipNext", 24.dp, 24.dp, 24f, 24f).apply {
            path(fill = SolidColor(Color.Black)) {
                moveTo(15.8f, 6f); lineTo(18f, 6f); lineTo(18f, 18f); lineTo(15.8f, 18f); close()
                moveTo(6f, 6f); lineTo(14.2f, 12f); lineTo(6f, 18f); close()
            }
        }.build()
    }

    val Music: ImageVector by lazy {
        ImageVector.Builder("Music", 24.dp, 24.dp, 24f, 24f).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = 2f,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round
            ) {
                moveTo(9f, 18f); lineTo(9f, 6f); lineTo(19f, 4f); lineTo(19f, 16f)
                moveTo(9f, 18f); curveTo(9f, 19.7f, 7.7f, 21f, 6f, 21f); curveTo(4.3f, 21f, 3f, 19.7f, 3f, 18f); curveTo(3f, 16.3f, 4.3f, 15f, 6f, 15f); curveTo(7.7f, 15f, 9f, 16.3f, 9f, 18f)
                moveTo(19f, 16f); curveTo(19f, 17.7f, 17.7f, 19f, 16f, 19f); curveTo(14.3f, 19f, 13f, 17.7f, 13f, 16f); curveTo(13f, 14.3f, 14.3f, 13f, 16f, 13f); curveTo(17.7f, 13f, 19f, 14.3f, 19f, 16f)
            }
        }.build()
    }

    val Video: ImageVector by lazy {
        ImageVector.Builder("Video", 24.dp, 24.dp, 24f, 24f).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = 2f,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round
            ) {
                moveTo(3f, 6f); lineTo(15f, 6f); lineTo(15f, 18f); lineTo(3f, 18f); close()
                moveTo(15f, 10f); lineTo(21f, 7f); lineTo(21f, 17f); lineTo(15f, 14f); close()
            }
        }.build()
    }

    val Download: ImageVector by lazy {
        ImageVector.Builder("Download", 24.dp, 24.dp, 24f, 24f).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = 2f,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round
            ) {
                moveTo(12f, 4f); lineTo(12f, 15f)
                moveTo(7.5f, 11f); lineTo(12f, 15.5f); lineTo(16.5f, 11f)
                moveTo(5f, 19.5f); lineTo(19f, 19.5f)
            }
        }.build()
    }

    val Settings: ImageVector by lazy {
        ImageVector.Builder("Settings", 24.dp, 24.dp, 24f, 24f).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = 2f,
                strokeLineCap = StrokeCap.Round
            ) {
                moveTo(4f, 7f); lineTo(20f, 7f)
                moveTo(4f, 12f); lineTo(20f, 12f)
                moveTo(4f, 17f); lineTo(20f, 17f)
                moveTo(9f, 5f); lineTo(9f, 9f)
                moveTo(15f, 10f); lineTo(15f, 14f)
                moveTo(10f, 15f); lineTo(10f, 19f)
            }
        }.build()
    }

    val Folder: ImageVector by lazy {
        ImageVector.Builder("Folder", 24.dp, 24.dp, 24f, 24f).apply {
            path(fill = SolidColor(Color.Black)) {
                moveTo(3f, 6f); lineTo(9.5f, 6f); lineTo(11.5f, 8.2f); lineTo(21f, 8.2f)
                lineTo(21f, 18.5f); lineTo(3f, 18.5f); close()
            }
        }.build()
    }

    val QrCode: ImageVector by lazy {
        ImageVector.Builder("QrCode", 24.dp, 24.dp, 24f, 24f).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = 2f,
                strokeLineJoin = StrokeJoin.Round
            ) {
                moveTo(4f, 4f); lineTo(10f, 4f); lineTo(10f, 10f); lineTo(4f, 10f); close()
                moveTo(14f, 4f); lineTo(20f, 4f); lineTo(20f, 10f); lineTo(14f, 10f); close()
                moveTo(4f, 14f); lineTo(10f, 14f); lineTo(10f, 20f); lineTo(4f, 20f); close()
                moveTo(14f, 14f); lineTo(17f, 14f); lineTo(17f, 17f); lineTo(20f, 17f); lineTo(20f, 20f); lineTo(14f, 20f); close()
            }
        }.build()
    }
}
