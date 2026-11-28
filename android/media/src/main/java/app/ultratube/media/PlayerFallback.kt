package app.ultratube.media

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Second opinion for videos NewPipe reports as unavailable.
 *
 * NewPipe asks YouTube's player API as one fixed client; YouTube refuses that
 * client for many Shorts and some regular videos with `UNPLAYABLE: "This
 * video is not available"`, while the iOS and Android app clients get the
 * same video with direct (unciphered) stream URLs. This asks those clients
 * and maps the answer to [Catalog.resolve]'s JSON shape. Returns null when no
 * client can play it, so the caller rethrows NewPipe's original error.
 *
 * Client versions age: when YouTube retires one, update [clients].
 */
object PlayerFallback {
    data class Client(val name: String, val id: Int, val version: String, val userAgent: String, val extra: JSONObject)

    val clients = listOf(
        Client(
            "IOS", 5, "20.10.4",
            "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            JSONObject().put("deviceMake", "Apple").put("deviceModel", "iPhone16,2")
                .put("osName", "iPhone").put("osVersion", "18.3.2.22D82"),
        ),
        Client(
            "ANDROID", 3, "20.10.38",
            "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip",
            JSONObject().put("androidSdkVersion", 30).put("osName", "Android").put("osVersion", "11"),
        ),
    )

    private val http = OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS).callTimeout(20, TimeUnit.SECONDS).build()

    /** Playable answer from the first client that gets one, or null. */
    fun resolve(videoId: String, video: Boolean, maxHeight: Int, audioQuality: String = AudioQuality.NORMAL): JSONObject? =
        playable(videoId)?.let { (client, response) -> streams(response, video, maxHeight, audioQuality)?.put("client", client.name) }

    /** Watch-page details ([Catalog.video] shape) from a playable answer. */
    fun details(videoId: String): JSONObject? = playable(videoId)?.second?.let(::metadata)

    private fun playable(videoId: String): Pair<Client, JSONObject>? {
        for (client in clients) {
            val response = runCatching { player(client, videoId) }.getOrNull() ?: continue
            if (response.optJSONObject("playabilityStatus")?.optString("status") == "OK" &&
                response.optJSONObject("streamingData") != null
            ) return client to response
        }
        return null
    }

    private fun player(client: Client, videoId: String): JSONObject {
        val context = JSONObject(client.extra.toString())
            .put("clientName", client.name).put("clientVersion", client.version).put("hl", "pt").put("gl", "BR")
        val body = JSONObject().put("context", JSONObject().put("client", context))
            .put("videoId", videoId).put("contentCheckOk", true).put("racyCheckOk", true)
        val request = Request.Builder()
            .url("https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false")
            .header("User-Agent", client.userAgent)
            .header("X-YouTube-Client-Name", client.id.toString())
            .header("X-YouTube-Client-Version", client.version)
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .build()
        var attempt = 0
        while (true) {
            try {
                http.newCall(request).execute().use {
                    if (!it.isSuccessful) throw IOException("player ${it.code}")
                    return JSONObject(it.body!!.string())
                }
            } catch (e: IOException) {
                if (++attempt >= 2) throw e
                Thread.sleep(500)
            }
        }
    }

    private data class Format(val url: String, val mime: String, val width: Int, val height: Int, val bitrate: Long, val fps: Int,
                              val drc: Boolean = false, val original: Boolean = true) {
        val isVideo get() = mime.startsWith("video/")
        val isMp4 get() = mime.startsWith("video/mp4") || mime.startsWith("audio/mp4")
        /** Quality as YouTube labels it: the short side (1080 for 1920x1080 and 1080x1920). */
        val quality get() = if (width > 0) minOf(width, height) else height
    }

    private fun formats(array: JSONArray?): List<Format> = (0 until (array?.length() ?: 0)).mapNotNull { i ->
        val f = array!!.getJSONObject(i)
        val url = f.optString("url").takeIf { it.startsWith("https://") } ?: return@mapNotNull null // ciphered
        // Multi-language videos list every dubbed track; the default one is the original.
        val original = f.optJSONObject("audioTrack")?.optBoolean("audioIsDefault", true) ?: true
        Format(url, f.optString("mimeType"), f.optInt("width"), f.optInt("height"), f.optLong("bitrate"), f.optInt("fps"),
            drc = f.optBoolean("isDrc"), original = original)
    }

    /** Maps a playable player response to the resolve JSON; internal for tests. */
    internal fun streams(response: JSONObject, video: Boolean, maxHeight: Int, audioQuality: String = AudioQuality.NORMAL): JSONObject? {
        val data = response.optJSONObject("streamingData") ?: return null
        val result = metadata(response)
        val hls = data.optString("hlsManifestUrl").takeIf { it.startsWith("https://") }
        if (result.optBoolean("live")) {
            hls ?: return null
            return result.put("hls", hls).put("stream", hls).put("height", 0)
        }
        val adaptive = formats(data.optJSONArray("adaptiveFormats"))
        val audios = adaptive.filter { it.mime.startsWith("audio/") }.let { all ->
            // Plain, original-language tracks first (no dubs, no "stable volume" DRC copies).
            all.filter { it.original && !it.drc }.ifEmpty { all }
        }
        val audio = AudioQuality.pick(audios, audioQuality, { it.bitrate }, { it.isMp4 })
        if (!video) {
            val stream = audio?.url ?: hls ?: return null
            return result.put("stream", stream)
        }
        // Prefer H.264 (hardware decoded everywhere), then quality and fps — as NewPipe's path does.
        val videoOnly = adaptive.filter { it.isVideo && it.quality in 1..maxHeight }
            .maxWithOrNull(compareBy<Format>({ it.quality }, { if (it.isMp4) 1 else 0 }, { it.fps }))
        val muxed = formats(data.optJSONArray("formats")).filter { it.isVideo }.maxByOrNull { it.quality }
        return when {
            videoOnly != null && audio != null && videoOnly.quality > (muxed?.quality ?: 0) ->
                result.put("stream", videoOnly.url).put("audio", audio.url).put("height", videoOnly.height)
            muxed != null -> result.put("stream", muxed.url).put("height", muxed.height)
            hls != null -> result.put("stream", hls).put("height", 0)
            else -> null
        }
    }

    /** Title/channel/cover from `videoDetails` ([Catalog.video] keys). */
    internal fun metadata(response: JSONObject): JSONObject {
        val d = response.optJSONObject("videoDetails") ?: JSONObject()
        val id = d.optString("videoId")
        val thumbs = d.optJSONObject("thumbnail")?.optJSONArray("thumbnails")
        val cover = thumbs?.let { if (it.length() > 0) it.getJSONObject(it.length() - 1).optString("url") else "" } ?: ""
        val author = d.optString("author")
        return JSONObject().put("url", "https://www.youtube.com/watch?v=$id").put("id", id)
            .put("title", d.optString("title")).put("channel", author).put("artist", Catalog.artistName(author))
            .put("channelUrl", d.optString("channelId").takeIf { it.isNotEmpty() }?.let { "https://www.youtube.com/channel/$it" } ?: "")
            .put("channelAvatar", "").put("subscribers", -1L).put("verified", false)
            .put("views", d.optString("viewCount").toLongOrNull() ?: -1L).put("likes", -1L)
            .put("uploaded", "").put("uploadedAt", 0L)
            .put("description", d.optString("shortDescription")).put("descriptionHtml", false)
            .put("cover", cover).put("coverHd", cover)
            .put("duration", d.optString("lengthSeconds").toLongOrNull() ?: 0L)
            .put("live", d.optBoolean("isLive"))
            .put("related", JSONArray())
    }
}
