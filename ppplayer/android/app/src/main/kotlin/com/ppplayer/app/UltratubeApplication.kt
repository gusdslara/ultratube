package com.ppplayer.app

import android.app.Application
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Prepares the one Flutter engine the app uses (the screen and audio_service
 * share it) with Ultratube's own native plugins attached.
 *
 * Without this, a play request from a paired watch, a headset or the
 * notification while the app is closed made audio_service start a bare
 * engine: only the pub plugins were registered, so resolving the stream
 * failed ("No implementation found for method resolve") and nothing played.
 */
class UltratubeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val id = AudioServicePlugin.getFlutterEngineId()
        if (FlutterEngineCache.getInstance().get(id) != null) return
        val engine = FlutterEngine(this)
        UltratubePlugins.register(engine)
        engine.navigationChannel.setInitialRoute("/")
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(id, engine)
    }
}

/** Ultratube's native plugins, added once per engine. */
object UltratubePlugins {
    fun register(engine: FlutterEngine) {
        val plugins = engine.plugins
        if (!plugins.has(UltratubeCatalogPlugin::class.java)) plugins.add(UltratubeCatalogPlugin())
        if (!plugins.has(WebViewPlugin::class.java)) plugins.add(WebViewPlugin())
        if (!plugins.has(LocalFilesPlugin::class.java)) plugins.add(LocalFilesPlugin())
        if (!plugins.has(NetworkOutputsPlugin::class.java)) plugins.add(NetworkOutputsPlugin())
    }
}
