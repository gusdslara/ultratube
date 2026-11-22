package app.ultratube.media

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * Optional YouTube account, signed in exactly like a browser: the normal
 * Google sign-in page runs in a WebView and the resulting youtube.com session
 * cookies are kept in app-private storage. No Google Cloud project, OAuth
 * client ID or API key is involved. Requests use the web client (InnerTube)
 * with the standard SAPISIDHASH header, the same way youtube.com does.
 *
 * Only the account features use these cookies (name/photo, subscriptions,
 * home recommendations); playback keeps going through NewPipeExtractor.
 */
object YoutubeAccount {
    private const val PREFS = "ultratube_account"
    private const val KEY_COOKIES = "cookies"
    private const val ORIGIN = "https://www.youtube.com"
    private const val CLIENT_VERSION = "2.20251114.01.00"
    private const val DESKTOP_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    const val LOGIN_URL = "https://accounts.google.com/ServiceLogin?service=youtube&passive=true&continue=" +
        "https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26next%3D%252F"

    private val http = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS).callTimeout(45, TimeUnit.SECONDS).build()
    private val json = "application/json".toMediaType()
    private val lock = Any()

    // ------------------------------------------------------------- cookies

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun cookies(ctx: Context): MutableMap<String, String> = parseCookies(prefs(ctx).getString(KEY_COOKIES, null) ?: "")

    private fun parseCookies(header: String): MutableMap<String, String> {
        val out = LinkedHashMap<String, String>()
        for (part in header.split(';')) {
            val eq = part.indexOf('=')
            if (eq > 0) out[part.substring(0, eq).trim()] = part.substring(eq + 1).trim()
        }
        return out
    }

    private fun save(ctx: Context, map: Map<String, String>) {
        prefs(ctx).edit().putString(KEY_COOKIES, map.entries.joinToString("; ") { "${it.key}=${it.value}" }).apply()
    }

    private fun hasSession(map: Map<String, String>) =
        map.containsKey("SAPISID") || map.containsKey("__Secure-3PAPISID")

    fun isSignedIn(ctx: Context) = hasSession(cookies(ctx))

    /** Called by the login page: true once youtube.com holds a signed-in session. */
    internal fun captureFromWebView(ctx: Context): Boolean {
        val manager = CookieManager.getInstance()
        val merged = LinkedHashMap<String, String>()
        for (url in listOf("https://youtube.com", ORIGIN, "https://m.youtube.com")) {
            merged.putAll(parseCookies(manager.getCookie(url) ?: ""))
        }
        if (!hasSession(merged)) return false
        synchronized(lock) { save(ctx, merged) }
        return true
    }

    /** The signed-in session as a Cookie header, for [WatchLink.send]; null when signed out. */
    fun exportCookies(ctx: Context): String? {
        val map = synchronized(lock) { cookies(ctx) }
        if (!hasSession(map)) return null
        return map.entries.joinToString("; ") { "${it.key}=${it.value}" }
    }

    /** Watch: adopts a session received from the phone ([WatchLink]). */
    fun importCookies(ctx: Context, header: String): Boolean {
        val map = parseCookies(header)
        if (!hasSession(map)) return false
        synchronized(lock) { save(ctx, map) }
        return true
    }

    fun signOut(ctx: Context) {
        synchronized(lock) { prefs(ctx).edit().clear().apply() }
        // Also forget the WebView session, so the next sign-in can pick another account.
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            // The watch has no WebView at all (its session came from the phone).
            runCatching {
                CookieManager.getInstance().removeAllCookies(null)
                CookieManager.getInstance().flush()
            }
        }
    }

    // ------------------------------------------------------------ InnerTube

    private fun sha1(text: String) = MessageDigest.getInstance("SHA-1").digest(text.toByteArray())
        .joinToString("") { "%02x".format(it) }

    private fun authorization(map: Map<String, String>): String {
        val ts = System.currentTimeMillis() / 1000
        fun hash(scheme: String, value: String?) = value?.let { "$scheme ${ts}_${sha1("$ts $it $ORIGIN")}" }
        return listOfNotNull(
            hash("SAPISIDHASH", map["SAPISID"] ?: map["__Secure-3PAPISID"]),
            hash("SAPISID1PHASH", map["__Secure-1PAPISID"]),
            hash("SAPISID3PHASH", map["__Secure-3PAPISID"]),
        ).joinToString(" ")
    }

    private fun context(): JSONObject {
        val locale = Locale.getDefault()
        return JSONObject().put("client", JSONObject()
            .put("clientName", "WEB").put("clientVersion", CLIENT_VERSION)
            .put("hl", locale.language.ifBlank { "pt" }).put("gl", locale.country.ifBlank { "BR" })
            .put("userAgent", DESKTOP_UA))
    }

    /**
     * [anonymous]: the call also works signed out (Shorts feed); the session
     * is still sent when there is one, which personalises the answer.
     */
    private fun call(ctx: Context, endpoint: String, body: JSONObject, anonymous: Boolean = false, session: Boolean = true): JSONObject {
        val map = synchronized(lock) { cookies(ctx) }
        val signedIn = session && hasSession(map)
        if (!signedIn && !anonymous) throw IllegalStateException("Entre com sua conta do YouTube")
        body.put("context", context())
        val builder = Request.Builder()
            .url("$ORIGIN/youtubei/v1/$endpoint?prettyPrint=false")
            .header("User-Agent", DESKTOP_UA)
            .header("Origin", ORIGIN).header("X-Origin", ORIGIN).header("Referer", "$ORIGIN/")
            .header("X-Youtube-Client-Name", "1").header("X-Youtube-Client-Version", CLIENT_VERSION)
            .post(body.toString().toRequestBody(json))
        if (signedIn) {
            builder.header("Cookie", map.entries.joinToString("; ") { "${it.key}=${it.value}" })
                .header("Authorization", authorization(map))
                .header("X-Goog-AuthUser", "0")
        }
        val request = builder.build()
        http.newCall(request).execute().use { response ->
            // Google rotates some session cookies; keep the fresh values.
            val fresh = response.headers("Set-Cookie").mapNotNull { line ->
                val pair = line.substringBefore(';')
                val eq = pair.indexOf('=')
                if (eq > 0) pair.substring(0, eq).trim() to pair.substring(eq + 1).trim() else null
            }
            if (fresh.isNotEmpty()) synchronized(lock) {
                val current = cookies(ctx)
                if (hasSession(current)) save(ctx, current.apply { fresh.forEach { (k, v) -> put(k, v) } })
            }
            if (signedIn && (response.code == 401 || response.code == 403)) throw IllegalStateException("Sessão do YouTube expirou; entre de novo")
            if (!response.isSuccessful) throw IllegalStateException("YouTube respondeu ${response.code}")
            return JSONObject(response.body?.string() ?: "{}")
        }
    }

    /** `{signedIn, name, handle, avatar}`; signedIn=false when the session is gone. */
    fun info(ctx: Context): JSONObject {
        if (!isSignedIn(ctx)) return JSONObject().put("signedIn", false)
        val menu = call(ctx, "account/account_menu", JSONObject())
        val header = find(menu, "activeAccountHeaderRenderer")
            ?: return JSONObject().put("signedIn", false).put("expired", true)
        return JSONObject().put("signedIn", true)
            .put("name", text(header.optJSONObject("accountName")))
            .put("handle", text(header.optJSONObject("channelHandle")))
            .put("avatar", thumb(header.optJSONObject("accountPhoto")))
    }

    /** Every channel the account follows: `[{url, title, avatar}]`. */
    fun subscriptions(ctx: Context): JSONArray {
        val out = LinkedHashMap<String, JSONObject>()
        var page = call(ctx, "browse", JSONObject().put("browseId", "FEchannels"))
        var pages = 0
        while (true) {
            walk(page) { key, node ->
                if (key == "channelRenderer" || key == "gridChannelRenderer") {
                    val id = node.optString("channelId")
                    if (id.startsWith("UC") && id !in out) {
                        out[id] = JSONObject().put("url", "https://www.youtube.com/channel/$id")
                            .put("title", text(node.optJSONObject("title"))).put("avatar", thumb(node.optJSONObject("thumbnail")))
                    }
                    true
                } else false
            }
            val token = continuation(page) ?: break
            if (++pages >= 40) break
            page = call(ctx, "browse", JSONObject().put("continuation", token))
        }
        return JSONArray(out.values.toList())
    }

    /** The account's own YouTube home ("recommended for you"). */
    fun home(ctx: Context, token: String?): JSONObject {
        val body = if (token.isNullOrEmpty()) JSONObject().put("browseId", "FEwhat_to_watch") else JSONObject().put("continuation", token)
        val page = call(ctx, "browse", body)
        return JSONObject().put("items", JSONArray(videos(page) + shortsLockups(page))).put("next", continuation(page) ?: JSONObject.NULL)
    }

    // ---------------------------------------------------------------- Shorts

    /**
     * A call that works signed out. An expired session must not take the
     * Shorts tab down with it: the same call is repeated without the account.
     */
    private fun open(ctx: Context, endpoint: String, body: JSONObject): JSONObject = try {
        call(ctx, endpoint, body, anonymous = true)
    } catch (e: IllegalStateException) {
        if (!isSignedIn(ctx)) throw e
        call(ctx, endpoint, body, anonymous = true, session = false)
    }

    /**
     * YouTube's own Shorts feed, the one the Shorts tab of youtube.com plays:
     * personalised when signed in, the regional feed otherwise.
     * `{items, next}`; [token] continues a previous page.
     *
     * Only the first entry of a page carries title and channel; the others
     * come with id and frame only and are completed by [shortInfo].
     */
    fun shorts(ctx: Context, token: String?): JSONObject {
        var first: JSONObject? = null
        var sequence = token
        if (sequence.isNullOrEmpty()) {
            first = open(ctx, "reel/reel_item_watch", JSONObject().put("disablePlayerResponse", true)
                .put("inputType", "REEL_WATCH_INPUT_TYPE_SEEDLESS").put("params", "CA8%3D"))
            sequence = first.optString("sequenceContinuation").ifEmpty { null } ?: return shortsPage(first, null)
        }
        return shortsPage(first, open(ctx, "reel/reel_watch_sequence", JSONObject().put("sequenceParams", sequence)))
    }

    /**
     * Maps the replies to `{items, next}`: [first] is the seed Short (first
     * page only), [sequence] the Shorts that follow. Internal for tests.
     */
    internal fun shortsPage(first: JSONObject?, sequence: JSONObject?): JSONObject {
        val items = LinkedHashMap<String, JSONObject>()
        first?.optJSONObject("replacementEndpoint")?.optJSONObject("reelWatchEndpoint")?.optString("videoId")
            ?.takeIf { it.length == 11 }?.let { items[it] = shortItem(it, overlayInfo(first)) }
        val entries = sequence?.optJSONArray("entries")
        for (i in 0 until (entries?.length() ?: 0)) {
            val reel = entries!!.optJSONObject(i)?.optJSONObject("command")?.optJSONObject("reelWatchEndpoint") ?: continue
            val id = reel.optString("videoId")
            if (id.length != 11 || id in items) continue
            val info = JSONObject()
            reel.optJSONObject("unserializedPrefetchData")?.optJSONObject("playerResponse")?.optJSONObject("videoDetails")?.let { d ->
                info.put("title", d.optString("title")).put("channel", d.optString("author"))
                    .put("channelId", d.optString("channelId")).put("duration", d.optString("lengthSeconds").toIntOrNull() ?: 0)
            }
            items[id] = shortItem(id, info)
        }
        val next = sequence?.optJSONObject("continuationEndpoint")?.optJSONObject("continuationCommand")?.optString("token")?.ifEmpty { null }
        return JSONObject().put("items", JSONArray(items.values.toList())).put("next", next ?: JSONObject.NULL)
    }

    /** Title, channel and counters of one Short: `{title, channel, channelUrl, channelAvatar, likes, comments}`. */
    fun shortInfo(ctx: Context, videoId: String): JSONObject {
        require(Regex("^[a-zA-Z0-9_-]{11}$").matches(videoId)) { "ID de vídeo inválido" }
        return shortInfo(open(ctx, "reel/reel_item_watch", JSONObject().put("disablePlayerResponse", true)
            .put("playerRequest", JSONObject().put("videoId", videoId))))
    }

    /** Internal for tests. */
    internal fun shortInfo(page: JSONObject): JSONObject {
        val info = overlayInfo(page)
        val channelId = info.optString("channelId")
        return JSONObject().put("title", info.optString("title")).put("channel", info.optString("channel"))
            .put("channelUrl", if (channelId.isEmpty()) "" else "$ORIGIN/channel/$channelId")
            .put("channelAvatar", info.optString("avatar"))
            .put("likes", info.optString("likes")).put("comments", info.optString("comments"))
    }

    /** What the Shorts player overlay says about its video. */
    private fun overlayInfo(page: JSONObject): JSONObject {
        val out = JSONObject()
        val overlay = find(page.optJSONObject("overlay"), "reelPlayerOverlayViewModel") ?: return out
        find(overlay, "shortsVideoTitleViewModel")?.let { out.put("title", text(it.optJSONObject("text"))) }
        find(overlay, "reelChannelBarViewModel")?.let { bar ->
            out.put("channel", text(bar.optJSONObject("channelName")).removePrefix("@"))
            out.put("channelId", channelId(bar))
            find(bar, "avatarViewModel")?.let { out.put("avatar", thumb(it.optJSONObject("image"))) }
        }
        val buttons = find(overlay, "reelActionBarViewModel")?.optJSONArray("buttonViewModels")
        for (i in 0 until (buttons?.length() ?: 0)) {
            val button = buttons!!.optJSONObject(i) ?: continue
            if (button.has("likeButtonViewModel")) {
                find(button, "defaultButtonViewModel")?.let { d -> find(d, "buttonViewModel")?.let { out.put("likes", it.optString("title")) } }
            } else if (i == 1) {
                // The comments button: its label is the count ("157").
                button.optJSONObject("buttonViewModel")?.optString("title")?.takeIf { it.any(Char::isDigit) }?.let { out.put("comments", it) }
            }
        }
        return out
    }

    private fun shortItem(id: String, info: JSONObject): JSONObject {
        val channelId = info.optString("channelId")
        val channel = info.optString("channel")
        // "oar2" is the vertical frame YouTube uses for Shorts covers.
        val cover = "https://i.ytimg.com/vi/$id/oar2.jpg"
        return JSONObject().put("type", "video").put("url", "$ORIGIN/shorts/$id").put("title", info.optString("title"))
            .put("artist", channel).put("channel", channel)
            .put("channelUrl", if (channelId.isEmpty()) "" else "$ORIGIN/channel/$channelId")
            .put("channelAvatar", info.optString("avatar")).put("cover", cover).put("coverHd", cover)
            .put("duration", info.optInt("duration", 0)).put("views", info.optLong("views", -1)).put("uploaded", "").put("uploadedAt", 0)
            .put("shorts", true).put("verified", false).put("live", false)
    }

    /** Shorts shown on shelves of a browse page (home, subscriptions). */
    internal fun shortsLockups(page: JSONObject): List<JSONObject> {
        val out = LinkedHashMap<String, JSONObject>()
        walk(page) { key, node ->
            if (key != "shortsLockupViewModel") return@walk key == "adSlotRenderer"
            val id = find(node, "reelWatchEndpoint")?.optString("videoId").orEmpty()
            if (id.length == 11 && id !in out) {
                val meta = node.optJSONObject("overlayMetadata")
                val info = JSONObject().put("title", text(meta?.optJSONObject("primaryText")))
                    .put("views", count(text(meta?.optJSONObject("secondaryText"))))
                out[id] = shortItem(id, info).also { item ->
                    thumb(node.optJSONObject("thumbnail")).takeIf { it.isNotEmpty() }?.let { item.put("cover", it).put("coverHd", it) }
                }
            }
            true
        }
        return out.values.toList()
    }

    /** "1,2 mi de visualizações" / "45 mil views" / "1.2M views" → number, -1 when unreadable. */
    internal fun count(label: String): Long {
        val m = Regex("""(\d+(?:[.,]\d+)?)\s*(mil|mi|bi|k|m|b)?""", RegexOption.IGNORE_CASE).find(label.replace('\u00a0', ' ')) ?: return -1
        val unit = m.groupValues[2].lowercase()
        val raw = m.groupValues[1]
        // With a unit the separator is decimal ("1,2 mi"); without, thousands ("1.234").
        val number = if (unit.isEmpty()) raw.replace(".", "").replace(",", "").toDoubleOrNull()
            else raw.replace(',', '.').toDoubleOrNull()
        val scale = when (unit) { "mil", "k" -> 1e3; "mi", "m" -> 1e6; "bi", "b" -> 1e9; else -> 1.0 }
        return number?.times(scale)?.toLong() ?: -1
    }

    // -------------------------------------------------------------- parsing

    /** Depth-first walk; [visit] returns true to stop descending into a node. */
    private fun walk(node: Any?, visit: (String, JSONObject) -> Boolean) {
        when (node) {
            is JSONObject -> for (key in node.keys()) {
                val child = node.opt(key)
                if (child is JSONObject && visit(key, child)) continue
                walk(child, visit)
            }
            is JSONArray -> for (i in 0 until node.length()) walk(node.opt(i), visit)
        }
    }

    private fun find(node: Any?, name: String): JSONObject? {
        var found: JSONObject? = null
        walk(node) { key, child -> if (found == null && key == name) { found = child; true } else found != null }
        return found
    }

    private fun continuation(page: JSONObject): String? {
        var token: String? = null
        walk(page) { key, node ->
            if (token == null && key == "continuationCommand") token = node.optString("token").ifEmpty { null }
            token != null
        }
        return token
    }

    private fun text(node: JSONObject?): String {
        if (node == null) return ""
        node.optString("simpleText").takeIf { it.isNotEmpty() }?.let { return it }
        node.optString("content").takeIf { it.isNotEmpty() }?.let { return it }
        val runs = node.optJSONArray("runs") ?: return ""
        return (0 until runs.length()).joinToString("") { runs.optJSONObject(it)?.optString("text") ?: "" }
    }

    private fun https(url: String) = if (url.startsWith("//")) "https:$url" else url

    /** Largest image of a `{thumbnails:[...]}` or `{sources:[...]}` node. */
    private fun thumb(node: JSONObject?): String {
        val list = node?.optJSONArray("thumbnails") ?: node?.optJSONArray("sources") ?: return ""
        var best = ""
        var width = -1
        for (i in 0 until list.length()) {
            val t = list.optJSONObject(i) ?: continue
            if (t.optInt("width", 0) >= width) { width = t.optInt("width", 0); best = t.optString("url") }
        }
        return https(best)
    }

    private fun seconds(label: String): Int {
        if (!Regex("""^\d+(:\d{1,2}){1,2}$""").matches(label.trim())) return 0
        return label.trim().split(':').fold(0) { acc, part -> acc * 60 + (part.toIntOrNull() ?: 0) }
    }

    private fun channelId(node: Any?): String {
        var id = ""
        walk(node) { key, child ->
            if (id.isEmpty() && key == "browseEndpoint") child.optString("browseId").takeIf { it.startsWith("UC") }?.let { id = it }
            id.isNotEmpty()
        }
        return id
    }

    private fun item(id: String, title: String, channel: String, channelId: String, avatar: String,
                     cover: String, duration: Int, uploaded: String, live: Boolean): JSONObject {
        val hd = "https://i.ytimg.com/vi/$id/hqdefault.jpg"
        return JSONObject().put("type", "video").put("url", "https://www.youtube.com/watch?v=$id").put("title", title)
            .put("artist", channel).put("channel", channel)
            .put("channelUrl", if (channelId.isEmpty()) "" else "https://www.youtube.com/channel/$channelId")
            .put("channelAvatar", avatar).put("cover", cover.ifEmpty { hd }).put("coverHd", cover.ifEmpty { hd })
            .put("duration", duration).put("views", -1).put("uploaded", uploaded).put("uploadedAt", 0)
            .put("shorts", false).put("verified", false).put("live", live)
    }

    private fun videos(page: JSONObject): List<JSONObject> {
        val out = LinkedHashMap<String, JSONObject>()
        walk(page) { key, node ->
            when (key) {
                "videoRenderer", "gridVideoRenderer", "compactVideoRenderer" -> {
                    val id = node.optString("videoId")
                    if (id.length == 11 && id !in out) {
                        val owner = node.optJSONObject("ownerText") ?: node.optJSONObject("shortBylineText") ?: node.optJSONObject("longBylineText")
                        val live = node.toString().contains("\"LIVE\"")
                        out[id] = item(id, text(node.optJSONObject("title")), text(owner), channelId(owner),
                            thumb(node.optJSONObject("channelThumbnailSupportedRenderers")?.optJSONObject("channelThumbnailWithLinkRenderer")?.optJSONObject("thumbnail")),
                            thumb(node.optJSONObject("thumbnail")), seconds(text(node.optJSONObject("lengthText"))),
                            text(node.optJSONObject("publishedTimeText")), live)
                    }
                    true
                }
                "lockupViewModel" -> {
                    val id = node.optString("contentId")
                    if (node.optString("contentType") == "LOCKUP_CONTENT_TYPE_VIDEO" && id.length == 11 && id !in out) {
                        val meta = node.optJSONObject("metadata")?.optJSONObject("lockupMetadataViewModel")
                        val parts = mutableListOf<String>()
                        walk(meta?.optJSONObject("metadata")) { k, n ->
                            if (k == "text" && n.has("content")) parts += n.optString("content"); false
                        }
                        var duration = 0
                        var live = false
                        val image = node.optJSONObject("contentImage")
                        walk(image) { k, n ->
                            if (k == "thumbnailBadgeViewModel") {
                                val label = n.optString("text")
                                if (seconds(label) > 0) duration = seconds(label)
                                if (n.optString("badgeStyle").contains("LIVE")) live = true
                            }
                            false
                        }
                        var avatar = ""
                        walk(meta?.optJSONObject("image")) { k, n -> if (avatar.isEmpty() && k == "image") avatar = thumb(n); avatar.isNotEmpty() }
                        out[id] = item(id, text(meta?.optJSONObject("title")), parts.firstOrNull() ?: "",
                            channelId(meta), avatar, thumb(image?.optJSONObject("thumbnailViewModel")?.optJSONObject("image")),
                            duration, parts.drop(1).lastOrNull() ?: "", live)
                    }
                    true
                }
                // Shorts shelves are read by shortsLockups(); ads are skipped.
                "reelShelfRenderer", "richShelfRenderer", "adSlotRenderer" ->
                    node.toString().contains("reelWatchEndpoint") || key == "adSlotRenderer"
                else -> false
            }
        }
        return out.values.toList()
    }
}

