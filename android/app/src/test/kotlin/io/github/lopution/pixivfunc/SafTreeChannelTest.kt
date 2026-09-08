package io.github.lopution.pixivfunc

import android.app.Activity
import io.flutter.plugin.common.MethodCall
import java.io.IOException
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM tests for saf_tree argument validation and `<reason>` error codes. */
class SafTreeChannelTest {

    @After
    fun resetPicker() {
        SafTreeChannel.abandonPendingPicker()
    }

    @Test
    fun `create missing treeUri is invalid_argument`() {
        val result = dispatch(
            "create",
            mapOf("displayName" to "a.png", "mimeType" to "image/png"),
        )
        assertEquals("saf_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("treeUri"))
    }

    @Test
    fun `create missing displayName is invalid_argument`() {
        val result = dispatch(
            "create",
            mapOf("treeUri" to "content://tree", "mimeType" to "image/png"),
        )
        assertEquals("saf_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("displayName"))
    }

    @Test
    fun `create wrong type mimeType is invalid_argument`() {
        val result = dispatch(
            "create",
            mapOf(
                "treeUri" to "content://tree",
                "displayName" to "a.png",
                "mimeType" to 1,
            ),
        )
        assertEquals("saf_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("mimeType"))
    }

    @Test
    fun `create ignores ownerId and still succeeds`() {
        val result = dispatch(
            "create",
            mapOf(
                "treeUri" to "content://tree",
                "displayName" to "a.png",
                "mimeType" to "image/png",
                "ownerId" to "acct-1",
            ),
        )
        assertEquals("content://doc/1", result.successValue)
        assertNull(result.errorCode)
    }

    @Test
    fun `write missing uri is invalid_argument`() {
        val result = dispatch("write", mapOf("bytes" to ByteArray(1)))
        assertEquals("saf_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("uri"))
    }

    @Test
    fun `write missing bytes is invalid_argument`() {
        val result = dispatch("write", mapOf("uri" to "content://doc/1"))
        assertEquals("saf_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("bytes"))
    }

    @Test
    fun `close missing uri is invalid_argument`() {
        val result = dispatch("close", emptyMap())
        assertEquals("saf_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("uri"))
    }

    @Test
    fun `delete missing uri is invalid_argument`() {
        val result = dispatch("delete", emptyMap())
        assertEquals("saf_invalid_argument", result.errorCode)
        assertTrue(result.errorMessage!!.contains("uri"))
    }

    @Test
    fun `unknown method is notImplemented`() {
        val result = dispatch("noSuchMethod", emptyMap())
        assertTrue(result.notImplemented)
        assertNull(result.errorCode)
    }

    @Test
    fun `create platform failure is saf_create_failed`() {
        val ops = FakeSafOps()
        ops.fail("create", IllegalStateException("SAF createDocument failed"))
        val result = dispatch(
            "create",
            mapOf(
                "treeUri" to "content://tree",
                "displayName" to "a.png",
                "mimeType" to "image/png",
            ),
            ops,
        )
        assertEquals("saf_create_failed", result.errorCode)
    }

    @Test
    fun `write missing stream is saf_not_found`() {
        val ops = FakeSafOps()
        ops.fail("write", IllegalStateException("no open SAF stream for content://x"))
        val result = dispatch(
            "write",
            mapOf("uri" to "content://x", "bytes" to ByteArray(1)),
            ops,
        )
        assertEquals("saf_not_found", result.errorCode)
    }

    @Test
    fun `write io failure is saf_write_failed`() {
        val ops = FakeSafOps()
        ops.fail("write", IOException("broken pipe"))
        val result = dispatch(
            "write",
            mapOf("uri" to "content://x", "bytes" to ByteArray(1)),
            ops,
        )
        assertEquals("saf_write_failed", result.errorCode)
    }

    @Test
    fun `delete security exception is saf_permission`() {
        val ops = FakeSafOps()
        ops.fail("delete", SecurityException("revoked"))
        val result = dispatch("delete", mapOf("uri" to "content://x"), ops)
        assertEquals("saf_permission", result.errorCode)
    }

    @Test
    fun `pickTree without activity is saf_unavailable`() {
        val result = dispatch("pickTree", emptyMap(), launcher = SafTreeLauncher { false })
        assertEquals("saf_unavailable", result.errorCode)
    }

    @Test
    fun `RESULT_OK with null uri is saf_launch_failed`() {
        val result = RecordingMethodResult()
        SafTreeChannel.completePickTree(result, Activity.RESULT_OK, null) { _, _ -> }
        assertEquals("saf_launch_failed", result.errorCode)
    }

    @Test
    fun `user cancel is success null`() {
        val result = RecordingMethodResult()
        SafTreeChannel.completePickTree(
            result,
            Activity.RESULT_CANCELED,
            null,
        ) { _, _ -> }
        assertNull(result.successValue)
        assertNull(result.errorCode)
    }

    @Test
    fun `pickTree is posted to main`() {
        val poster = RecordingMainThreadPoster()
        var started = 0
        val result = RecordingMethodResult()
        SafTreeChannel.handle(
            MethodCall("pickTree", emptyMap<String, Any?>()),
            result,
            FakeSafOps(),
            SafTreeLauncher {
                started += 1
                true
            },
            poster,
        )
        assertEquals(0, started)
        assertEquals(1, poster.posted.size)
        assertNull(result.errorCode)
        assertFalse(result.hasSuccess())
        poster.runAll()
        assertEquals(1, started)
        assertNull(result.errorCode)
        assertFalse(result.hasSuccess())
    }

    @Test
    fun `pickTree while pending is saf_busy before main runs`() {
        val poster = RecordingMainThreadPoster()
        val first = RecordingMethodResult()
        SafTreeChannel.handle(
            MethodCall("pickTree", emptyMap<String, Any?>()),
            first,
            FakeSafOps(),
            SafTreeLauncher { true },
            poster,
        )
        val second = dispatch("pickTree", emptyMap())
        assertEquals("saf_busy", second.errorCode)
        assertNull(first.errorCode)
        assertEquals(1, poster.posted.size)
    }

    @Test
    fun `failed pickTree on main clears pending so the next pick can start`() {
        val poster = RecordingMainThreadPoster()
        val first = RecordingMethodResult()
        SafTreeChannel.handle(
            MethodCall("pickTree", emptyMap<String, Any?>()),
            first,
            FakeSafOps(),
            SafTreeLauncher { false },
            poster,
        )
        poster.runAll()
        assertEquals("saf_unavailable", first.errorCode)
        var started = 0
        val second = RecordingMethodResult()
        SafTreeChannel.handle(
            MethodCall("pickTree", emptyMap<String, Any?>()),
            second,
            FakeSafOps(),
            SafTreeLauncher {
                started += 1
                true
            },
            ImmediateMainThreadPoster,
        )
        assertEquals(1, started)
        assertNull(second.errorCode)
    }

    @Test
    fun `onActivityResult clears pending so the next pick can start`() {
        val first = RecordingMethodResult()
        SafTreeChannel.handle(
            MethodCall("pickTree", emptyMap<String, Any?>()),
            first,
            FakeSafOps(),
            SafTreeLauncher { true },
            ImmediateMainThreadPoster,
        )
        assertTrue(SafTreeChannel.onActivityResult(0x53AF, Activity.RESULT_CANCELED, null))
        assertNull(first.errorCode)
        assertNull(first.successValue)
        var started = 0
        val second = RecordingMethodResult()
        SafTreeChannel.handle(
            MethodCall("pickTree", emptyMap<String, Any?>()),
            second,
            FakeSafOps(),
            SafTreeLauncher {
                started += 1
                true
            },
            ImmediateMainThreadPoster,
        )
        assertEquals(1, started)
        assertNull(second.errorCode)
    }

    private fun dispatch(
        method: String,
        args: Map<String, Any?>,
        ops: SafTreeOperations = FakeSafOps(),
        launcher: SafTreeLauncher = SafTreeLauncher { false },
    ): RecordingMethodResult {
        val result = RecordingMethodResult()
        SafTreeChannel.handle(MethodCall(method, args), result, ops, launcher)
        return result
    }

    private class FakeSafOps : SafTreeOperations {
        private val failures = mutableMapOf<String, Exception>()

        fun fail(method: String, error: Exception) {
            failures[method] = error
        }

        private fun maybeThrow(method: String) {
            failures[method]?.let { throw it }
        }

        override fun create(treeUri: String, displayName: String, mimeType: String): String {
            maybeThrow("create")
            return "content://doc/1"
        }

        override fun write(uri: String, bytes: ByteArray) {
            maybeThrow("write")
        }

        override fun close(uri: String) {
            maybeThrow("close")
        }

        override fun delete(uri: String) {
            maybeThrow("delete")
        }
    }
}
