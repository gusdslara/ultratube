package com.ppplayer.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import app.ultratube.media.Catalog
import app.ultratube.media.Downloads
import app.ultratube.media.YoutubeAccount
import app.ultratube.media.YoutubeLoginActivity
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Runs extraction off the UI thread; no WebView or external helper process. */
class UltratubeCatalogPlugin : FlutterPlugin, ActivityAware {
    private var channel: MethodChannel? = null
    private var account: MethodChannel? = null
    private var activity: Activity? = null
    private var downloads: MethodChannel? = null
    private var downloadEvents: EventChannel? = null
    private var context: Context? = null
    private val executor = Executors.newFixedThreadPool(8)
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var attached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = true
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "app.ultratube/catalog").also { channel ->
            channel.setMethodCallHandler { call, reply ->
                fun str(name: String) = call.argument<String>(name) ?: ""
                background(reply) {
                    when (call.method) {
                        "search" -> if (call.argument<String>("kind") != null) Catalog.search(str("query"), str("kind")).toString()
                            else Catalog.search(str("query"), call.argument<Boolean>("music") ?: true, call.argument<Boolean>("shorts") ?: false).toString()
                        "suggestions" -> Catalog.suggestions(str("query")).toString()
                        "more" -> Catalog.more(str("token")).toString()
                        "kiosks" -> Catalog.kiosks().toString()
                        "kiosk" -> Catalog.kiosk(str("id")).toString()
                        "feed" -> Catalog.feed(call.argument<List<String>>("channels") ?: emptyList()).toString()
                        "channel" -> Catalog.channel(str("url")).toString()
                        "channelTab" -> Catalog.channelTab(str("url"), str("tab")).toString()
                        "playlist" -> Catalog.playlist(str("url")).toString()
                        "video" -> Catalog.video(str("url")).toString()
                        "comments" -> Catalog.comments(str("url")).toString()
                        "resolve" -> Catalog.resolve(str("url"), call.argument<Boolean>("video") ?: false, call.argument<Int>("maxHeight") ?: 1080,
                            call.argument<Boolean>("fast") ?: false).toString()
                        "related" -> Catalog.related(str("url")).toString()
                        "lyrics" -> Catalog.lyrics(str("title"), str("artist")).toString()
                        else -> throw UnsupportedOperationException(call.method)
                    }
                }
            }
        }
        downloads = MethodChannel(binding.binaryMessenger, "app.ultratube/downloads").also { channel ->
            channel.setMethodCallHandler { call, reply ->
                val ctx = context ?: return@setMethodCallHandler reply.error("detached", null, null)
                background(reply) {
                    when (call.method) {
                        "enqueue" -> Downloads.enqueue(ctx, call.argument<String>("url") ?: error("url"), call.argument<String>("title") ?: "",
                            call.argument<String>("artist") ?: "", call.argument<String>("cover") ?: "", call.argument<Boolean>("video") ?: false,
                            call.argument<Int>("maxHeight") ?: 1080)
                        "list" -> Downloads.list(ctx).toString()
                        "cancel" -> { Downloads.cancel(ctx, call.argument<String>("id") ?: ""); "" }
                        "retry" -> { Downloads.retry(ctx, call.argument<String>("id") ?: ""); "" }
                        "remove" -> { Downloads.remove(ctx, call.argument<String>("id") ?: ""); "" }
                        else -> throw UnsupportedOperationException(call.method)
                    }
                }
            }
        }
        // Optional YouTube account: the normal Google sign-in page, no client ID.
        account = MethodChannel(binding.binaryMessenger, "app.ultratube/account").also { channel ->
            channel.setMethodCallHandler { call, reply ->
                val ctx = context ?: return@setMethodCallHandler reply.error("detached", null, null)
                if (call.method == "signIn") {
                    val host = activity ?: return@setMethodCallHandler reply.error("no_activity", "Abra o app para entrar", null)
                    YoutubeLoginActivity.onResult?.invoke(false) // a previous, abandoned attempt
                    YoutubeLoginActivity.onResult = { ok -> main.post { if (attached) reply.success(ok) } }
                    host.startActivity(Intent(host, YoutubeLoginActivity::class.java))
                    return@setMethodCallHandler
                }
                background(reply) {
                    when (call.method) {
                        "info" -> YoutubeAccount.info(ctx).toString()
                        "subscriptions" -> YoutubeAccount.subscriptions(ctx).toString()
                        "home" -> YoutubeAccount.home(ctx, call.argument<String>("token")).toString()
                        "shorts" -> YoutubeAccount.shorts(ctx, call.argument<String>("token")).toString()
                        "shortInfo" -> YoutubeAccount.shortInfo(ctx, call.argument<String>("id") ?: "").toString()
                        "signOut" -> { YoutubeAccount.signOut(ctx); "true" }
                        else -> throw UnsupportedOperationException(call.method)
                    }
                }
            }
        }
        // Change signal only; Dart re-reads the list. Progress is throttled natively (~2/s).
        downloadEvents = EventChannel(binding.binaryMessenger, "app.ultratube/downloads/events").also { events ->
            events.setStreamHandler(object : EventChannel.StreamHandler {
                private var listener: (() -> Unit)? = null
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    val l: () -> Unit = { main.post { if (attached) sink.success(null) } }
                    listener = l
                    Downloads.addListener(l)
                }
                override fun onCancel(arguments: Any?) { listener?.let { Downloads.removeListener(it) }; listener = null }
            })
        }
    }

    private fun background(reply: MethodChannel.Result, task: () -> String) {
        executor.execute {
            val response = runCatching(task)
            // "unavailable" = this item can never play (private/removed/age/region);
            // Dart retries "ultratube_error" (network, YouTube hiccups) on its own.
            main.post {
                if (attached) response.fold({ reply.success(it) }, {
                    reply.error(if (Catalog.isPermanent(it)) "unavailable" else "ultratube_error", it.localizedMessage, null)
                })
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel?.setMethodCallHandler(null); channel = null
        downloads?.setMethodCallHandler(null); downloads = null
        account?.setMethodCallHandler(null); account = null
        downloadEvents?.setStreamHandler(null); downloadEvents = null
        context = null
        executor.shutdownNow()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { activity = null }
}
