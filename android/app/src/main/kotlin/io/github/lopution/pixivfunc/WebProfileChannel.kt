package io.github.lopution.pixivfunc

import android.content.Context
import android.webkit.CookieManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Session bridge: exports/clears the shared WebView cookies for
 * www.pixiv.net so the in-app profile API adapter can use the same session
 * established by the ordinary login flow. No profile editor WebView is
 * opened by this bridge.
 *
 * The WebView cookie store is shared across every WebView in the app (and
 * persisted by the platform), so after the user logs in once in the login
 * page the cookie is available here and stays available across restarts.
 */
internal interface WebProfileCookies {
    fun cookie(url: String): String?

    fun clearAll()
}

object WebProfileChannel {

    private const val CHANNEL = "pixivfunc/webprofile"
    internal const val PIXIV_WEB = "https://www.pixiv.net"

    fun configure(context: Context, engine: FlutterEngine) {
        // CookieManager.getCookie / flush are not documented as thread-safe
        // (https://developer.android.com/reference/android/webkit/CookieManager).
        // Stay on the platform thread.
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                handle(call, result, AndroidWebProfileCookies)
            }
    }

    internal fun handle(
        call: MethodCall,
        result: MethodChannel.Result,
        cookies: WebProfileCookies,
    ) {
        try {
            when (call.method) {
                // Returns the raw Cookie header value for the web
                // profile host (e.g. "PHPSESSID=...; device_token=...").
                "readSession" -> result.success(cookies.cookie(PIXIV_WEB))
                // Clears the web session cookies (logout, switch
                // account). Also clears the accounts host so the next
                // login starts fresh.
                "clearSession" -> {
                    cookies.clearAll()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error(webprofileErrorCode(call.method, error), error.message, null)
        }
    }

    internal fun webprofileErrorCode(method: String, error: Throwable): String {
        if (error is SecurityException) return "webprofile_permission"
        if (method == "readSession") return "webprofile_read_failed"
        if (method == "clearSession") return "webprofile_clear_failed"
        return "webprofile_io_failed"
    }

    private object AndroidWebProfileCookies : WebProfileCookies {
        override fun cookie(url: String): String? =
            CookieManager.getInstance().getCookie(url)

        override fun clearAll() {
            val manager = CookieManager.getInstance()
            manager.removeAllCookies(null)
            manager.flush()
        }
    }
}
