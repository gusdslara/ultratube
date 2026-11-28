package app.ultratube.media

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayerFallbackTest {
    private fun format(url: String?, mime: String, w: Int, h: Int, bitrate: Long, fps: Int = 30) = JSONObject()
        .put("mimeType", mime).put("width", w).put("height", h).put("bitrate", bitrate).put("fps", fps)
        .apply { if (url != null) put("url", url) else put("signatureCipher", "s=abc&url=https%3A%2F%2Fx") }

    /** A vertical 1080p Short as the iOS client answers it. */
    private fun short(live: Boolean = false) = JSONObject()
        .put("playabilityStatus", JSONObject().put("status", "OK"))
        .put("videoDetails", JSONObject().put("videoId", "vOQvZKGo8m0").put("title", "Um dois")
            .put("author", "Artist - Topic").put("channelId", "UC123").put("lengthSeconds", "42")
            .put("viewCount", "1000").put("isLive", live)
            .put("thumbnail", JSONObject().put("thumbnails", JSONArray()
                .put(JSONObject().put("url", "https://i.ytimg.com/small.jpg"))
                .put(JSONObject().put("url", "https://i.ytimg.com/big.jpg")))))
        .put("streamingData", JSONObject()
            .put("hlsManifestUrl", "https://manifest.googlevideo.com/master.m3u8")
            .put("formats", JSONArray().put(format("https://v/muxed360", "video/mp4; codecs=\"avc1\"", 360, 640, 500_000)))
            .put("adaptiveFormats", JSONArray()
                .put(format("https://v/vp9-1080", "video/webm; codecs=\"vp9\"", 1080, 1920, 2_000_000))
                .put(format("https://v/avc-1080", "video/mp4; codecs=\"avc1\"", 1080, 1920, 3_000_000))
                .put(format("https://v/avc-720", "video/mp4; codecs=\"avc1\"", 720, 1280, 1_500_000))
                .put(format(null, "video/mp4; codecs=\"avc1\"", 2160, 3840, 9_000_000)) // ciphered
                .put(format("https://a/opus", "audio/webm; codecs=\"opus\"", 0, 0, 160_000))
                .put(format("https://a/m4a", "audio/mp4; codecs=\"mp4a\"", 0, 0, 128_000))))

    @Test fun `vertical Short picks H264 at the requested quality plus M4A audio`() {
        val r = PlayerFallback.streams(short(), video = true, maxHeight = 1080)!!
        assertEquals("https://v/avc-1080", r.getString("stream"))
        assertEquals("https://a/m4a", r.getString("audio"))
        assertEquals("Um dois", r.getString("title"))
        assertEquals("Artist", r.getString("artist"))
        assertEquals("https://i.ytimg.com/big.jpg", r.getString("cover"))
        assertEquals(42L, r.getLong("duration"))
        assertFalse(r.getBoolean("live"))
    }

    @Test fun `quality cap uses the short side`() {
        val r = PlayerFallback.streams(short(), video = true, maxHeight = 720)!!
        assertEquals("https://v/avc-720", r.getString("stream"))
    }

    @Test fun `audio mode returns one M4A stream`() {
        val r = PlayerFallback.streams(short(), video = false, maxHeight = 1080)!!
        assertEquals("https://a/m4a", r.getString("stream"))
        assertFalse(r.has("audio"))
    }

    @Test fun `ciphered formats are never used`() {
        val r = PlayerFallback.streams(short(), video = true, maxHeight = 4000)!!
        assertEquals("https://v/avc-1080", r.getString("stream"))
    }

    @Test fun `live answers with its HLS master`() {
        val r = PlayerFallback.streams(short(live = true), video = true, maxHeight = 1080)!!
        assertTrue(r.getBoolean("live"))
        assertEquals("https://manifest.googlevideo.com/master.m3u8", r.getString("stream"))
    }

    @Test fun `no streaming data means no answer`() {
        val r = short().apply { remove("streamingData") }
        assertNull(PlayerFallback.streams(r, video = true, maxHeight = 1080))
    }
}
