package app.ultratube.media

import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request as HttpRequest
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import org.schabi.newpipe.extractor.Image
import org.schabi.newpipe.extractor.InfoItem
import org.schabi.newpipe.extractor.MediaFormat
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.Page
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.channel.ChannelInfo
import org.schabi.newpipe.extractor.channel.ChannelInfoItem
import org.schabi.newpipe.extractor.channel.tabs.ChannelTabInfo
import org.schabi.newpipe.extractor.channel.tabs.ChannelTabs
import org.schabi.newpipe.extractor.comments.CommentsInfo
import org.schabi.newpipe.extractor.comments.CommentsInfoItem
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.exceptions.ContentNotAvailableException
import org.schabi.newpipe.extractor.exceptions.ParsingException
import org.schabi.newpipe.extractor.services.youtube.YoutubeJavaScriptPlayerManager
import org.schabi.newpipe.extractor.feed.FeedInfo
import org.schabi.newpipe.extractor.kiosk.KioskInfo
import org.schabi.newpipe.extractor.linkhandler.ListLinkHandler
import org.schabi.newpipe.extractor.localization.ContentCountry
import org.schabi.newpipe.extractor.localization.Localization
import org.schabi.newpipe.extractor.playlist.PlaylistInfo
import org.schabi.newpipe.extractor.playlist.PlaylistInfoItem
import org.schabi.newpipe.extractor.search.SearchInfo
import org.schabi.newpipe.extractor.stream.StreamInfo
import org.schabi.newpipe.extractor.stream.StreamInfoItem
import org.schabi.newpipe.extractor.stream.StreamType
import org.schabi.newpipe.extractor.stream.VideoStream
import android.util.Log
import java.io.IOException
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * YouTube catalog through NewPipeExtractor: no account, no API key, no ads.
 * Every list call returns `{items: [...], next: token|null}`; the token is an
 * opaque handle to the extractor's continuation page, kept in memory.
 */
