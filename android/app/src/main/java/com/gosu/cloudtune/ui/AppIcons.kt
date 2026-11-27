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

    val Cloud: ImageVector by lazy {
        ImageVector.Builder("Cloud", 24.dp, 24.dp, 24f, 24f).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = 2f,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round
            ) {
                moveTo(6.5f, 18.5f)
                lineTo(17.5f, 18.5f)
                curveTo(19.9f, 18.5f, 21.5f, 16.9f, 21.5f, 14.7f)
                curveTo(21.5f, 12.7f, 20.1f, 11.1f, 18.1f, 10.9f)
                curveTo(17.4f, 7.8f, 14.7f, 5.5f, 11.5f, 5.5f)
                curveTo(8.1f, 5.5f, 5.3f, 8.1f, 5.0f, 11.5f)
                curveTo(3.3f, 12.0f, 2.5f, 13.5f, 2.5f, 15.1f)
                curveTo(2.5f, 17.0f, 4.2f, 18.5f, 6.5f, 18.5f)
            }
        }.build()
    }

    val Transfers: ImageVector by lazy {
        ImageVector.Builder("Transfers", 24.dp, 24.dp, 24f, 24f).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = 2f,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round
            ) {
                moveTo(8f, 5f); lineTo(8f, 17f)
                moveTo(4.5f, 13.5f); lineTo(8f, 17f); lineTo(11.5f, 13.5f)
                moveTo(16f, 19f); lineTo(16f, 7f)
                moveTo(12.5f, 10.5f); lineTo(16f, 7f); lineTo(19.5f, 10.5f)
            }
        }.build()
    }

    val Download: ImageVector get() = Transfers

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

    val Shuffle: ImageVector by lazy {
        ImageVector.Builder("Shuffle", 24.dp, 24.dp, 24f, 24f).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = 2f,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round
            ) {
                moveTo(4f, 7f); lineTo(8.5f, 7f); lineTo(15.5f, 17f); lineTo(20f, 17f)
                moveTo(17.5f, 14.5f); lineTo(20f, 17f); lineTo(17.5f, 19.5f)
                moveTo(4f, 17f); lineTo(8.5f, 17f); lineTo(15.5f, 7f); lineTo(20f, 7f)
                moveTo(17.5f, 4.5f); lineTo(20f, 7f); lineTo(17.5f, 9.5f)
            }
        }.build()
    }

    val Repeat: ImageVector by lazy {
        ImageVector.Builder("Repeat", 24.dp, 24.dp, 24f, 24f).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = 2f,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round
            ) {
                moveTo(17f, 4f); lineTo(20f, 7f); lineTo(17f, 10f)
                moveTo(4f, 11f); lineTo(4f, 9f); curveTo(4f, 7.9f, 4.9f, 7f, 6f, 7f); lineTo(20f, 7f)
                moveTo(7f, 20f); lineTo(4f, 17f); lineTo(7f, 14f)
                moveTo(20f, 13f); lineTo(20f, 15f); curveTo(20f, 16.1f, 19.1f, 17f, 18f, 17f); lineTo(4f, 17f)
            }
        }.build()
    }

    val SpeakerWave: ImageVector by lazy {
        ImageVector.Builder("SpeakerWave", 24.dp, 24.dp, 24f, 24f).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = 2f,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round
            ) {
                moveTo(4f, 9.5f); lineTo(8f, 9.5f); lineTo(13f, 5.5f); lineTo(13f, 18.5f); lineTo(8f, 14.5f); lineTo(4f, 14.5f); close()
                moveTo(16.5f, 9f); curveTo(18f, 10.5f, 18f, 13.5f, 16.5f, 15f)
                moveTo(19f, 6.8f); curveTo(21.4f, 9.5f, 21.4f, 14.5f, 19f, 17.2f)
            }
        }.build()
    }

    val QueueList: ImageVector by lazy {
        ImageVector.Builder("QueueList", 24.dp, 24.dp, 24f, 24f).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = 2f,
                strokeLineCap = StrokeCap.Round
            ) {
                moveTo(4f, 7f); lineTo(14f, 7f)
                moveTo(4f, 12f); lineTo(14f, 12f)
                moveTo(4f, 17f); lineTo(11f, 17f)
                moveTo(17f, 11f); lineTo(17f, 18f)
                moveTo(17f, 11f); lineTo(20f, 10f)
            }
        }.build()
    }

    val Pip: ImageVector by lazy {
        ImageVector.Builder("Pip", 24.dp, 24.dp, 24f, 24f).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = 2f,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round
            ) {
                moveTo(3f, 5f); lineTo(21f, 5f); lineTo(21f, 19f); lineTo(3f, 19f); close()
                moveTo(12f, 12f); lineTo(19f, 12f); lineTo(19f, 17f); lineTo(12f, 17f); close()
            }
        }.build()
    }

    val Search: ImageVector by lazy {
        ImageVector.Builder("Search", 24.dp, 24.dp, 24f, 24f).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = 2f,
                strokeLineCap = StrokeCap.Round
            ) {
                moveTo(16f, 11f)
                curveTo(16f, 13.8f, 13.8f, 16f, 11f, 16f)
                curveTo(8.2f, 16f, 6f, 13.8f, 6f, 11f)
                curveTo(6f, 8.2f, 8.2f, 6f, 11f, 6f)
                curveTo(13.8f, 6f, 16f, 8.2f, 16f, 11f)
                moveTo(15f, 15f); lineTo(19.5f, 19.5f)
            }
        }.build()
    }

    val ArrowBack: ImageVector by lazy {
        ImageVector.Builder("ArrowBack", 24.dp, 24.dp, 24f, 24f).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = 2f,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round
            ) {
                moveTo(19f, 12f); lineTo(5f, 12f)
                moveTo(11f, 6f); lineTo(5f, 12f); lineTo(11f, 18f)
            }
        }.build()
    }

    val ChevronDown: ImageVector by lazy {
        ImageVector.Builder("ChevronDown", 24.dp, 24.dp, 24f, 24f).apply {
            path(
                stroke = SolidColor(Color.Black),
                strokeLineWidth = 2f,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round
            ) {
                moveTo(6f, 9f); lineTo(12f, 15f); lineTo(18f, 9f)
            }
        }.build()
    }

    val MoreVert: ImageVector by lazy {
        ImageVector.Builder("MoreVert", 24.dp, 24.dp, 24f, 24f).apply {
            path(fill = SolidColor(Color.Black)) {
                moveTo(12f, 5f); curveTo(12.9f, 5f, 13.6f, 5.7f, 13.6f, 6.6f); curveTo(13.6f, 7.5f, 12.9f, 8.2f, 12f, 8.2f); curveTo(11.1f, 8.2f, 10.4f, 7.5f, 10.4f, 6.6f); curveTo(10.4f, 5.7f, 11.1f, 5.0f, 12f, 5f)
                moveTo(12f, 10.4f); curveTo(12.9f, 10.4f, 13.6f, 11.1f, 13.6f, 12f); curveTo(13.6f, 12.9f, 12.9f, 13.6f, 12f, 13.6f); curveTo(11.1f, 13.6f, 10.4f, 12.9f, 10.4f, 12f); curveTo(10.4f, 11.1f, 11.1f, 10.4f, 12f, 10.4f)
                moveTo(12f, 15.8f); curveTo(12.9f, 15.8f, 13.6f, 16.5f, 13.6f, 17.4f); curveTo(13.6f, 18.3f, 12.9f, 19f, 12f, 19f); curveTo(11.1f, 19f, 10.4f, 18.3f, 10.4f, 17.4f); curveTo(10.4f, 16.5f, 11.1f, 15.8f, 12f, 15.8f)
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
