package io.github.lopution.pixivfunc

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Explicit MethodCall argument reads. Missing or mistyped required values
 * become `<prefix>invalid_argument` instead of an unchecked force-unwrap.
 */
internal object ChannelArgs {
    fun requiredString(
        call: MethodCall,
        result: MethodChannel.Result,
        name: String,
        prefix: String,
    ): String? {
        val raw = call.argument<Any?>(name)
        if (raw == null) {
            result.error("${prefix}invalid_argument", "$name missing", null)
            return null
        }
        if (raw !is String) {
            result.error("${prefix}invalid_argument", "$name has wrong type", null)
            return null
        }
        return raw
    }

    /**
     * Optional string. [ok] is false when the key is present but not a
     * String (error already reported). Absent key → [ok] true and [value]
     * null.
     */
    fun optionalString(
        call: MethodCall,
        result: MethodChannel.Result,
        name: String,
        prefix: String,
    ): OptionalString {
        val raw = call.argument<Any?>(name) ?: return OptionalString(null, ok = true)
        if (raw !is String) {
            result.error("${prefix}invalid_argument", "$name has wrong type", null)
            return OptionalString(null, ok = false)
        }
        return OptionalString(raw, ok = true)
    }

    fun requiredInt(
        call: MethodCall,
        result: MethodChannel.Result,
        name: String,
        prefix: String,
    ): Int? {
        val raw = call.argument<Any?>(name)
        if (raw == null) {
            result.error("${prefix}invalid_argument", "$name missing", null)
            return null
        }
        val number = raw as? Number
        if (number == null) {
            result.error("${prefix}invalid_argument", "$name has wrong type", null)
            return null
        }
        return number.toInt()
    }

    fun requiredBytes(
        call: MethodCall,
        result: MethodChannel.Result,
        name: String,
        prefix: String,
    ): ByteArray? {
        val raw = call.argument<Any?>(name)
        if (raw == null) {
            result.error("${prefix}invalid_argument", "$name missing", null)
            return null
        }
        if (raw !is ByteArray) {
            result.error("${prefix}invalid_argument", "$name has wrong type", null)
            return null
        }
        return raw
    }
}

internal data class OptionalString(val value: String?, val ok: Boolean)
