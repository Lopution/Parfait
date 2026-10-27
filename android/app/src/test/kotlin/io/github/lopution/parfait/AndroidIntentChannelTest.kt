package io.github.lopution.parfait

import io.flutter.plugin.common.EventChannel
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM tests: intent probes run off main, in order, and never escape. */
class AndroidIntentChannelTest {

    @Test
    fun `initial and new intents are probed off main in arrival order`() {
        val io = QueuedExecutor()
        val poster = RecordingMainThreadPoster()
        val prober = RecordingProber()
        val relay = IntentRelay(io, poster, prober)
        val sink = RecordingSink()
        relay.sink = sink
        val initial = RecordingMethodResult()

        relay.answer(snapshot("content://a"), initial)
        relay.emit(snapshot("content://b"))
        assertTrue(prober.probed.isEmpty())
        assertFalse(initial.hasSuccess())

        io.runAll()
        assertEquals(listOf("content://a", "content://b"), prober.probed.distinct())
        assertEquals("content://a", (initial.successValue as Map<*, *>)["uri"])
        assertTrue(sink.events.isEmpty())
        poster.runAll()
        assertEquals("content://b", sink.events.single()["uri"])
        assertEquals(true, sink.events.single()["hasReadUriPermission"])
        assertEquals(7L, sink.events.single()["sizeBytes"])
    }

    @Test
    fun `an event reaches only the listener it arrived for`() {
        val io = QueuedExecutor()
        val poster = RecordingMainThreadPoster()
        val relay = IntentRelay(io, poster, RecordingProber())
        val first = RecordingSink()

        relay.sink = first
        relay.emit(snapshot("content://b"))
        io.runAll()
        relay.sink = null
        poster.runAll()
        assertTrue(first.events.isEmpty())

        // Cancelled and listening again while the probe ran.
        poster.posted.clear()
        relay.sink = first
        relay.emit(snapshot("content://c"))
        io.runAll()
        val second = RecordingSink()
        relay.sink = second
        poster.runAll()
        assertTrue(first.events.isEmpty())
        assertTrue(second.events.isEmpty())
    }

    @Test
    fun `a throwing provider reads as unreadable with an unknown size`() {
        val relay = IntentRelay(
            Executor { it.run() },
            ImmediateMainThreadPoster,
            RecordingProber(fail = IllegalStateException("provider died")),
        )
        val result = RecordingMethodResult()
        relay.answer(snapshot("content://a"), result)
        val payload = result.successValue as Map<*, *>
        assertEquals(false, payload["hasReadUriPermission"])
        assertNull(payload["sizeBytes"])
    }

    private fun snapshot(uri: String) = IntentSnapshot(
        action = "android.intent.action.SEND",
        uri = uri,
        isContentUri = true,
        mimeType = "image/png",
        grantsRead = true,
        extraKeys = listOf("android.intent.extra.STREAM"),
    )

    private class QueuedExecutor : Executor {
        private val queue = ArrayDeque<Runnable>()

        override fun execute(command: Runnable) {
            queue.addLast(command)
        }

        fun runAll() {
            while (queue.isNotEmpty()) queue.removeFirst().run()
        }
    }

    private class RecordingProber(private val fail: Exception? = null) : ContentProber {
        val probed = mutableListOf<String>()

        override fun canRead(uri: String): Boolean {
            probed += uri
            fail?.let { throw it }
            return true
        }

        override fun sizeBytes(uri: String): Long? {
            probed += uri
            fail?.let { throw it }
            return 7L
        }
    }

    private class RecordingSink : EventChannel.EventSink {
        val events = mutableListOf<Map<*, *>>()

        override fun success(event: Any?) {
            events += event as Map<*, *>
        }

        override fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) = Unit

        override fun endOfStream() = Unit
    }
}
