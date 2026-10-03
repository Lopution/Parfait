package io.github.lopution.parfait

import android.os.VibrationEffect
import android.view.HapticFeedbackConstants
import io.flutter.plugin.common.MethodCall
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HapticPlannerTest {
    private val sdks = listOf(29, 30, 34)

    @Test
    fun `every role plans something on every playable tier and sdk`() {
        for (role in HapticRole.entries) {
            for (strength in HapticStrength.entries) {
                for (sdk in sdks) {
                    for (tier in listOf(HapticTier.COMPOSITION, HapticTier.PREDEFINED, HapticTier.SYSTEM)) {
                        val plan = HapticPlanner.plan(role, strength, tier, sdk)
                        assertFalse("$role $strength $tier $sdk", plan == HapticPlan.Silent)
                    }
                    assertEquals(HapticPlan.Silent, HapticPlanner.plan(role, strength, HapticTier.NONE, sdk))
                }
            }
        }
    }

    @Test
    fun `adjacent strengths differ by at least 1_4x on the composition tier`() {
        for (role in HapticRole.entries) {
            val scales = HapticStrength.entries.map { strength ->
                val plan = HapticPlanner.plan(role, strength, HapticTier.COMPOSITION, 34) as HapticPlan.Primitives
                plan.steps.first().scale
            }
            for (i in 1 until scales.size) {
                assertTrue("$role ${scales[i - 1]} → ${scales[i]}", scales[i] / scales[i - 1] >= 1.399f)
            }
        }
    }

    @Test
    fun `composition scales stay within the primitive range`() {
        for (role in HapticRole.entries) {
            for (strength in HapticStrength.entries) {
                val plan = HapticPlanner.plan(role, strength, HapticTier.COMPOSITION, 34) as HapticPlan.Primitives
                for (step in plan.steps) assertTrue(step.scale > 0f && step.scale <= 1f)
            }
        }
    }

    @Test
    fun `only tick may fall back to the faint text-handle constant and nothing uses clock tick`() {
        for (role in HapticRole.entries) {
            for (strength in HapticStrength.entries) {
                for (sdk in sdks) {
                    val constant = HapticPlanner.viewConstant(role, strength, sdk)
                    assertFalse(constant == HapticFeedbackConstants.CLOCK_TICK)
                    if (role != HapticRole.TICK) {
                        assertFalse("$role", constant == HapticFeedbackConstants.TEXT_HANDLE_MOVE)
                    }
                }
            }
        }
    }

    @Test
    fun `toggles, ticks and thresholds use the Android 14 constants when available`() {
        val s = HapticStrength.STANDARD
        assertEquals(HapticFeedbackConstants.TOGGLE_ON, HapticPlanner.viewConstant(HapticRole.TOGGLE_ON, s, 34))
        assertEquals(HapticFeedbackConstants.TOGGLE_OFF, HapticPlanner.viewConstant(HapticRole.TOGGLE_OFF, s, 34))
        assertEquals(HapticFeedbackConstants.SEGMENT_TICK, HapticPlanner.viewConstant(HapticRole.TICK, s, 34))
        assertEquals(
            HapticFeedbackConstants.GESTURE_THRESHOLD_ACTIVATE,
            HapticPlanner.viewConstant(HapticRole.THRESHOLD_ON, s, 34),
        )
        assertEquals(
            HapticFeedbackConstants.GESTURE_THRESHOLD_DEACTIVATE,
            HapticPlanner.viewConstant(HapticRole.THRESHOLD_OFF, s, 34),
        )
        assertEquals(HapticFeedbackConstants.CONTEXT_CLICK, HapticPlanner.viewConstant(HapticRole.TOGGLE_ON, s, 30))
        assertEquals(HapticFeedbackConstants.TEXT_HANDLE_MOVE, HapticPlanner.viewConstant(HapticRole.TICK, s, 30))
    }

    @Test
    fun `success and error use confirm and reject from Android 11`() {
        val s = HapticStrength.STANDARD
        assertEquals(HapticFeedbackConstants.CONFIRM, HapticPlanner.viewConstant(HapticRole.SUCCESS, s, 30))
        assertEquals(HapticFeedbackConstants.REJECT, HapticPlanner.viewConstant(HapticRole.ERROR, s, 30))
        assertEquals(HapticFeedbackConstants.VIRTUAL_KEY, HapticPlanner.viewConstant(HapticRole.SUCCESS, s, 29))
        assertEquals(HapticFeedbackConstants.LONG_PRESS, HapticPlanner.viewConstant(HapticRole.ERROR, s, 29))
    }

    @Test
    fun `predefined tier swaps effects by strength`() {
        fun effect(role: HapticRole, strength: HapticStrength) =
            (HapticPlanner.plan(role, strength, HapticTier.PREDEFINED, 29) as HapticPlan.Predefined).effectId
        assertEquals(VibrationEffect.EFFECT_TICK, effect(HapticRole.SELECT, HapticStrength.LIGHT))
        assertEquals(VibrationEffect.EFFECT_CLICK, effect(HapticRole.SELECT, HapticStrength.STRONG))
        assertEquals(VibrationEffect.EFFECT_CLICK, effect(HapticRole.LONG_PRESS, HapticStrength.LIGHT))
        assertEquals(VibrationEffect.EFFECT_HEAVY_CLICK, effect(HapticRole.LONG_PRESS, HapticStrength.STANDARD))
        assertEquals(VibrationEffect.EFFECT_DOUBLE_CLICK, effect(HapticRole.ERROR, HapticStrength.LIGHT))
    }

    @Test
    fun `error composes two clicks with a gap`() {
        val plan = HapticPlanner.plan(HapticRole.ERROR, HapticStrength.STRONG, HapticTier.COMPOSITION, 34)
            as HapticPlan.Primitives
        assertEquals(2, plan.steps.size)
        assertEquals(VibrationEffect.Composition.PRIMITIVE_CLICK, plan.steps[1].primitive)
        assertTrue(plan.steps[1].delayMs > 0)
    }
}

