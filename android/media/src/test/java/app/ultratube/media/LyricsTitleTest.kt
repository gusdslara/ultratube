package app.ultratube.media

import org.junit.Assert.assertEquals
import org.junit.Test

/** One clean-up rule for the phone, the watch (Kotlin) and iOS (Dart port). */
class LyricsTitleTest {
    @Test fun youtubeTagsAreDropped() {
        assertEquals("Shape of You", Catalog.lyricsTitle("Shape of You (Official Music Video)"))
        assertEquals("Evidências", Catalog.lyricsTitle("Evidências [Clipe Oficial] (4K)"))
        assertEquals("Song", Catalog.lyricsTitle("Song (Lyric Video)"))
        assertEquals("Song (Remix)", Catalog.lyricsTitle("Song (Remix) (Áudio Oficial)"))
    }
}
