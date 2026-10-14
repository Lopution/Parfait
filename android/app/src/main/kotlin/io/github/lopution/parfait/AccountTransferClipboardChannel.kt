package io.github.lopution.parfait

import android.app.Activity
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/**
 * Sensitive, short-lived clipboard bridge for account transfer.
 *
 * The channel never logs or persists the text. Clearing after the lifetime
 * goes through [PendingTransferClear], which recognises our clip without
 * reading it, so a later user copy is not overwritten by our cleanup.
 */
object AccountTransferClipboardChannel {
    private const val CHANNEL = "parfait/account_transfer_clipboard"
    private const val PREFS = "parfait_transfer_clipboard"
    private const val MAX_TEXT_LENGTH = 32 * 1024
    private const val MIN_CLEAR_DELAY_MS = 1L
    private const val MAX_CLEAR_DELAY_MS = 10L * 60L * 1000L

    /** Sweeps the pending clear; the activity calls it whenever it gains focus. */
    class Sweeper internal constructor(
        private val activity: Activity,
        private val pending: PendingTransferClear,
        private val handler: Handler,
    ) {
        private val timer = Runnable { if (activity.hasWindowFocus()) sweep() }

        fun sweep() {
            handler.removeCallbacks(timer)
            val outcome = pending.sweep()
            if (outcome is PendingTransferClear.Outcome.Waiting) {
                handler.postDelayed(timer, outcome.remainingMs)
            }
        }

        fun dispose() = handler.removeCallbacks(timer)
    }

    fun configure(activity: Activity, engine: FlutterEngine): Sweeper {
        val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val pending = PendingTransferClear(
            PrefsPendingClearStore(prefs),
            SystemClipStamps(clipboard),
            System::currentTimeMillis,
        )
        val sweeper = Sweeper(activity, pending, Handler(Looper.getMainLooper()))
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "write" -> write(clipboard, pending, sweeper, call, result)
                    "read" -> read(clipboard, result)
                    "clearIfCurrent" -> clearIfCurrent(clipboard, pending, call, result)
                    "capabilities" -> capabilities(result)
                    else -> result.notImplemented()
                }
            }
        return sweeper
    }

    /**
     * Reports which safety capabilities this platform offers for the
     * transfer clipboard. `sensitiveMarkSupported` is false below API 33:
     * the system then stores the credential in plaintext without the
     * sensitive flag, and callers must surface an explicit warning instead
     * of silently skipping a safety feature.
     */
    private fun capabilities(result: MethodChannel.Result) {
        result.success(
            mapOf(
                "sensitiveMarkSupported" to
                    (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU),
            ),
        )
    }

    private fun write(
        clipboard: ClipboardManager,
        pending: PendingTransferClear,
        sweeper: Sweeper,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val text = call.argument<String>("text")
        val fingerprint = call.argument<String>("fingerprint")
        val delayMs = call.argument<Number>("clearAfterMs")?.toLong()
        if (text.isNullOrEmpty() || text.length > MAX_TEXT_LENGTH ||
            fingerprint.isNullOrBlank() || delayMs == null ||
            delayMs !in MIN_CLEAR_DELAY_MS..MAX_CLEAR_DELAY_MS ||
            fingerprint != fingerprintOf(text)
        ) {
            result.error("invalid_payload", "clipboard transfer payload is invalid", null)
            return
        }

        val clip = ClipData.newPlainText(PendingTransferClear.LABEL, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            clip.description.setExtras(PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            })
        }
        clipboard.setPrimaryClip(clip)
        // The system stamps the clip when it becomes primary; without that
        // stamp no later sweep could recognise it, so take it back out.
        val stamp = SystemClipStamps(clipboard).current()
        if (stamp == null || stamp.label != PendingTransferClear.LABEL) {
            clear(clipboard)
            result.error("clear_unarmed", "clipboard did not report the exported clip", null)
            return
        }
        pending.arm(stamp, delayMs)
        sweeper.sweep()
        result.success(true)
    }

    private fun read(
        clipboard: ClipboardManager,
        result: MethodChannel.Result,
    ) {
        val text = currentText(clipboard)
        if (text == null) {
            result.success(null)
            return
        }
        if (text.isEmpty() || text.length > MAX_TEXT_LENGTH) {
            result.error("too_large", "clipboard transfer payload is too large", null)
            return
        }
        result.success(mapOf("text" to text, "fingerprint" to fingerprintOf(text)))
    }

    private fun clearIfCurrent(
        clipboard: ClipboardManager,
        pending: PendingTransferClear,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val expected = call.argument<String>("fingerprint")
        if (expected.isNullOrBlank()) {
            result.error("invalid_fingerprint", "clipboard fingerprint is invalid", null)
            return
        }
        if (fingerprintOf(currentText(clipboard)) != expected) {
            result.success(false)
            return
        }
        clear(clipboard)
        pending.disarm()
        result.success(true)
    }

    private fun currentText(clipboard: ClipboardManager): String? {
        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        return clip.getItemAt(0).text?.toString()
    }

    private fun clear(clipboard: ClipboardManager) {
        clipboard.clearPrimaryClip()
    }

    private fun fingerprintOf(text: String?): String {
        if (text == null) return ""
        val digest = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }
}

private class PrefsPendingClearStore(private val prefs: SharedPreferences) : PendingClearStore {
    override fun read(): PendingClear? {
        if (!prefs.contains(CLIP_TIMESTAMP) || !prefs.contains(EXPIRES_AT)) return null
        return PendingClear(prefs.getLong(CLIP_TIMESTAMP, 0), prefs.getLong(EXPIRES_AT, 0))
    }

    override fun write(pending: PendingClear) {
        prefs.edit()
            .putLong(CLIP_TIMESTAMP, pending.clipTimestamp)
            .putLong(EXPIRES_AT, pending.expiresAtMs)
            .apply()
    }

    override fun remove() {
        prefs.edit().clear().apply()
    }

    private companion object {
        const val CLIP_TIMESTAMP = "clipTimestamp"
        const val EXPIRES_AT = "expiresAt"
    }
}

private class SystemClipStamps(private val clipboard: ClipboardManager) : ClipStamps {
    // getPrimaryClipDescription, unlike getPrimaryClip, does not raise the
    // Android 12 clipboard access notice.
    override fun current(): ClipStamp? {
        val description = clipboard.primaryClipDescription ?: return null
        return ClipStamp(description.label?.toString(), description.timestamp)
    }

    override fun clear() = clipboard.clearPrimaryClip()
}
