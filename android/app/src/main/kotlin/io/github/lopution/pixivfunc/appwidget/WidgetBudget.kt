package io.github.lopution.pixivfunc.appwidget

import kotlin.math.max
import kotlin.math.min

/**
 * Pure bitmap/IPC budget math for widget rendering.
 *
 * Constraints (PRD R7 / AC): per-widget decoded pixels stay bounded by the
 * slot size times [PIXEL_HEADROOM] but never exceed the download resolution,
 * and the total decoded bytes across one render stay under
 * [MAX_TOTAL_BITMAP_BYTES].
 */
object WidgetBudget {
    /** Allow up to 2x slot pixels for density/overscan before downscaling. */
    const val PIXEL_HEADROOM = 2

    /** Hard cap on decoded pixels per image (beta56 used Glide override(600)). */
    const val MAX_PIXELS_PER_IMAGE = 600 * 600

    /** ARGB_8888 bytes per pixel. */
    const val BYTES_PER_PIXEL = 4

    /** Total decoded bitmap memory allowed across one widget render pass. */
    const val MAX_TOTAL_BITMAP_BYTES = 8 * 1024 * 1024

    /**
     * Largest power-of-two [BitmapFactory.Options.inSampleSize] that keeps
     * the decoded image within [maxWidth]x[maxHeight] * [PIXEL_HEADROOM] and
     * [MAX_PIXELS_PER_IMAGE].
     */
    fun sampleSizeFor(
        slotWidthPx: Int,
        slotHeightPx: Int,
        sourceWidth: Int,
        sourceHeight: Int,
    ): Int {
        if (slotWidthPx <= 0 || slotHeightPx <= 0 ||
            sourceWidth <= 0 || sourceHeight <= 0
        ) {
            return 1
        }
        val maxWidth = min(slotWidthPx.toLong() * PIXEL_HEADROOM, 600L).toInt()
        val maxHeight = min(slotHeightPx.toLong() * PIXEL_HEADROOM, 600L).toInt()
        var sample = 1
        // Grows until the decoded size fits the slot headroom in both axes.
        while (sourceWidth / (sample * 2) >= maxWidth &&
            sourceHeight / (sample * 2) >= maxHeight
        ) {
            sample *= 2
        }
        // Second pass: enforce the hard pixel cap on either axis overflow.
        while (sourceWidth / sample > maxWidth || sourceHeight / sample > maxHeight) {
            if (sample >= 32) break
            sample *= 2
        }
        return sample
    }

    /** Decoded ARGB bytes for a decoded size after sampling. */
    fun decodedBytes(width: Int, height: Int, sampleSize: Int): Long {
        val divisor = sampleSize.coerceAtLeast(1)
        val decodedWidth = max(1, width / divisor).toLong()
        val decodedHeight = max(1, height / divisor).toLong()
        val bytesPerPixel = BYTES_PER_PIXEL.toLong()
        if (decodedWidth > Long.MAX_VALUE / bytesPerPixel / decodedHeight) {
            return Long.MAX_VALUE
        }
        return decodedWidth * decodedHeight * bytesPerPixel
    }

    /** True when one more decoded bitmap still fits the total budget. */
    fun withinTotalBudget(currentBytes: Int, nextDecodedBytes: Int): Boolean =
        currentBytes.toLong() + nextDecodedBytes.toLong() <=
            MAX_TOTAL_BITMAP_BYTES.toLong()

    /**
     * Slot pixel size for a widget, from the remote views option bundle
     * values (min width/height in dips) and display density, capped to
     * [MAX_SLOT_DP] so pathological launcher sizes cannot inflate the budget.
     */
    fun slotPixels(optionDips: Int, density: Float): Int {
        if (optionDips <= 0 || density <= 0f) return 0
        val capped = min(optionDips, MAX_SLOT_DP)
        return (capped * density).toInt().coerceAtLeast(1)
    }

    const val MAX_SLOT_DP = 380
}
