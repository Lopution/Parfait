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
            FakeArmer(),
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
            FakeArmer(),
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
            FakeArmer(),
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
            FakeArmer(),
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
            FakeArmer(),
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

    @Test
    fun `armReverseUpload returns the armed uri`() {
        val result = dispatch("armReverseUpload", mapOf("path" to "/tmp/in"))
        assertEquals("content://armed/in", result.successValue)
        assertNull(result.errorCode)
    }

    @Test
    fun `armReverseUpload blank path is invalid_path`() {
        val result = dispatch("armReverseUpload", mapOf("path" to " "))
        assertEquals("invalid_path", result.errorCode)
    }

    @Test
    fun `armReverseUpload armer failure surfaces arm_failed`() {
        val result = RecordingMethodResult()
        ReverseImageInputChannel.handle(
            MethodCall("armReverseUpload", mapOf("path" to "/tmp/x")),
            result,
            FakeIo(),
            ReverseImagePickerLauncher { },
            ReverseImageExternalOpener { true },
            object : ReverseImageUploadArmer {
                override fun arm(path: String): String = error("outside owner")
                override fun disarm() {}
            },
            ImmediateMainThreadPoster,
        )
        assertEquals("arm_failed", result.errorCode)
    }

    @Test
    fun `disarmReverseUpload clears the armed slot`() {
        var disarmed = 0
        val result = RecordingMethodResult()
        ReverseImageInputChannel.handle(
            MethodCall("disarmReverseUpload", null),
            result,
            FakeIo(),
            ReverseImagePickerLauncher { },
            ReverseImageExternalOpener { true },
            object : ReverseImageUploadArmer {
                override fun arm(path: String): String = "content://x"
                override fun disarm() {
                    disarmed += 1
                }
            },
            ImmediateMainThreadPoster,
        )
        assertEquals(1, disarmed)
        assertTrue(result.hasSuccess())
        assertNull(result.errorCode)
    }

    @Test
    fun `requireOwnedInputPath rejects paths outside the owner directory`() {
        val root = java.nio.file.Files.createTempDirectory("ri-owned").toFile()
        var outside: java.io.File? = null
        try {
            val inside = java.io.File(root, "input-1.bin").apply { writeBytes(byteArrayOf(1)) }
            assertEquals(
                inside.canonicalFile,
                ReverseImageInputChannel.requireOwnedInputFile(root, inside.absolutePath),
            )
            outside = java.io.File(root.parentFile, "escape-${root.name}.bin")
                .apply { writeBytes(byteArrayOf(1)) }
            try {
                ReverseImageInputChannel.requireOwnedInputPath(root, outside.absolutePath)
                org.junit.Assert.fail("outside path must be rejected")
            } catch (_: IllegalArgumentException) {
            }
            // A missing file is fine for path-level checks (idempotent delete)
            // but must be rejected before arming.
            val missing = java.io.File(root, "missing.bin").absolutePath
            assertEquals(
                java.io.File(missing).canonicalFile,
                ReverseImageInputChannel.requireOwnedInputPath(root, missing),
            )
            try {
                ReverseImageInputChannel.requireOwnedInputFile(root, missing)
                org.junit.Assert.fail("missing file must be rejected before arming")
            } catch (_: IllegalArgumentException) {
            }
        } finally {
            outside?.delete()
            root.deleteRecursively()
        }
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
            FakeArmer(),
            poster,
        )
        return result
    }

    private class FakeIo : ReverseImageOperations {
        override fun copyToTemp(uri: String): Map<String, Any> =
            mapOf("path" to "/tmp/x", "mimeType" to "image/png", "sizeBytes" to 1L)

        override fun deleteTemp(path: String): Boolean = true
    }

    private class FakeArmer : ReverseImageUploadArmer {
        override fun arm(path: String): String = "content://armed/in"

        override fun disarm() {}
    }
}
