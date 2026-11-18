package app.ultratube.media

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.drm.DrmSessionManagerProvider
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Media3 session for the watch (and any native surface).
 *
 * Queue items use `ultratube://<videoId>` (audio) or `ultratube://<videoId>?v=1`
 * (video). Stream URLs are resolved just in time on ExoPlayer's loader
 * threads, so a long queue costs one extraction per played item and expired
 * URLs refresh automatically. Video items merge a light video-only track with
 * the audio track, which is how YouTube serves everything but legacy 360p.
 */
@UnstableApi
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null
    private val handler = Handler(Looper.getMainLooper())
    private val sleep = Runnable { session?.player?.pause(); sleepAt = 0L }

    override fun onCreate() {
        super.onCreate()
        instance = this
        val http = DefaultHttpDataSource.Factory()
            .setUserAgent("Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/131.0 Mobile Safari/537.36")
            .setAllowCrossProtocolRedirects(true)
        val resolving = ResolvingDataSource.Factory(DefaultDataSource.Factory(this, http)) { spec ->
            if (spec.uri.scheme != SCHEME) return@Factory spec
            val id = spec.uri.host ?: ""
            val url = try {
                when (spec.uri.path) {
                    "/video" -> Streams.video(id).first
                    "/audio" -> Streams.video(id).second
                    else -> Streams.audio(id)
                }
            } catch (error: java.io.IOException) {
                throw error
            } catch (error: Exception) {
                // Extraction failures (blocked/age-gated video) are ordinary load errors.
                throw java.io.IOException(error.message ?: "Vídeo indisponível", error)
            }
            spec.withUri(Uri.parse(url))
        }
        val player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(UltratubeSourceFactory(this, resolving))
            .build().apply {
                setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
                setHandleAudioBecomingNoisy(true)
                // Keeps CPU and Wi-Fi awake while the screen is off or the watch is locked.
                setWakeMode(C.WAKE_MODE_NETWORK)
                addListener(object : Player.Listener {
                    private var failures = 0
                    override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                        // A stale URL or a blocked video must not end the whole queue:
                        // skip it (deferred, outside the error dispatch), up to 15 in a row.
                        currentMediaItem?.mediaId?.let(Streams::forget)
                        if (++failures > 15) return
                        handler.post {
                            if (hasNextMediaItem()) { seekToNextMediaItem(); prepare(); play() }
                        }
                    }
                    override fun onIsPlayingChanged(isPlaying: Boolean) { if (isPlaying) failures = 0 }
                })
            }
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        session = MediaSession.Builder(this, player).setCallback(object : MediaSession.Callback {
            // Controllers may strip local configuration; rebuild URIs from the request metadata.
            override fun onAddMediaItems(mediaSession: MediaSession, controller: MediaSession.ControllerInfo, mediaItems: MutableList<MediaItem>): ListenableFuture<MutableList<MediaItem>> =
                Futures.immediateFuture(mediaItems.map { item ->
                    item.buildUpon().setUri(item.requestMetadata.mediaUri ?: item.localConfiguration?.uri ?: Uri.parse("$SCHEME://${item.mediaId}")).build()
                }.toMutableList())
        }).apply { launch?.let(::setSessionActivity) }.build()
        setMediaNotificationProvider(DefaultMediaNotificationProvider.Builder(this).build().apply {
            setSmallIcon(R.drawable.ic_ultratube_notification)
        })
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo) = session

    override fun onTaskRemoved(rootIntent: android.content.Intent?) {
        val player = session?.player
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0) stopSelf()
    }

    override fun onDestroy() {
        handler.removeCallbacks(sleep)
        instance = null
        session?.run { player.release(); release() }; session = null
        super.onDestroy()
    }

    internal fun setSleep(minutes: Int) {
        handler.removeCallbacks(sleep)
        sleepAt = if (minutes > 0) System.currentTimeMillis() + minutes * 60_000L else 0L
        if (minutes > 0) handler.postDelayed(sleep, minutes * 60_000L)
    }

    companion object {
        const val SCHEME = "ultratube"
        @Volatile private var instance: PlaybackService? = null
        /** Wall-clock time when the sleep timer pauses playback, or 0. */
        @Volatile var sleepAt = 0L; private set
        fun sleepTimer(minutes: Int) { Handler(Looper.getMainLooper()).post { instance?.setSleep(minutes) } }
    }
}

/** Builds merged video+audio sources for `?v=1` items; everything else is default. */
@UnstableApi
private class UltratubeSourceFactory(context: Context, dataSource: DataSource.Factory) : MediaSource.Factory {
    private val default = DefaultMediaSourceFactory(context).setDataSourceFactory(dataSource)
    private val progressive = ProgressiveMediaSource.Factory(dataSource)

    override fun createMediaSource(mediaItem: MediaItem): MediaSource {
        val uri = mediaItem.localConfiguration?.uri
        if (uri?.scheme != PlaybackService.SCHEME || uri.getQueryParameter("v") != "1") return default.createMediaSource(mediaItem)
        val id = uri.host ?: ""
        // Keep the original item (id + metadata) on both parts; only the URI differs.
        val video = progressive.createMediaSource(mediaItem.buildUpon().setUri("${PlaybackService.SCHEME}://$id/video").build())
        val audio = progressive.createMediaSource(mediaItem.buildUpon().setUri("${PlaybackService.SCHEME}://$id/audio").build())
        return MergingMediaSource(true, true, video, audio)
    }

