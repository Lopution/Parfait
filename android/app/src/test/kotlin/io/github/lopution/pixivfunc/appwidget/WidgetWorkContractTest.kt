package io.github.lopution.pixivfunc.appwidget

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Contract tests for revision-keyed unique work and bounded retries. */
class WidgetWorkContractTest {

    @Test
    fun `periodic and one-shot names carry family and account revision`() {
        val periodic = WidgetUpdateCoordinator.periodicWorkName(17)
        val oneShot = WidgetUpdateCoordinator.oneShotWorkName(17)

        assertTrue(periodic.startsWith("widget_recommend_periodic_r17"))
        assertTrue(oneShot.startsWith("widget_recommend_refresh_now_r17"))
    }

    @Test
    fun `transient work retries only within the bounded attempt count`() {
        assertTrue(WidgetBackgroundWorker.shouldRetry(0))
        assertTrue(WidgetBackgroundWorker.shouldRetry(1))
        assertFalse(WidgetBackgroundWorker.shouldRetry(2))
        assertFalse(WidgetBackgroundWorker.shouldRetry(3))
    }
}
