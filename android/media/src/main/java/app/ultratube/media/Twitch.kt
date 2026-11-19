package app.ultratube.media

import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlin.random.Random

/**
 * Twitch for native surfaces (Wear OS): directory/search through the public
 * web GraphQL endpoint (no account), and ad-free live playlists.
 *
 * Twitch stitches ads into the HLS media playlist on the server. [playlist]
 * rebuilds that playlist on every player refresh: ad segments (EXTINF title
 * without "live") never reach the player, and during a break the same moment
 * is taken from a backup access token (embed/popout/autoplay), merged by
 * PROGRAM-DATE-TIME with our own sequence numbers. Same logic as the Dart
 * `TwitchProxy` used by the phone/desktop app.
 */
object Twitch {
    private const val CLIENT_ID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    private const val UA = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/131.0 Mobile Safari/537.36"
    private val json = "application/json".toMediaType()
    private val deviceId = (1..32).map { "abcdefghijklmnopqrstuvwxyz0123456789"[Random.nextInt(36)] }.joinToString("")
    private val http = OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS).readTimeout(15, TimeUnit.SECONDS).build()
    private val loginRe = Regex("^[a-zA-Z0-9_]{2,25}$")

    fun validLogin(login: String) = loginRe.matches(login)

    private fun gql(query: String, variables: JSONObject = JSONObject()): JSONObject {
        val body = JSONObject().put("query", query).put("variables", variables).toString().toRequestBody(json)
        val req = Request.Builder().url("https://gql.twitch.tv/gql").post(body)
            .header("Client-ID", CLIENT_ID).header("X-Device-Id", deviceId).header("User-Agent", UA).build()
        http.newCall(req).execute().use {
            check(it.isSuccessful) { "Twitch respondeu ${it.code}" }
            val root = JSONObject(it.body!!.string())
            val data = root.optJSONObject("data")
            if (data == null) error("Twitch: ${root.optJSONArray("errors")?.optJSONObject(0)?.optString("message") ?: "sem dados"}")
            return data
        }
    }

    private const val STREAM_FIELDS = "id title viewersCount createdAt previewImageURL(width: 440, height: 248) " +
        "broadcaster { login displayName profileImageURL(width: 70) } game { displayName }"

    private fun streamItem(node: JSONObject): JSONObject? {
        val b = node.optJSONObject("broadcaster") ?: return null
        val login = b.optString("login").ifBlank { return null }
        return JSONObject().put("type", "twitch").put("login", login)
            .put("url", "https://www.twitch.tv/$login")
            .put("title", node.optString("title").ifBlank { b.optString("displayName") })
            .put("artist", b.optString("displayName", login)).put("channel", b.optString("displayName", login))
            .put("viewers", node.optInt("viewersCount", -1))
            .put("game", node.optJSONObject("game")?.optString("displayName").orEmpty())
            .put("cover", node.optString("previewImageURL")).put("avatar", b.optString("profileImageURL"))
            .put("live", true)
    }

    /** Most watched lives (language "pt", "en"… or "" for all). Max 30. */
    fun top(language: String = "pt"): JSONArray {
        val vars = JSONObject().put("langs", if (language.isBlank()) JSONObject.NULL else JSONArray().put(language.uppercase()))
        val data = gql("query(\$langs: [Language!]) { streams(first: 30, options: {languages: \$langs}) { edges { node { $STREAM_FIELDS } } } }", vars)
        val out = JSONArray()
        val edges = data.optJSONObject("streams")?.optJSONArray("edges") ?: return out
        for (i in 0 until edges.length()) streamItem(edges.getJSONObject(i).getJSONObject("node"))?.let(out::put)
        return out
    }

    /** Channels matching [query]: live ones as playable items first. */
    fun search(query: String): JSONArray {
        val q = query.trim().take(100)
        require(q.isNotEmpty()) { "Digite um canal" }
        val data = gql(
            "query(\$q: String!) { searchUsers(userQuery: \$q, first: 20) { edges { node { login displayName profileImageURL(width: 70) followers { totalCount } stream { $STREAM_FIELDS } } } } }",
            JSONObject().put("q", q),
        )
        val live = ArrayList<JSONObject>(); val offline = ArrayList<JSONObject>()
        val edges = data.optJSONObject("searchUsers")?.optJSONArray("edges") ?: JSONArray()
        for (i in 0 until edges.length()) {
            val u = edges.getJSONObject(i).optJSONObject("node") ?: continue
            val stream = u.optJSONObject("stream")
            if (stream != null) {
                stream.put("broadcaster", JSONObject().put("login", u.optString("login")).put("displayName", u.optString("displayName")).put("profileImageURL", u.optString("profileImageURL")))
                streamItem(stream)?.let(live::add)
            } else {
                offline += JSONObject().put("type", "twitch").put("login", u.optString("login")).put("title", u.optString("displayName"))
                    .put("artist", "Offline").put("cover", u.optString("profileImageURL")).put("live", false)
            }
        }
        live.sortByDescending { it.optInt("viewers") }
        return JSONArray(live + offline)
    }

    // ------------------------------------------------------------ playback

    private const val TOKEN_QUERY =
        "query PlaybackAccessToken_Template(\$login: String!, \$isLive: Boolean!, \$vodID: ID!, \$isVod: Boolean!, \$playerType: String!, \$platform: String!) { " +
            "streamPlaybackAccessToken(channelName: \$login, params: {platform: \$platform, playerBackend: \"mediaplayer\", playerType: \$playerType}) @include(if: \$isLive) { value signature } " +
            "videoPlaybackAccessToken(id: \$vodID, params: {platform: \$platform, playerBackend: \"mediaplayer\", playerType: \$playerType}) @include(if: \$isVod) { value signature } }"

    private fun fetch(url: String): String {
        http.newCall(Request.Builder().url(url).header("User-Agent", UA).build()).execute().use {
            if (it.code == 404) throw java.io.IOException("Transmissão offline")
            if (!it.isSuccessful) throw java.io.IOException("Twitch respondeu ${it.code}")
            return it.body!!.string()
        }
    }

    internal data class Variant(val name: String, val url: String, val bandwidth: Long, val height: Int) {
        val audioOnly get() = name == "audio_only" || height == 0
    }

    internal fun parseMaster(text: String): List<Variant> {
        val media = HashMap<String, String>()
        val out = ArrayList<Variant>()
        var pending: String? = null
        for (raw in text.lines()) {
            val line = raw.trim()
            when {
                line.startsWith("#EXT-X-MEDIA:") -> {
                    val g = Regex("GROUP-ID=\"([^\"]+)\"").find(line)?.groupValues?.get(1)
                    val n = Regex("NAME=\"([^\"]+)\"").find(line)?.groupValues?.get(1)
                    if (g != null && n != null) media[g] = n
                }
                line.startsWith("#EXT-X-STREAM-INF:") -> pending = line
                line.isNotEmpty() && !line.startsWith("#") && pending != null -> {
                    val inf = pending!!
                    val group = Regex("VIDEO=\"([^\"]+)\"").find(inf)?.groupValues?.get(1)
                    out += Variant(
                        name = media[group] ?: group ?: "?",
                        url = line,
                        bandwidth = Regex("BANDWIDTH=(\\d+)").find(inf)?.groupValues?.get(1)?.toLong() ?: 0,
                        height = Regex("RESOLUTION=\\d+x(\\d+)").find(inf)?.groupValues?.get(1)?.toInt() ?: 0,
                    )
                    pending = null
                }
            }
        }
        return out
    }

    /** "audio_only", "best" or a height like "360p": the closest rendition not above it. */
    internal fun pick(variants: List<Variant>, quality: String): Variant {
        val video = variants.filter { !it.audioOnly }.sortedByDescending { it.bandwidth }
        if (quality == "audio_only") return variants.firstOrNull { it.audioOnly } ?: video.last()
        if (video.isEmpty()) return variants.first()
        if (quality == "best") return video.first()
        val want = Regex("^(\\d+)").find(quality)?.groupValues?.get(1)?.toInt() ?: 360
        return video.firstOrNull { it.height in 1..want } ?: video.last()
    }

    private class Source(val login: String, val playerType: String, val platform: String = "web") {
        var variants: List<Variant> = emptyList()
        private var fetchedAt = 0L
        var failedAt = 0L

        fun master(force: Boolean = false) {
            if (!force && variants.isNotEmpty() && System.currentTimeMillis() - fetchedAt < 8 * 60_000) return
            val t = gql(TOKEN_QUERY, JSONObject().put("login", login).put("isLive", true).put("vodID", "").put("isVod", false)
                .put("playerType", playerType).put("platform", platform)).optJSONObject("streamPlaybackAccessToken")
                ?: throw java.io.IOException("Canal offline")
            val url = "https://usher.ttvnw.net/api/channel/hls/$login.m3u8".toHttpUrl().newBuilder()
                .addQueryParameter("sig", t.getString("signature")).addQueryParameter("token", t.getString("value"))
                .addQueryParameter("allow_source", "true").addQueryParameter("allow_audio_only", "true")
                .addQueryParameter("fast_bread", "true").addQueryParameter("p", Random.nextInt(9_999_999).toString())
                .addQueryParameter("player_backend", "mediaplayer").addQueryParameter("playlist_include_framerate", "true")
                .addQueryParameter("supported_codecs", "avc1").addQueryParameter("platform", "web").build().toString()
            val parsed = parseMaster(fetch(url))
            if (parsed.isEmpty()) throw java.io.IOException("Transmissão offline")
            variants = parsed; fetchedAt = System.currentTimeMillis()
        }

        fun media(quality: String): Media = try {
            master(); read(quality)
        } catch (e: Exception) {
            try { master(force = true); read(quality) } catch (e2: Exception) { failedAt = System.currentTimeMillis(); throw e2 }
        }

        private fun read(quality: String): Media {
            val v = pick(variants, quality)
            return Media.parse(fetch(v.url), v.url)
        }
    }

    private class Segment(val uri: String, val duration: Double, val title: String, val pdt: Long?, val map: String?) {
        var discontinuity = false
        val isAd get() = !title.contains("live")
    }

    private class Media(val segments: List<Segment>, val target: Int, val adMarkers: Boolean) {
        val hasAds get() = adMarkers || segments.any { it.isAd }

        companion object {
            fun parse(text: String, base: String): Media {
                val baseUrl = base.toHttpUrl()
                fun abs(u: String) = baseUrl.resolve(u)?.toString() ?: u
                val out = ArrayList<Segment>()
                var target = 6; var ads = false; var pdt: Long? = null; var map: String? = null
                var duration: Double? = null; var title = ""
                for (raw in text.lines()) {
                    val line = raw.trim()
                    when {
                        line.isEmpty() -> {}
                        line.startsWith("#EXT-X-TARGETDURATION:") -> target = line.substring(22).toIntOrNull() ?: target
                        line.startsWith("#EXT-X-PROGRAM-DATE-TIME:") -> pdt = runCatching { Instant.parse(line.substring(25)).toEpochMilli() }.getOrNull()
                        line.startsWith("#EXT-X-MAP:") -> map = Regex("URI=\"([^\"]+)\"").find(line)?.groupValues?.get(1)?.let(::abs)
                        line.startsWith("#EXT-X-DATERANGE:") -> if ("stitched-ad" in line || "twitch-ad-quartile" in line || "X-TV-TWITCH-AD" in line) ads = true
                        line.startsWith("#EXTINF:") -> {
                            val body = line.substring(8); val comma = body.indexOf(',')
                            duration = (if (comma < 0) body else body.substring(0, comma)).toDoubleOrNull()
                            title = if (comma < 0) "" else body.substring(comma + 1)
                        }
                        !line.startsWith("#") && duration != null -> {
                            out += Segment(abs(line), duration!!, title, pdt, map); duration = null; pdt = null; title = ""
                        }
                    }
                }
                return Media(out, target, ads)
            }
        }
    }

    /** Rolling, ad-free playlist for one channel/quality. */
    private class Live(val login: String) {
        val primary = Source(login, "site")
        val backups = listOf(Source(login, "embed"), Source(login, "popout"), Source(login, "autoplay", "android"))
        val window = ArrayList<Segment>()
        var mediaSeq = 0L; var discSeq = 0L; var lastPdt: Long? = null; var lastSource: String? = null
        val seen = HashSet<String>()
        var target = 6
        var quality = ""
        @Volatile var adState = "none"

        @Synchronized
        fun playlist(quality: String): String {
            if (quality != this.quality) { this.quality = quality; window.clear(); seen.clear(); lastPdt = null; lastSource = null }
            val main = primary.media(quality)
            target = main.target
            if (!main.hasAds) {
                adState = "none"; append(main.segments, "site")
            } else {
                var clean: Pair<Media, String>? = null
                for (b in backups) {
                    if (System.currentTimeMillis() - b.failedAt < 30_000) continue
                    val m = runCatching { b.media(quality) }.getOrNull() ?: continue
                    if (!m.hasAds && m.segments.isNotEmpty()) { clean = m to b.playerType; break }
                }
                if (clean != null) { adState = "backup"; append(clean.first.segments, clean.second) }
                else { adState = "blocking"; append(main.segments.filter { !it.isAd }, "site") }
            }
            var waits = 0
            while (window.isEmpty() && waits++ < 4) { // pre-roll on first open: wait for real content
                Thread.sleep(2000)
                append(primary.media(quality).segments.filter { !it.isAd }, "site")
            }
            return render()
        }

        private fun append(incoming: List<Segment>, source: String) {
            val list = if (window.isEmpty() && incoming.size > 6) incoming.takeLast(6) else incoming
            var added = false
            for (s in list) {
                if (s.isAd) continue
                val newer = s.pdt?.let { p -> lastPdt == null || p > lastPdt!! + 250 } ?: (s.uri !in seen)
                if (!newer) continue
                if (lastSource != null && lastSource != source) s.discontinuity = true
                lastSource = source
                s.pdt?.let { lastPdt = it }
                seen += s.uri; window += s; added = true
            }
            if (!added) return
            while (window.size > 24) { val r = window.removeAt(0); mediaSeq++; if (r.discontinuity) discSeq++ }
            if (seen.size > 400) { seen.clear(); window.forEach { seen += it.uri } }
        }

        private fun render(): String {
            val b = StringBuilder("#EXTM3U\n#EXT-X-VERSION:6\n")
            val t = maxOf(target, window.maxOfOrNull { kotlin.math.ceil(it.duration).toInt() } ?: 0)
            b.append("#EXT-X-TARGETDURATION:$t\n#EXT-X-MEDIA-SEQUENCE:$mediaSeq\n#EXT-X-DISCONTINUITY-SEQUENCE:$discSeq\n")
            var map: String? = null
            window.forEachIndexed { i, s ->
                if (s.discontinuity && i > 0) b.append("#EXT-X-DISCONTINUITY\n")
                if (s.map != null && (s.map != map || i == 0)) { b.append("#EXT-X-MAP:URI=\"${s.map}\"\n"); map = s.map }
                s.pdt?.let { b.append("#EXT-X-PROGRAM-DATE-TIME:${Instant.ofEpochMilli(it)}\n") }
                b.append("#EXTINF:%.3f,live\n".format(java.util.Locale.US, s.duration)).append(s.uri).append('\n')
            }
            return b.toString()
        }
    }

    private val lives = ConcurrentHashMap<String, Live>()

    /** Ad-free media playlist text for [login] at [quality] (blocking network call). */
    fun playlist(login: String, quality: String): String {
        require(validLogin(login)) { "Canal inválido" }
        return lives.getOrPut(login.lowercase()) { Live(login.lowercase()) }.playlist(quality)
    }

    /** "none" | "backup" | "blocking" for the channel's current ad break. */
    fun adState(login: String) = lives[login.lowercase()]?.adState ?: "none"

    fun forget(login: String) { lives.remove(login.lowercase()) }
}
