package app.ultratube.wear

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.Player
import app.ultratube.media.Playback
import app.ultratube.media.YoutubeAccount
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * YouTube's own Shorts feed as the watch queue (the account's when signed
 * in): pages are appended as you swipe, and [refresh] swaps in a fresh feed
 * (pull down on the first Short, the refresh button, or "previous" on it).
 */
object WatchShorts {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** Continuation of the feed while it is the queue. */
    @Volatile var token: String? = null; private set
    /** The queue is the feed (not a topic search or other content). */
    @Volatile var active = false
    @Volatile private var loading = false
    private var generation = 0

    /**
     * One page with titles: YouTube only names the first Short of a page,
     * so the others are completed in parallel (a few hundred ms).
     */
    fun page(ctx: Context, token: String?): JSONObject {
        val page = YoutubeAccount.shorts(ctx, token)
        val items = page.getJSONArray("items")
        val missing = (0 until items.length()).map { items.getJSONObject(it) }.filter { it.optString("title").isBlank() }.take(12)
        if (missing.isNotEmpty()) {
            val pool = Executors.newFixedThreadPool(4)
            try {
                missing.map { item ->
                    pool.submit {
                        val id = item.optString("url").substringAfterLast('/')
                        runCatching { YoutubeAccount.shortInfo(ctx, id) }.getOrNull()?.let { info ->
                            item.put("title", info.optString("title")).put("artist", info.optString("channel"))
                        }
                    }
                }.forEach { runCatching { it.get(6, TimeUnit.SECONDS) } }
            } finally { pool.shutdownNow() }
        }
        for (i in 0 until items.length()) items.getJSONObject(i).let { if (it.optString("title").isBlank()) it.put("title", "Short") }
        return page
    }

    /** Starts the queue from a page already loaded (see [page]). */
    fun play(player: Player, page: JSONObject) {
        generation++
        token = next(page)
        active = true
        val items = page.getJSONArray("items")
        Playback.playAll(player, (0 until items.length()).map { Playback.online(items.getJSONObject(it), video = true) }, 0)
    }

    /** Near the end of the feed: append the next page (endless swiping). */
    fun moreIfNeeded(ctx: Context, player: Player) {
        val pending = token ?: return
        if (!active || loading || player.mediaItemCount - player.currentMediaItemIndex > 3) return
        loading = true
        val request = generation
        val app = ctx.applicationContext
        io.execute {
            val page = runCatching { page(app, pending) }.getOrNull()
            main.post {
                loading = false
                if (page == null || !active || request != generation) return@post
                token = next(page)
                val items = page.getJSONArray("items")
                player.addMediaItems((0 until items.length()).map { Playback.online(items.getJSONObject(it), video = true) })
            }
        }
    }

    /** A fresh feed in place of the current one. [done] gets an error message or null. */
    fun refresh(ctx: Context, player: Player, done: (String?) -> Unit) {
        val request = ++generation
        val app = ctx.applicationContext
        // YouTube starts every new sequence with the same Short: keep only
        // the ones that were not in the feed yet (a few pages at most).
        val shown = (0 until player.mediaItemCount).map { player.getMediaItemAt(it).mediaId }.toSet()
        player.pause()
        io.execute {
            val page = runCatching {
                var current = page(app, null)
                var tries = 0
                while (true) {
                    val all = current.getJSONArray("items")
                    val fresh = org.json.JSONArray((0 until all.length()).map { all.getJSONObject(it) }
                        .filter { it.optString("url").substringAfterLast('/') !in shown })
                    val more = next(current)
                    if (fresh.length() > 0 || more == null || ++tries >= 3) { current.put("items", fresh); break }
                    current = page(app, more)
                }
                current
            }
            main.post {
                if (request != generation) return@post
                page.fold({
                    if (it.getJSONArray("items").length() == 0) return@fold done("Nenhum Short encontrado")
                    play(player, it); done(null)
                }, { done(it.localizedMessage ?: "Falha de rede") })
            }
        }
    }

    private fun next(page: JSONObject) = page.optString("next").takeIf { it.isNotBlank() && it != "null" }
}
