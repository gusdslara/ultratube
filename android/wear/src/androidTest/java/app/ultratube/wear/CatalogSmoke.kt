package app.ultratube.wear

import android.app.Instrumentation
import android.app.Activity
import android.os.Bundle
import app.ultratube.media.Catalog

/** Explicit network smoke test: does not start audio or change saved favorites. */
class CatalogSmoke : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        val report = Bundle()
        try {
            val results = Catalog.search("Beethoven Moonlight Sonata", true)
            check(results.length() > 0) { "No search results" }
            val track = Catalog.resolve(results.getJSONObject(0).getString("url"), false)
            check(track.getString("stream").startsWith("https://"))
            val connection = java.net.URL(track.getString("stream")).openConnection() as java.net.HttpURLConnection
            try {
                connection.connectTimeout = 15000; connection.readTimeout = 15000
                connection.setRequestProperty("Range", "bytes=0-2047")
                check(connection.responseCode in 200..299) { "Media HTTP ${connection.responseCode}" }
                val count = connection.inputStream.use { it.read(ByteArray(2048)) }
                check(count > 0) { "Empty audio response" }
                report.putString("stream", "PASS: ${results.length()} results; resolved audio and read $count media bytes")
            } finally { connection.disconnect() }
            finish(Activity.RESULT_OK, report)
        } catch (error: Throwable) {
            report.putString("stream", "FAIL: ${error.javaClass.simpleName}: ${error.message}")
            finish(Activity.RESULT_CANCELED, report)
        }
    }
}
