package app.ultratube.wear

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import android.util.Log
import app.ultratube.media.WatchLink
import app.ultratube.media.YoutubeAccount
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.IOException
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket

/**
 * Watch side of "Entrar com o celular" ([WatchLink]): keeps the Wi-Fi up,
 * listens on the local network and waits for the phone to send its sealed
 * YouTube session. Only one message is accepted, and only if it opens with
 * this screen's code; anything else is answered with an error.
 */
class AccountLink(private val context: Context, private val listener: Listener) {
    interface Listener {
        /** [address] "ip:port"; [qr] encodes the page URL with the code in its fragment. */
        fun onReady(address: String, code: String, qr: Bitmap)
        fun onWaitingForWifi()
        fun onLinked(name: String)
        fun onError(message: String)
    }

    val code = WatchLink.newCode()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var server: ServerSocket? = null
    @Volatile private var running = false
    @Volatile private var shownIp: String? = null
    private var connectivity: ConnectivityManager? = null
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var wifi: Network? = null
    private var waiting = false

    fun start() {
        if (running) return
        running = true
        Thread({ listen() }, "AccountLink").start()
        requestWifi()
        main.postDelayed(poll, 1500)
    }

    fun stop() {
        running = false
        main.removeCallbacks(poll)
        runCatching { server?.close() }
        server = null
        wifiCallback?.let { cb -> runCatching { connectivity?.unregisterNetworkCallback(cb) } }
        wifiCallback = null
    }

    // Wi-Fi can take a few seconds to come up on a watch (it prefers the
    // phone's Bluetooth link): keep looking for an address.
    private val poll = object : Runnable {
        override fun run() {
            if (!running) return
            update()
            main.postDelayed(this, if (shownIp == null) 1500 else 5000)
        }
    }