/**
 * The regular Google sign-in page. Finishes as soon as youtube.com holds a
 * signed-in session; the result goes to [onResult] (one login at a time).
 */
class YoutubeLoginActivity : Activity() {
    companion object {
        @Volatile var onResult: ((Boolean) -> Unit)? = null
    }

    private var done = false
    private lateinit var web: WebView

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = Color.BLACK
        val density = resources.displayMetrics.density
        fun dp(v: Int) = (v * density).toInt()

        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(Color.BLACK)
            setPadding(dp(4), 0, dp(16), 0)
        }
        bar.addView(ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            setColorFilter(Color.WHITE)
            setBackgroundColor(Color.TRANSPARENT)
            contentDescription = "Cancelar"
            setOnClickListener { finish() }
        }, LinearLayout.LayoutParams(dp(48), dp(48)))
        bar.addView(TextView(this).apply {
            text = "Entrar no YouTube"
            setTextColor(Color.WHITE)
            textSize = 18f
            typeface = Typeface.DEFAULT_BOLD
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))

        val progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = false
            max = 100
            progressTintList = android.content.res.ColorStateList.valueOf(Color.rgb(255, 0, 51))
        }

        web = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.cacheMode = WebSettings.LOAD_DEFAULT
            // Google refuses sign-in inside an embedded browser that announces
            // itself ("; wv"); present the same UA as mobile Chrome.
            settings.userAgentString = WebSettings.getDefaultUserAgent(context)
                .replace("; wv", "").replace(Regex("""Version/\d+(\.\d+)* """), "")
            CookieManager.getInstance().setAcceptCookie(true)
            CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
            webChromeClient = object : WebChromeClient() {
                override fun onProgressChanged(view: WebView, newProgress: Int) {
                    progress.progress = newProgress
                    progress.visibility = if (newProgress >= 100) View.INVISIBLE else View.VISIBLE
                }
            }
            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, url: String) {
                    val host = android.net.Uri.parse(url).host ?: ""
                    if (host.endsWith("youtube.com")) {
                        CookieManager.getInstance().flush()
                        if (YoutubeAccount.captureFromWebView(applicationContext)) finishWith(true)
                    }
                }
            }
        }

        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            fitsSystemWindows = true
            addView(bar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56)))
            addView(progress, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(3)))
            addView(web, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        })
        registerBack()
        if (savedInstanceState == null) web.loadUrl(YoutubeAccount.LOGIN_URL) else web.restoreState(savedInstanceState)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        web.saveState(outState)
    }

    @Deprecated("Activity back handling")
    override fun onBackPressed() {
        if (web.canGoBack()) web.goBack() else super.onBackPressed()
    }

    /** Android 13+ (mandatory on 16) delivers back through this dispatcher. */
    private fun registerBack() {
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT) {
                if (web.canGoBack()) web.goBack() else finish()
            }
        }
    }

    private fun finishWith(ok: Boolean) {
        if (done) return
        done = true
        onResult?.invoke(ok)
        onResult = null
        finish()
    }

    override fun onDestroy() {
        if (isFinishing) finishWith(false)
        web.destroy()
        super.onDestroy()
    }
}
