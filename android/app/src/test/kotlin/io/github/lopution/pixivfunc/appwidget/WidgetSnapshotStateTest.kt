package io.github.lopution.pixivfunc.appwidget

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure age-boundary tests for the native snapshot contract. */
class WidgetSnapshotStateTest {

    @Test
    fun `snapshot becomes stale only after the age limit`() {
        val now = 10_000L
        assertFalse(WidgetSnapshotReader.isStaleAt(now, now))
        assertFalse(
            WidgetSnapshotReader.isStaleAt(
                now - WidgetSnapshotReader.MAX_AGE_MS,
                now,
            ),
        )
        assertTrue(
            WidgetSnapshotReader.isStaleAt(
                now - WidgetSnapshotReader.MAX_AGE_MS - 1,
                now,
            ),
        )
    }

    @Test
    fun `future generated snapshot is not treated as stale`() {
        assertFalse(WidgetSnapshotReader.isStaleAt(20_000L, 10_000L))
    }

    @Test
    fun `hostile old timestamp cannot wrap into a fresh snapshot`() {
        assertTrue(WidgetSnapshotReader.isStaleAt(Long.MIN_VALUE, 10_000L))
    }
}
