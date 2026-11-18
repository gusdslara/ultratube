package app.ultratube.media

import android.app.Activity
import android.os.Bundle
import androidx.media3.session.MediaController
import androidx.media3.ui.PlayerView

class VideoActivity : Activity() {
    private var controller: MediaController? = null
    private var connection: com.google.common.util.concurrent.ListenableFuture<MediaController>? = null
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val view = PlayerView(this)
        setContentView(view)
        connection = Playback.connect(this) { controller = it; view.player = it }
    }
    override fun onDestroy() { connection?.let { MediaController.releaseFuture(it) }; super.onDestroy() }
}
