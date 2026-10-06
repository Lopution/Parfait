package io.github.lopution.parfait

import android.content.Context
import android.view.accessibility.AccessibilityManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Signals read from [AccessibilityManager]; faked in JVM tests. */
internal interface AccessibilitySignals {
    fun isTouchExplorationEnabled(): Boolean

    fun recommendedTimeoutMillis(originalTimeoutMs: Int, contentFlags: Int): Int
}

/**
 * The real touch-exploration signal plus the system's recommended UI
 * timeout. The engine's `accessibleNavigation` bit is unusable here: it is
 * set by any assistive service that reads a node once and never reset, so
 * ad-skipping services like GKD pin it true forever. Touch exploration is
 * the flag Material components actually gate on.
 */
object AccessibilityChannel {
    private const val METHOD_CHANNEL = "parfait/accessibility"
    private const val EVENT_CHANNEL = "parfait/accessibility/events"
    private const val PREFIX = "a11y_"

    fun configure(context: Context, engine: FlutterEngine) {
        val manager =
            context.getSystemService(Context.ACCESSIBILITY_SERVICE)
                as AccessibilityManager
        val signals =
            object : AccessibilitySignals {
                override fun isTouchExplorationEnabled() =
                    manager.isTouchExplorationEnabled

                override fun recommendedTimeoutMillis(
                    originalTimeoutMs: Int,
                    contentFlags: Int,
                ) = manager.getRecommendedTimeoutMillis(originalTimeoutMs, contentFlags)
            }
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result, signals) }
        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(TouchExplorationStreamHandler(manager))
    }

    internal fun handle(
        call: MethodCall,
        result: MethodChannel.Result,
        signals: AccessibilitySignals,
    ) {
        when (call.method) {
            "getTouchExplorationEnabled" ->
                result.success(signals.isTouchExplorationEnabled())
            "recommendedTimeoutMillis" -> {
                val base =
                    ChannelArgs.requiredInt(call, result, "originalTimeoutMs", PREFIX)
                        ?: return
                val flags =
                    ChannelArgs.requiredInt(call, result, "contentFlags", PREFIX)
                        ?: return
                result.success(signals.recommendedTimeoutMillis(base, flags))
            }
            else -> result.notImplemented()
        }
    }
}

/** Pushes the current value on listen, then every state change. */
private class TouchExplorationStreamHandler(
    private val manager: AccessibilityManager,
) : EventChannel.StreamHandler {
    private var listener: AccessibilityManager.TouchExplorationStateChangeListener? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        listener =
            AccessibilityManager.TouchExplorationStateChangeListener { enabled ->
                events?.success(enabled)
            }
        listener?.let { manager.addTouchExplorationStateChangeListener(it) }
        events?.success(manager.isTouchExplorationEnabled)
    }

    override fun onCancel(arguments: Any?) {
        listener?.let { manager.removeTouchExplorationStateChangeListener(it) }
        listener = null
    }
}