    private fun requestWifi() {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return
        connectivity = cm
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { wifi = network; main.post { update() } }
            override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) { main.post { update() } }
            override fun onLost(network: Network) { if (wifi == network) wifi = null; main.post { update() } }
        }
        wifiCallback = callback
        // Asking for a Wi-Fi network (no internet needed) turns the watch's
        // Wi-Fi on and keeps it up while this screen is open.
        runCatching {
            cm.requestNetwork(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(), callback)
        }.onFailure { Log.w(TAG, "requestNetwork", it) }
    }

    private fun update() {
        if (!running) return
        val port = server?.localPort ?: return
        val ip = wifiAddress()
        if (ip == null) {
            if (!waiting) { waiting = true; listener.onWaitingForWifi() }
            shownIp = null
            return
        }
        waiting = false
        if (ip == shownIp) return
        shownIp = ip
        val address = "$ip:$port"
        // The code rides in the fragment: browsers never send it to the
        // server, so it only reaches the phone through the camera.
        val qr = qr("http://$address/#${code}") ?: return listener.onError("Não foi possível gerar o QR")
        listener.onReady(address, code, qr)
    }

    private fun wifiAddress(): String? {
        // The Wi-Fi network's own address first, then any private IPv4 on wlan.
        wifi?.let { network ->
            connectivity?.getLinkProperties(network)?.linkAddresses
                ?.map { it.address }?.firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
                ?.let { return it.hostAddress }
        }
        return runCatching {
            NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback && (it.name.startsWith("wlan") || it.name.startsWith("eth")) }
                .flatMap { it.inetAddresses.toList() }
                .firstOrNull { it is Inet4Address && it.isSiteLocalAddress }?.hostAddress
        }.getOrNull()
    }

    private fun listen() {
        val socket = bind()
        if (socket == null) {
            main.post { listener.onError("Nenhuma porta livre no relógio") }
            return
        }
        if (!running) { runCatching { socket.close() }; return }
        server = socket
        main.post { update() }
        while (running && !socket.isClosed) {
            val client = try { socket.accept() } catch (_: IOException) { break }
            Thread({ handle(client) }, "AccountLink-Client").start()
        }
    }

    private fun bind(): ServerSocket? {
        for (port in WatchLink.DEFAULT_PORT..WatchLink.DEFAULT_PORT + 10) {
            runCatching { return ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(port)) } }
        }
        return runCatching { ServerSocket().apply { bind(InetSocketAddress(0)) } }.getOrNull()
    }

    private fun handle(client: Socket) {
        client.use { c ->
            runCatching {
                c.soTimeout = 20000
                val input = BufferedInputStream(c.getInputStream())
                val head = WatchLink.readHead(input) ?: return
                val requestLine = head.lineSequence().first().split(' ')
                val method = requestLine.getOrNull(0).orEmpty()
                val path = requestLine.getOrNull(1).orEmpty().substringBefore('?')
                when {
                    method == "GET" && (path == "/" || path.isEmpty()) -> respond(c, 200, "text/html; charset=utf-8", PAGE)
                    method == "POST" && path == WatchLink.PATH -> {
                        val length = WatchLink.header(head, "content-length")?.toIntOrNull() ?: -1
                        if (length !in 1..65536) return respondJson(c, 411, false, "Tamanho inválido")
                        val body = String(WatchLink.readExactly(input, length))
                        val plain = WatchLink.open(code, body)
                            ?: return respondJson(c, 403, false, "Código errado. Confira o código mostrado no relógio.")
                        val cookies = JSONObject(plain).optString("cookies")
                        if (!YoutubeAccount.importCookies(context, cookies)) return respondJson(c, 400, false, "O celular não está com uma conta do YouTube conectada.")
                        // Confirms the session works from here before saying so.
                        val info = runCatching { YoutubeAccount.info(context) }.getOrNull()
                        val name = info?.optString("name").orEmpty()
                        respondJson(c, 200, true, name = name)
                        main.post { listener.onLinked(name) }
                    }
                    else -> respond(c, 404, "text/plain", "Not found")
                }
            }.onFailure { Log.w(TAG, "client", it) }
        }
    }

    private fun respondJson(c: Socket, status: Int, ok: Boolean, error: String = "", name: String = "") =
        respond(c, status, "application/json", JSONObject().put("ok", ok).put("error", error).put("name", name).toString())

    private fun respond(c: Socket, status: Int, type: String, body: String) {
        val bytes = body.toByteArray()
        val reason = when (status) { 200 -> "OK"; 403 -> "Forbidden"; 404 -> "Not Found"; else -> "Error" }
        c.getOutputStream().apply {
            write("HTTP/1.1 $status $reason\r\nContent-Type: $type\r\nContent-Length: ${bytes.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".toByteArray())
            write(bytes); flush()
        }
    }

    private fun qr(text: String): Bitmap? = runCatching {
        val hints = mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 2)
        val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0, hints)
        val scale = 6
        val size = matrix.width
        Bitmap.createBitmap(size * scale, size * scale, Bitmap.Config.RGB_565).apply {
            for (y in 0 until size) for (x in 0 until size) {
                val color = if (matrix[x, y]) Color.BLACK else Color.WHITE
                for (dy in 0 until scale) for (dx in 0 until scale) setPixel(x * scale + dx, y * scale + dy, color)
            }
        }
    }.getOrNull()

    private companion object {
        const val TAG = "AccountLink"

        /**
         * What the phone's camera opens. The code is read from the fragment
         * (never sent here) and handed to the Ultratube app on the phone.
         */
        val PAGE = """
            <!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>Ultratube · Conectar relógio</title>
            <style>
              :root{color-scheme:dark}
              body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
                   background:#0a0a0a;color:#f2f2f2;font:16px/1.45 system-ui,sans-serif}
              main{max-width:360px;padding:24px;text-align:center}
              h1{font-size:22px;margin:0 0 8px}
              p{color:#b5b5b5;margin:0 0 24px}
              a{display:block;padding:14px 20px;border-radius:999px;background:#e5202e;color:#fff;
                font-weight:600;text-decoration:none;min-height:20px}
              a:focus-visible{outline:3px solid #fff;outline-offset:3px}
              small{display:block;margin-top:16px;color:#8a8a8a}
            </style></head><body><main>
            <h1>Conectar o relógio</h1>
            <p>Abra o Ultratube neste celular para enviar sua conta do YouTube ao relógio.</p>
            <a id="open" href="#">Abrir no Ultratube</a>
            <small>O celular precisa estar com a conta conectada (Você › Entrar).</small>
            </main><script>
              var k = location.hash.slice(1).replace(/[^A-Za-z0-9]/g, '');
              var q = 'h=' + encodeURIComponent(location.host) + '&k=' + encodeURIComponent(k);
              var link = /Android/i.test(navigator.userAgent)
                ? 'intent://link?' + q + '#Intent;scheme=ultratube;package=app.ultratube.mobile;end'
                : 'ultratube://link?' + q;
              var a = document.getElementById('open');
              a.href = link;
              if (k) setTimeout(function(){ location.href = link; }, 300);
            </script></body></html>
        """.trimIndent()
    }
}
