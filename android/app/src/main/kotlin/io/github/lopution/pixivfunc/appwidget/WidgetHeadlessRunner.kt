package io.github.lopution.pixivfunc.appwidget

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Runs one widget feed generation pass inside a controlled headless Flutter
 * engine (PRD R4).
 *
 * The engine executes the same Dart entrypoint graph as the app — shared
 * AccountStore, PixivHttpClient, TokenRefreshGate and NetworkAccessPolicy —
 * and reports only a classified outcome over `pixivfunc/widget_background`.
 * No credential, token or account data is read or stored on the native side.
 *
 * Engine creation, channel wiring and teardown must run on the main thread
 * (FlutterJNI enforces @UiThread); the calling worker thread only waits on
 * the bounded latch.
 */
object WidgetHeadlessRunner {
    private const val TAG = "WidgetHeadless"
    private const val CHANNEL = "pixivfunc/widget_background"
    private const val ENTRYPOINT = "widgetBackgroundMain"

    /** Hard wall-clock bound; stays well inside the WorkManager 10 min cap. */
    private const val WAIT_MINUTES = 4L

    enum class Outcome { WRITTEN, NO_ACCOUNT, AUTH_REQUIRED, TRANSIENT }

    fun runGeneration(context: Context): Outcome {
        val engineRef = AtomicReference<FlutterEngine?>(null)
        val outcomeRef = AtomicReference(Outcome.TRANSIENT)
        val latch = CountDownLatch(1)
        val mainHandler = Handler(Looper.getMainLooper())
        mainHandler.post {
            try {
                val flutterLoader = FlutterInjector.instance().flutterLoader()
                flutterLoader.startInitialization(context)
                flutterLoader.ensureInitializationComplete(context, emptyArray())
                val entrypoint = DartExecutor.DartEntrypoint(
                    flutterLoader.findAppBundlePath(),
                    ENTRYPOINT,
                )
                // Wire the result channel before Dart executes. Creating the
                // engine group with createAndRunEngine first leaves a small
                // cold-start window where the first result could be dropped.
                val engine = FlutterEngine(context)
                engineRef.set(engine)
                MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                    .setMethodCallHandler { call, result ->
                        if (call.method == "result") {
                            // Publish before releasing the waiter: no race.
                            outcomeRef.set(parseOutcome(call.argument<String>("outcome")))
                            result.success(null)
                            latch.countDown()
                        } else {
                            result.notImplemented()
                        }
                    }
                engine.dartExecutor.executeDartEntrypoint(entrypoint)
            } catch (error: Throwable) {
                // The worker still receives a classified outcome; the cause
                // stays visible in logcat for diagnosis.
                Log.e(TAG, "headless engine setup failed", error)
                latch.countDown()
            }
        }
        val finished = try {
            latch.await(WAIT_MINUTES, TimeUnit.MINUTES)
        } catch (_: InterruptedException) {
            false
        }
        destroyOnMainThread(engineRef)
        return if (finished) outcomeRef.get() else Outcome.TRANSIENT
    }

    private fun parseOutcome(raw: String?): Outcome = when (raw) {
        "written" -> Outcome.WRITTEN
        "noAccount" -> Outcome.NO_ACCOUNT
        "authRequired" -> Outcome.AUTH_REQUIRED
        else -> Outcome.TRANSIENT
    }

    /** FlutterEngine.destroy must run on the main thread. */
    private fun destroyOnMainThread(engineRef: AtomicReference<FlutterEngine?>) {
        val engine = engineRef.get() ?: return
        if (Looper.myLooper() == Looper.getMainLooper()) {
            engine.destroy()
            return
        }
        val destroyed = CountDownLatch(1)
        Handler(Looper.getMainLooper()).post {
            try {
                engine.destroy()
            } catch (error: Throwable) {
                Log.w(TAG, "engine teardown failed", error)
            } finally {
                destroyed.countDown()
            }
        }
        try {
            destroyed.await(5, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            // Best-effort teardown; the OS reclaims the process-owned engine.
        }
    }
}
