package app.ultratube.media

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Shorts feed parsing against replies captured from YouTube (trimmed). */
class YoutubeShortsTest {
    private val replies = JSONObject(javaClass.getResource("/reels.json")!!.readText())
    private val first = replies.getJSONObject("first")
    private val sequence = replies.getJSONObject("sequence")

    private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }

    @Test fun firstPageStartsWithTheSeedShortThenTheSequence() {
        val page = YoutubeAccount.shortsPage(first, sequence)
        val items = page.getJSONArray("items").objects()
        assertEquals("SEQ2", page.getString("next"))
        assertEquals(4, items.size)
        val seed = items.first()
        assertEquals("https://www.youtube.com/shorts/jn-cyR3HV-o", seed.getString("url"))
        assertEquals("7 mentiras ⭐️ - animação roblox", seed.getString("title"))
        assertEquals("pixza_roblox", seed.getString("channel"))
        assertEquals("https://www.youtube.com/channel/UCMl1U9sX0-0F6umMndZwGRA", seed.getString("channelUrl"))
        assertTrue(seed.getString("channelAvatar").startsWith("https://yt3.ggpht.com/"))
        // The sequence names only its first entry.
        assertEquals("Músicas que Todo Jogador de Roblox Conhece", items[1].getString("title"))
        assertEquals("Reizin 2.0", items[1].getString("channel"))
        assertEquals(52, items[1].getInt("duration"))
        assertEquals("", items[2].getString("title"))
        assertTrue(items.all { it.getBoolean("shorts") && it.getString("type") == "video" })
        assertTrue(items.all { it.getString("cover").startsWith("https://i.ytimg.com/vi/") })
    }

    @Test fun laterPagesHaveNoSeedAndTheLastOneNoToken() {
        val page = YoutubeAccount.shortsPage(null, JSONObject().put("entries", sequence.getJSONArray("entries")))
        assertEquals(3, page.getJSONArray("items").length())
        assertTrue(page.isNull("next"))
        assertEquals(0, YoutubeAccount.shortsPage(null, JSONObject()).getJSONArray("items").length())
    }

    @Test fun shortInfoReadsTitleChannelAndCounters() {
        val info = YoutubeAccount.shortInfo(first)
        assertEquals("7 mentiras ⭐️ - animação roblox", info.getString("title"))
        assertEquals("pixza_roblox", info.getString("channel"))
        assertEquals("78 mil", info.getString("likes"))
        assertEquals("157", info.getString("comments"))
    }

    @Test fun homeShelfShortsAreRead() {
        val lockup = JSONObject()
            .put("onTap", JSONObject().put("innertubeCommand", JSONObject().put("reelWatchEndpoint", JSONObject().put("videoId", "abcdefghijk"))))
            .put("overlayMetadata", JSONObject()
                .put("primaryText", JSONObject().put("content", "Um Short"))
                .put("secondaryText", JSONObject().put("content", "1,2 mi de visualizações")))
            .put("thumbnail", JSONObject().put("sources", JSONArray().put(JSONObject().put("url", "https://i.ytimg.com/vi/abcdefghijk/oardefault.jpg").put("width", 405))))
        val page = JSONObject().put("contents", JSONArray()
            .put(JSONObject().put("richItemRenderer", JSONObject().put("content", JSONObject().put("shortsLockupViewModel", lockup))))
            .put(JSONObject().put("richItemRenderer", JSONObject().put("content", JSONObject().put("shortsLockupViewModel", lockup))))) // repeated
        val shorts = YoutubeAccount.shortsLockups(page)
        assertEquals(1, shorts.size)
        assertEquals("https://www.youtube.com/shorts/abcdefghijk", shorts[0].getString("url"))
        assertEquals("Um Short", shorts[0].getString("title"))
        assertEquals(1_200_000L, shorts[0].getLong("views"))
        assertEquals("https://i.ytimg.com/vi/abcdefghijk/oardefault.jpg", shorts[0].getString("cover"))
    }

    @Test fun viewCountLabels() {
        assertEquals(1_200_000L, YoutubeAccount.count("1,2 mi de visualizações"))
        assertEquals(45_000L, YoutubeAccount.count("45 mil visualizações"))
        assertEquals(1_234L, YoutubeAccount.count("1.234 visualizações"))
        assertEquals(1_500_000L, YoutubeAccount.count("1.5M views"))
        assertEquals(-1L, YoutubeAccount.count("Sem visualizações"))
    }
}
