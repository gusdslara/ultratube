package app.ultratube.media

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.graphics.drawable.IconCompat
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaNotification
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaStyleNotificationHelper
import androidx.wear.ongoing.OngoingActivity
import androidx.wear.ongoing.Status
import com.google.common.collect.ImmutableList

/**
 * Playback notification with Play/Pause, Next and **Stop**.
 *
 * On Wear OS it is also an Ongoing Activity: while something is playing the
 * Ultratube icon stays on the watch face (and in the recents), so the user can
 * always get back to the player or stop it after leaving the app with the
 * crown. Without it the media service kept playing with no visible way back.
 */
@UnstableApi
internal class PlaybackNotification(private val context: Context) : MediaNotification.Provider {
    private val manager = context.getSystemService(NotificationManager::class.java)
    private val watch = context.packageManager.hasSystemFeature(PackageManager.FEATURE_WATCH)

    override fun createNotification(
        mediaSession: MediaSession,
        customLayout: ImmutableList<CommandButton>,
        actionFactory: MediaNotification.ActionFactory,
        onNotificationChangedCallback: MediaNotification.Provider.Callback,
    ): MediaNotification {
        ensureChannel()
        val player = mediaSession.player
        val title = player.mediaMetadata.title?.toString().orEmpty().ifBlank { "Ultratube" }
        val artist = player.mediaMetadata.artist?.toString().orEmpty()
        val playing = player.playWhenReady && player.playbackState != Player.STATE_ENDED && player.playbackState != Player.STATE_IDLE
        val open = mediaSession.sessionActivity
        val builder = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_ultratube_notification)
            .setContentTitle(title)
            .setContentText(artist)
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setOngoing(playing)
            .setDeleteIntent(stopIntent())
        builder.addAction(
            actionFactory.createMediaAction(
                mediaSession,
                IconCompat.createWithResource(context, if (playing) R.drawable.ic_ut_pause else R.drawable.ic_ut_play),
                if (playing) "Pausar" else "Tocar",
                Player.COMMAND_PLAY_PAUSE,
            ),
        )
        var actions = 1
        if (player.hasNextMediaItem()) {
            actions++
            builder.addAction(
                actionFactory.createMediaAction(mediaSession, IconCompat.createWithResource(context, R.drawable.ic_ut_next), "Próxima", Player.COMMAND_SEEK_TO_NEXT),
            )
        }
        builder.addAction(R.drawable.ic_ut_stop, "Parar", stopIntent())
        builder.setStyle(MediaStyleNotificationHelper.MediaStyle(mediaSession).setShowActionsInCompactView(0, actions))

        if (watch && playing) {
            // Watch-face / recents chip that leads back to the player.
            val status = Status.Builder().addTemplate("#title#").addPart("title", Status.TextPart(title)).build()
            OngoingActivity.Builder(context, NOTIFICATION_ID, builder)
                .setStaticIcon(R.drawable.ic_ultratube_notification)
                .setAnimatedIcon(R.drawable.ic_ultratube_notification)
                .apply { if (open != null) setTouchIntent(open) }
                .setStatus(status)
                .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
                .build()
                .apply(context)
        }
        return MediaNotification(NOTIFICATION_ID, builder.build())
    }

    override fun handleCustomCommand(session: MediaSession, action: String, extras: android.os.Bundle) = false

    private fun stopIntent(): PendingIntent = PendingIntent.getService(
        context,
        1,
        Intent(context, PlaybackService::class.java).setAction(PlaybackService.ACTION_STOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun ensureChannel() {
        if (manager.getNotificationChannel(CHANNEL) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Reprodução", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Controles do que está tocando"
                setShowBadge(false)
            },
        )
    }

    companion object {
        const val CHANNEL = "ultratube_playback"
        const val NOTIFICATION_ID = 1001
    }
}