object Catalog {
    private val http = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS).callTimeout(45, TimeUnit.SECONDS).build()
    private val service = ServiceList.YouTube
    private val pool = Executors.newFixedThreadPool(6)
    private val hosts = setOf("www.youtube.com", "youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be")

    init {
        val locale = Locale.getDefault()
        NewPipe.init(object : Downloader() {
            override fun execute(request: Request): Response {
                val builder = HttpRequest.Builder().url(request.url())
                    .header("User-Agent", "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/131.0 Mobile Safari/537.36")
                request.headers().forEach { (key, values) -> values.forEach { builder.addHeader(key, it) } }
                builder.method(request.httpMethod(), request.dataToSend()?.toRequestBody())
                val call = builder.build()
                // Sockets die while the phone sleeps and the radio needs a
                // moment after unlock: retry plain I/O failures with backoff.
                var attempt = 0
                while (true) {
                    try {
                        http.newCall(call).execute().use {
                            return Response(it.code, it.message, it.headers.toMultimap(), it.body?.string(), it.request.url.toString())
                        }
                    } catch (e: IOException) {
                        if (++attempt >= NET_RETRIES) throw e
                        Thread.sleep(NET_BACKOFF_MS * attempt)
                    }
                }
            }
        }, Localization(locale.language.ifBlank { "pt" }, locale.country.ifBlank { "BR" }), ContentCountry(locale.country.ifBlank { "BR" }))
    }

    private const val NET_RETRIES = 3
    private const val NET_BACKOFF_MS = 700L

    /**
     * Content the viewer can never play (private, removed, age/region/paid).
     * Everything else (network, YouTube hiccups, stale player JS) is retried.
     */
    fun isPermanent(e: Throwable): Boolean = e is ContentNotAvailableException

    /**
     * Runs a watch-page extraction, retrying transient failures. A parsing
     * failure usually means YouTube rotated its player JS: drop NewPipe's
     * cached deobfuscation code before trying again.
     */
    private fun <T> extract(block: () -> T): T {
        var attempt = 0
        while (true) {
            try {
                return block()
            } catch (e: Exception) {
                if (isPermanent(e) || e is IllegalArgumentException || ++attempt >= 3) throw e
                if (e is ParsingException) runCatching { YoutubeJavaScriptPlayerManager.clearAllCaches() }
                Thread.sleep(NET_BACKOFF_MS * attempt)
            }
        }
    }

    // ------------------------------------------------------------ pagination

    private sealed interface Cursor
    private data class SearchCursor(val handler: org.schabi.newpipe.extractor.linkhandler.SearchQueryHandler, val page: Page, val filter: (InfoItem) -> Boolean) : Cursor
    private data class KioskCursor(val url: String, val page: Page) : Cursor
    private data class TabCursor(val handler: ListLinkHandler, val page: Page) : Cursor
    private data class CommentsCursor(val url: String, val page: Page) : Cursor
    private data class PlaylistCursor(val url: String, val page: Page) : Cursor
    private val cursors = object : LinkedHashMap<String, Cursor>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Cursor>?) = size > 200
    }
    private fun remember(cursor: Cursor?): Any = cursor?.let { synchronized(cursors) { UUID.randomUUID().toString().also { id -> cursors[id] = cursor } } } ?: JSONObject.NULL
    private fun page(items: List<JSONObject>, next: Cursor?) = JSONObject().put("items", JSONArray(items)).put("next", remember(next))

    /** Continues any list returned earlier. */
    fun more(token: String): JSONObject {
        val cursor = synchronized(cursors) { cursors[token] } ?: error("Lista expirada; atualize a página")
        return when (cursor) {
            is SearchCursor -> {
                var p = SearchInfo.getMoreItems(service, cursor.handler, cursor.page)
                var items = p.items.filter(cursor.filter).mapNotNull(::item)
                var hops = 0
                while (items.size < 8 && p.nextPage != null && hops++ < 3) {
                    p = SearchInfo.getMoreItems(service, cursor.handler, p.nextPage)
                    items = items + p.items.filter(cursor.filter).mapNotNull(::item)
                }
                page(items, p.nextPage?.let { SearchCursor(cursor.handler, it, cursor.filter) })
            }
            is KioskCursor -> KioskInfo.getMoreItems(service, cursor.url, cursor.page).let { p ->
                page(p.items.mapNotNull(::item), p.nextPage?.let { KioskCursor(cursor.url, it) })
            }
            is TabCursor -> ChannelTabInfo.getMoreItems(service, cursor.handler, cursor.page).let { p ->
                page(p.items.mapNotNull(::item), p.nextPage?.let { TabCursor(cursor.handler, it) })
            }
            is PlaylistCursor -> PlaylistInfo.getMoreItems(service, cursor.url, cursor.page).let { p ->
                page(p.items.mapNotNull(::item), p.nextPage?.let { PlaylistCursor(cursor.url, it) })
            }
            is CommentsCursor -> CommentsInfo.getMoreItems(service, cursor.url, cursor.page).let { p ->
                page(p.items.map(::comment), p.nextPage?.let { CommentsCursor(cursor.url, it) })
            }
        }
    }

    // ---------------------------------------------------------------- search

    /**
     * [kind]: all | videos | shorts | channels | playlists | music (songs) |
     * music_videos | music_albums | music_playlists | music_artists.
     */
    fun search(query: String, kind: String): JSONObject {
        require(query.isNotBlank()) { "Digite uma busca" }
        val filter = when (kind) {
            "music" -> "music_songs"
            "videos", "channels", "playlists", "music_videos", "music_albums", "music_playlists", "music_artists" -> kind
            else -> "all"
        }
        val accept: (InfoItem) -> Boolean = when (kind) {
            "shorts" -> { it -> it is StreamInfoItem && isShort(it) }
            "videos" -> { it -> it is StreamInfoItem && !it.isShortFormContent }
            else -> { _ -> true }
        }
        val handler = service.searchQHFactory.fromQuery(query.take(200), listOf(filter), "")
        val info = SearchInfo.getInfo(service, handler)
        var items = info.relatedItems.filter(accept).mapNotNull(::item)
        var next = info.nextPage
        // Shorts/videos filters can empty a page; keep reading until something shows.
        val want = if (kind == "shorts") 12 else 8
        var hops = 0
        while (items.size < want && next != null && hops++ < (if (kind == "shorts") 5 else 3)) {
            val more = SearchInfo.getMoreItems(service, handler, next)
            items = items + more.items.filter(accept).mapNotNull(::item)
            next = more.nextPage
        }
        return page(items, next?.let { SearchCursor(handler, it, accept) })
            .put("suggestion", info.searchSuggestion ?: "").put("corrected", info.isCorrectedSearch)
    }

    /** Playlist header plus its first page of videos. */
    fun playlist(url: String): JSONObject {
        val info = PlaylistInfo.getInfo(service, url)
        return page(info.relatedItems.mapNotNull(::item), info.nextPage?.let { PlaylistCursor(url, it) })
            .put("title", info.name).put("channel", info.uploaderName ?: "").put("channelUrl", info.uploaderUrl ?: "")
            .put("cover", hd(best(info.thumbnails, 4000))).put("count", info.streamCount)
    }

    /** Legacy flat search used by the watch: `[items]`. */
    fun search(query: String, music: Boolean, shorts: Boolean = false): JSONArray =
        search(query, if (shorts) "shorts" else if (music) "music" else "videos").getJSONArray("items")

    fun suggestions(query: String): JSONArray =
        if (query.isBlank()) JSONArray() else JSONArray(service.suggestionExtractor.suggestionList(query.take(100)).take(8))

    // ----------------------------------------------------------------- feeds

    /** Kiosk ids available for this region (Trending, live, music, gaming…). */
    fun kiosks(): JSONArray = JSONArray(service.kioskList.availableKiosks.toList())

    fun kiosk(id: String): JSONObject {
        val url = service.kioskList.getListLinkHandlerFactoryByType(id).fromId(id).url
        val info = KioskInfo.getInfo(service, url)
        return page(info.relatedItems.mapNotNull(::item), info.nextPage?.let { KioskCursor(url, it) })
    }

    /**
     * Latest uploads of many channels through YouTube's lightweight RSS feeds,
     * fetched in parallel and merged newest first.
     */
    fun feed(channels: List<String>, perChannel: Int = 15): JSONObject {
        val jobs = channels.distinct().take(300).map { url ->
            pool.submit(Callable { runCatching { FeedInfo.getInfo(service, url).relatedItems.take(perChannel).mapNotNull(::item) } })
        }
        var failed = 0
        val items = jobs.flatMap { job ->
            runCatching { job.get(30, TimeUnit.SECONDS) }.getOrNull()?.getOrNull() ?: run { failed++; emptyList() }
        }.sortedByDescending { it.optLong("uploadedAt") }
        return page(items, null).put("failed", failed)
    }

    // --------------------------------------------------------------- channel

    fun channel(url: String): JSONObject {
        val info = ChannelInfo.getInfo(service, url)
        val result = JSONObject().put("url", info.url).put("id", info.id).put("title", info.name)
            .put("avatar", best(info.avatars, 176)).put("banner", best(info.banners, 1080))
            .put("subscribers", info.subscriberCount).put("description", info.description ?: "")
            .put("verified", info.isVerified)
        val tabs = JSONArray()
        for (tab in info.tabs) {
            val name = tab.contentFilters.firstOrNull() ?: continue
            if (name in setOf(ChannelTabs.VIDEOS, ChannelTabs.SHORTS, ChannelTabs.LIVESTREAMS, ChannelTabs.PLAYLISTS)) tabs.put(name)
        }
        result.put("tabs", tabs)
        // First tab ships with the channel so the page renders in one round trip.
        val first = info.tabs.firstOrNull { it.contentFilters.firstOrNull() == ChannelTabs.VIDEOS } ?: info.tabs.firstOrNull()
        if (first != null) result.put("videos", runCatching { tabPage(first) }.getOrElse { page(emptyList(), null) })
        return result
    }

    fun channelTab(url: String, tab: String): JSONObject {
        val info = ChannelInfo.getInfo(service, url)
        val handler = info.tabs.firstOrNull { it.contentFilters.firstOrNull() == tab } ?: return page(emptyList(), null)
        return tabPage(handler)
    }

    private fun tabPage(handler: ListLinkHandler): JSONObject {
        val info = ChannelTabInfo.getInfo(service, handler)
        return page(info.relatedItems.mapNotNull(::item), info.nextPage?.let { TabCursor(handler, it) })
    }

    // ----------------------------------------------------------------- video

    /** Watch-page details: metadata, channel, description and "up next". */
    fun video(url: String): JSONObject {
        checkUrl(url)
        val info = try {
            extract { StreamInfo.getInfo(service, url) }
        } catch (e: ContentNotAvailableException) {
            return PlayerFallback.details(videoId(url)) ?: throw e
        }
        return JSONObject().put("url", info.url).put("id", info.id).put("title", info.name)
            .put("channel", info.uploaderName ?: "").put("artist", artistName(info.uploaderName))
            .put("channelUrl", info.uploaderUrl ?: "").put("channelAvatar", best(info.uploaderAvatars, 88))
            .put("subscribers", info.uploaderSubscriberCount).put("verified", info.isUploaderVerified)
            .put("views", info.viewCount).put("likes", info.likeCount)
            .put("uploaded", info.textualUploadDate ?: "").put("uploadedAt", info.uploadDate?.instant?.toEpochMilli() ?: 0L)
            .put("description", info.description?.content() ?: "").put("descriptionHtml", info.description?.type()?.name == "HTML")
            .put("cover", best(info.thumbnails, 720)).put("coverHd", hd(best(info.thumbnails, 4000)))
            .put("duration", info.duration)
            .put("live", info.streamType == StreamType.LIVE_STREAM || info.streamType == StreamType.AUDIO_LIVE_STREAM)
            .put("related", JSONArray(info.relatedItems.mapNotNull(::item)))
    }

    /** "Up next" items for endless autoplay; live streams and Shorts excluded. */
    fun related(url: String): JSONArray {
        checkUrl(url)
        val info = extract { StreamInfo.getInfo(service, url) }
        return JSONArray(info.relatedItems.filterIsInstance<StreamInfoItem>()
            .filter { it.duration > 0 && !it.isShortFormContent }.take(20).mapNotNull(::item))
    }

    fun comments(url: String): JSONObject {
        checkUrl(url)
        val info = CommentsInfo.getInfo(service, url)
        if (info.isCommentsDisabled) return page(emptyList(), null).put("disabled", true)
        return page(info.relatedItems.map(::comment), info.nextPage?.let { CommentsCursor(url, it) }).put("count", info.commentsCount)
    }

    /**
     * Playable URLs. Audio mode returns one stream; video mode prefers a
     * separate video-only track (up to [maxHeight]) plus an `audio` track,
     * which is how YouTube serves anything above 360p.
     */
    fun resolve(url: String, video: Boolean, maxHeight: Int = 1080, fast: Boolean = false): JSONObject {
        checkUrl(url)
        val started = System.currentTimeMillis()
        // Shorts: one request to the app client's player API answers in a
        // third of the time of a full watch-page extraction, with direct
        // URLs. Anything it cannot play falls through to NewPipe below.
        if (fast) {
            runCatching { PlayerFallback.resolve(videoId(url), video, maxHeight) }.getOrNull()
                ?.takeIf { !it.optBoolean("live") && it.optString("stream").startsWith("https://") }
                ?.let {
                    Log.i(TAG, "resolve ${videoId(url)} fast via ${it.optString("client")} (${System.currentTimeMillis() - started} ms)")
                    return it.put("url", url)
                }
        }
        val info = try {
            extract { StreamInfo.getInfo(service, url) }
        } catch (e: ContentNotAvailableException) {
            // NewPipe asks YouTube as a client it now refuses for many Shorts
            // and some videos ("UNPLAYABLE: This video is not available").
            // The same video usually plays for the iOS/Android app clients.
            val fallback = PlayerFallback.resolve(videoId(url), video, maxHeight) ?: throw e
            Log.i(TAG, "resolve ${videoId(url)} via ${fallback.optString("client")} after \"${e.message}\" (${System.currentTimeMillis() - started} ms)")
            fallback.optString("hls").takeIf { fallback.optBoolean("live") && it.isNotEmpty() }?.let { hls ->
                runCatching { liveRendition(hls, maxHeight, video) }.getOrNull()?.let { (stream, audio, height) ->
                    fallback.put("stream", stream).put("height", height)
                    if (audio != null) fallback.put("audio", audio) else fallback.remove("audio")
                }
            }
            return fallback.put("url", url)
        }
        Log.i(TAG, "resolve ${info.id} (${System.currentTimeMillis() - started} ms)")
        val result = JSONObject().put("url", url).put("title", info.name)
            .put("artist", artistName(info.uploaderName)).put("cover", hd(best(info.thumbnails, 4000)))
            .put("duration", info.duration)
        val live = info.streamType == StreamType.LIVE_STREAM || info.streamType == StreamType.AUDIO_LIVE_STREAM
        result.put("live", live)
        val hls = info.hlsUrl?.takeIf { it.startsWith("https://") }
        if (live) {
            // Handing the player the HLS master makes it open every rendition
            // at once; YouTube refuses some of those parallel TLS handshakes
            // and one failed rendition kills playback. Pick one video
            // rendition (≤ maxHeight) plus its audio group instead.
            if (hls != null) {
                runCatching { liveRendition(hls, maxHeight, video) }.getOrNull()?.let { (stream, audio, height) ->
                    result.put("stream", stream).put("height", height)
                    if (audio != null) result.put("audio", audio)
                    return result
                }
            }
            val manifest = hls ?: info.dashMpdUrl?.takeIf { it.startsWith("https://") }
            require(!manifest.isNullOrBlank()) { "Transmissão ao vivo indisponível no momento." }
            return result.put("stream", manifest).put("height", 0)
        }
        val audio = info.audioStreams.filter { it.isUrl }.let { streams ->
            streams.filter { it.format == MediaFormat.M4A }.maxByOrNull { it.averageBitrate } ?: streams.maxByOrNull { it.averageBitrate }
        }
        if (!video) {
            val stream = audio?.content ?: hls
            require(!stream.isNullOrBlank()) { "Áudio indisponível para este conteúdo." }
            return result.put("stream", stream)
        }
        // Quality is the short side, as YouTube labels it: a vertical 1080p
        // Short is 1080x1920 and must not be capped down to 480p by its height.
        fun quality(s: VideoStream) = if (s.width > 0 && s.height > 0) minOf(s.width, s.height) else s.height
        val videoOnly = info.videoOnlyStreams.filter { it.isUrl && quality(it) in 1..maxHeight }
            // Prefer H.264 (hardware decoded everywhere), then the highest resolution/fps.
            .maxWithOrNull(compareBy<VideoStream>({ quality(it) }, { if (it.format == MediaFormat.MPEG_4) 1 else 0 }, { it.fps }))
        val muxed = info.videoStreams.filter { it.isUrl }.maxByOrNull { quality(it) }
        return when {
            videoOnly != null && audio != null && quality(videoOnly) > (muxed?.let(::quality) ?: 0) ->
                result.put("stream", videoOnly.content).put("audio", audio.content).put("height", videoOnly.height)
            muxed != null -> result.put("stream", muxed.content).put("height", muxed.height)
            hls != null -> result.put("stream", hls).put("height", 0)
            else -> throw IllegalStateException("Vídeo indisponível; tente o modo áudio.")
        }
    }

    /**
     * Reads a live HLS master: returns (media playlist, audio playlist or
     * null when muxed, height). Audio mode returns the best audio group alone.
     */
    private fun liveRendition(master: String, maxHeight: Int, video: Boolean): Triple<String, String?, Int>? {
        val text = http.newCall(HttpRequest.Builder().url(master).build()).execute().use {
            if (!it.isSuccessful) return null
            it.body?.string() ?: return null
        }
        val base = master.toHttpUrl()
        fun abs(u: String) = base.resolve(u)?.toString() ?: u
        val audioGroups = mutableMapOf<String, String>()
        data class Variant(val url: String, val height: Int, val bandwidth: Long, val audio: String?)
        val variants = mutableListOf<Variant>()
        var pending: String? = null
        for (raw in text.lines()) {
            val line = raw.trim()
            when {
                line.startsWith("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO") -> {
                    val uri = Regex("URI=\"([^\"]+)\"").find(line)?.groupValues?.get(1)
                    val group = Regex("GROUP-ID=\"([^\"]+)\"").find(line)?.groupValues?.get(1)
                    if (uri != null && group != null) audioGroups[group] = abs(uri)
                }
                line.startsWith("#EXT-X-STREAM-INF:") -> pending = line
                line.isNotEmpty() && !line.startsWith("#") && pending != null -> {
                    val inf = pending!!
                    variants += Variant(
                        url = abs(line),
                        height = Regex("RESOLUTION=\\d+x(\\d+)").find(inf)?.groupValues?.get(1)?.toInt() ?: 0,
                        bandwidth = Regex("BANDWIDTH=(\\d+)").find(inf)?.groupValues?.get(1)?.toLong() ?: 0,
                        audio = Regex("AUDIO=\"([^\"]+)\"").find(inf)?.groupValues?.get(1),
                    )
                    pending = null
                }
            }
        }
        if (variants.isEmpty()) return null
        // Highest-bandwidth audio group (YouTube: 233 = low, 234 = high).
        val bestAudioGroup = variants.filter { it.audio != null && audioGroups.containsKey(it.audio) }
            .maxByOrNull { it.bandwidth }?.audio
        if (!video) {
            val audio = bestAudioGroup?.let { audioGroups[it] }
            if (audio != null) return Triple(audio, null, 0)
            val lowest = variants.minByOrNull { it.bandwidth }!!
            return Triple(lowest.url, null, 0)
        }
        val pick = variants.filter { it.height in 1..maxHeight }.maxByOrNull { it.bandwidth }
            ?: variants.minByOrNull { it.height.takeIf { h -> h > 0 } ?: Int.MAX_VALUE }!!
        return Triple(pick.url, pick.audio?.let { audioGroups[it] }, pick.height)
    }

    fun lyrics(title: String, artist: String): JSONObject {
        val url = "https://lrclib.net/api/get".toHttpUrl().newBuilder()
            .addQueryParameter("track_name", title).addQueryParameter("artist_name", artist).build()
        http.newCall(HttpRequest.Builder().url(url).header("User-Agent", "Ultratube/0.2.0").build()).execute().use {
            if (it.code == 404) return JSONObject().put("plainLyrics", "Letra não encontrada")
            check(it.isSuccessful) { "Não foi possível carregar a letra (${it.code})" }
            return JSONObject(it.body!!.string())
        }
    }

    // ---------------------------------------------------------------- mapping

    /**
     * Search results don't always carry the Shorts flag; a short (≤ 3 min)
     * upload tagged #shorts is one too.
     */
    private fun isShort(item: StreamInfoItem) = item.isShortFormContent ||
        (item.duration in 1..180 && (item.name.contains("#short", ignoreCase = true) || item.url.contains("/shorts/")))

    /** YouTube's auto-generated music channels are named "<Artist> - Topic". */
    fun artistName(uploader: String?) = uploader.orEmpty().removeSuffix(" - Topic").trim()

    private const val TAG = "UltratubeCatalog"

    private fun videoId(url: String): String = service.streamLHFactory.getId(url)

    private fun checkUrl(url: String) {
        val parsed = url.toHttpUrl()
        require(parsed.isHttps && parsed.host in hosts) { "Link do YouTube inválido" }
    }

    /**
     * Full-resolution variant: YouTube Music art (googleusercontent/ggpht)
     * is served at whatever size the URL asks for, usually 60–120 px.
     */
    private fun hd(url: String): String = when {
        url.isEmpty() -> url
        "googleusercontent.com" in url || "ggpht.com" in url ->
            url.replace(Regex("=w\\d+-h\\d+[^/]*$"), "=w1080-h1080-l90-rj").replace(Regex("=s\\d+[^/]*$"), "=s1080")
        else -> url
    }

    /** Smallest image at least [width] wide, else the largest one. */
    private fun best(images: List<Image>?, width: Int): String {
        if (images.isNullOrEmpty()) return ""
        return (images.filter { it.width >= width }.minByOrNull { it.width } ?: images.maxByOrNull { it.width })?.url ?: images.last().url
    }

    private fun item(item: InfoItem): JSONObject? = when (item) {
        is StreamInfoItem -> JSONObject().put("type", "video").put("url", item.url).put("title", item.name)
            .put("artist", artistName(item.uploaderName)).put("channel", item.uploaderName ?: "")
            .put("channelUrl", item.uploaderUrl ?: "").put("channelAvatar", best(item.uploaderAvatars, 68))
            .put("cover", best(item.thumbnails, if (item.isShortFormContent) 400 else 480))
            .put("coverHd", hd(best(item.thumbnails, 4000)))
            .put("duration", item.duration).put("views", item.viewCount)
            .put("uploaded", item.textualUploadDate ?: "").put("uploadedAt", item.uploadDate?.instant?.toEpochMilli() ?: 0L)
            .put("shorts", isShort(item)).put("verified", item.isUploaderVerified)
            .put("live", item.streamType == StreamType.LIVE_STREAM)
        is ChannelInfoItem -> JSONObject().put("type", "channel").put("url", item.url).put("title", item.name)
            .put("cover", best(item.thumbnails, 176)).put("subscribers", item.subscriberCount)
            .put("videos", item.streamCount).put("description", item.description ?: "")
        is PlaylistInfoItem -> JSONObject().put("type", "playlist").put("url", item.url).put("title", item.name)
            .put("cover", best(item.thumbnails, 480)).put("coverHd", hd(best(item.thumbnails, 4000)))
            .put("channel", item.uploaderName ?: "").put("channelUrl", item.uploaderUrl ?: "").put("videos", item.streamCount)
        else -> null
    }

    private fun comment(item: CommentsInfoItem) = JSONObject().put("author", item.uploaderName ?: "")
        .put("avatar", best(item.uploaderAvatars, 48)).put("text", item.commentText?.content() ?: "")
        .put("html", item.commentText?.type()?.name == "HTML").put("likes", item.likeCount)
        .put("uploaded", item.textualUploadDate ?: "").put("pinned", item.isPinned)
        .put("hearted", item.isHeartedByUploader).put("replies", item.replyCount)
}
