package io.github.lopution.pixivfunc.appwidget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Plain JVM tests for the widget bitmap/IPC budget math (PRD R7 / R9). */
class WidgetBudgetTest {

    @Test
    fun `sample size keeps decode within slot headroom`() {
        // Slot 100x100, source 600x600: first factor that fits 2x headroom
        // in both axes is 4 (150x150 <= 200x200, 300x300 does not).
        assertEquals(4, WidgetBudget.sampleSizeFor(100, 100, 600, 600))
    }

    @Test
    fun `sample size enforces the absolute pixel cap`() {
        // Slot is huge but the 600x600 hard cap bounds the decode.
        assertEquals(1, WidgetBudget.sampleSizeFor(400, 400, 600, 600))
        assertEquals(2, WidgetBudget.sampleSizeFor(400, 400, 1200, 1200))
    }

    @Test
    fun `degenerate sizes return unit sample`() {
        assertEquals(1, WidgetBudget.sampleSizeFor(0, 100, 600, 600))
        assertEquals(1, WidgetBudget.sampleSizeFor(100, 0, 600, 600))
        assertEquals(1, WidgetBudget.sampleSizeFor(100, 100, 0, 600))
    }

    @Test
    fun `decoded bytes scale with sampling`() {
        val full = WidgetBudget.decodedBytes(600, 600, 1)
        val half = WidgetBudget.decodedBytes(600, 600, 2)
        assertEquals(full / 4, half)
        assertEquals(
            WidgetBudget.MAX_PIXELS_PER_IMAGE.toLong() * WidgetBudget.BYTES_PER_PIXEL,
            full,
        )
    }

    @Test
    fun `decoded bytes do not overflow for hostile image bounds`() {
        val bytes = WidgetBudget.decodedBytes(Int.MAX_VALUE, Int.MAX_VALUE, 1)
        assertTrue(
            bytes > WidgetBudget.MAX_PIXELS_PER_IMAGE.toLong() *
                WidgetBudget.BYTES_PER_PIXEL,
        )
    }

    @Test
    fun `total budget rejects the next bitmap once exhausted`() {
        val nearLimit = WidgetBudget.MAX_TOTAL_BITMAP_BYTES - 1000
        assertTrue(WidgetBudget.withinTotalBudget(0, nearLimit))
        // The bitmap that would push past the total budget is refused...
        assertFalse(WidgetBudget.withinTotalBudget(nearLimit, 2000))
        // ...but one that still fits is accepted.
        assertTrue(WidgetBudget.withinTotalBudget(nearLimit, 500))
        // And a single full-size cover decode fits the total budget.
        val single = WidgetBudget.MAX_PIXELS_PER_IMAGE * WidgetBudget.BYTES_PER_PIXEL
        assertTrue(WidgetBudget.withinTotalBudget(0, single))
    }

    @Test
    fun `total budget does not overflow on hostile byte counts`() {
        assertFalse(
            WidgetBudget.withinTotalBudget(
                Int.MAX_VALUE,
                Int.MAX_VALUE,
            ),
        )
    }

    @Test
    fun `slot pixels are density scaled and capped`() {
        assertEquals(200, WidgetBudget.slotPixels(100, 2f))
        assertEquals(0, WidgetBudget.slotPixels(0, 2f))
        assertEquals(0, WidgetBudget.slotPixels(100, 0f))
        assertEquals(
            WidgetBudget.MAX_SLOT_DP * 3,
            WidgetBudget.slotPixels(100000, 3f),
        )
    }
}
