package app.ultratube.media

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import java.util.concurrent.Executors

/** Foreground worker that drains the [Downloads] queue one job at a time. */
class DownloadService : Service() {
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var running = false
    private val manager by lazy { getSystemService(NotificationManager::class.java) }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Downloads", NotificationManager.IMPORTANCE_LOW))
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = notification("Preparando download…", -1.0)
        if (Build.VERSION.SDK_INT >= 29) startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(ID, notification)
        if (!running) {
            running = true
            worker.execute(::drain)
        }
        return START_NOT_STICKY
    }

    private fun drain() {
        try {
            while (true) {
                val job = Downloads.nextQueued(this) ?: break
                val id = job.getString("id")
                val title = job.optString("title").ifBlank { "Ultratube" }
                var last = 0L
                manager.notify(ID, notification(title, 0.0))
                Downloads.run(this, job) { value ->
                    val now = SystemClock.elapsedRealtime()
                    if (now - last > 500) {
                        last = now
                        Downloads.reportProgress(this, id, value)
                        manager.notify(ID, notification(title, value))
                    }
                }
            }
        } finally {
            running = false
            // A job queued while the loop was ending must not be stranded.
            if (Downloads.hasQueued(this)) { running = true; worker.execute(::drain) }
            else { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
        }
    }

    private fun notification(title: String, progress: Double): Notification {
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        builder.setSmallIcon(R.drawable.ic_ultratube_notification).setContentTitle(title)
            .setContentText(if (progress < 0) "Na fila" else "Baixando ${(progress * 100).toInt()}%")
            .setOngoing(true).setOnlyAlertOnce(true)
        if (progress >= 0) builder.setProgress(100, (progress * 100).toInt(), false) else builder.setProgress(0, 0, true)
        packageManager.getLaunchIntentForPackage(packageName)?.let {
            builder.setContentIntent(android.app.PendingIntent.getActivity(this, 0, it, android.app.PendingIntent.FLAG_IMMUTABLE))
        }
        return builder.build()
    }

    override fun onDestroy() { worker.shutdown(); super.onDestroy() }

    private companion object { const val CHANNEL = "ultratube.downloads"; const val ID = 4107 }
}
