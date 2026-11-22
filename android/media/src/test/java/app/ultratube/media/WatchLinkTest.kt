package app.ultratube.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WatchLinkTest {
    @Test fun sealedSessionOpensOnlyWithTheSameCode() {
        val code = WatchLink.newCode()
        val sealed = WatchLink.seal(code, """{"cookies":"SAPISID=abc"}""")
        assertEquals("""{"cookies":"SAPISID=abc"}""", WatchLink.open(code, sealed))
        // As typed on the phone: lower case with dashes.
        assertEquals("""{"cookies":"SAPISID=abc"}""", WatchLink.open(WatchLink.pretty(code).lowercase(), sealed))
        assertNull(WatchLink.open(WatchLink.newCode(), sealed))
    }

    @Test fun tamperedMessageIsRejected() {
        val code = WatchLink.newCode()
        val bytes = java.util.Base64.getDecoder().decode(WatchLink.seal(code, "secret"))
        bytes[bytes.size - 1] = (bytes.last() + 1).toByte()
        assertNull(WatchLink.open(code, java.util.Base64.getEncoder().encodeToString(bytes)))
        assertNull(WatchLink.open(code, "not base64 !!"))
    }

    @Test fun codesAreRandomAndReadable() {
        val a = WatchLink.newCode()
        assertEquals(16, a.length)
        assertTrue(WatchLink.isValidCode(a))
        assertNotEquals(a, WatchLink.newCode())
        assertEquals(19, WatchLink.pretty(a).length) // XXXX-XXXX-XXXX-XXXX
        assertFalse(WatchLink.isValidCode("ABCD"))
        assertFalse(WatchLink.isValidCode("0000-1111-OOOO-IIII")) // never in the alphabet
    }

    @Test fun hostAcceptsWhatTheWatchShows() {
        assertEquals("192.168.0.20" to 8091, WatchLink.parseHost("192.168.0.20:8091"))
        assertEquals("192.168.0.20" to 8090, WatchLink.parseHost(" http://192.168.0.20:8090/#K7QM "))
        assertEquals("10.0.0.5" to WatchLink.DEFAULT_PORT, WatchLink.parseHost("10.0.0.5"))
        assertTrue(runCatching { WatchLink.parseHost("relogio.local:8090") }.isFailure)
    }
}
