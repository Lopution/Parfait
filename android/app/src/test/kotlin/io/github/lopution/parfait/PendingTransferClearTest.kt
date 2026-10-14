package io.github.lopution.parfait

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingTransferClearTest {
    private class MemoryStore : PendingClearStore {
        var pending: PendingClear? = null
        override fun read() = pending
        override fun write(pending: PendingClear) { this.pending = pending }
        override fun remove() { pending = null }
    }

    private class FakeClipboard(var stamp: ClipStamp?) : ClipStamps {
        var reads = 0
        var clears = 0
        override fun current(): ClipStamp? {
            reads++
            return stamp
        }
        override fun clear() {
            clears++
            stamp = null
        }
    }

    private val exported = ClipStamp(PendingTransferClear.LABEL, timestamp = 42)
    private val lifetime = 5 * 60 * 1000L

    private fun world(clip: ClipStamp?): Triple<MemoryStore, FakeClipboard, LongArray> =
        Triple(MemoryStore(), FakeClipboard(clip), longArrayOf(1_000))

    @Test
    fun `an expired export is cleared on the next sweep, even after the process died`() {
        val (store, clipboard, clock) = world(exported)
        PendingTransferClear(store, clipboard) { clock[0] }.arm(exported, lifetime)

        // A new process: only the persisted record survives.
        clock[0] += lifetime
        val outcome = PendingTransferClear(store, clipboard) { clock[0] }.sweep()

        assertEquals(PendingTransferClear.Outcome.Cleared, outcome)
        assertEquals(1, clipboard.clears)
        assertNull(store.pending)
    }

    @Test
    fun `a sweep before expiry waits and touches nothing`() {
        val (store, clipboard, clock) = world(exported)
        val pending = PendingTransferClear(store, clipboard) { clock[0] }
        pending.arm(exported, lifetime)

        clock[0] += lifetime - 10
        assertEquals(PendingTransferClear.Outcome.Waiting(10), pending.sweep())
        assertEquals(0, clipboard.reads)
        assertEquals(0, clipboard.clears)
    }

    @Test
    fun `content copied after the export survives and the record is dropped`() {
        for (later in listOf(ClipStamp("note", 99), ClipStamp(PendingTransferClear.LABEL, 43), null)) {
            val (store, clipboard, clock) = world(exported)
            val pending = PendingTransferClear(store, clipboard) { clock[0] }
            pending.arm(exported, lifetime)
            clipboard.stamp = later

            clock[0] += lifetime
            assertEquals(PendingTransferClear.Outcome.Replaced, pending.sweep())
            assertEquals(0, clipboard.clears)
            assertNull(store.pending)
        }
    }

    @Test
    fun `without a record a sweep never looks at the clipboard`() {
        val (store, clipboard, clock) = world(exported)
        val pending = PendingTransferClear(store, clipboard) { clock[0] }

        assertEquals(PendingTransferClear.Outcome.Idle, pending.sweep())
        pending.arm(exported, lifetime)
        pending.disarm()
        clock[0] += lifetime
        assertEquals(PendingTransferClear.Outcome.Idle, pending.sweep())
        assertTrue(clipboard.reads == 0 && clipboard.clears == 0)
    }
}
