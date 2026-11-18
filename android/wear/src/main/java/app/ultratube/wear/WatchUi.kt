package app.ultratube.wear

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.view.View

/** Ultratube watch tokens (mirror the phone's black + red system). */
object Ut {
    val BG = Color.BLACK
    val SURFACE = Color.rgb(28, 28, 28)
    val SURFACE2 = Color.rgb(42, 42, 42)
    val TEXT = Color.rgb(244, 244, 244)
    val TEXT2 = Color.rgb(166, 166, 166)
    val RED = Color.rgb(255, 0, 51)
    val ERROR = Color.rgb(255, 120, 120)
    const val RIPPLE = 0x33FFFFFF

    fun circle(fill: Int) = RippleDrawable(ColorStateList.valueOf(RIPPLE), GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(fill) }, null)
    fun pill(fill: Int, radius: Float) = RippleDrawable(ColorStateList.valueOf(RIPPLE), GradientDrawable().apply { setColor(fill); cornerRadius = radius }, null)
}

/** Progress arc hugging the round display edge, YouTube red on a dim track. */
class RingProgressView(context: Context) : View(context) {
    private val density = resources.displayMetrics.density
    private val track = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 4 * density; color = 0x33FFFFFF; strokeCap = Paint.Cap.ROUND }
    private val bar = Paint(track).apply { color = Ut.RED }
    private val buffer = Paint(track).apply { color = 0x55FFFFFF }
    private val oval = RectF()
    var progress = 0f
        set(value) { if (field != value) { field = value.coerceIn(0f, 1f); invalidate() } }
    var buffered = 0f
        set(value) { if (field != value) { field = value.coerceIn(0f, 1f); invalidate() } }

    init { isClickable = false; importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    override fun onDraw(canvas: Canvas) {
        val inset = track.strokeWidth / 2 + 2 * density
        oval.set(inset, inset, width - inset, height - inset)
        canvas.drawArc(oval, -90f, 360f, false, track)
        if (buffered > 0f) canvas.drawArc(oval, -90f, 360f * buffered, false, buffer)
        if (progress > 0f) canvas.drawArc(oval, -90f, 360f * progress, false, bar)
    }
}