class HapticsControllerTest {
    @Test
    fun `tier is probed once and reported with the system switch`() {
        val device = FakeDevice(tier = HapticTier.PREDEFINED, systemOff = true)
        val controller = HapticsController(device)
        assertEquals(mapOf("tier" to "predefined", "systemOff" to true), controller.capabilities())
        controller.play(HapticRole.SELECT, HapticStrength.STANDARD)
        controller.capabilities()
        assertEquals(1, device.probes)
    }

    @Test
    fun `vibrator plans play through the vibrator`() {
        val device = FakeDevice(tier = HapticTier.COMPOSITION)
        HapticsController(device).play(HapticRole.TOGGLE_ON, HapticStrength.STANDARD)
        assertEquals(
            listOf(HapticPlanner.plan(HapticRole.TOGGLE_ON, HapticStrength.STANDARD, HapticTier.COMPOSITION, 34)),
            device.vibrated,
        )
        assertTrue(device.viewHaptics.isEmpty())
    }

    @Test
    fun `system touch feedback off silences the vibrator`() {
        val device = FakeDevice(tier = HapticTier.COMPOSITION, systemOff = true)
        HapticsController(device).play(HapticRole.CONFIRM, HapticStrength.STRONG)
        assertTrue(device.vibrated.isEmpty())
        assertTrue(device.viewHaptics.isEmpty())
    }

    @Test
    fun `a refused vibrator demotes to view constants and replays`() {
        val device = FakeDevice(tier = HapticTier.COMPOSITION, refuse = true)
        val controller = HapticsController(device)
        controller.play(HapticRole.SUCCESS, HapticStrength.STANDARD)
        assertEquals(listOf(HapticFeedbackConstants.CONFIRM), device.viewHaptics)
        assertEquals("system", controller.capabilities()["tier"])

        device.refuse = false
        controller.play(HapticRole.ERROR, HapticStrength.STANDARD)
        assertTrue(device.vibrated.isEmpty())
        assertEquals(listOf(HapticFeedbackConstants.CONFIRM, HapticFeedbackConstants.REJECT), device.viewHaptics)
    }

    @Test
    fun `no vibrator plays nothing`() {
        val device = FakeDevice(tier = HapticTier.NONE)
        HapticsController(device).play(HapticRole.CONFIRM, HapticStrength.STRONG)
        assertTrue(device.vibrated.isEmpty())
        assertTrue(device.viewHaptics.isEmpty())
    }

    @Test
    fun `play decodes wire names`() {
        val device = FakeDevice(tier = HapticTier.PREDEFINED)
        val result = RecordingMethodResult()
        HapticsController(device).handle(
            MethodCall("play", mapOf("role" to "thresholdOn", "strength" to "light")),
            result,
        )
        assertTrue(result.hasSuccess())
        assertNull(result.successValue)
        assertEquals(listOf(HapticPlan.Predefined(VibrationEffect.EFFECT_TICK)), device.vibrated)
    }

    @Test
    fun `bad play arguments are invalid_argument`() {
        for (args in listOf(
            mapOf("strength" to "light"),
            mapOf("role" to "edge", "strength" to "light"),
            mapOf("role" to "select", "strength" to "off"),
            mapOf("role" to 1, "strength" to "light"),
        )) {
            val result = RecordingMethodResult()
            HapticsController(FakeDevice()).handle(MethodCall("play", args), result)
            assertEquals("$args", "haptics_invalid_argument", result.errorCode)
        }
    }

    @Test
    fun `unknown method is notImplemented`() {
        val result = RecordingMethodResult()
        HapticsController(FakeDevice()).handle(MethodCall("buzz", null), result)
        assertTrue(result.notImplemented)
    }

    @Test
    fun `device failures surface as haptics_failed`() {
        val device = FakeDevice(probeError = IllegalStateException("no service"))
        val result = RecordingMethodResult()
        HapticsController(device).handle(MethodCall("capabilities", null), result)
        assertEquals("haptics_failed", result.errorCode)
    }

    private class FakeDevice(
        private val tier: HapticTier = HapticTier.COMPOSITION,
        private val systemOff: Boolean = false,
        var refuse: Boolean = false,
        private val probeError: RuntimeException? = null,
    ) : HapticsDevice {
        override val sdkInt = 34
        var probes = 0
        val vibrated = mutableListOf<HapticPlan>()
        val viewHaptics = mutableListOf<Int>()

        override fun probeTier(): HapticTier {
            probeError?.let { throw it }
            probes++
            return tier
        }

        override fun systemHapticsOff() = systemOff

        override fun vibrate(plan: HapticPlan) {
            if (refuse) throw SecurityException("vibration revoked")
            vibrated += plan
        }

        override fun performViewHaptic(constant: Int) {
            viewHaptics += constant
        }
    }
}
