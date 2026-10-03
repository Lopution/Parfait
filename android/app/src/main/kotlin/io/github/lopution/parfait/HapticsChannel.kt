package io.github.lopution.parfait

import android.app.Activity
import android.content.Context
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Device access behind the haptics channel; faked in JVM tests. */
internal interface HapticsDevice {
    val sdkInt: Int

    /** [HapticTier.COMPOSITION], [HapticTier.PREDEFINED] or [HapticTier.NONE]. */
    fun probeTier(): HapticTier

    /** The system "touch feedback" switch is off. */
    fun systemHapticsOff(): Boolean

    /** Plays a vibrator plan; throws [SecurityException] when the ROM refuses. */
    fun vibrate(plan: HapticPlan)

    fun performViewHaptic(constant: Int)
}

/**
 * Plays app haptics by role. The tier is probed once; a vibrator refused at
 * play time (some ROMs revoke vibration per app) demotes this process to
 * View haptic constants and replays the refused haptic that way.
 */
internal class HapticsController(private val device: HapticsDevice) {
    private var tier: HapticTier? = null

    private fun tier(): HapticTier = tier ?: device.probeTier().also { tier = it }

    fun capabilities(): Map<String, Any> =
        mapOf("tier" to tier().wire, "systemOff" to device.systemHapticsOff())

    fun play(role: HapticRole, strength: HapticStrength) {
        when (val plan = HapticPlanner.plan(role, strength, tier(), device.sdkInt)) {
            HapticPlan.Silent -> Unit
            // performHapticFeedback applies the system switch itself.
            is HapticPlan.ViewConstant -> device.performViewHaptic(plan.constant)
            is HapticPlan.Primitives, is HapticPlan.Predefined -> {
                if (device.systemHapticsOff()) return
                try {
                    device.vibrate(plan)
                } catch (_: SecurityException) {
                    tier = HapticTier.SYSTEM
                    device.performViewHaptic(HapticPlanner.viewConstant(role, strength, device.sdkInt))
                }
            }
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "capabilities" -> result.success(capabilities())
                "play" -> {
                    val role = ChannelArgs.requiredString(call, result, "role", PREFIX) ?: return
                    val strength = ChannelArgs.requiredString(call, result, "strength", PREFIX) ?: return
                    val parsedRole = HapticRole.fromWire(role)
                    val parsedStrength = HapticStrength.fromWire(strength)
                    if (parsedRole == null || parsedStrength == null) {
                        result.error("${PREFIX}invalid_argument", "unknown role or strength", null)
                        return
                    }
                    play(parsedRole, parsedStrength)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: RuntimeException) {
            result.error("${PREFIX}failed", e.message, null)
        }
    }

    companion object {
        const val PREFIX = "haptics_"
    }
}

internal object HapticsChannel {
    private const val CHANNEL = "parfait/haptics"

    fun configure(activity: Activity, engine: FlutterEngine) {
        // performHapticFeedback needs the main thread; vibrate is a one-way
        // binder call, so the platform thread is the right place for both.
        val controller = HapticsController(AndroidHapticsDevice(activity))
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> controller.handle(call, result) }
    }
}

private class AndroidHapticsDevice(private val activity: Activity) : HapticsDevice {
    override val sdkInt: Int = Build.VERSION.SDK_INT

    private val vibrator: Vibrator? by lazy {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            activity.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            activity.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }

    override fun probeTier(): HapticTier {
        val v = vibrator
        if (v == null || !v.hasVibrator()) return HapticTier.NONE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            v.hasAmplitudeControl() &&
            v.areAllPrimitivesSupported(
                VibrationEffect.Composition.PRIMITIVE_CLICK,
                VibrationEffect.Composition.PRIMITIVE_TICK,
            )
        ) {
            return HapticTier.COMPOSITION
        }
        return HapticTier.PREDEFINED
    }

    // Read on every play: the framework caches the setting in-process.
    // Deprecated from Android 13, where the touch-feedback intensity also
    // mutes USAGE_TOUCH vibrations system-side; the switch is still kept in
    // sync there, and older releases only have this switch.
    @Suppress("DEPRECATION")
    override fun systemHapticsOff(): Boolean =
        Settings.System.getInt(activity.contentResolver, Settings.System.HAPTIC_FEEDBACK_ENABLED, 1) == 0

    override fun vibrate(plan: HapticPlan) {
        val v = vibrator ?: return
        val effect = when (plan) {
            is HapticPlan.Primitives ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) composition(plan) else return
            is HapticPlan.Predefined -> VibrationEffect.createPredefined(plan.effectId)
            else -> return
        }
        // Touch usage puts app haptics under the system touch-feedback
        // intensity, like View haptics.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            v.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_TOUCH))
        } else {
            @Suppress("DEPRECATION")
            v.vibrate(effect, TOUCH_AUDIO_ATTRIBUTES)
        }
    }

    override fun performViewHaptic(constant: Int) {
        activity.window?.decorView?.performHapticFeedback(constant)
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun composition(plan: HapticPlan.Primitives): VibrationEffect {
        val composition = VibrationEffect.startComposition()
        for (step in plan.steps) {
            composition.addPrimitive(step.primitive, step.scale.coerceIn(0f, 1f), step.delayMs)
        }
        return composition.compose()
    }

    private companion object {
        val TOUCH_AUDIO_ATTRIBUTES: AudioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
    }
}
