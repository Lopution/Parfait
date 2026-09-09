package io.github.lopution.pixivfunc

import io.flutter.plugin.common.MethodCall
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM tests for mediastore argument validation and `<reason>` error codes. */
class MediaStoreChannelTest {

    @Test
    fun `begin missing displayName is invalid_argument`() {
        val result = dispatch("begin", mapOf("mimeType" to "image/png"))
        assertEquals("mediastore_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("displayName"))
    }

    @Test
    fun `begin missing mimeType is invalid_argument`() {
        val result = dispatch("begin", mapOf("displayName" to "a.png"))
        assertEquals("mediastore_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("mimeType"))
    }

    @Test
    fun `begin wrong type displayName is invalid_argument`() {
        val result = dispatch("begin", mapOf("displayName" to 1, "mimeType" to "image/png"))
        assertEquals("mediastore_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("displayName"))
    }

    @Test
    fun `write missing id is invalid_argument`() {
        val result = dispatch("write", mapOf("bytes" to ByteArray(1)))
        assertEquals("mediastore_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("id"))
    }

    @Test
    fun `write missing bytes is invalid_argument`() {
        val result = dispatch("write", mapOf("id" to 1))
        assertEquals("mediastore_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("bytes"))
    }

    @Test
    fun `write wrong type id is invalid_argument`() {
        val result = dispatch("write", mapOf("id" to "1", "bytes" to ByteArray(1)))
        assertEquals("mediastore_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("id"))
    }

    @Test
    fun `finalize missing id is invalid_argument`() {
        val result = dispatch("finalize", emptyMap())
        assertEquals("mediastore_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("id"))
    }

    @Test
    fun `abort missing id is invalid_argument`() {
        val result = dispatch("abort", emptyMap())
        assertEquals("mediastore_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("id"))
    }

    @Test
    fun `abortPending missing ownerId is invalid_argument`() {
        val result = dispatch("abortPending", mapOf("id" to 3))
        assertEquals("mediastore_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("ownerId"))
    }

    @Test
    fun `unknown method is notImplemented`() {
        val result = dispatch("noSuchMethod", emptyMap())
        assertTrue(result.notImplemented)
        assertNull(result.errorCode)
        assertFalse(result.hasSuccess())
    }

    @Test
    fun `begin insert failure is mediastore_insert_failed`() {
        val ops = FakeMediaStoreOps()
        ops.fail("begin", IllegalStateException("MediaStore insert failed"))
        val result = dispatch(
            "begin",
            mapOf("displayName" to "a.png", "mimeType" to "image/png"),
            ops,
        )
        assertEquals("mediastore_insert_failed", result.errorCode)
    }

    @Test
    fun `write io failure is mediastore_write_failed`() {
        val ops = FakeMediaStoreOps()
        ops.fail("write", IOException("disk full"))
        val result = dispatch("write", mapOf("id" to 1, "bytes" to ByteArray(1)), ops)
        assertEquals("mediastore_write_failed", result.errorCode)
    }

    @Test
    fun `write missing stream is mediastore_not_found`() {
        val ops = FakeMediaStoreOps()
        ops.fail("write", IllegalStateException("no open stream for item 9"))
        val result = dispatch("write", mapOf("id" to 9, "bytes" to ByteArray(1)), ops)
        assertEquals("mediastore_not_found", result.errorCode)
    }

    @Test
    fun `finalize missing row is mediastore_not_found`() {
        val ops = FakeMediaStoreOps()
        ops.fail("finalize", IllegalStateException("no pending item 4"))
        val result = dispatch("finalize", mapOf("id" to 4), ops)
        assertEquals("mediastore_not_found", result.errorCode)
    }

    @Test
    fun `finalize update failure is mediastore_finalize_failed`() {
        val ops = FakeMediaStoreOps()
        ops.fail("finalize", IllegalStateException("MediaStore finalize update failed"))
        val result = dispatch("finalize", mapOf("id" to 4), ops)
        assertEquals("mediastore_finalize_failed", result.errorCode)
    }

    @Test
    fun `security exception is mediastore_permission`() {
        val ops = FakeMediaStoreOps()
        ops.fail("listPending", SecurityException("denied"))
        val result = dispatch("listPending", emptyMap(), ops)
        assertEquals("mediastore_permission", result.errorCode)
    }

    @Test
    fun `listPending other exception is mediastore_io_failed`() {
        val ops = FakeMediaStoreOps()
        ops.fail("listPending", RuntimeException("cursor died"))
        val result = dispatch("listPending", emptyMap(), ops)
        assertEquals("mediastore_io_failed", result.errorCode)
    }

    @Test
    fun `begin success returns id`() {
        val result = dispatch(
            "begin",
            mapOf("displayName" to "a.png", "mimeType" to "image/png"),
        )
        assertEquals(7, result.successValue)
        assertNull(result.errorCode)
    }

    private fun dispatch(
        method: String,
        args: Map<String, Any?>,
        ops: MediaStoreOperations = FakeMediaStoreOps(),
    ): RecordingMethodResult {
        val result = RecordingMethodResult()
        MediaStoreChannel.handle(MethodCall(method, args), result, ops)
        return result
    }

    private class FakeMediaStoreOps : MediaStoreOperations {
        private val failures = mutableMapOf<String, Exception>()

        fun fail(method: String, error: Exception) {
            failures[method] = error
        }

        private fun maybeThrow(method: String) {
            failures[method]?.let { throw it }
        }

        override fun begin(
            displayName: String,
            mimeType: String,
            ownerId: String?,
            relativePath: String?,
        ): Int {
            maybeThrow("begin")
            return 7
        }

        override fun write(id: Int, bytes: ByteArray) {
            maybeThrow("write")
        }

        override fun finalize(id: Int): String {
            maybeThrow("finalize")
            return "content://media/external/images/media/7"
        }

        override fun abort(id: Int) {
            maybeThrow("abort")
        }

        override fun listPending(): List<Map<String, Any?>> {
            maybeThrow("listPending")
            return emptyList()
        }

        override fun abortPending(id: Int, ownerId: String): Boolean {
            maybeThrow("abortPending")
            return true
        }
    }
}
