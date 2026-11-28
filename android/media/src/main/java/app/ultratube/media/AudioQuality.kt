package app.ultratube.media

/**
 * Audio bitrate tiers for audio-only playback (and the audio half of a video):
 * - [LOW]: data saver, the smallest usable track (~48–70 kbps: HE-AAC or Opus).
 *   About a third of the data of [NORMAL]; fine for speech, earbuds and the watch.
 * - [NORMAL]: AAC ~128 kbps (what the apps used before).
 * - [HIGH]: the best track offered (usually Opus ~160 kbps).
 */
object AudioQuality {
    const val LOW = "low"
    const val NORMAL = "normal"
    const val HIGH = "high"

    /** Anything below this is a placeholder or broken entry, not real audio. */
    private const val FLOOR = 32_000L

    fun <T> pick(items: List<T>, quality: String, bitrate: (T) -> Long, mp4: (T) -> Boolean): T? {
        if (items.isEmpty()) return null
        return when (quality) {
            LOW -> items.filter { bitrate(it) >= FLOOR }.minByOrNull(bitrate) ?: items.maxByOrNull(bitrate)
            HIGH -> items.maxByOrNull(bitrate)
            else -> items.filter(mp4).maxByOrNull(bitrate) ?: items.maxByOrNull(bitrate)
        }
    }

    fun parse(value: String?): String = when (value) { LOW, HIGH -> value; else -> NORMAL }
}
