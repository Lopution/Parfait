package io.github.lopution.parfait

/** What the clipboard says about its current clip, without the clip's text. */
data class ClipStamp(val label: String?, val timestamp: Long)

/** An exported credential that still has to be cleared; never holds the text. */
data class PendingClear(val clipTimestamp: Long, val expiresAtMs: Long)

interface PendingClearStore {
    fun read(): PendingClear?
    fun write(pending: PendingClear)
    fun remove()
}

interface ClipStamps {
    /** Null when the clipboard is empty. Only meaningful while the app has focus. */
    fun current(): ClipStamp?
    fun clear()
}

/**
 * Clears an exported credential once its lifetime is over, even when the
 * process died or sat in the background when the lifetime ended.
 *
 * The clip is recognised by its label and the timestamp the system gave it,
 * so a sweep never reads clipboard text: reading another app's clip would
 * raise Android 12's "pasted from" notice. Android 10+ only lets the focused
 * app see the clipboard, so callers sweep only while they have focus.
 */
class PendingTransferClear(
    private val store: PendingClearStore,
    private val clipboard: ClipStamps,
    private val now: () -> Long,
) {
    sealed interface Outcome {
        data object Idle : Outcome
        data class Waiting(val remainingMs: Long) : Outcome
        data object Cleared : Outcome
        data object Replaced : Outcome
    }

    fun arm(stamp: ClipStamp, lifetimeMs: Long) {
        store.write(PendingClear(stamp.timestamp, now() + lifetimeMs))
    }

    fun disarm() = store.remove()

    fun sweep(): Outcome {
        val pending = store.read() ?: return Outcome.Idle
        val remaining = pending.expiresAtMs - now()
        if (remaining > 0) return Outcome.Waiting(remaining)
        val stamp = clipboard.current()
        val ours = stamp != null && stamp.label == LABEL &&
            stamp.timestamp == pending.clipTimestamp
        if (ours) clipboard.clear()
        store.remove()
        return if (ours) Outcome.Cleared else Outcome.Replaced
    }

    companion object {
        /** Label of every exported clip; part of how a sweep recognises it. */
        const val LABEL = "Parfait account transfer"
    }
}
