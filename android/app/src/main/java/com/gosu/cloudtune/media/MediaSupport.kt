package com.gosu.cloudtune.media

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.gosu.cloudtune.ui.CloudTuneAppRuntime
import java.io.File

object PlaybackSessionBridge {
    @Volatile var onSkipNext: (() -> Unit)? = null
    @Volatile var onSkipPrevious: (() -> Unit)? = null
}

data class ExtractedAudioMetadata(
    val title: String,
    val artist: String,
    val album: String,
    val artworkBytes: ByteArray?
)

object AudioMetadataHelper {
    fun extract(
        localFile: File?,
        fallbackTitle: String,
        fallbackArtist: String,
        fallbackAlbum: String
    ): ExtractedAudioMetadata {
        if (localFile == null || !localFile.isFile || localFile.length() <= 0L) {
            return ExtractedAudioMetadata(fallbackTitle, fallbackArtist, fallbackAlbum, null)
        }
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(localFile.absolutePath)
            val title = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)
                ?.trim()?.takeIf { it.isNotEmpty() } ?: fallbackTitle
            val artist = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                ?.trim()?.takeIf { it.isNotEmpty() } ?: fallbackArtist
            val album = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM)
                ?.trim()?.takeIf { it.isNotEmpty() } ?: fallbackAlbum
            val art = retriever.embeddedPicture?.takeIf { it.isNotEmpty() }
            ExtractedAudioMetadata(title, artist, album, art)
        } catch (_: Throwable) {
            ExtractedAudioMetadata(fallbackTitle, fallbackArtist, fallbackAlbum, null)
        } finally {
            runCatching { retriever.release() }
        }
    }
}

@OptIn(UnstableApi::class)
class PlaybackService : MediaSessionService() {
    private var exoPlayer: ExoPlayer? = null
    private var mediaSession: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val audioAttrs = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
            .build()
        val rawPlayer = ExoPlayer.Builder(this)
            .setAudioAttributes(audioAttrs, true)
            .setHandleAudioBecomingNoisy(true)
            .build()
        exoPlayer = rawPlayer

        val forwardingPlayer = object : ForwardingPlayer(rawPlayer) {
            override fun getAvailableCommands(): Player.Commands {
                return super.getAvailableCommands()
                    .buildUpon()
                    .add(Player.COMMAND_SEEK_TO_NEXT)
                    .add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
                    .add(Player.COMMAND_SEEK_TO_PREVIOUS)
                    .add(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
                    .build()
            }

            override fun isCommandAvailable(command: Int): Boolean {
                return when (command) {
                    Player.COMMAND_SEEK_TO_NEXT,
                    Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
                    Player.COMMAND_SEEK_TO_PREVIOUS,
                    Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> true
                    else -> super.isCommandAvailable(command)
                }
            }

            override fun hasNextMediaItem(): Boolean = true

            override fun hasPreviousMediaItem(): Boolean = true

            override fun seekToNext() {
                PlaybackSessionBridge.onSkipNext?.invoke() ?: super.seekToNext()
            }

            override fun seekToNextMediaItem() {
                PlaybackSessionBridge.onSkipNext?.invoke() ?: super.seekToNextMediaItem()
            }

            override fun seekToPrevious() {
                PlaybackSessionBridge.onSkipPrevious?.invoke() ?: super.seekToPrevious()
            }

            override fun seekToPreviousMediaItem() {
                PlaybackSessionBridge.onSkipPrevious?.invoke() ?: super.seekToPreviousMediaItem()
            }
        }
        mediaSession = MediaSession.Builder(this, forwardingPlayer).build()
        CloudTuneAppRuntime.getOrCreate(applicationContext).bindSkipBridge()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = mediaSession

    override fun onDestroy() {
        mediaSession?.release()
        mediaSession = null
        exoPlayer?.release()
        exoPlayer = null
        super.onDestroy()
    }
}

object QrCodeHelper {
    private const val QR_DARK_PINE = 0xFF13271F.toInt()
    private const val QR_WARM_LIGHT = 0xFFF6F1E8.toInt()

    /** Fixed `#13271F` modules on `#F6F1E8` warm light substrate across both light and dark themes. */
    fun generateQrBitmap(content: String, sizePx: Int = 512): Bitmap? {
        if (content.isBlank()) return null
        return runCatching {
            val hints = mapOf(
                EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M,
                EncodeHintType.CHARACTER_SET to "UTF-8",
                EncodeHintType.MARGIN to 2
            )
            val matrix = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, sizePx, sizePx, hints)
            val pixels = IntArray(sizePx * sizePx)
            for (y in 0 until sizePx) {
                val row = y * sizePx
                for (x in 0 until sizePx) {
                    pixels[row + x] = if (matrix.get(x, y)) QR_DARK_PINE else QR_WARM_LIGHT
                }
            }
            Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888).apply {
                setPixels(pixels, 0, sizePx, 0, 0, sizePx, sizePx)
            }
        }.getOrNull()
    }

    fun saveQrBitmapToGallery(context: Context, bitmap: Bitmap): Boolean = runCatching {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "CloudTune_Tianyi_QR_${System.currentTimeMillis()}.png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/CloudTune")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return false
        resolver.openOutputStream(uri)?.use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        } ?: return false
        values.clear()
        values.put(MediaStore.Images.Media.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        true
    }.getOrDefault(false)
}