    override fun setDrmSessionManagerProvider(provider: DrmSessionManagerProvider) = apply {
        default.setDrmSessionManagerProvider(provider); progressive.setDrmSessionManagerProvider(provider)
    }

    override fun setLoadErrorHandlingPolicy(policy: LoadErrorHandlingPolicy) = apply {
        default.setLoadErrorHandlingPolicy(policy); progressive.setLoadErrorHandlingPolicy(policy)
    }

    override fun getSupportedTypes(): IntArray = default.supportedTypes
}

/** Short-lived cache of resolved stream URLs (YouTube URLs expire after ~6 h). */
internal object Streams {
    private val audio = ConcurrentHashMap<String, Pair<String, Long>>()
    private val video = ConcurrentHashMap<String, Pair<Pair<String, String>, Long>>()
    private const val TTL = 3 * 60 * 60 * 1000L
    /** Watch screens are ~432 px: 360p is sharp and cheap on battery and data. */
    private const val WATCH_MAX_HEIGHT = 360

    private fun check(id: String) = require(Regex("^[a-zA-Z0-9_-]{11}$").matches(id)) { "ID de vídeo inválido" }

    fun audio(videoId: String): String {
        check(videoId)
        audio[videoId]?.takeIf { System.currentTimeMillis() - it.second < TTL }?.let { return it.first }
        val stream = Catalog.resolve("https://www.youtube.com/watch?v=$videoId", false).getString("stream")
        audio[videoId] = stream to System.currentTimeMillis()
        return stream
    }

    /** (video URL, audio URL); for muxed streams both point to the same file. */
    @Synchronized
    fun video(videoId: String): Pair<String, String> {
        check(videoId)
        video[videoId]?.takeIf { System.currentTimeMillis() - it.second < TTL }?.let { return it.first }
        val r = Catalog.resolve("https://www.youtube.com/watch?v=$videoId", true, WATCH_MAX_HEIGHT)
        val stream = r.getString("stream")
        val pair = stream to (r.optString("audio").ifBlank { stream })
        video[videoId] = pair to System.currentTimeMillis()
        return pair
    }

    fun forget(mediaId: String) { audio.remove(mediaId); video.remove(mediaId) }
}

object Playback {
    fun connect(context: Context, ready: (MediaController) -> Unit) =
        MediaController.Builder(context, SessionToken(context, ComponentName(context, PlaybackService::class.java))).buildAsync().also { future ->
            future.addListener({ if (!future.isCancelled) runCatching { ready(future.get()) } }, java.util.concurrent.Executor { Handler(Looper.getMainLooper()).post(it) })
        }

    private fun videoId(url: String) = Uri.parse(url).let { it.getQueryParameter("v") ?: it.lastPathSegment ?: "" }

    /** Queue entry for a YouTube catalog item; [video] streams picture as well. */
    fun online(item: JSONObject, video: Boolean = false): MediaItem {
        val id = videoId(item.getString("url"))
        val uri = Uri.parse("${PlaybackService.SCHEME}://$id" + if (video) "?v=1" else "")
        val cover = item.optString("coverHd").ifBlank { item.optString("cover") }
        return item(id, uri, item.optString("title"), item.optString("artist"), cover, video)
    }

    /** Queue entry for a finished download from [Downloads]. */
    fun offline(job: JSONObject): MediaItem {
        val file = File(job.getString("file"))
        val cover = job.optString("coverFile").takeIf { it.isNotBlank() }?.let { Uri.fromFile(File(it)).toString() } ?: job.optString("cover")
        return item(videoId(job.optString("url")).ifBlank { job.getString("id") }, Uri.fromFile(file), job.optString("title"), job.optString("artist"), cover, job.optBoolean("video"))
    }

    private fun item(id: String, uri: Uri, title: String, artist: String, cover: String, video: Boolean): MediaItem {
        val metadata = MediaMetadata.Builder().setTitle(title).setArtist(artist)
            .setMediaType(if (video) MediaMetadata.MEDIA_TYPE_VIDEO else MediaMetadata.MEDIA_TYPE_MUSIC)
            .apply { if (cover.isNotBlank()) setArtworkUri(Uri.parse(cover)) }.build()
        return MediaItem.Builder().setMediaId(id).setUri(uri).setMediaMetadata(metadata)
            .setRequestMetadata(MediaItem.RequestMetadata.Builder().setMediaUri(uri).build()).build()
    }

    fun isVideo(item: MediaItem?) = item?.mediaMetadata?.mediaType == MediaMetadata.MEDIA_TYPE_VIDEO

    /** Replaces the queue and starts at [index]. */
    fun playAll(player: Player, items: List<MediaItem>, index: Int) {
        if (items.isEmpty()) return
        player.setMediaItems(items, index.coerceIn(0, items.lastIndex), 0L)
        player.prepare(); player.play()
    }

    /** Legacy single-item entry used by the instrumented smoke test. */
    fun play(player: Player, track: JSONObject) = playAll(player, listOf(online(track)), 0)

    fun state(player: Player) = JSONObject().put("playing", player.isPlaying)
        .put("position", player.currentPosition / 1000.0).put("duration", player.duration.coerceAtLeast(0) / 1000.0)
        .put("title", player.mediaMetadata.title?.toString() ?: "").put("artist", player.mediaMetadata.artist?.toString() ?: "")
        .put("cover", player.mediaMetadata.artworkUri?.toString() ?: "")
        .put("error", player.playerError?.localizedMessage ?: "")
}
