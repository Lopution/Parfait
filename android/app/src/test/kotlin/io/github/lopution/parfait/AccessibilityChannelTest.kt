package io.github.lopution.parfait

import io.flutter.plugin.common.MethodCall
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM tests for the a11y signal handler: flag passthrough and arg checks. */
class AccessibilityChannelTest {
    private class FakeSignals(
        var touchExploration: Boolean = false,
        var timeout: Int = 0,
    ) : AccessibilitySignals {
        var lastBase: Int? = null
        var lastFlags: Int? = null

        override fun isTouchExplorationEnabled() = touchExploration

        override fun recommendedTimeoutMillis(
            originalTimeoutMs: Int,
            contentFlags: Int,
        ): Int {
            lastBase = originalTimeoutMs
            lastFlags = contentFlags
            return timeout
        }
    }

    private fun dispatch(
        method: String,
        args: Map<String, Any?> = emptyMap(),
        signals: FakeSignals = FakeSignals(),
    ): RecordingMethodResult {
        val result = RecordingMethodResult()
        AccessibilityChannel.handle(MethodCall(method, args), result, signals)
        return result
    }

    @Test
    fun `getTouchExplorationEnabled returns the flag`() {
        val signals = FakeSignals(touchExploration = true)
        val result = dispatch("getTouchExplorationEnabled", signals = signals)
        assertEquals(true, result.successValue)
    }

    @Test
    fun `recommendedTimeoutMillis passes base and flags through`() {
        val signals = FakeSignals(timeout = 12000)
        val result = dispatch(
            "recommendedTimeoutMillis",
            mapOf("originalTimeoutMs" to 4000, "contentFlags" to 5),
            signals,
        )
        assertEquals(12000, result.successValue)
        assertEquals(4000, signals.lastBase)
        assertEquals(5, signals.lastFlags)
    }

    @Test
    fun `recommendedTimeoutMillis missing base is invalid_argument`() {
        val result = dispatch(
            "recommendedTimeoutMillis",
            mapOf("contentFlags" to 1),
        )
        assertEquals("a11y_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("originalTimeoutMs"))
    }

    @Test
    fun `recommendedTimeoutMillis wrong type flags is invalid_argument`() {
        val result = dispatch(
            "recommendedTimeoutMillis",
            mapOf("originalTimeoutMs" to 4000, "contentFlags" to "x"),
        )
        assertEquals("a11y_invalid_argument", result.errorCode)
    }

    @Test
    fun `unknown method is notImplemented`() {
        val result = dispatch("nope")
        assertTrue(result.notImplemented)
        assertFalse(result.hasSuccess())
    }
}
