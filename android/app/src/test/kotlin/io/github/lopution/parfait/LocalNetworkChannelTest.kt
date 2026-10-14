package io.github.lopution.parfait

import android.content.pm.PackageManager
import io.flutter.plugin.common.MethodCall
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM tests for the local network channel: the dialog and its answer. */
class LocalNetworkChannelTest {
    private class FakeSignals(var granted: Boolean = false) : LocalNetworkSignals {
        var requests = 0

        override fun isGranted() = granted

        override fun requestPermission() {
            requests++
        }

        override fun proxyHost(): String? = "192.168.1.2"
    }

    private fun LocalNetworkChannel.call(method: String): RecordingMethodResult {
        val result = RecordingMethodResult()
        handle(MethodCall(method, null), result)
        return result
    }

    @Test
    fun `request shows the dialog once and answers with its result`() {
        val signals = FakeSignals()
        val channel = LocalNetworkChannel(signals)

        val first = channel.call("request")
        val second = channel.call("request")
        assertEquals(1, signals.requests)
        assertFalse(first.hasSuccess())
        assertEquals("local_network_busy", second.errorCode)

        val granted = intArrayOf(PackageManager.PERMISSION_GRANTED)
        assertFalse(channel.onPermissionResult(1, granted))
        assertTrue(channel.onPermissionResult(LocalNetworkChannel.REQUEST_CODE, granted))
        assertEquals(true, first.successValue)

        val denied = intArrayOf(PackageManager.PERMISSION_DENIED)
        val third = channel.call("request")
        channel.onPermissionResult(LocalNetworkChannel.REQUEST_CODE, denied)
        assertEquals(false, third.successValue)
        assertEquals(2, signals.requests)
    }

    @Test
    fun `a granted permission answers without a dialog`() {
        val signals = FakeSignals(granted = true)
        val channel = LocalNetworkChannel(signals)

        assertEquals(true, channel.call("request").successValue)
        assertEquals(true, channel.call("isGranted").successValue)
        assertEquals("192.168.1.2", channel.call("proxyHost").successValue)
        assertTrue(channel.call("unknown").notImplemented)
        assertEquals(0, signals.requests)
    }
}
