package com.gosu.cloudtune.media

import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.gosu.cloudtune.MainActivity
import com.gosu.cloudtune.R
import com.gosu.cloudtune.ui.CloudTuneAppRuntime
import java.io.File
import java.util.concurrent.CopyOnWriteArraySet

object PlaybackSessionBridge {
    @Volatile var onSkipNext: (() -> Unit)? = null
    @Volatile var onSkipPrevious: (() -> Unit)? = null
    @Volatile var canSkipNext: Boolean = false
    @Volatile var canSkipPrevious: Boolean = false
    @Volatile var onQueueAvailabilityChanged: (() -> Unit)? = null

    fun updateAvailability(canNext: Boolean, canPrev: Boolean) {
        if (canSkipNext != canNext || canSkipPrevious != canPrev) {
            canSkipNext = canNext
            canSkipPrevious = canPrev
            onQueueAvailabilityChanged?.invoke()
        }
    }
}

data class ExtractedAudioMetadata(
    val title: String,
    val artist: String?,
    val album: String,
    val artworkBytes: ByteArray?
)

object AudioMetadataHelper {
    fun extract(
        localFile: File?,
        fallbackTitle: String,
        fallbackArtist: String? = null,
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
    private val mainHandler = Handler(Looper.getMainLooper())
    private val registeredListeners = CopyOnWriteArraySet<Player.Listener>()

    override fun onCreate() {
        super.onCreate()
        setMediaNotificationProvider(
            DefaultMediaNotificationProvider.Builder(applicationContext)
                .build()
                .apply {
                    setSmallIcon(R.drawable.ic_stat_cloudtune)
                }
        )

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
            override fun addListener(listener: Player.Listener) {
                registeredListeners.add(listener)
                super.addListener(listener)
            }

            override fun removeListener(listener: Player.Listener) {
                registeredListeners.remove(listener)
                super.removeListener(listener)
            }

            override fun getAvailableCommands(): Player.Commands {
                val builder = super.getAvailableCommands().buildUpon()
                if (PlaybackSessionBridge.canSkipNext) {
                    builder.add(Player.COMMAND_SEEK_TO_NEXT)
                    builder.add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
                } else {
                    builder.remove(Player.COMMAND_SEEK_TO_NEXT)
                    builder.remove(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
                }
                if (PlaybackSessionBridge.canSkipPrevious) {
                    builder.add(Player.COMMAND_SEEK_TO_PREVIOUS)
                    builder.add(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
                } else {
                    builder.remove(Player.COMMAND_SEEK_TO_PREVIOUS)
                    builder.remove(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
                }
                return builder.build()
            }

            override fun isCommandAvailable(command: Int): Boolean {
                return when (command) {
                    Player.COMMAND_SEEK_TO_NEXT,
                    Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> PlaybackSessionBridge.canSkipNext
                    Player.COMMAND_SEEK_TO_PREVIOUS,
                    Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> PlaybackSessionBridge.canSkipPrevious
                    else -> super.isCommandAvailable(command)
                }
            }

            override fun hasNextMediaItem(): Boolean = PlaybackSessionBridge.canSkipNext

            override fun hasPreviousMediaItem(): Boolean = PlaybackSessionBridge.canSkipPrevious

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

        PlaybackSessionBridge.onQueueAvailabilityChanged = {
            mainHandler.post {
                val cmds = forwardingPlayer.availableCommands
                for (listener in registeredListeners) {
                    listener.onAvailableCommandsChanged(cmds)
                }
            }
        }

        val sessionActivityIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val sessionPendingIntent = PendingIntent.getActivity(
            this,
            0,
            sessionActivityIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        mediaSession = MediaSession.Builder(this, forwardingPlayer)
            .setSessionActivity(sessionPendingIntent)
            .build()
        CloudTuneAppRuntime.getOrCreate(applicationContext).bindSkipBridge()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = mediaSession

    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = mediaSession?.player
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0 || player.playbackState == Player.STATE_ENDED) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        PlaybackSessionBridge.onQueueAvailabilityChanged = null
        PlaybackSessionBridge.onSkipNext = null
        PlaybackSessionBridge.onSkipPrevious = null
        registeredListeners.clear()
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

    fun saveQrBitmapToGallery(context: Context, bitmap: Bitmap): Boolean {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "CloudTune_Tianyi_QR_${System.currentTimeMillis()}.png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/CloudTune")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = runCatching {
            resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
        }.getOrNull() ?: return false
        var published = false
        return try {
            val compressed = resolver.openOutputStream(uri)?.use { out ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            } ?: false
            if (!compressed) return false
            val publishValues = ContentValues().apply {
                put(MediaStore.Images.Media.IS_PENDING, 0)
            }
            published = resolver.update(uri, publishValues, null, null) > 0
            published
        } catch (_: Throwable) {
            false
        } finally {
            if (!published) {
                runCatching { resolver.delete(uri, null, null) }
            }
        }
    }
}
