package app.ultratube.wear

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognizerIntent
import android.text.TextUtils
import android.view.Gravity
import android.view.InputDevice
import android.view.MotionEvent
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import app.ultratube.media.Catalog
import app.ultratube.media.Downloads
import app.ultratube.media.Playback
import app.ultratube.media.PlaybackService
import app.ultratube.media.Twitch
import app.ultratube.media.WatchLink
import app.ultratube.media.YoutubeAccount
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/**
 * Standalone Wear OS client. Screens are plain views swapped inside one
 * rotary-scrollable column, sized for round 1.2–1.5" displays.
 */
class MainActivity : Activity() {
    private enum class Screen { HOME, SEARCH, RESULTS, DOWNLOADS, QUEUE, LYRICS, TWITCH, ACCOUNT, LINK }

    private val io = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private lateinit var scroll: ScrollView
    private lateinit var content: LinearLayout
    private var controller: MediaController? = null
    private var connection: com.google.common.util.concurrent.ListenableFuture<MediaController>? = null
    private var screen = Screen.HOME
    private var generation = 0
    private var resultsTitle = ""
    private val covers = HashMap<String, Bitmap?>()

    // Now-playing widgets, valid while HOME is shown.
    private var titleView: TextView? = null
    private var artistView: TextView? = null
    private var coverView: ImageView? = null
    private var progressView: ProgressBar? = null
    private var playButton: ImageButton? = null
    private var timerView: TextView? = null
    private var shownCover: String? = null

