package app.ultratube.media

import android.content.Context
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Hands the phone's YouTube session to the watch ("Entrar com o celular").
 *
 * Wear OS has no WebView, so the Google sign-in page cannot run on the
 * watch. Instead the watch opens a small HTTP endpoint on the Wi-Fi and
 * shows its address with a one-time code (and a QR with both). The phone
 * app — already signed in — sends its youtube.com cookies there, sealed
 * with AES-GCM under a key derived from the code. The code only travels
 * through the watch screen (QR or typed by the user), never over the
 * network, so someone else on the Wi-Fi sees nothing usable; a wrong code
 * fails authentication and the watch keeps waiting.
 */
object WatchLink {
    const val PATH = "/link"
    /** 16 Crockford-like base32 symbols = 80 bits, typed as XXXX-XXXX-XXXX-XXXX. */
    private const val ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
    private const val CODE_LENGTH = 16
    private val random = SecureRandom()

    fun newCode(): String = (1..CODE_LENGTH).map { ALPHABET[random.nextInt(ALPHABET.length)] }.joinToString("")

    /** "K7QM2X9P…" → "K7QM-2X9P-…" for display. */
    fun pretty(code: String) = normalize(code).chunked(4).joinToString("-")

    /** Accepts what a person types: spaces, dashes, lower case. (0/1/O/I/L are never used.) */
    fun normalize(code: String) = code.uppercase().filter { it.isLetterOrDigit() }

    fun isValidCode(code: String) = normalize(code).let { n -> n.length == CODE_LENGTH && n.all { it in ALPHABET } }

    private fun key(code: String) = SecretKeySpec(
        MessageDigest.getInstance("SHA-256").digest("ultratube-link:v1:${normalize(code)}".toByteArray()).copyOf(16), "AES")

    /** `nonce(12) | ciphertext+tag`, Base64. */
    fun seal(code: String, plain: String): String {
        val nonce = ByteArray(12).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(code), GCMParameterSpec(128, nonce))
        cipher.updateAAD(PATH.toByteArray())
        return java.util.Base64.getEncoder().encodeToString(nonce + cipher.doFinal(plain.toByteArray()))
    }

    /** Null when the code is wrong or the message was altered. */
    fun open(code: String, sealed: String): String? = runCatching {
        val data = java.util.Base64.getDecoder().decode(sealed.trim())
        if (data.size < 12 + 16) return null
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(code), GCMParameterSpec(128, data, 0, 12))
        cipher.updateAAD(PATH.toByteArray())
        String(cipher.doFinal(data, 12, data.size - 12))
    }.getOrNull()

    // ------------------------------------------------------------ phone side

    /**
     * Phone: sends this app's YouTube session to the watch at [host]
     * ("192.168.0.20:8090") sealed with [code]. Returns the account name the
     * watch confirmed. Plain sockets: the request goes to the local network
     * and is already encrypted, so it must not depend on the app's
     * cleartext HTTP policy.
     */
    fun send(ctx: Context, host: String, code: String): String {
        require(isValidCode(code)) { "Código inválido. Confira as 16 letras/números no relógio." }
        val cookies = YoutubeAccount.exportCookies(ctx) ?: throw IllegalStateException("Entre com sua conta do YouTube neste celular primeiro.")
        val (address, port) = parseHost(host)
        val body = seal(code, JSONObject().put("cookies", cookies).put("from", android.os.Build.MODEL ?: "").toString()).toByteArray()
        Socket().use { socket ->
            socket.connect(InetSocketAddress(address, port), 8000)
            socket.soTimeout = 30000
            val out = socket.getOutputStream()
            out.write(("POST $PATH HTTP/1.1\r\nHost: $address:$port\r\nContent-Type: text/plain\r\n" +
                "Content-Length: ${body.size}\r\nConnection: close\r\n\r\n").toByteArray())
            out.write(body)
            out.flush()
            val (status, text) = readResponse(BufferedInputStream(socket.getInputStream()))
            val reply = runCatching { JSONObject(text) }.getOrNull()
            if (status != 200 || reply?.optBoolean("ok") != true) {
                throw IOException(reply?.optString("error")?.ifBlank { null } ?: "O relógio recusou ($status).")
            }
            return reply.optString("name")
        }
    }

    /** "ip:port", "http://ip:port/#…" or a bare IP (default port 8090). */
    fun parseHost(raw: String): Pair<String, Int> {
        val text = raw.trim().removePrefix("http://").removePrefix("https://").substringBefore('/').substringBefore('#')
        val address = text.substringBefore(':').trim()
        val port = text.substringAfter(':', "").toIntOrNull() ?: DEFAULT_PORT
        require(Regex("^\\d{1,3}(\\.\\d{1,3}){3}$").matches(address) && port in 1..65535) { "Endereço inválido. Use o que aparece no relógio, ex.: 192.168.0.20:8090" }
        return address to port
    }

    const val DEFAULT_PORT = 8090

    // ------------------------------------------------------------ HTTP bits

    /** (status, body) of a small HTTP/1.1 response. */
    private fun readResponse(input: InputStream): Pair<Int, String> {
        val head = readHead(input) ?: throw IOException("Resposta vazia do relógio")
        val status = head.lineSequence().firstOrNull()?.split(' ')?.getOrNull(1)?.toIntOrNull() ?: 0
        val length = header(head, "content-length")?.toIntOrNull()
        val body = if (length != null) readExactly(input, length) else input.readBytes()
        return status to String(body)
    }

    /** Request/response head up to the blank line, or null on EOF. Max 16 KB. */
    fun readHead(input: InputStream): String? {
        val buffer = ByteArrayOutputStream()
        var matched = 0
        while (buffer.size() < 16384) {
            val b = input.read()
            if (b < 0) return null
            buffer.write(b)
            matched = when {
                b == '\r'.code && (matched == 0 || matched == 2) -> matched + 1
                b == '\n'.code && (matched == 1 || matched == 3) -> matched + 1
                else -> 0
            }
            if (matched == 4) return buffer.toString(Charsets.ISO_8859_1.name())
        }
        throw IOException("Cabeçalho grande demais")
    }

    fun header(head: String, name: String) = head.lineSequence().drop(1)
        .firstOrNull { it.substringBefore(':').trim().equals(name, ignoreCase = true) }?.substringAfter(':')?.trim()

    fun readExactly(input: InputStream, length: Int): ByteArray {
        require(length in 0..65536) { "Corpo grande demais" }
        val data = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(data, read, length - read)
            if (n < 0) throw IOException("Conexão interrompida")
            read += n
        }
        return data
    }
}
