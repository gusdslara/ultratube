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
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.hls.playlist.DefaultHlsPlaylistTracker
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
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

    /**
     * Paused/stopped with no Ultratube screen open: nothing to keep alive.
     * The service (and its notification) goes away instead of lingering as
     * an invisible background process.
     */
    private val idleStop = Runnable {
        val player = session?.player ?: return@Runnable
        if (!player.playWhenReady && uiVisible <= 0) stopAll()
    }

    private fun scheduleIdleStop(player: Player) {
        handler.removeCallbacks(idleStop)
        if (!player.playWhenReady || player.playbackState == Player.STATE_ENDED) handler.postDelayed(idleStop, IDLE_STOP_MS)
    }

    /** Stops playback, drops the queue and ends the service + notification. */
    internal fun stopAll() {
        handler.removeCallbacks(idleStop)
        handler.removeCallbacks(sleep); sleepAt = 0L
        session?.player?.let { it.stop(); it.clearMediaItems() }
        stopSelf()
    }

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
                    // Lives: one HLS rendition (<= 360p) and its audio group.
                    "/livevideo" -> Streams.live(id).first
                    "/liveaudio" -> Streams.live(id).second
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
            // twitch:// playlists are generated (ads removed) by [Twitch].
            .setMediaSourceFactory(UltratubeSourceFactory(this, DataSource.Factory { TwitchPlaylistDataSource(resolving.createDataSource()) }))
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
                    override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) = scheduleIdleStop(this@apply)
                    override fun onPlaybackStateChanged(playbackState: Int) = scheduleIdleStop(this@apply)
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
        // Play/Pause · Next · Stop, plus the Wear OS Ongoing Activity chip.
        setMediaNotificationProvider(PlaybackNotification(this))
    }

    override fun onStartCommand(intent: android.content.Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopAll()
            return START_NOT_STICKY
        }
        return super.onStartCommand(intent, flags, startId)
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo) = session

    /**
     * The user closed Ultratube (swiped it away from recents): stop the music
     * and the process with it. Leaving with the crown/home button keeps
     * playing, with the Ongoing Activity chip on the watch face to get back.
     */
    override fun onTaskRemoved(rootIntent: android.content.Intent?) = stopAll()

    override fun onDestroy() {
        handler.removeCallbacks(sleep)
        handler.removeCallbacks(idleStop)
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
        const val ACTION_STOP = "app.ultratube.media.STOP"
        private const val IDLE_STOP_MS = 5 * 60_000L

        /** Ultratube screens currently on screen (activities call [uiStarted]/[uiStopped]). */
        @Volatile private var uiVisible = 0
        fun uiStarted() { uiVisible++ }
        fun uiStopped() { uiVisible = (uiVisible - 1).coerceAtLeast(0) }

        /** Closes playback for good (used when the user exits the app). */
        fun stop(context: Context) {
            if (instance == null) return
            context.startService(android.content.Intent(context, PlaybackService::class.java).setAction(ACTION_STOP))
        }
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
    // A live may add no segments for a while (blocked ad break with no clean
    // backup, slow encoder): tolerate ~30 target durations instead of 3.5
    // before declaring the playlist stuck. An ended broadcast still fails
    // fast, because Twitch/YouTube then answer the refresh with 404.
    private val hls = HlsMediaSource.Factory(dataSource).setAllowChunklessPreparation(true)
        .setPlaylistTrackerFactory { factory, policy, parser -> DefaultHlsPlaylistTracker(factory, policy, parser, 30.0) }

    override fun createMediaSource(mediaItem: MediaItem): MediaSource {
        val uri = mediaItem.localConfiguration?.uri
        if (uri?.scheme == "twitch") return hls.createMediaSource(mediaItem)
        if (uri?.scheme == PlaybackService.SCHEME && uri.path == "/live") {
            val liveId = uri.host ?: ""
            val audio = hls.createMediaSource(mediaItem.buildUpon().setUri("${PlaybackService.SCHEME}://$liveId/liveaudio").build())
            if (uri.getQueryParameter("v") != "1") return audio
            val video = hls.createMediaSource(mediaItem.buildUpon().setUri("${PlaybackService.SCHEME}://$liveId/livevideo").build())
            return MergingMediaSource(true, true, video, audio)
        }
        if (uri?.scheme != PlaybackService.SCHEME || uri.getQueryParameter("v") != "1") return default.createMediaSource(mediaItem)
        val id = uri.host ?: ""
        // Keep the original item (id + metadata) on both parts; only the URI differs.
        val video = progressive.createMediaSource(mediaItem.buildUpon().setUri("${PlaybackService.SCHEME}://$id/video").build())
        val audio = progressive.createMediaSource(mediaItem.buildUpon().setUri("${PlaybackService.SCHEME}://$id/audio").build())
        return MergingMediaSource(true, true, video, audio)
    }

    override fun setDrmSessionManagerProvider(provider: DrmSessionManagerProvider) = apply {
        default.setDrmSessionManagerProvider(provider); progressive.setDrmSessionManagerProvider(provider); hls.setDrmSessionManagerProvider(provider)
    }

    override fun setLoadErrorHandlingPolicy(policy: LoadErrorHandlingPolicy) = apply {
        default.setLoadErrorHandlingPolicy(policy); progressive.setLoadErrorHandlingPolicy(policy); hls.setLoadErrorHandlingPolicy(policy)
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

    private val live = ConcurrentHashMap<String, Pair<Pair<String, String>, Long>>()

    /** (video rendition playlist, audio playlist) of a live; same URL when muxed. */
    @Synchronized
    fun live(videoId: String): Pair<String, String> {
        check(videoId)
        live[videoId]?.takeIf { System.currentTimeMillis() - it.second < TTL }?.let { return it.first }
        val r = Catalog.resolve("https://www.youtube.com/watch?v=$videoId", true, WATCH_MAX_HEIGHT)
        val stream = r.getString("stream")
        val pair = stream to (r.optString("audio").ifBlank { stream })
        live[videoId] = pair to System.currentTimeMillis()
        return pair
    }

    fun forget(mediaId: String) {
        audio.remove(mediaId); video.remove(mediaId); live.remove(mediaId)
        if (mediaId.startsWith("twitch:")) Twitch.forget(mediaId.removePrefix("twitch:"))
    }
}

object Playback {
    fun connect(context: Context, ready: (MediaController) -> Unit) =
        MediaController.Builder(context, SessionToken(context, ComponentName(context, PlaybackService::class.java))).buildAsync().also { future ->
            future.addListener({ if (!future.isCancelled) runCatching { ready(future.get()) } }, java.util.concurrent.Executor { Handler(Looper.getMainLooper()).post(it) })
        }

    private fun videoId(url: String) = Uri.parse(url).let { it.getQueryParameter("v") ?: it.lastPathSegment ?: "" }

    /** Queue entry for a YouTube catalog item; [video] streams picture as well. */
    fun online(item: JSONObject, video: Boolean = false): MediaItem {
        if (item.optString("type") == "twitch") return twitch(item, video)
        val id = videoId(item.getString("url"))
        val live = if (item.optBoolean("live")) "/live" else ""
        val uri = Uri.parse("${PlaybackService.SCHEME}://$id$live" + if (video) "?v=1" else "")
        val cover = item.optString("coverHd").ifBlank { item.optString("cover") }
        return item(id, uri, item.optString("title"), item.optString("artist"), cover, video)
    }

    /** Twitch live; [video] at watch quality (<= 360p), otherwise audio only. */
    fun twitch(item: JSONObject, video: Boolean = true): MediaItem {
        val login = item.getString("login").lowercase()
        val uri = Uri.parse("twitch://$login?q=" + if (video) "360p" else "audio_only")
        return item("twitch:$login", uri, item.optString("title"), item.optString("artist", login), item.optString("cover"), video)
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

/** Serves `twitch://<login>?q=<quality>` as an ad-free media playlist; delegates the rest. */
@UnstableApi
private class TwitchPlaylistDataSource(private val fallback: DataSource) : BaseDataSource(true) {
    private var bytes: ByteArray? = null
    private var offset = 0
    private var left = 0
    private var uri: Uri? = null
    private var delegating = false

    override fun open(dataSpec: DataSpec): Long {
        if (dataSpec.uri.scheme != "twitch") {
            delegating = true
            return fallback.open(dataSpec)
        }
        transferInitializing(dataSpec)
        uri = dataSpec.uri
        val text = try {
            Twitch.playlist(dataSpec.uri.host ?: "", dataSpec.uri.getQueryParameter("q") ?: "360p")
        } catch (e: java.io.IOException) {
            throw e
        } catch (e: Exception) {
            throw java.io.IOException(e.message ?: "Twitch indisponivel", e)
        }
        val data = text.toByteArray()
        bytes = data
        offset = dataSpec.position.toInt().coerceIn(0, data.size)
        left = data.size - offset
        transferStarted(dataSpec)
        return left.toLong()
    }

    override fun read(buffer: ByteArray, off: Int, length: Int): Int {
        if (delegating) return fallback.read(buffer, off, length)
        if (length == 0) return 0
        if (left == 0) return C.RESULT_END_OF_INPUT
        val n = minOf(length, left)
        System.arraycopy(bytes!!, offset, buffer, off, n)
        offset += n; left -= n
        bytesTransferred(n)
        return n
    }

    override fun getUri(): Uri? = if (delegating) fallback.uri else uri

    override fun close() {
        if (delegating) { delegating = false; fallback.close(); return }
        if (bytes != null) { bytes = null; transferEnded() }
        uri = null
    }
}
