package app.ultratube.media

import android.content.Context
import android.content.Intent
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaMuxer
import android.os.Build
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import org.schabi.newpipe.extractor.MediaFormat
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.StreamInfo
import org.schabi.newpipe.extractor.stream.VideoStream
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Persistent offline downloads shared by phone and watch.
 * Jobs run one at a time inside [DownloadService]; the index survives restarts.
 * Files live in the app-specific external directory, so no storage permission is required.
 */
object Downloads {
    const val QUEUED = "queued"; const val RUNNING = "running"; const val DONE = "done"
    const val FAILED = "failed"; const val CANCELED = "canceled"

    private val lock = Any()
    private val jobs = LinkedHashMap<String, JSONObject>()
    private var loaded = false
    @Volatile private var current: Pair<String, AtomicBoolean>? = null
    private val listeners = mutableSetOf<() -> Unit>()

    private val http = OkHttpClient.Builder().connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS).followRedirects(true).build()

    fun directory(context: Context): File =
        File(context.getExternalFilesDir(null) ?: context.filesDir, "downloads").apply { mkdirs() }

    private fun index(context: Context) = File(directory(context), "index.json")

    private fun ensureLoaded(context: Context) {
        if (loaded) return
        runCatching {
            val array = JSONArray(index(context).readText())
            for (i in 0 until array.length()) {
                val job = array.getJSONObject(i)
                // A process death interrupts the running job; resume it from the queue.
                if (job.optString("state") == RUNNING) job.put("state", QUEUED).put("progress", 0.0)
                jobs[job.getString("id")] = job
            }
        }
        loaded = true
    }

    private fun persist(context: Context) {
        val array = JSONArray(jobs.values.toList())
        val tmp = File(directory(context), "index.json.tmp")
        tmp.writeText(array.toString())
        tmp.renameTo(index(context)) || run { index(context).writeText(array.toString()); true }
    }

    fun addListener(listener: () -> Unit) = synchronized(lock) { listeners += listener }
    fun removeListener(listener: () -> Unit) = synchronized(lock) { listeners -= listener }
    private fun changed() = synchronized(lock) { listeners.toList() }.forEach { runCatching { it() } }

    /** Queues a download and starts the foreground worker. Returns the job id (existing job when duplicated). */
    fun enqueue(context: Context, url: String, title: String, artist: String, cover: String, video: Boolean, maxHeight: Int): String {
        val id = synchronized(lock) {
            ensureLoaded(context)
            jobs.values.firstOrNull {
                it.optString("url") == url && it.optBoolean("video") == video && it.optString("state") in setOf(QUEUED, RUNNING, DONE)
            }?.let { return@synchronized it.getString("id") }
            val id = UUID.randomUUID().toString()
            jobs[id] = JSONObject().put("id", id).put("url", url).put("title", title).put("artist", artist)
                .put("cover", cover).put("video", video).put("maxHeight", maxHeight).put("state", QUEUED)
                .put("progress", 0.0).put("created", System.currentTimeMillis())
            persist(context)
            id
        }
        changed()
        start(context)
        return id
    }

    fun start(context: Context) {
        val intent = Intent(context, DownloadService::class.java)
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
    }

    fun list(context: Context): JSONArray = synchronized(lock) {
        ensureLoaded(context)
        JSONArray(jobs.values.sortedByDescending { it.optLong("created") }.map { JSONObject(it.toString()) })
    }

    fun get(context: Context, id: String): JSONObject? = synchronized(lock) { ensureLoaded(context); jobs[id]?.let { JSONObject(it.toString()) } }

    fun cancel(context: Context, id: String) {
        synchronized(lock) {
            ensureLoaded(context)
            current?.takeIf { it.first == id }?.second?.set(true)
            jobs[id]?.takeIf { it.optString("state") == QUEUED }?.put("state", CANCELED)
            persist(context)
        }
        changed()
    }

    fun retry(context: Context, id: String) {
        synchronized(lock) {
            ensureLoaded(context)
            jobs[id]?.takeIf { it.optString("state") in setOf(FAILED, CANCELED) }?.apply { put("state", QUEUED); put("progress", 0.0); remove("error") }
            persist(context)
        }
        changed(); start(context)
    }

    fun remove(context: Context, id: String) {
        synchronized(lock) {
            ensureLoaded(context)
            current?.takeIf { it.first == id }?.second?.set(true)
            jobs.remove(id)?.let { job ->
                job.optString("file").takeIf { it.isNotBlank() }?.let { File(it).delete() }
                job.optString("coverFile").takeIf { it.isNotBlank() }?.let { File(it).delete() }
            }
            persist(context)
        }
        changed()
    }

    internal fun hasQueued(context: Context) = synchronized(lock) { ensureLoaded(context); jobs.values.any { it.optString("state") == QUEUED } }

    internal fun nextQueued(context: Context): JSONObject? = synchronized(lock) {
        ensureLoaded(context)
        jobs.values.firstOrNull { it.optString("state") == QUEUED }?.also { it.put("state", RUNNING); persist(context) }
    }

    private fun update(context: Context, id: String, persist: Boolean = true, block: JSONObject.() -> Unit) {
        synchronized(lock) { jobs[id]?.block(); if (persist) persist(context) }
        changed()
    }

    /** Runs one job to completion. Called on the service worker thread. */
    internal fun run(context: Context, job: JSONObject, onProgress: (Double) -> Unit) {
        val id = job.getString("id")
        val canceled = AtomicBoolean(false)
        current = id to canceled
        val temps = mutableListOf<File>()
        try {
            val info = StreamInfo.getInfo(ServiceList.YouTube, job.getString("url"))
            val dir = directory(context)
            val artist = Catalog.artistName(info.uploaderName)
            val base = safeName("$artist - ${info.name}").ifBlank { id }
            val coverFile = File(dir, "$id.jpg")
            runCatching { info.thumbnails.maxByOrNull { it.width }?.url?.let { fetch(it, coverFile, canceled) { _, _ -> } } }
            val audio = bestAudio(info.audioStreams) ?: throw IOException("Áudio indisponível para este conteúdo")
            val output: File
            if (job.optBoolean("video")) {
                val maxHeight = job.optInt("maxHeight", 1080).coerceAtLeast(144)
                val videoOnly = info.videoOnlyStreams.filter { it.isUrl && it.format == MediaFormat.MPEG_4 && it.height in 1..maxHeight }
                    .maxWithOrNull(compareBy<VideoStream>({ it.height }, { it.fps }, { it.bitrate }))
                output = uniqueFile(dir, base, "mp4")
                temps += output // removed on failure; detached below on success
                if (videoOnly != null && audio.format == MediaFormat.M4A) {
                    val v = File(dir, "$id.video.part").also { temps += it }
                    val a = File(dir, "$id.audio.part").also { temps += it }
                    val total = (videoOnly.itagItem?.contentLength ?: 0L) + (audio.itagItem?.contentLength ?: 0L)
                    var videoBytes = 0L
                    fetch(videoOnly.content, v, canceled) { done, size -> videoBytes = done; onProgress(ratio(done, if (total > 0) total else size * 2)) }
                    fetch(audio.content, a, canceled) { done, _ -> onProgress(ratio(videoBytes + done, if (total > 0) total else videoBytes * 2)) }
                    mux(v, a, output)
                } else {
                    val muxed = info.videoStreams.filter { it.isUrl && !it.isVideoOnly && it.format == MediaFormat.MPEG_4 }.maxByOrNull { it.height }
                        ?: throw IOException("Vídeo indisponível para download")
                    fetch(muxed.content, output, canceled) { done, size -> onProgress(ratio(done, size)) }
                }
                temps -= output
                update(context, id, false) { put("resolution", "${videoOnly?.height ?: 360}p") }
            } else {
                val ext = if (audio.format == MediaFormat.M4A) "m4a" else (audio.format?.suffix ?: "webm")
                output = uniqueFile(dir, base, ext)
                temps += output // removed on failure; detached below on success
                fetch(audio.content, output, canceled) { done, size -> onProgress(ratio(done, size)) }
                temps -= output
            }
            update(context, id) {
                put("state", DONE); put("progress", 1.0); put("file", output.absolutePath); put("size", output.length())
                put("title", info.name); put("artist", artist); put("duration", info.duration)
                if (coverFile.exists()) put("coverFile", coverFile.absolutePath)
                put("finished", System.currentTimeMillis())
            }
        } catch (error: Throwable) {
            val wasCanceled = canceled.get()
            update(context, id) {
                put("state", if (wasCanceled) CANCELED else FAILED)
                if (!wasCanceled) put("error", error.localizedMessage ?: error.javaClass.simpleName)
            }
            if (!wasCanceled) android.util.Log.w("Ultratube", "download $id failed", error)
        } finally {
            temps.forEach { it.delete() }
            current = null
        }
    }

    internal fun reportProgress(context: Context, id: String, value: Double) =
        update(context, id, persist = false) { put("progress", value) }

    private fun ratio(done: Long, total: Long) = if (total <= 0) 0.0 else (done.toDouble() / total).coerceIn(0.0, 0.99)

    private fun bestAudio(streams: List<AudioStream>): AudioStream? {
        val usable = streams.filter { it.isUrl }
        return usable.filter { it.format == MediaFormat.M4A }.maxByOrNull { it.averageBitrate }
            ?: usable.maxByOrNull { it.averageBitrate }
    }

    private fun safeName(value: String) = value.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), " ")
        .replace(Regex("\\s+"), " ").trim().take(120)

    private fun uniqueFile(dir: File, base: String, ext: String): File {
        var file = File(dir, "$base.$ext"); var n = 2
        while (file.exists()) { file = File(dir, "$base ($n).$ext"); n++ }
        return file
    }

    /**
     * Downloads in ranged chunks. YouTube throttles single long requests, while
     * ~10 MB ranges are served at full speed.
     */
    private fun fetch(url: String, target: File, canceled: AtomicBoolean, progress: (Long, Long) -> Unit) {
        val chunk = 10L * 1024 * 1024
        var offset = 0L
        var total = -1L
        target.outputStream().buffered(256 * 1024).use { out ->
            val buffer = ByteArray(64 * 1024)
            while (total < 0 || offset < total) {
                if (canceled.get()) throw IOException("Cancelado")
                val end = if (total > 0) minOf(offset + chunk, total) - 1 else offset + chunk - 1
                val request = Request.Builder().url(url).header("Range", "bytes=$offset-$end")
                    .header("User-Agent", "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/131.0 Mobile Safari/537.36").build()
                http.newCall(request).execute().use { response ->
                    if (response.code == 416 && total < 0) { total = offset; return@use }
                    if (!response.isSuccessful) throw IOException("Falha no download (HTTP ${response.code})")
                    val body = response.body ?: throw IOException("Resposta vazia")
                    if (response.code == 200) {
                        // Server ignored the range: stream the whole body once.
                        total = body.contentLength().takeIf { it > 0 } ?: Long.MAX_VALUE
                    } else if (total < 0) {
                        total = response.header("Content-Range")?.substringAfter('/')?.toLongOrNull() ?: Long.MAX_VALUE
                    }
                    var received = 0L
                    body.byteStream().use { input ->
                        while (true) {
                            if (canceled.get()) throw IOException("Cancelado")
                            val read = input.read(buffer)
                            if (read < 0) break
                            out.write(buffer, 0, read); offset += read; received += read
                            progress(offset, total)
                        }
                    }
                    if (response.code == 200 && total == Long.MAX_VALUE) total = offset
                    if (received == 0L) total = offset
                }
            }
        }
    }

    /** Joins a video-only MP4 and an M4A track without re-encoding. */
    private fun mux(video: File, audio: File, output: File) {
        val muxer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val extractors = listOf(MediaExtractor().apply { setDataSource(video.absolutePath) }, MediaExtractor().apply { setDataSource(audio.absolutePath) })
        try {
            val mapping = extractors.map { extractor ->
                val prefix = if (extractor === extractors[0]) "video/" else "audio/"
                val track = (0 until extractor.trackCount).first { extractor.getTrackFormat(it).getString(android.media.MediaFormat.KEY_MIME)?.startsWith(prefix) == true }
                extractor.selectTrack(track)
                muxer.addTrack(extractor.getTrackFormat(track))
            }
            muxer.start()
            val buffer = ByteBuffer.allocate(4 * 1024 * 1024)
            val info = MediaCodec.BufferInfo()
            // Interleave by timestamp so players read the file sequentially
            // instead of seeking between a video block and an audio block.
            val finished = BooleanArray(extractors.size)
            while (!finished.all { it }) {
                val i = extractors.indices.filter { !finished[it] }.minBy { extractors[it].sampleTime }
                val extractor = extractors[i]
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) { finished[i] = true; continue }
                info.set(0, size, extractor.sampleTime, if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                muxer.writeSampleData(mapping[i], buffer, info)
                if (!extractor.advance()) finished[i] = true
            }
            muxer.stop()
        } catch (error: Throwable) {
            output.delete(); throw error
        } finally {
            extractors.forEach { it.release() }
            runCatching { muxer.release() }
        }
    }
}
