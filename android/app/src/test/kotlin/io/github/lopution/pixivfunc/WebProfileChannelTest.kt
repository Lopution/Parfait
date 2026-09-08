package io.github.lopution.pixivfunc

import io.flutter.plugin.common.MethodCall
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM tests for webprofile dispatch. Methods take no arguments, so
 * `webprofile_invalid_argument` is not reachable; extra keys are ignored.
 */
class WebProfileChannelTest {

    @Test
    fun `unknown method is notImplemented`() {
        val result = dispatch("noSuchMethod", FakeCookies())
        assertTrue(result.notImplemented)
        assertNull(result.errorCode)
    }

    @Test
    fun `readSession platform exception is webprofile_read_failed`() {
        val cookies = FakeCookies()
        cookies.readError = IllegalStateException("cookie store down")
        val result = dispatch("readSession", cookies)
        assertEquals("webprofile_read_failed", result.errorCode)
    }

    @Test
    fun `clearSession platform exception is webprofile_clear_failed`() {
        val cookies = FakeCookies()
        cookies.clearError = RuntimeException("flush failed")
        val result = dispatch("clearSession", cookies)
        assertEquals("webprofile_clear_failed", result.errorCode)
    }

    @Test
    fun `security exception is webprofile_permission`() {
        val cookies = FakeCookies()
        cookies.readError = SecurityException("blocked")
        val result = dispatch("readSession", cookies)
        assertEquals("webprofile_permission", result.errorCode)
    }

    @Test
    fun `readSession success returns cookie`() {
        val cookies = FakeCookies()
        cookies.cookieValue = "PHPSESSID=abc"
        val result = dispatch("readSession", cookies)
        assertEquals("PHPSESSID=abc", result.successValue)
        assertEquals(WebProfileChannel.PIXIV_WEB, cookies.lastUrl)
    }

    @Test
    fun `clearSession success returns true`() {
        val result = dispatch("clearSession", FakeCookies())
        assertEquals(true, result.successValue)
    }

    @Test
    fun `extra arguments do not become invalid_argument`() {
        val result = RecordingMethodResult()
        WebProfileChannel.handle(
            MethodCall("readSession", mapOf("unexpected" to 1)),
            result,
            FakeCookies(),
        )
        assertNull(result.errorCode)
        assertTrue(result.hasSuccess())
    }

    private fun dispatch(method: String, cookies: WebProfileCookies): RecordingMethodResult {
        val result = RecordingMethodResult()
        WebProfileChannel.handle(MethodCall(method, null), result, cookies)
        return result
    }

    private class FakeCookies : WebProfileCookies {
        var cookieValue: String? = null
        var lastUrl: String? = null
        var readError: Exception? = null
        var clearError: Exception? = null

        override fun cookie(url: String): String? {
            lastUrl = url
            readError?.let { throw it }
            return cookieValue
        }

        override fun clearAll() {
            clearError?.let { throw it }
        }
    }
}
