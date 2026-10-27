package io.github.lopution.parfait

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Posts work to the Android main looper. Injected so JVM tests can run the
 * posted [Runnable] inline or record it without a Looper.
 */
internal fun interface MainThreadPoster {
    fun post(action: Runnable)
}

internal object AndroidMainThreadPoster : MainThreadPoster {
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun post(action: Runnable) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            action.run()
        } else {
            mainHandler.post(action)
        }
    }
}

/** Default [MainThreadPoster] for `handle(...)` so JVM tests stay synchronous. */
internal object ImmediateMainThreadPoster : MainThreadPoster {
    override fun post(action: Runnable) = action.run()
}

/**
 * A serial thread for probing other apps' content URIs (shared intents,
 * picker results) that arrive on main: a slow or hostile provider then
 * blocks this thread instead of the UI, and queued probes keep their order.
 * Each channel configuration gets its own, so an activity recreated while a
 * probe hangs does not queue behind it; the old one is shut down.
 */
internal fun foreignContentExecutor(name: String): ExecutorService =
    Executors.newSingleThreadExecutor { task -> Thread(task, name) }

/**
 * Registers a MethodChannel whose handler runs on a serial background
 * [BinaryMessenger.TaskQueue]. Replies may be sent from that thread
 * ([MethodChannel.Result] is any-thread).
 */
internal fun backgroundMethodChannel(
    messenger: BinaryMessenger,
    name: String,
): MethodChannel {
    val taskQueue = messenger.makeBackgroundTaskQueue()
    return MethodChannel(messenger, name, StandardMethodCodec.INSTANCE, taskQueue)
}
