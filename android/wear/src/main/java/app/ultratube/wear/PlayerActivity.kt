package app.ultratube.wear

import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.AudioManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.view.GestureDetector
import android.view.Gravity
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaController
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import androidx.recyclerview.widget.RecyclerView
import androidx.viewpager2.widget.ViewPager2
import app.ultratube.media.Downloads
import app.ultratube.media.Playback
import app.ultratube.media.PlaybackService
import java.util.concurrent.Executors
import kotlin.math.abs

/**
 * Full-screen watch player. Three horizontal pages:
 * controls (left) · video/artwork (centre) · up next (right).
 * Back returns to the centre page first, then leaves; playback continues.
 */
@UnstableApi
class PlayerActivity : ComponentActivity() {
    companion object {
        const val EXTRA_SHORTS = "shorts"
        private const val PAGE_CONTROLS = 0
        private const val PAGE_NOW = 1
        private const val PAGE_QUEUE = 2
        fun open(context: Context, shorts: Boolean = false) =
            context.startActivity(Intent(context, PlayerActivity::class.java).putExtra(EXTRA_SHORTS, shorts).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP))
    }

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var controller: MediaController? = null
    private var connection: com.google.common.util.concurrent.ListenableFuture<MediaController>? = null
    private lateinit var pager: ViewPager2
    private lateinit var dots: LinearLayout
    private var shorts = false
    private var zoom = false
    private val audio by lazy { getSystemService(AudioManager::class.java) }

    // Centre page.
    private lateinit var playerView: PlayerView
    private lateinit var artwork: ImageView
    private lateinit var nowTitle: TextView
    private lateinit var nowArtist: TextView
    private lateinit var nowOverlay: LinearLayout
    private lateinit var flash: ImageView
    private lateinit var spinner: View
    private lateinit var ringNow: RingProgressView
    private var shownArt: String? = null

    // Controls page.
    private lateinit var ringControls: RingProgressView
    private lateinit var ctlTitle: TextView
    private lateinit var ctlTime: TextView
    private lateinit var ctlPlay: ImageButton
    private lateinit var ctlMode: ImageButton
    private lateinit var ctlFit: ImageButton

    // Queue page.
    private lateinit var queueList: LinearLayout

    private fun dp(v: Int) = (resources.displayMetrics.density * v).toInt()

    private val tick = object : Runnable {
        override fun run() { refresh(); main.postDelayed(this, 500) }
    }
    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            refresh()
            if (events.contains(Player.EVENT_MEDIA_ITEM_TRANSITION) || events.contains(Player.EVENT_TIMELINE_CHANGED)) buildQueue()
        }
    }

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        shorts = intent.getBooleanExtra(EXTRA_SHORTS, false)
        zoom = shorts
        val root = FrameLayout(this).apply { setBackgroundColor(Ut.BG) }
        pager = ViewPager2(this).apply {
            offscreenPageLimit = 2
            adapter = Pages(listOf(::controlsPage, ::nowPage, ::queuePage))
            registerOnPageChangeCallback(object : ViewPager2.OnPageChangeCallback() {
                override fun onPageSelected(position: Int) { updateDots(position); if (position == PAGE_QUEUE) buildQueue() }
            })
        }
        root.addView(pager, FrameLayout.LayoutParams(-1, -1))
        // Page dots on a dark pill so they stay legible over lists and video.
        dots = LinearLayout(this).apply {
            gravity = Gravity.CENTER; setPadding(dp(6), 0, dp(6), 0)
            background = GradientDrawable().apply { setColor(0xCC000000.toInt()); cornerRadius = dp(8).toFloat() }
        }
        root.addView(dots, FrameLayout.LayoutParams(-2, dp(14), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply { bottomMargin = dp(6) })
        setContentView(root)
        pager.setCurrentItem(PAGE_NOW, false)
        updateDots(PAGE_NOW)

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (pager.currentItem != PAGE_NOW) pager.currentItem = PAGE_NOW else finish()
            }
        })
        connection = Playback.connect(this) { c ->
            controller = c
            c.addListener(listener)
            c.trackSelectionParameters = c.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, false).build()
            playerView.player = c
            applyFit()
            refresh(); buildQueue()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        shorts = intent.getBooleanExtra(EXTRA_SHORTS, false)
        zoom = shorts
        applyFit()
        pager.setCurrentItem(PAGE_NOW, false)
    }

    // -------------------------------------------------------------- pages

    private inner class Pages(val builders: List<() -> View>) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        private val views = builders.map { it() }
        override fun getItemCount() = views.size
        override fun getItemViewType(position: Int) = position
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = object : RecyclerView.ViewHolder(views[viewType].apply {
            layoutParams = RecyclerView.LayoutParams(-1, -1)
        }) {}
        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {}
    }

    private fun nowPage(): View {
        val page = FrameLayout(this).apply { setBackgroundColor(Ut.BG) }
        artwork = ImageView(this).apply { scaleType = ImageView.ScaleType.CENTER_CROP; alpha = 0.55f; clipToOutline = true; background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Ut.SURFACE) } }
        page.addView(artwork, FrameLayout.LayoutParams(-1, -1))
        playerView = PlayerView(this).apply {
            useController = false
            setShutterBackgroundColor(Color.BLACK)
            setKeepContentOnPlayerReset(true)
            visibility = View.GONE
        }
        page.addView(playerView, FrameLayout.LayoutParams(-1, -1))
        nowOverlay = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER; setPadding(dp(30), 0, dp(30), 0) }
        nowTitle = TextView(this).apply { textSize = 16f; typeface = Typeface.DEFAULT_BOLD; setTextColor(Ut.TEXT); gravity = Gravity.CENTER; maxLines = 2; ellipsize = TextUtils.TruncateAt.END; setShadowLayer(8f, 0f, 0f, Color.BLACK) }
        nowArtist = TextView(this).apply { textSize = 12f; setTextColor(Ut.TEXT2); gravity = Gravity.CENTER; maxLines = 1; ellipsize = TextUtils.TruncateAt.END; setShadowLayer(8f, 0f, 0f, Color.BLACK) }
        nowOverlay.addView(nowTitle); nowOverlay.addView(nowArtist)
        page.addView(nowOverlay, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM).apply { bottomMargin = dp(46) })
        flash = ImageView(this).apply { alpha = 0f; background = Ut.circle(0x99000000.toInt()); setPadding(dp(16), dp(16), dp(16), dp(16)) }
        page.addView(flash, FrameLayout.LayoutParams(dp(64), dp(64), Gravity.CENTER))
        spinner = android.widget.ProgressBar(this).apply { indeterminateTintList = ColorStateList.valueOf(Ut.RED); visibility = View.GONE }
        page.addView(spinner, FrameLayout.LayoutParams(dp(40), dp(40), Gravity.CENTER))
        ringNow = RingProgressView(this)
        page.addView(ringNow, FrameLayout.LayoutParams(-1, -1))

        val gestures = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent) = true
            override fun onSingleTapConfirmed(e: MotionEvent): Boolean { togglePlay(); return true }
            override fun onDoubleTap(e: MotionEvent): Boolean {
                if (Playback.isVideo(controller?.currentMediaItem)) { zoom = !zoom; applyFit(); toast(if (zoom) "Preencher a tela" else "Vídeo inteiro") }
                return true
            }
            override fun onFling(e1: MotionEvent?, e2: MotionEvent, vx: Float, vy: Float): Boolean {
                if (e1 == null || abs(vy) < abs(vx) || abs(e2.y - e1.y) < dp(40)) return false
                // Vertical swipe: next/previous (Shorts style); also works for any queue.
                controller?.let { if (vy < 0) { if (it.hasNextMediaItem()) it.seekToNextMediaItem() } else it.seekToPreviousMediaItem() }
                return true
            }
        })
        page.setOnTouchListener { _, event -> gestures.onTouchEvent(event); true }
        page.isFocusable = true
        page.setOnGenericMotionListener { _, e -> rotaryVolume(e) }
        return page
    }

    private fun controlsPage(): View {
        val page = FrameLayout(this).apply { setBackgroundColor(Ut.BG) }
        ringControls = RingProgressView(this)
        page.addView(ringControls, FrameLayout.LayoutParams(-1, -1))
        // Sized for the round screen: every row stays inside the circle's chord.
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER; setPadding(dp(8), dp(14), dp(8), dp(22)) }
        ctlTitle = TextView(this).apply { textSize = 13f; typeface = Typeface.DEFAULT_BOLD; setTextColor(Ut.TEXT); gravity = Gravity.CENTER; isSingleLine = true; ellipsize = TextUtils.TruncateAt.MARQUEE; marqueeRepeatLimit = -1; isSelected = true }
        ctlTime = TextView(this).apply { textSize = 11f; setTextColor(Ut.TEXT2); gravity = Gravity.CENTER }
        col.addView(ctlTitle, LinearLayout.LayoutParams(dp(132), -2))
        col.addView(ctlTime)
        val main = LinearLayout(this).apply { gravity = Gravity.CENTER; setPadding(0, dp(6), 0, dp(6)) }
        main.addView(round(R.drawable.ic_prev_fill, "Anterior", 40, Ut.SURFACE) { controller?.seekToPreviousMediaItem() })
        ctlPlay = round(R.drawable.ic_play_fill, "Reproduzir", 56, Ut.RED) { togglePlay() }
        main.addView(ctlPlay, LinearLayout.LayoutParams(dp(56), dp(56)).apply { marginStart = dp(8); marginEnd = dp(8) })
        main.addView(round(R.drawable.ic_next_fill, "Próximo", 40, Ut.SURFACE) { controller?.let { if (it.hasNextMediaItem()) it.seekToNextMediaItem() } })
        col.addView(main)
        val second = LinearLayout(this).apply { gravity = Gravity.CENTER }
        second.addView(round(R.drawable.ic_rewind, "Voltar 10 segundos", 34, Ut.SURFACE) { seekBy(-10_000) }, sp(34))
        second.addView(round(R.drawable.ic_vol_down, "Diminuir volume", 34, Ut.SURFACE) { volume(-1) }, sp(34))
        second.addView(round(R.drawable.ic_vol_up, "Aumentar volume", 34, Ut.SURFACE) { volume(1) }, sp(34))
        second.addView(round(R.drawable.ic_forward, "Avançar 10 segundos", 34, Ut.SURFACE) { seekBy(10_000) }, sp(34))
        col.addView(second)
        // Bottom row sits where the circle narrows: icon buttons, not text chips.
        val third = LinearLayout(this).apply { gravity = Gravity.CENTER; setPadding(0, dp(6), 0, 0) }
        ctlMode = round(R.drawable.ic_headphones, "Só áudio", 34, Ut.SURFACE2) { toggleVideo() }
        ctlFit = round(R.drawable.ic_fill, "Preencher a tela", 34, Ut.SURFACE2) { zoom = !zoom; applyFit(); refresh() }
        third.addView(ctlMode, sp(34)); third.addView(ctlFit, sp(34))
        col.addView(third)
        page.addView(col, FrameLayout.LayoutParams(-1, -1))
        page.isFocusable = true
        page.setOnGenericMotionListener { _, e -> rotaryVolume(e) }
        return page
    }

    private fun queuePage(): View {
        val scroll = ScrollView(this).apply { setBackgroundColor(Ut.BG); isFillViewport = true; isVerticalScrollBarEnabled = false }
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(22), dp(28), dp(22), dp(64)) }
        col.addView(TextView(this).apply { text = "A seguir"; textSize = 15f; typeface = Typeface.DEFAULT_BOLD; setTextColor(Ut.TEXT); gravity = Gravity.CENTER })
        val actions = LinearLayout(this).apply { gravity = Gravity.CENTER; setPadding(0, dp(8), 0, dp(8)) }
        actions.addView(chip("Baixar") { download() })
        actions.addView(chip("Timer") { timer() }, LinearLayout.LayoutParams(-2, dp(32)).apply { marginStart = dp(6) })
        col.addView(actions)
        queueList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        col.addView(queueList, LinearLayout.LayoutParams(-1, -2))
        scroll.addView(col)
        scroll.setOnGenericMotionListener { _, e ->
            if (e.action == MotionEvent.ACTION_SCROLL && e.isFromSource(InputDevice.SOURCE_ROTARY_ENCODER)) {
                scroll.smoothScrollBy(0, (-e.getAxisValue(MotionEvent.AXIS_SCROLL) * dp(56)).toInt()); true
            } else false
        }
        return scroll
    }

    // -------------------------------------------------------------- widgets

    private fun sp(size: Int) = LinearLayout.LayoutParams(dp(size), dp(size)).apply { marginStart = dp(4); marginEnd = dp(4) }

    private fun round(icon: Int, description: String, size: Int, fill: Int, action: () -> Unit) = ImageButton(this).apply {
        setImageResource(icon); imageTintList = ColorStateList.valueOf(Color.WHITE); contentDescription = description
        background = Ut.circle(fill); scaleType = ImageView.ScaleType.FIT_CENTER
        val pad = dp(size) / 4; setPadding(pad, pad, pad, pad)
        layoutParams = LinearLayout.LayoutParams(dp(size), dp(size))
        setOnClickListener { action() }
    }

    private fun chip(label: String, action: () -> Unit) = TextView(this).apply {
        text = label; textSize = 12f; setTextColor(Ut.TEXT); gravity = Gravity.CENTER; typeface = Typeface.DEFAULT_BOLD
        setPadding(dp(14), 0, dp(14), 0); minWidth = dp(64); height = dp(32)
        background = Ut.pill(Ut.SURFACE, dp(16).toFloat()); isClickable = true; isFocusable = true
        layoutParams = LinearLayout.LayoutParams(-2, dp(32))
        setOnClickListener { action() }
    }

    private fun updateDots(selected: Int) {
        dots.removeAllViews()
        for (i in 0 until 3) dots.addView(View(this).apply {
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(if (i == selected) Ut.TEXT else 0x55FFFFFF) }
        }, LinearLayout.LayoutParams(dp(if (i == selected) 7 else 5), dp(if (i == selected) 7 else 5)).apply { marginStart = dp(3); marginEnd = dp(3) })
    }

    // -------------------------------------------------------------- actions

    private fun togglePlay() {
        val c = controller ?: return
        if (c.isPlaying) c.pause() else { if (c.playbackState == Player.STATE_IDLE) c.prepare(); if (c.playbackState == Player.STATE_ENDED) c.seekToDefaultPosition(); c.play() }
        flash.setImageResource(if (c.isPlaying) R.drawable.ic_pause_fill else R.drawable.ic_play_fill)
        flash.animate().cancel(); flash.alpha = 1f; flash.animate().alpha(0f).setStartDelay(450).setDuration(250).start()
    }

    private fun seekBy(ms: Long) = controller?.let {
        if (it.isCurrentMediaItemLive) return@let
        it.seekTo((it.currentPosition + ms).coerceIn(0, it.duration.coerceAtLeast(0)))
    }

    private fun volume(direction: Int) = audio.adjustStreamVolume(AudioManager.STREAM_MUSIC,
        if (direction > 0) AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI)

    private fun rotaryVolume(e: MotionEvent): Boolean {
        if (e.action != MotionEvent.ACTION_SCROLL || !e.isFromSource(InputDevice.SOURCE_ROTARY_ENCODER)) return false
        volume(if (-e.getAxisValue(MotionEvent.AXIS_SCROLL) > 0) 1 else -1)
        return true
    }

    /** Switches the current item between video and audio-only, keeping position. */
    private fun toggleVideo() {
        val c = controller ?: return
        val item = c.currentMediaItem ?: return
        val uri = item.requestMetadata.mediaUri ?: return
        val video = !Playback.isVideo(item)
        val newUri = when {
            // Twitch: switch rendition (watch-sized video or the audio-only feed).
            uri.scheme == "twitch" -> Uri.parse("twitch://${uri.host}?q=" + if (video) "360p" else "audio_only")
            uri.scheme != PlaybackService.SCHEME -> return toast("Download local")
            // YouTube live keeps its /live path.
            uri.path == "/live" -> Uri.parse("${PlaybackService.SCHEME}://${uri.host}/live" + if (video) "?v=1" else "")
            else -> Uri.parse("${PlaybackService.SCHEME}://${uri.host}" + if (video) "?v=1" else "")
        }
        val replaced = item.buildUpon().setUri(newUri)
            .setRequestMetadata(item.requestMetadata.buildUpon().setMediaUri(newUri).build())
            .setMediaMetadata(item.mediaMetadata.buildUpon().setMediaType(if (video) androidx.media3.common.MediaMetadata.MEDIA_TYPE_VIDEO else androidx.media3.common.MediaMetadata.MEDIA_TYPE_MUSIC).build())
            .build()
        val index = c.currentMediaItemIndex
        val position = c.currentPosition
        c.replaceMediaItem(index, replaced)
        c.seekTo(index, position)
        c.prepare(); c.play()
        toast(if (video) "Vídeo" else "Só áudio")
    }

    private fun applyFit() {
        playerView.resizeMode = if (zoom) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
    }

    private fun download() {
        val c = controller ?: return
        val item = c.currentMediaItem ?: return
        val uri = item.requestMetadata.mediaUri
        if (uri?.scheme != PlaybackService.SCHEME) return toast("Já está no relógio")
        Downloads.enqueue(this, "https://www.youtube.com/watch?v=${uri.host}", item.mediaMetadata.title?.toString().orEmpty(),
            item.mediaMetadata.artist?.toString().orEmpty(), item.mediaMetadata.artworkUri?.toString().orEmpty(), false, 0)
        toast("Baixando no relógio")
    }

    private fun timer() {
        val options = intArrayOf(0, 15, 30, 60)
        val next = options[(options.indexOfFirst { it * 60_000L >= PlaybackService.sleepAt - System.currentTimeMillis() }.coerceAtLeast(0) + 1) % options.size]
        PlaybackService.sleepTimer(next)
        toast(if (next == 0) "Timer desligado" else "Pausa em $next min")
    }

    private fun toast(text: String) = Toast.makeText(this, text, Toast.LENGTH_SHORT).show()

    // -------------------------------------------------------------- state

    private fun refresh() {
        val c = controller ?: return
        val item = c.currentMediaItem
        val video = Playback.isVideo(item)
        val meta = c.mediaMetadata
        val live = c.isCurrentMediaItemLive || item?.requestMetadata?.mediaUri?.let { it.scheme == "twitch" || it.path == "/live" } == true
        val duration = c.duration.takeIf { it > 0 && !live } ?: 0L
        // A live has no timeline: full ring instead of a stuck one.
        val progress = if (live) 1f else if (duration > 0) c.currentPosition.toFloat() / duration else 0f
        val buffered = if (duration > 0) c.bufferedPosition.toFloat() / duration else 0f
        ringNow.progress = progress; ringNow.buffered = buffered
        ringControls.progress = progress; ringControls.buffered = buffered

        playerView.visibility = if (video) View.VISIBLE else View.GONE
        artwork.visibility = if (video) View.GONE else View.VISIBLE
        // Title over video only while paused, so it never covers playback.
        nowOverlay.visibility = if (!video || !c.isPlaying) View.VISIBLE else View.GONE
        nowTitle.text = meta.title ?: "Nada tocando"
        nowArtist.text = c.playerError?.let { "Erro: ${it.localizedMessage ?: "falha de rede"}" } ?: meta.artist ?: ""
        nowArtist.setTextColor(if (c.playerError != null) Ut.ERROR else Ut.TEXT2)
        spinner.visibility = if (c.playbackState == Player.STATE_BUFFERING && c.playWhenReady) View.VISIBLE else View.GONE

        ctlTitle.text = meta.title ?: "Nada tocando"
        ctlTime.text = if (live) "● AO VIVO" else "${fmt(c.currentPosition)} / ${fmt(duration)}"
        ctlPlay.setImageResource(if (c.isPlaying || (c.playWhenReady && c.playbackState == Player.STATE_BUFFERING)) R.drawable.ic_pause_fill else R.drawable.ic_play_fill)
        ctlMode.setImageResource(if (video) R.drawable.ic_headphones else R.drawable.ic_video)
        ctlMode.contentDescription = if (video) "Só áudio" else "Assistir vídeo"
        ctlFit.visibility = if (video) View.VISIBLE else View.GONE
        ctlFit.setImageResource(if (zoom) R.drawable.ic_fit else R.drawable.ic_fill)
        ctlFit.contentDescription = if (zoom) "Vídeo inteiro" else "Preencher a tela"

        // Keep the screen awake only while a video is actually playing.
        if (video && c.isPlaying) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val art = meta.artworkUri?.toString()
        if (art != shownArt) { shownArt = art; loadArt(art) }
    }

    private fun buildQueue() {
        val c = controller ?: return
        if (!::queueList.isInitialized) return
        queueList.removeAllViews()
        if (c.mediaItemCount == 0) {
            queueList.addView(TextView(this).apply { text = "Fila vazia"; setTextColor(Ut.TEXT2); gravity = Gravity.CENTER })
            return
        }
        val start = (c.currentMediaItemIndex - 1).coerceAtLeast(0)
        for (i in start until minOf(c.mediaItemCount, start + 25)) {
            val item = c.getMediaItemAt(i)
            val current = i == c.currentMediaItemIndex
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL; setPadding(dp(12), dp(8), dp(12), dp(8)); minimumHeight = dp(48)
                background = Ut.pill(if (current) Ut.SURFACE2 else Ut.SURFACE, dp(14).toFloat()); isClickable = true
                setOnClickListener { c.seekToDefaultPosition(i); c.play(); pager.currentItem = PAGE_NOW }
            }
            row.addView(TextView(this).apply {
                text = (if (Playback.isVideo(item)) "▶ " else "♪ ") + (item.mediaMetadata.title ?: "")
                textSize = 13f; setTextColor(if (current) Ut.RED else Ut.TEXT); maxLines = 2; ellipsize = TextUtils.TruncateAt.END
                if (current) typeface = Typeface.DEFAULT_BOLD
            })
            item.mediaMetadata.artist?.let { a -> row.addView(TextView(this).apply { text = a; textSize = 11f; setTextColor(Ut.TEXT2); maxLines = 1 }) }
            queueList.addView(row, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) })
        }
    }

    private fun loadArt(url: String?) {
        if (url.isNullOrBlank()) { artwork.setImageDrawable(null); return }
        io.execute {
            val bitmap: Bitmap? = runCatching {
                val options = BitmapFactory.Options().apply { inSampleSize = 2 }
                if (url.startsWith("file:")) BitmapFactory.decodeFile(Uri.parse(url).path, options)
                else java.net.URL(url).openConnection().apply { connectTimeout = 10000; readTimeout = 10000 }.getInputStream().use { BitmapFactory.decodeStream(it, null, options) }
            }.getOrNull()
            main.post { if (!isDestroyed && shownArt == url) artwork.setImageBitmap(bitmap) }
        }
    }

    private fun fmt(ms: Long): String { val s = (ms / 1000).coerceAtLeast(0); return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s % 3600 / 60, s % 60) else "%d:%02d".format(s / 60, s % 60) }

    // -------------------------------------------------------------- lifecycle

    override fun onStart() {
        super.onStart()
        app.ultratube.media.PlaybackService.uiStarted()
        main.post(tick)
        // Screen back on: restore the picture.
        controller?.let { it.trackSelectionParameters = it.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, false).build() }
        if (::playerView.isInitialized) playerView.player = controller
    }

    override fun onStop() {
        main.removeCallbacks(tick)
        // Screen off / locked / left the app: keep audio, stop decoding video.
        controller?.let { it.trackSelectionParameters = it.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, true).build() }
        if (::playerView.isInitialized) playerView.player = null
        app.ultratube.media.PlaybackService.uiStopped()
        super.onStop()
    }

    override fun onDestroy() {
        controller?.removeListener(listener)
        connection?.let { MediaController.releaseFuture(it) }
        io.shutdownNow()
        super.onDestroy()
    }
}