    private val downloadsChanged: () -> Unit = { main.post { if (screen == Screen.DOWNLOADS) showDownloads() } }
    private val tick = object : Runnable {
        override fun run() { refreshNowPlaying(); main.postDelayed(this, 1000) }
    }
    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            refreshNowPlaying()
            if (screen == Screen.QUEUE && events.contains(Player.EVENT_MEDIA_ITEM_TRANSITION)) showQueue()
            if (events.contains(Player.EVENT_MEDIA_ITEM_TRANSITION)) WatchShorts.moreIfNeeded(this@MainActivity, player)
        }
    }

    private fun dp(value: Int) = (resources.displayMetrics.density * value).toInt()

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.statusBarColor = Color.BLACK
        scroll = ScrollView(this).apply {
            setBackgroundColor(BG); isFillViewport = true; isFocusableInTouchMode = true
            setOnGenericMotionListener { _, event ->
                if (event.action == MotionEvent.ACTION_SCROLL && event.isFromSource(InputDevice.SOURCE_ROTARY_ENCODER)) {
                    smoothScrollBy(0, (-event.getAxisValue(MotionEvent.AXIS_SCROLL) * dp(56)).toInt()); true
                } else false
            }
        }
        content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL }
        scroll.addView(content)
        setContentView(scroll)
        connection = Playback.connect(this) { c -> controller = c; c.addListener(listener); refreshNowPlaying() }
        // Android 13+ (predictive back, default from API 35/36) never calls
        // onBackPressed: route back/swipe-to-dismiss through the dispatcher.
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT) { handleBack() }
        }
        showHome()
    }

    // ---------------------------------------------------------------- screens

    private fun reset(next: Screen, horizontal: Int = 30) {
        if (next != Screen.LINK) stopLink()
        screen = next
        generation++
        titleView = null; artistView = null; coverView = null; progressView = null; playButton = null; timerView = null; shownCover = null
        content.removeAllViews()
        content.setPadding(dp(horizontal), dp(26), dp(horizontal), dp(48))
        scroll.scrollTo(0, 0)
        scroll.requestFocus()
    }

    private fun showHome() {
        reset(Screen.HOME, 24)
        label("ULTRATUBE", 11, ACCENT, bold = true).apply { letterSpacing = 0.25f }
        coverView = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP; clipToOutline = true
            background = rounded(SURFACE, dp(14)); contentDescription = "Capa"
        }
        content.addView(coverView, LinearLayout.LayoutParams(dp(64), dp(64)).apply { topMargin = dp(8) })
        titleView = label("Nada tocando", 15, Color.WHITE, bold = true, lines = 2)
        artistView = label("Busque por voz para começar", 12, MUTED, lines = 1)
        progressView = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000; progressTintList = ColorStateList.valueOf(ACCENT); progressBackgroundTintList = ColorStateList.valueOf(SURFACE)
        }
        content.addView(progressView, LinearLayout.LayoutParams(dp(120), dp(6)).apply { topMargin = dp(6) })

        val controls = LinearLayout(this).apply { gravity = Gravity.CENTER; orientation = LinearLayout.HORIZONTAL }
        controls.addView(roundButton(R.drawable.ic_prev, "Anterior", dp(40), SURFACE, Color.WHITE) {
            controller?.let { if (it.currentPosition > 5000 || !it.hasPreviousMediaItem()) it.seekTo(0) else it.seekToPreviousMediaItem() }
        })
        val play = roundButton(R.drawable.ic_play, "Reproduzir", dp(56), ACCENT, Color.WHITE) {
            controller?.let { if (it.isPlaying) it.pause() else { if (it.playbackState == Player.STATE_IDLE) it.prepare(); it.play() } }
        }
        playButton = play
        controls.addView(play, LinearLayout.LayoutParams(dp(56), dp(56)).apply { marginStart = dp(10); marginEnd = dp(10) })
        controls.addView(roundButton(R.drawable.ic_next, "Próxima", dp(40), SURFACE, Color.WHITE) {
            controller?.let { if (it.hasNextMediaItem()) it.seekToNextMediaItem() }
        })
        content.addView(controls, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(10); bottomMargin = dp(10) })
        // Tapping the now-playing block opens the full player.
        coverView?.setOnClickListener { openPlayer() }
        titleView?.setOnClickListener { openPlayer() }

        pill("Abrir player", R.drawable.ic_video, primary = true) { openPlayer() }
        pill("Buscar por voz", R.drawable.ic_mic) { voiceSearch() }
        pill("Digitar busca", R.drawable.ic_keyboard) { showSearch() }
        pill("Shorts", R.drawable.ic_shorts) { startShorts() }
        if (YoutubeAccount.isSignedIn(this)) pill("Para você", R.drawable.ic_video) { forYou() }
        pill(if (YoutubeAccount.isSignedIn(this)) "Conta" else "Entrar com o celular", R.drawable.ic_account) { showAccount() }
        pill("Twitch ao vivo", R.drawable.ic_twitch) { showTwitch() }
        pill("Lives do YouTube", R.drawable.ic_live) { youtubeLives() }
        pill("Downloads", R.drawable.ic_download) { showDownloads() }
        pill("Favoritos", R.drawable.ic_heart) { showResults("Favoritos", favorites()) }
        pill("Fila", R.drawable.ic_list) { showQueue() }
        pill("Letra", R.drawable.ic_lyrics) { showLyrics() }
        timerView = pill(timerLabel(), R.drawable.ic_timer) { chooseTimer() }.getChildAt(1) as TextView
        refreshNowPlaying()
    }

    // Search kinds offered on the watch.
    private val kinds = listOf("music" to "Músicas", "videos" to "Vídeos", "shorts" to "Shorts")
    private var searchKind: String
        get() = getPreferences(0).getString("searchKind", "music") ?: "music"
        set(value) { getPreferences(0).edit().putString("searchKind", value).apply() }

    private fun recentSearches() = runCatching { JSONArray(getPreferences(0).getString("recent", "[]")) }.getOrDefault(JSONArray())
        .let { a -> (0 until a.length()).map { a.getString(it) } }

    private fun remember(query: String) {
        val next = (listOf(query) + recentSearches().filter { !it.equals(query, ignoreCase = true) }).take(8)
        getPreferences(0).edit().putString("recent", JSONArray(next).toString()).apply()
    }

    private fun showSearch() {
        reset(Screen.SEARCH)
        header("Buscar")
        val query = EditText(this).apply {
            hint = "Música, vídeo ou canal"; setSingleLine(); setTextColor(Color.WHITE); setHintTextColor(MUTED); textSize = 14f
            background = rounded(SURFACE, dp(24)); setPadding(dp(16), 0, dp(16), 0)
            // The keyboard's ✓ runs the search right away (last kind used).
            imeOptions = EditorInfo.IME_ACTION_SEARCH
            setOnEditorActionListener { v, _, _ ->
                getSystemService(android.view.inputmethod.InputMethodManager::class.java).hideSoftInputFromWindow(v.windowToken, 0)
                runSearch(v.text.toString(), searchKind); true
            }
        }
        content.addView(query, LinearLayout.LayoutParams(-1, dp(48)).apply { topMargin = dp(6) })
        hint("Toque em ✓ no teclado ou escolha:")
        for ((kind, label) in kinds) {
            val icon = when (kind) { "videos" -> R.drawable.ic_video; "shorts" -> R.drawable.ic_shorts; else -> R.drawable.ic_music }
            pill(label, icon, primary = kind == searchKind) {
                if (query.text.isBlank()) { searchKind = kind; toast("Digite o que procurar"); query.requestFocus() } else runSearch(query.text.toString(), kind)
            }
        }
        val recent = recentSearches()
        if (recent.isNotEmpty()) {
            label("Recentes", 12, MUTED, bold = true).apply { setPadding(0, dp(12), 0, dp(2)) }
            for (q in recent) pill(q, R.drawable.ic_search) { runSearch(q, searchKind) }
        }
        query.requestFocus()
    }

    private fun runSearch(raw: String, kind: String) {
        val query = raw.trim()
        if (query.isEmpty()) return toast("Digite o que procurar")
        remember(query)
        searchKind = kind
        if (kind == "shorts") startShorts(query) else search(query, music = kind == "music")
    }

    /** Músicas · Vídeos · Shorts switcher for the same query. */
    private fun kindChips(query: String, current: String) {
        // Equal thirds, inset from the round edge, so no label gets clipped.
        val row = LinearLayout(this).apply { gravity = Gravity.CENTER; orientation = LinearLayout.HORIZONTAL; setPadding(dp(4), 0, dp(4), 0) }
        for ((kind, label) in kinds) {
            row.addView(TextView(this).apply {
                text = label; textSize = 11f; gravity = Gravity.CENTER; typeface = Typeface.DEFAULT_BOLD; maxLines = 1
                setTextColor(Color.WHITE)
                background = RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), rounded(if (kind == current) ACCENT else SURFACE, dp(14)), null)
                isClickable = true; setOnClickListener { if (kind != current) runSearch(query, kind) }
            }, LinearLayout.LayoutParams(0, dp(30), 1f).apply { marginStart = dp(2); marginEnd = dp(2) })
        }
        content.addView(row, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(4) })
    }

    private fun showResults(title: String, items: JSONArray, video: Boolean = false) {
        resultsTitle = title
        reset(Screen.RESULTS, 22)
        header(title)
        // Músicas · Vídeos · Shorts only switch a search, not the account lists.
        if (title !in setOf("Favoritos", "Para você", "Inscrições", "Lives")) kindChips(title, if (video) "videos" else "music")
        if (items.length() == 0) { empty(if (title == "Favoritos") "Sem favoritos.\nSegure um resultado para salvar." else "Nenhum resultado.\nTente outro tipo acima."); return }
        hint(if (video) "Vídeos · toque para assistir" else "Toque para tocar · segure para mais")
        val queue = (0 until items.length()).map { Playback.online(items.getJSONObject(it), video) }
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            row(item.optString("title"), listOfNotNull(item.optString("artist").ifBlank { null }, duration(item.optLong("duration"))).joinToString(" · "),
                item.optString("cover"), onClick = { play(queue, i) }, onLongClick = { itemActions(item) })
        }
    }

    private fun showDownloads() {
        val refreshing = screen == Screen.DOWNLOADS
        val y = scroll.scrollY
        reset(Screen.DOWNLOADS, 22)
        header("Downloads")
        val jobs = Downloads.list(this)
        if (jobs.length() == 0) { empty("Nada baixado ainda.\nSegure um resultado da busca e escolha Baixar."); return }
        val done = (0 until jobs.length()).map { jobs.getJSONObject(it) }
            .filter { it.optString("state") == Downloads.DONE && File(it.optString("file")).exists() }
        hint("${done.size} offline · ${done.sumOf { it.optLong("size") } / (1024 * 1024)} MB")
        val queue = done.map(Playback::offline)
        for (i in 0 until jobs.length()) {
            val job = jobs.getJSONObject(i)
            val state = job.optString("state")
            val subtitle = when (state) {
                Downloads.QUEUED -> "Na fila"
                Downloads.RUNNING -> "Baixando ${(job.optDouble("progress") * 100).toInt()}%"
                Downloads.FAILED -> "Falhou · segure para tentar"
                Downloads.CANCELED -> "Cancelado"
                else -> job.optString("artist")
            }
            val cover = job.optString("coverFile").takeIf { it.isNotBlank() }?.let { Uri.fromFile(File(it)).toString() } ?: job.optString("cover")
            val index = done.indexOfFirst { it.optString("id") == job.optString("id") }
            row(job.optString("title"), subtitle, cover,
                onClick = { if (index >= 0) play(queue, index) else toast(subtitle) },
                onLongClick = { downloadActions(job) })
        }
        if (refreshing) scroll.post { scroll.scrollTo(0, y) }
    }

    private fun showQueue() {
        val c = controller ?: return toast("Player indisponível")
        val refreshing = screen == Screen.QUEUE
        val y = scroll.scrollY
        reset(Screen.QUEUE, 22)
        header("Fila")
        if (c.mediaItemCount == 0) { empty("A fila está vazia"); return }
        for (i in 0 until c.mediaItemCount) {
            val item = c.getMediaItemAt(i)
            val current = i == c.currentMediaItemIndex
            row(item.mediaMetadata.title?.toString().orEmpty(), if (current) "Tocando agora" else item.mediaMetadata.artist?.toString().orEmpty(),
                item.mediaMetadata.artworkUri?.toString().orEmpty(), highlight = current,
                onClick = { c.seekToDefaultPosition(i); c.play(); showHome() }, onLongClick = null)
        }
        if (refreshing) scroll.post { scroll.scrollTo(0, y) }
    }

    private fun showLyrics() {
        val c = controller
        val title = c?.mediaMetadata?.title?.toString().orEmpty()
        if (title.isBlank()) return toast("Toque algo primeiro")
        reset(Screen.LYRICS)
        header("Letra")
        val body = label("Carregando…", 15, Color.WHITE)
        // Read on the main thread: MediaController refuses calls from the worker.
        val artist = c?.mediaMetadata?.artist?.toString().orEmpty()
        work({ Catalog.lyrics(title, artist) }, onError = { body.text = it }) {
            body.text = it.optString("plainLyrics").ifBlank { "Letra indisponível" }
        }
    }

    /** Twitch: most watched lives in Portuguese, plus channel search. */
    private fun showTwitch(query: String = "") {
        reset(Screen.TWITCH, 22)
        header(if (query.isBlank()) "Twitch" else query)
        pill("Buscar canal", R.drawable.ic_keyboard) { askTwitchChannel() }
        val loading = label(if (query.isBlank()) "Carregando lives…" else "Buscando…", 13, MUTED)
        work({ if (query.isBlank()) Twitch.top("pt") else Twitch.search(query) }, onError = { error ->
            loading.text = "Não foi possível falar com a Twitch.\n($error)"
            pill("Tentar de novo", R.drawable.ic_twitch, primary = true) { showTwitch(query) }
        }) { items ->
            content.removeView(loading)
            if (items.length() == 0) { empty("Ninguém ao vivo agora."); return@work }
            hint("Sem anúncios · toque para assistir · segure para só áudio")
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                val live = item.optBoolean("live")
                val subtitle = if (!live) "Offline" else listOf(item.optString("artist"), viewers(item.optInt("viewers", -1)), item.optString("game"))
                    .filter { it.isNotBlank() }.joinToString(" · ")
                row(item.optString("title"), subtitle, item.optString("cover"),
                    onClick = { if (live) playTwitch(item, video = true) else toast("Canal offline") },
                    onLongClick = { if (live) playTwitch(item, video = false) })
            }
        }
    }

    private fun askTwitchChannel() {
        val input = EditText(this).apply {
            hint = "Nome do canal"; setSingleLine(); setTextColor(Color.WHITE); setHintTextColor(MUTED)
            imeOptions = EditorInfo.IME_ACTION_SEARCH
        }
        val dialog = AlertDialog.Builder(this).setView(input).create()
        input.setOnEditorActionListener { v, _, _ ->
            dialog.dismiss()
            val q = v.text.toString().trim()
            if (q.isNotEmpty()) showTwitch(q)
            true
        }
        dialog.show()
        input.requestFocus()
    }

    private fun playTwitch(item: JSONObject, video: Boolean) {
        val c = controller ?: return toast("Player indisponível")
        Playback.playAll(c, listOf(Playback.twitch(item, video)), 0)
        if (video) PlayerActivity.open(this) else showHome()
    }

    /** YouTube broadcasts happening now (search filtered to lives). */
    private fun youtubeLives() {
        reset(Screen.RESULTS); header("Lives")
        val loading = label("Buscando lives…", 13, MUTED)
        work({
            val all = Catalog.search("ao vivo agora", music = false)
            JSONArray((0 until all.length()).map { all.getJSONObject(it) }.filter { it.optBoolean("live") })
        }, onError = { error ->
            loading.text = "Não foi possível buscar lives.\n($error)"
            pill("Tentar de novo", R.drawable.ic_live, primary = true) { youtubeLives() }
        }) { showResults("Lives", it, video = true) }
    }

    private fun viewers(n: Int): String = when {
        n < 0 -> ""
        n >= 1_000_000 -> "%.1f mi".format(n / 1e6).replace('.', ',')
        n >= 1_000 -> "%.1f mil".format(n / 1e3).replace('.', ',').replace(",0 mil", " mil")
        else -> "$n"
    } + if (n >= 0) " assistindo" else ""

    // --------------------------------------------------------------- actions

    private fun voiceSearch() {
        try {
            startActivityForResult(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_PROMPT, "O que você quer ouvir?"), VOICE)
        } catch (_: Exception) { showSearch() }
    }

    private fun search(query: String, music: Boolean = true) {
        if (query.isBlank()) return
        reset(Screen.RESULTS); header(query)
        kindChips(query, if (music) "music" else "videos")
        val loading = label("Buscando…", 13, MUTED)
        work({ Catalog.search(query, music) }, onError = { error ->
            loading.text = "Não foi possível buscar.\nVerifique a internet do relógio.\n($error)"
            pill("Tentar de novo", R.drawable.ic_search, primary = true) { search(query, music) }
        }) { showResults(query, it, video = !music) }
    }

    // ---------------------------------------------------------------- Shorts

    /**
     * Vertical Shorts player. Without a [topic] it plays YouTube's own Shorts
     * feed (the account's when signed in, the regional one otherwise) and
     * keeps adding pages as you swipe; a topic searches Shorts instead.
     */
    private fun startShorts(topic: String = "") {
        reset(Screen.RESULTS); header(if (topic.isBlank()) "Shorts" else topic)
        if (topic.isNotBlank()) kindChips(topic, "shorts")
        val loading = label("Carregando Shorts…", 13, MUTED)
        work({
            if (topic.isNotBlank()) return@work JSONObject().put("items", Catalog.search(topic, true, shorts = true)).put("next", JSONObject.NULL)
            // The real feed; a topic search only if YouTube's feed fails.
            runCatching { WatchShorts.page(this, null) }.getOrNull()?.takeIf { it.getJSONArray("items").length() > 0 }
                ?: JSONObject().put("items", Catalog.search(listOf("shorts brasil", "shorts engraçados", "shorts futebol", "shorts música").random(), true, shorts = true))
                    .put("next", JSONObject.NULL)
        }, onError = { error ->
            loading.text = "Não foi possível carregar Shorts.\n($error)"
            pill("Tentar de novo", R.drawable.ic_shorts, primary = true) { startShorts(topic) }
        }) { page ->
            val items = page.getJSONArray("items")
            if (items.length() == 0) { loading.text = "Nenhum Short encontrado"; return@work }
            val c = controller ?: return@work toast("Player indisponível")
            WatchShorts.play(c, page)
            // A topic search is a fixed list: no paging or refresh of the feed.
            WatchShorts.active = topic.isBlank()
            showHome()
            PlayerActivity.open(this, shorts = true)
        }
    }

    // --------------------------------------------------------------- account

    /** The account's own YouTube home ("Para você"). */
    private fun forYou() {
        reset(Screen.RESULTS); header("Para você")
        val loading = label("Carregando…", 13, MUTED)
        work({
            val page = YoutubeAccount.home(this, null)
            val items = page.getJSONArray("items")
            // Regular videos only: Shorts have their own player.
            JSONArray((0 until items.length()).map { items.getJSONObject(it) }.filter { !it.optBoolean("shorts") })
        }, onError = { error ->
            loading.text = "Não foi possível carregar.\n($error)"
            pill("Tentar de novo", R.drawable.ic_video, primary = true) { forYou() }
        }) { showResults("Para você", it, video = true) }
    }

    private fun showAccount() {
        if (!YoutubeAccount.isSignedIn(this)) return showLink()
        reset(Screen.ACCOUNT, 22)
        header("Conta")
        val avatar = ImageView(this).apply { scaleType = ImageView.ScaleType.CENTER_CROP; clipToOutline = true; background = rounded(SURFACE, dp(28)) }
        content.addView(avatar, LinearLayout.LayoutParams(dp(56), dp(56)).apply { gravity = Gravity.CENTER_HORIZONTAL })
        val name = label("Conta do YouTube", 15, Color.WHITE, bold = true, lines = 1)
        val handle = label("Verificando…", 12, MUTED, lines = 1)
        work({ YoutubeAccount.info(this) }, onError = { handle.text = "Sem conexão" }) { info ->
            if (!info.optBoolean("signedIn")) {
                handle.text = "A sessão expirou. Entre de novo pelo celular."
                handle.setTextColor(ERROR)
                return@work
            }
            name.text = info.optString("name").ifBlank { "Conta do YouTube" }
            handle.text = info.optString("handle")
            // YouTube sends an 88 px photo; ask for a bigger one (covers are
            // decoded at 1/4 size to save memory).
            loadCover(info.optString("avatar").replace(Regex("=s\\d+"), "=s400"), avatar)
        }
        pill("Para você", R.drawable.ic_video, primary = true) { forYou() }
        pill("Shorts da conta", R.drawable.ic_shorts) { startShorts() }
        pill("Inscrições", R.drawable.ic_list) { subscriptionsFeed() }
        pill("Trocar de conta", R.drawable.ic_account) { showLink() }
        pill("Sair", R.drawable.ic_logout) {
            AlertDialog.Builder(this).setMessage("Sair da conta do YouTube no relógio?")
                .setPositiveButton("Sair") { _, _ -> YoutubeAccount.signOut(this); toast("Conta removida do relógio"); showHome() }
                .setNegativeButton("Cancelar", null).show()
        }
    }

    /** Newest uploads from the channels the account follows. */
    private fun subscriptionsFeed() {
        reset(Screen.RESULTS); header("Inscrições")
        val loading = label("Carregando inscrições…", 13, MUTED)
        work({
            val channels = YoutubeAccount.subscriptions(this)
            val urls = (0 until channels.length()).map { channels.getJSONObject(it).optString("url") }.filter { it.isNotBlank() }.take(40)
            val feed = Catalog.feed(urls).getJSONArray("items")
            JSONArray((0 until feed.length()).map { feed.getJSONObject(it) }.filter { !it.optBoolean("shorts") }.take(40))
        }, onError = { error ->
            loading.text = "Não foi possível carregar.\n($error)"
            pill("Tentar de novo", R.drawable.ic_list, primary = true) { subscriptionsFeed() }
        }) { showResults("Inscrições", it, video = true) }
    }

    private var link: AccountLink? = null

    /**
     * "Entrar com o celular": Wear OS has no browser to show Google's page,
     * so the signed-in Ultratube on the phone sends its session here over
     * the Wi-Fi (scan the QR, or type the address and code in the phone app).
     */
    private fun showLink() {
        reset(Screen.LINK, 26)
        header("Entrar")
        val status = label("Ligando o Wi-Fi…", 12, MUTED)
        val qrImage = ImageView(this).apply {
            scaleType = ImageView.ScaleType.FIT_CENTER; background = rounded(Color.WHITE, dp(10)); setPadding(dp(6), dp(6), dp(6), dp(6))
            contentDescription = "QR para o celular"; visibility = android.view.View.GONE
        }
        content.addView(qrImage, LinearLayout.LayoutParams(dp(150), dp(150)).apply { gravity = Gravity.CENTER_HORIZONTAL; topMargin = dp(4) })
        val addressView = label("", 13, Color.WHITE, bold = true)
        val codeView = label("", 13, ACCENT, bold = true).apply { letterSpacing = 0.05f }
        hint("No celular: Ultratube › Você › Conectar relógio, ou escaneie o QR com a câmera. Mesmo Wi-Fi nos dois.")
        val request = generation
        link?.stop()
        link = AccountLink(this, object : AccountLink.Listener {
            override fun onReady(address: String, code: String, qr: android.graphics.Bitmap) {
                if (request != generation) return
                status.text = "Escaneie com a câmera do celular"
                qrImage.setImageBitmap(qr); qrImage.visibility = android.view.View.VISIBLE
                addressView.text = address
                codeView.text = "Código\n${WatchLink.pretty(code)}"
            }
            override fun onWaitingForWifi() {
                if (request != generation) return
                status.text = "Procurando Wi-Fi… Conecte o relógio a uma rede Wi-Fi (a mesma do celular)."
            }
            override fun onLinked(name: String) {
                stopLink()
                toast(if (name.isBlank()) "Conta conectada" else "Conectado: $name")
                if (request == generation) showAccount()
            }
            override fun onError(message: String) { if (request == generation) status.text = message }
        }).also { it.start() }
    }

    private fun stopLink() { link?.stop(); link = null }

    private fun openPlayer() {
        if ((controller?.mediaItemCount ?: 0) == 0) return toast("Busque algo para tocar")
        PlayerActivity.open(this)
    }

    private fun play(queue: List<MediaItem>, index: Int) {
        val c = controller ?: return toast("Player indisponível")
        WatchShorts.active = false
        Playback.playAll(c, queue, index)
        showHome()
        PlayerActivity.open(this)
    }

    private fun itemActions(item: JSONObject) {
        val favorite = isFavorite(item)
        AlertDialog.Builder(this).setTitle(item.optString("title"))
            .setItems(arrayOf("Tocar em seguida", "Baixar no relógio", if (favorite) "Remover dos favoritos" else "Favoritar")) { _, which ->
                when (which) {
                    0 -> controller?.let { c ->
                        val empty = c.mediaItemCount == 0
                        c.addMediaItem(if (empty) 0 else c.currentMediaItemIndex + 1, Playback.online(item))
                        if (empty) { c.prepare(); c.play() }
                        toast("Toca em seguida")
                    }
                    1 -> {
                        Downloads.enqueue(this, item.getString("url"), item.optString("title"), item.optString("artist"), item.optString("cover"), false, 0)
                        toast("Baixando no relógio")
                    }
                    2 -> { toggleFavorite(item); if (resultsTitle == "Favoritos") showResults("Favoritos", favorites()) }
                }
            }.show()
    }

    private fun downloadActions(job: JSONObject) {
        val id = job.getString("id")
        val state = job.optString("state")
        val options = buildList {
            if (state == Downloads.FAILED || state == Downloads.CANCELED) add("Tentar de novo")
            add(if (state == Downloads.QUEUED || state == Downloads.RUNNING) "Cancelar" else "Apagar")
        }
        AlertDialog.Builder(this).setTitle(job.optString("title")).setItems(options.toTypedArray()) { _, which ->
            when (options[which]) {
                "Tentar de novo" -> Downloads.retry(this, id)
                "Cancelar" -> Downloads.cancel(this, id)
                else -> AlertDialog.Builder(this).setMessage("Apagar \"${job.optString("title")}\" do relógio?")
                    .setPositiveButton("Apagar") { _, _ -> Downloads.remove(this, id) }.setNegativeButton("Manter", null).show()
            }
        }.show()
    }

    private fun chooseTimer() {
        val minutes = intArrayOf(0, 15, 30, 45, 60, 90)
        AlertDialog.Builder(this).setTitle("Pausar em")
            .setItems(minutes.map { if (it == 0) "Desligado" else "$it min" }.toTypedArray()) { _, which ->
                PlaybackService.sleepTimer(minutes[which])
                main.postDelayed({ timerView?.text = timerLabel() }, 150)
                toast(if (minutes[which] == 0) "Timer desligado" else "Pausa em ${minutes[which]} min")
            }.show()
    }

    private fun timerLabel(): String {
        val left = PlaybackService.sleepAt - System.currentTimeMillis()
        return if (PlaybackService.sleepAt == 0L || left <= 0) "Timer" else "Timer · ${left / 60_000 + 1} min"
    }

    // ------------------------------------------------------------- favorites

    private fun favorites() = runCatching { JSONArray(getPreferences(0).getString("favorites", "[]")) }.getOrDefault(JSONArray())
    private fun isFavorite(item: JSONObject) = favorites().let { f -> (0 until f.length()).any { f.getJSONObject(it).optString("url") == item.optString("url") } }
    private fun toggleFavorite(item: JSONObject) {
        val current = favorites()
        val kept = JSONArray()
        var removed = false
        for (i in 0 until current.length()) {
            val entry = current.getJSONObject(i)
            if (entry.optString("url") == item.optString("url")) removed = true else kept.put(entry)
        }
        if (!removed) kept.put(item)
        getPreferences(0).edit().putString("favorites", kept.toString()).apply()
        toast(if (removed) "Removido dos favoritos" else "Salvo nos favoritos")
    }

    // ------------------------------------------------------------ now playing

    private fun refreshNowPlaying() {
        timerView?.text = timerLabel()
        val c = controller ?: return
        if (screen != Screen.HOME) return
        val metadata = c.mediaMetadata
        val title = metadata.title?.toString()
        titleView?.text = title ?: "Nada tocando"
        val error = c.playerError
        artistView?.text = when {
            error != null -> "Erro: ${error.localizedMessage ?: "falha de rede"}"
            title == null -> "Busque por voz para começar"
            c.playbackState == Player.STATE_BUFFERING -> "Carregando…"
            else -> metadata.artist?.toString().orEmpty()
        }
        artistView?.setTextColor(if (error != null) ERROR else MUTED)
        val duration = c.duration
        progressView?.progress = if (duration > 0) (c.currentPosition * 1000 / duration).toInt() else 0
        val showPause = c.isPlaying || (c.playbackState == Player.STATE_BUFFERING && c.playWhenReady)
        playButton?.setImageResource(if (showPause) R.drawable.ic_pause else R.drawable.ic_play)
        playButton?.contentDescription = if (showPause) "Pausar" else "Reproduzir"
        val art = metadata.artworkUri?.toString()
        if (art != shownCover) { shownCover = art; coverView?.let { loadCover(art, it) } }
    }

    // ------------------------------------------------------------ view kit

    private fun label(value: String, size: Int, color: Int, bold: Boolean = false, lines: Int = 0) = TextView(this).apply {
        text = value; textSize = size.toFloat(); gravity = Gravity.CENTER; setTextColor(color)
        if (bold) typeface = Typeface.DEFAULT_BOLD
        if (lines > 0) { maxLines = lines; ellipsize = TextUtils.TruncateAt.END }
        setPadding(0, dp(3), 0, dp(3)); content.addView(this, LinearLayout.LayoutParams(-1, -2))
    }

    private fun hint(value: String) = label(value, 11, MUTED)
    private fun empty(value: String) = label(value, 13, MUTED).apply { setPadding(0, dp(18), 0, dp(18)) }

    private fun header(title: String) {
        val bar = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL; orientation = LinearLayout.HORIZONTAL }
        bar.addView(roundButton(R.drawable.ic_back, "Voltar", dp(36), SURFACE, Color.WHITE) { showHome() })
        bar.addView(TextView(this).apply {
            text = title; textSize = 14f; typeface = Typeface.DEFAULT_BOLD; setTextColor(Color.WHITE); maxLines = 1; ellipsize = TextUtils.TruncateAt.END
            setPadding(dp(8), 0, 0, 0)
        }, LinearLayout.LayoutParams(0, -2, 1f))
        content.addView(bar, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(6) })
    }

    private fun roundButton(icon: Int, description: String, size: Int, fill: Int, tint: Int, action: () -> Unit) = ImageButton(this).apply {
        setImageResource(icon); imageTintList = ColorStateList.valueOf(tint); contentDescription = description
        background = RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(fill) }, null)
        val pad = size / 4; setPadding(pad, pad, pad, pad); scaleType = ImageView.ScaleType.FIT_CENTER
        layoutParams = LinearLayout.LayoutParams(size, size)
        setOnClickListener { action() }
    }

    private fun pill(text: String, icon: Int, primary: Boolean = false, action: () -> Unit): LinearLayout {
        val fg = Color.WHITE
        val view = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; minimumHeight = dp(48)
            setPadding(dp(16), dp(6), dp(16), dp(6)); isClickable = true; isFocusable = true
            background = RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), rounded(if (primary) ACCENT else SURFACE, dp(24)), null)
            setOnClickListener { action() }
            addView(ImageView(context).apply { setImageResource(icon); imageTintList = ColorStateList.valueOf(fg) }, LinearLayout.LayoutParams(dp(20), dp(20)))
            addView(TextView(context).apply { this.text = text; textSize = 13f; setTextColor(fg); setPadding(dp(10), 0, 0, 0); maxLines = 1; ellipsize = TextUtils.TruncateAt.END },
                LinearLayout.LayoutParams(0, -2, 1f))
        }
        content.addView(view, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) })
        return view
    }

    private fun row(title: String, subtitle: String, cover: String, highlight: Boolean = false, onClick: () -> Unit, onLongClick: (() -> Unit)?) {
        val image = ImageView(this).apply { scaleType = ImageView.ScaleType.CENTER_CROP; clipToOutline = true; background = rounded(SURFACE, dp(8)) }
        val texts = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(10), 0, 0, 0)
            addView(TextView(context).apply { text = title; textSize = 13f; setTextColor(if (highlight) ACCENT else Color.WHITE); maxLines = 2; ellipsize = TextUtils.TruncateAt.END })
            if (subtitle.isNotBlank()) addView(TextView(context).apply { text = subtitle; textSize = 11f; setTextColor(MUTED); maxLines = 1; ellipsize = TextUtils.TruncateAt.END })
        }
        val view = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; minimumHeight = dp(56)
            setPadding(dp(8), dp(6), dp(10), dp(6)); isClickable = true; isFocusable = true
            background = RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), rounded(SURFACE, dp(16)), null)
            addView(image, LinearLayout.LayoutParams(dp(40), dp(40)))
            addView(texts, LinearLayout.LayoutParams(0, -2, 1f))
            setOnClickListener { onClick() }
            onLongClick?.let { action -> setOnLongClickListener { action(); true } }
        }
        content.addView(view, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) })
        loadCover(cover, image)
    }

    private fun rounded(color: Int, radius: Int) = GradientDrawable().apply { setColor(color); cornerRadius = radius.toFloat() }

    private fun loadCover(url: String?, view: ImageView) {
        view.tag = url
        if (url.isNullOrBlank()) { view.setImageDrawable(null); return }
        if (covers.containsKey(url)) { view.setImageBitmap(covers[url]); return }
        io.execute {
            val bitmap = runCatching {
                val options = BitmapFactory.Options().apply { inSampleSize = 4 }
                when {
                    url.startsWith("file:") -> BitmapFactory.decodeFile(Uri.parse(url).path, options)
                    url.startsWith("https://") -> java.net.URL(url).openConnection().apply { connectTimeout = 10000; readTimeout = 10000 }
                        .getInputStream().use { BitmapFactory.decodeStream(it, null, options) }
                    else -> null
                }
            }.getOrNull()
            main.post { covers[url] = bitmap; if (view.tag == url && !isDestroyed) view.setImageBitmap(bitmap) }
        }
    }

    private fun <T> work(task: () -> T, onError: ((String) -> Unit)? = null, ready: (T) -> Unit) {
        val request = generation
        io.execute {
            val result = runCatching(task)
            main.post {
                if (isDestroyed || request != generation) return@post
                result.fold(ready) {
                    val message = it.localizedMessage ?: "Falha de rede"
                    if (onError != null) onError(message) else toast(message)
                }
            }
        }
    }

    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    private fun duration(seconds: Long) = if (seconds <= 0) null else "%d:%02d".format(seconds / 60, seconds % 60)

    // ------------------------------------------------------------ lifecycle

    @Deprecated("Platform callback")
    override fun onActivityResult(request: Int, result: Int, data: Intent?) {
        super.onActivityResult(request, result, data)
        if (request == VOICE && result == RESULT_OK) data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()?.let { runSearch(it, searchKind) }
    }

    @Deprecated("Platform callback")
    override fun onBackPressed() = handleBack()

    private fun handleBack() {
        if (screen != Screen.HOME) return showHome()
        closeApp()
    }

    /**
     * Leaving with back = closing Ultratube: stop the music and the background
     * service. (The crown/home button keeps playing, with the Ongoing Activity
     * chip on the watch face to come back or stop.)
     */
    private var closed = false
    private fun closeApp() {
        if (closed) return
        closed = true
        controller?.let { it.stop(); it.clearMediaItems() }
        PlaybackService.stop(this)
        finishAndRemoveTask()
    }

    override fun onStart() { super.onStart(); PlaybackService.uiStarted(); Downloads.addListener(downloadsChanged); main.post(tick) }
    override fun onStop() { main.removeCallbacks(tick); Downloads.removeListener(downloadsChanged); PlaybackService.uiStopped(); super.onStop() }
    override fun onDestroy() {
        // Finished by the user (not a rotation/low-memory recreation): any
        // way out of the app also ends playback.
        if (isFinishing && !isChangingConfigurations) closeApp()
        generation++
        stopLink()
        controller?.removeListener(listener)
        connection?.let { MediaController.releaseFuture(it) }
        io.shutdownNow()
        super.onDestroy()
    }

    private companion object {
        const val VOICE = 7
        const val BG = Color.BLACK
        val SURFACE = Ut.SURFACE
        val ACCENT = Ut.RED
        val MUTED = Color.rgb(170, 174, 166)
        val ERROR = Color.rgb(255, 138, 128)
    }
}
