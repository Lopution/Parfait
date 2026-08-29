package io.github.lopution.pixivfunc

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
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
 * The channel never logs or persists the text. Delayed clearing compares a
 * one-way fingerprint with the current clipboard first, so a later user copy
 * is not overwritten by our cleanup task.
 */
object AccountTransferClipboardChannel {
    private const val CHANNEL = "pixivfunc/account_transfer_clipboard"
    private const val MAX_TEXT_LENGTH = 32 * 1024
    private const val MIN_CLEAR_DELAY_MS = 1L
    private const val MAX_CLEAR_DELAY_MS = 10L * 60L * 1000L

    fun configure(context: Context, engine: FlutterEngine) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val handler = Handler(Looper.getMainLooper())
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "write" -> write(clipboard, handler, call, result)
                    "read" -> read(clipboard, result)
                    "clearIfCurrent" -> clearIfCurrent(clipboard, call, result)
                    "capabilities" -> capabilities(result)
                    else -> result.notImplemented()
                }
            }
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
        handler: Handler,
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

        val clip = ClipData.newPlainText("Pixiv Func account transfer", text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            clip.description.setExtras(PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            })
        }
        clipboard.setPrimaryClip(clip)
        handler.postDelayed({
            if (fingerprintOf(currentText(clipboard)) == fingerprint) {
                clear(clipboard)
            }
        }, delayMs)
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
        result.success(true)
    }

    private fun currentText(clipboard: ClipboardManager): String? {
        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        return clip.getItemAt(0).text?.toString()
    }

    private fun clear(clipboard: ClipboardManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            clipboard.clearPrimaryClip()
        } else {
            clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
        }
    }

    private fun fingerprintOf(text: String?): String {
        if (text == null) return ""
        val digest = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }
}
