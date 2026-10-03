package io.github.lopution.parfait

import android.annotation.SuppressLint
import android.os.Build
import android.os.VibrationEffect
import android.view.HapticFeedbackConstants

/** What the app means by a haptic; the wire names match Dart `HapticRole`. */
internal enum class HapticRole(val wire: String) {
    SELECT("select"),
    TOGGLE_ON("toggleOn"),
    TOGGLE_OFF("toggleOff"),
    TICK("tick"),
    THRESHOLD_ON("thresholdOn"),
    THRESHOLD_OFF("thresholdOff"),
    LONG_PRESS("longPress"),
    CONFIRM("confirm"),
    SUCCESS("success"),
    ERROR("error");

    companion object {
        fun fromWire(value: String): HapticRole? = entries.firstOrNull { it.wire == value }
    }
}

/**
 * User strength tier. [scale] multiplies primitive amplitudes; adjacent
 * tiers differ by ≥ 1.4×, the smallest step users reliably tell apart.
 */
internal enum class HapticStrength(val wire: String, val scale: Float) {
    LIGHT("light", 0.5f),
    STANDARD("standard", 0.7f),
    STRONG("strong", 1.0f);

    companion object {
        fun fromWire(value: String): HapticStrength? = entries.firstOrNull { it.wire == value }
    }
}

/** How this device can play haptics, best first. */
internal enum class HapticTier(val wire: String) {
    /** Android 11+ primitives with amplitude control: strength is continuous. */
    COMPOSITION("composition"),

    /** Predefined effects: strength picks a different effect per tier. */
    PREDEFINED("predefined"),

    /** Vibrator refused: View haptic constants only, strength ignored. */
    SYSTEM("system"),
    NONE("none"),
}

internal data class PrimitiveStep(val primitive: Int, val scale: Float, val delayMs: Int = 0)

internal sealed interface HapticPlan {
    data class Primitives(val steps: List<PrimitiveStep>) : HapticPlan
    data class Predefined(val effectId: Int) : HapticPlan
    data class ViewConstant(val constant: Int) : HapticPlan
    data object Silent : HapticPlan
}

/**
 * The only role → effect mapping. Pure, so every role × strength × tier ×
 * SDK combination is covered by JVM tests.
 *
 * Constants newer than minSdk are only returned behind an [sdkInt] check,
 * which lint cannot see through a parameter.
 */
@SuppressLint("InlinedApi")
internal object HapticPlanner {
    private const val CLICK = VibrationEffect.Composition.PRIMITIVE_CLICK
    private const val TICK = VibrationEffect.Composition.PRIMITIVE_TICK
    private const val ERROR_GAP_MS = 80

    fun plan(role: HapticRole, strength: HapticStrength, tier: HapticTier, sdkInt: Int): HapticPlan =
        when (tier) {
            HapticTier.COMPOSITION -> primitives(role, strength.scale)
            HapticTier.PREDEFINED -> HapticPlan.Predefined(predefined(role, strength))
            HapticTier.SYSTEM -> HapticPlan.ViewConstant(viewConstant(role, strength, sdkInt))
            HapticTier.NONE -> HapticPlan.Silent
        }

    /** The View constant replayed when the vibrator refuses at play time. */
    fun viewConstant(role: HapticRole, strength: HapticStrength, sdkInt: Int): Int {
        val u = sdkInt >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE
        val r = sdkInt >= Build.VERSION_CODES.R
        return when (role) {
            HapticRole.SELECT ->
                if (strength == HapticStrength.STRONG) {
                    HapticFeedbackConstants.VIRTUAL_KEY
                } else {
                    HapticFeedbackConstants.CONTEXT_CLICK
                }
            HapticRole.TOGGLE_ON ->
                if (u) HapticFeedbackConstants.TOGGLE_ON else HapticFeedbackConstants.CONTEXT_CLICK
            HapticRole.TOGGLE_OFF ->
                if (u) HapticFeedbackConstants.TOGGLE_OFF else HapticFeedbackConstants.CONTEXT_CLICK
            HapticRole.TICK ->
                if (u) HapticFeedbackConstants.SEGMENT_TICK else HapticFeedbackConstants.TEXT_HANDLE_MOVE
            HapticRole.THRESHOLD_ON ->
                if (u) {
                    HapticFeedbackConstants.GESTURE_THRESHOLD_ACTIVATE
                } else {
                    HapticFeedbackConstants.CONTEXT_CLICK
                }
            HapticRole.THRESHOLD_OFF ->
                if (u) {
                    HapticFeedbackConstants.GESTURE_THRESHOLD_DEACTIVATE
                } else {
                    HapticFeedbackConstants.CONTEXT_CLICK
                }
            HapticRole.LONG_PRESS, HapticRole.CONFIRM -> HapticFeedbackConstants.LONG_PRESS
            HapticRole.SUCCESS ->
                if (r) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.VIRTUAL_KEY
            HapticRole.ERROR ->
                if (r) HapticFeedbackConstants.REJECT else HapticFeedbackConstants.LONG_PRESS
        }
    }

    private fun primitives(role: HapticRole, s: Float): HapticPlan.Primitives {
        val steps = when (role) {
            HapticRole.SELECT -> listOf(PrimitiveStep(TICK, s * 1.0f))
            HapticRole.TOGGLE_ON -> listOf(PrimitiveStep(CLICK, s * 0.7f))
            HapticRole.TOGGLE_OFF -> listOf(PrimitiveStep(TICK, s * 0.8f))
            HapticRole.TICK -> listOf(PrimitiveStep(TICK, s * 0.5f))
            HapticRole.THRESHOLD_ON -> listOf(PrimitiveStep(CLICK, s * 0.8f))
            HapticRole.THRESHOLD_OFF -> listOf(PrimitiveStep(TICK, s * 0.6f))
            HapticRole.LONG_PRESS, HapticRole.CONFIRM -> listOf(PrimitiveStep(CLICK, s * 1.0f))
            HapticRole.SUCCESS -> listOf(PrimitiveStep(CLICK, s * 0.8f))
            HapticRole.ERROR -> listOf(
                PrimitiveStep(CLICK, s * 1.0f),
                PrimitiveStep(CLICK, s * 1.0f, ERROR_GAP_MS),
            )
        }
        return HapticPlan.Primitives(steps)
    }

    private fun predefined(role: HapticRole, strength: HapticStrength): Int {
        val tick = VibrationEffect.EFFECT_TICK
        val click = VibrationEffect.EFFECT_CLICK
        val heavy = VibrationEffect.EFFECT_HEAVY_CLICK
        // (light, standard, strong)
        val tiers = when (role) {
            HapticRole.SELECT -> Triple(tick, tick, click)
            HapticRole.TOGGLE_ON, HapticRole.THRESHOLD_ON -> Triple(tick, click, click)
            HapticRole.TOGGLE_OFF, HapticRole.TICK, HapticRole.THRESHOLD_OFF -> Triple(tick, tick, tick)
            HapticRole.LONG_PRESS -> Triple(click, heavy, heavy)
            HapticRole.CONFIRM -> Triple(heavy, heavy, heavy)
            HapticRole.SUCCESS -> Triple(click, click, heavy)
            HapticRole.ERROR -> VibrationEffect.EFFECT_DOUBLE_CLICK.let { Triple(it, it, it) }
        }
        return when (strength) {
            HapticStrength.LIGHT -> tiers.first
            HapticStrength.STANDARD -> tiers.second
            HapticStrength.STRONG -> tiers.third
        }
    }
}
