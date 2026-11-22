package com.ppplayer.app

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import app.ultratube.media.WatchLink
import app.ultratube.media.YoutubeAccount
import java.util.concurrent.Executors

/**
 * "Conectar relógio": sends this phone's YouTube session to the Ultratube
 * watch app (which cannot show Google's sign-in page itself).
 *
 * Opened two ways:
 * - scanning the QR on the watch: the camera opens the watch's page, which
 *   hands over `ultratube://link?h=<ip:port>&k=<code>` — fields come filled;
 * - from Você › Conta › Conectar relógio: the address and code are typed.
 *
 * Nothing is sent until the user confirms.
 */
class WatchLinkActivity : Activity() {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var dialog: AlertDialog? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!YoutubeAccount.isSignedIn(this)) {
            AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setTitle("Conectar relógio")
                .setMessage("Entre com sua conta do YouTube neste celular primeiro (Ultratube › Você › Entrar). Depois conecte o relógio.")
                .setPositiveButton("OK", null)
                .setOnDismissListener { finish() }
                .show()
            return
        }
        val data = intent?.data
        val host = data?.getQueryParameter("h").orEmpty()
        val code = data?.getQueryParameter("k").orEmpty()
        showForm(host, code)
    }

    private fun dp(v: Int) = (resources.displayMetrics.density * v).toInt()

    private fun showForm(host: String, code: String) {
        val fromQr = host.isNotBlank() && WatchLink.isValidCode(code)
        fun field(hintText: String, value: String, type: Int) = EditText(this).apply {
            hint = hintText; setText(value); setSingleLine(); inputType = type
            setTextColor(Color.WHITE); setHintTextColor(Color.GRAY)
        }
        val address = field("Endereço (ex.: 192.168.0.20:8090)", host, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI)
        val codeField = field("Código (16 letras/números)", if (code.isBlank()) "" else WatchLink.pretty(code),
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS).apply {
            imeOptions = EditorInfo.IME_ACTION_DONE
        }
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(22), dp(8), dp(22), 0)
            addView(TextView(context).apply {
                text = if (fromQr) "Enviar sua conta do YouTube para o relógio? Ele passa a mostrar suas inscrições, o Início e os Shorts da sua conta."
                else "No relógio, abra Ultratube › Conta › Entrar com o celular. Com os dois no mesmo Wi-Fi, digite o que aparece lá (ou escaneie o QR com a câmera)."
                setTextColor(Color.LTGRAY); textSize = 14f
            })
            if (!fromQr) { addView(address); addView(codeField) }
        }
        dialog = AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle("Conectar relógio")
            .setView(body)
            .setPositiveButton("Enviar", null)
            .setNegativeButton("Cancelar") { _, _ -> finish() }
            .setOnCancelListener { finish() }
            .create().also { d ->
                d.setOnShowListener {
                    d.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                        send(d, if (fromQr) host else address.text.toString(), if (fromQr) code else codeField.text.toString())
                    }
                }
                d.show()
            }
    }

    private fun send(d: AlertDialog, host: String, code: String) {
        val button = d.getButton(AlertDialog.BUTTON_POSITIVE)
        button.isEnabled = false
        button.text = "Enviando…"
        io.execute {
            val result = runCatching { WatchLink.send(this, host, code) }
            main.post {
                if (isFinishing || isDestroyed) return@post
                result.fold({ name ->
                    Toast.makeText(this, if (name.isBlank()) "Relógio conectado" else "Relógio conectado como $name", Toast.LENGTH_LONG).show()
                    d.dismiss(); finish()
                }, { error ->
                    button.isEnabled = true
                    button.text = "Tentar de novo"
                    val message = when (error) {
                        is java.net.ConnectException, is java.net.SocketTimeoutException, is java.net.NoRouteToHostException ->
                            "Não achei o relógio nesse endereço. Os dois estão no mesmo Wi-Fi e a tela do relógio está aberta?"
                        else -> error.message ?: "Falha ao enviar"
                    }
                    Toast.makeText(this, message, Toast.LENGTH_LONG).show()
                })
            }
        }
    }

    override fun onDestroy() {
        dialog?.setOnCancelListener(null)
        dialog?.dismiss()
        io.shutdownNow()
        super.onDestroy()
    }
}
