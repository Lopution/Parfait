package io.github.lopution.pixivfunc

import io.flutter.plugin.common.MethodChannel

/** Hand-written [MethodChannel.Result] for JVM handler tests. */
internal class RecordingMethodResult : MethodChannel.Result {
    var successValue: Any? = UNSET
    var errorCode: String? = null
    var errorMessage: String? = null
    var errorDetails: Any? = null
    var notImplemented = false

    override fun success(result: Any?) {
        successValue = result
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        this.errorCode = errorCode
        this.errorMessage = errorMessage
        this.errorDetails = errorDetails
    }

    override fun notImplemented() {
        notImplemented = true
    }

    fun hasSuccess(): Boolean = successValue !== UNSET

    companion object {
        val UNSET = Any()
    }
}
