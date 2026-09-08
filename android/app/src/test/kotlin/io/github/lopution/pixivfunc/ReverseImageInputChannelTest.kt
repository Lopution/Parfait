package io.github.lopution.pixivfunc

import io.flutter.plugin.common.MethodCall
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM tests for reverse-image main-thread posts and picker pending state. */
class ReverseImageInputChannelTest {

    @After
    fun resetPicker() {
        ReverseImageInputChannel.abandonPendingPicker()
    }

    @Test
    fun `pickImage is posted to main`() {
        val poster = RecordingMainThreadPoster()
        var started = 0
        val result = RecordingMethodResult()
        ReverseImageInputChannel.handle(
            MethodCall("pickImage", null),
            result,
            FakeIo(),
            ReverseImagePickerLauncher { started += 1 },
            ReverseImageExternalOpener { true },
            poster,
        )
        assertEquals(0, started)
        assertEquals(1, poster.posted.size)
        assertNull(result.errorCode)
        assertFalse(result.hasSuccess())
        poster.runAll()
        assertEquals(1, started)
        assertNull(result.errorCode)
    }

    @Test
    fun `pickImage while pending is picker_busy before main runs`() {
        val poster = RecordingMainThreadPoster()
        val first = RecordingMethodResult()
        ReverseImageInputChannel.handle(
            MethodCall("pickImage", null),
            first,
            FakeIo(),
            ReverseImagePickerLauncher { },
            ReverseImageExternalOpener { true },
            poster,
        )
        val second = dispatch("pickImage")
        assertEquals("picker_busy", second.errorCode)
        assertNull(first.errorCode)
        assertEquals(1, poster.posted.size)
    }

    @Test
    fun `failed pickImage on main clears pending so the next pick can start`() {
        val poster = RecordingMainThreadPoster()
        val first = RecordingMethodResult()
        ReverseImageInputChannel.handle(
            MethodCall("pickImage", null),
            first,
            FakeIo(),
            ReverseImagePickerLauncher { error("no activity") },
            ReverseImageExternalOpener { true },
            poster,
        )
        poster.runAll()
        assertEquals("picker_failed", first.errorCode)
        var started = 0
        val second = RecordingMethodResult()
        ReverseImageInputChannel.handle(
            MethodCall("pickImage", null),
            second,
            FakeIo(),
            ReverseImagePickerLauncher { started += 1 },
            ReverseImageExternalOpener { true },
            ImmediateMainThreadPoster,
        )
        assertEquals(1, started)
        assertNull(second.errorCode)
    }

    @Test
    fun `openExternal is posted to main`() {
        val poster = RecordingMainThreadPoster()
        var opened: String? = null
        val result = RecordingMethodResult()
        ReverseImageInputChannel.handle(
            MethodCall("openExternal", mapOf("url" to "https://example.com")),
            result,
            FakeIo(),
            ReverseImagePickerLauncher { },
            ReverseImageExternalOpener { url ->
                opened = url
                true
            },
            poster,
        )
        assertNull(opened)
        assertEquals(1, poster.posted.size)
        assertFalse(result.hasSuccess())
        poster.runAll()
        assertEquals("https://example.com", opened)
        assertEquals(true, result.successValue)
    }

    @Test
    fun `blank openExternal url is invalid_url without a main-thread post`() {
        val poster = RecordingMainThreadPoster()
        val result = dispatch("openExternal", mapOf("url" to ""), poster)
        assertEquals("invalid_url", result.errorCode)
        assertTrue(poster.posted.isEmpty())
    }

    @Test
    fun `copyToTemp missing uri is invalid_uri`() {
        val result = dispatch("copyToTemp", emptyMap())
        assertEquals("invalid_uri", result.errorCode)
    }

    private fun dispatch(
        method: String,
        args: Map<String, Any?>? = null,
        poster: MainThreadPoster = ImmediateMainThreadPoster,
    ): RecordingMethodResult {
        val result = RecordingMethodResult()
        ReverseImageInputChannel.handle(
            MethodCall(method, args),
            result,
            FakeIo(),
            ReverseImagePickerLauncher { },
            ReverseImageExternalOpener { true },
            poster,
        )
        return result
    }

    private class FakeIo : ReverseImageOperations {
        override fun copyToTemp(uri: String): Map<String, Any> =
            mapOf("path" to "/tmp/x", "mimeType" to "image/png", "sizeBytes" to 1L)

        override fun deleteTemp(path: String): Boolean = true
    }
}
