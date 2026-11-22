package app.ultratube.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AudioQualityTest {
    private data class Track(val itag: Int, val bitrate: Long, val mp4: Boolean)
    // What YouTube usually offers: HE-AAC 48k, AAC 128k, Opus 50/70/160k.
    private val tracks = listOf(
        Track(139, 48_000, true), Track(140, 129_000, true),
        Track(249, 51_000, false), Track(250, 68_000, false), Track(251, 135_000, false),
    )
    private fun pick(q: String, list: List<Track> = tracks) = AudioQuality.pick(list, q, { it.bitrate }, { it.mp4 })?.itag

    @Test fun tiers() {
        assertEquals(139, pick(AudioQuality.LOW))
        assertEquals(140, pick(AudioQuality.NORMAL))
        assertEquals(251, pick(AudioQuality.HIGH))
    }

    @Test fun dataSaverIgnoresBrokenEntries() {
        assertEquals(249, pick(AudioQuality.LOW, tracks.filter { it.itag != 139 } + Track(1, 0, true)))
    }

    @Test fun normalFallsBackWhenThereIsNoMp4() {
        assertEquals(251, pick(AudioQuality.NORMAL, tracks.filter { !it.mp4 }))
        assertNull(pick(AudioQuality.NORMAL, emptyList()))
    }

    @Test fun unknownValuesMeanNormal() {
        assertEquals(AudioQuality.NORMAL, AudioQuality.parse(null))
        assertEquals(AudioQuality.NORMAL, AudioQuality.parse("ultra"))
        assertEquals(AudioQuality.LOW, AudioQuality.parse("low"))
    }
}
