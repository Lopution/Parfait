package io.github.lopution.pixivfunc

import android.content.Context
import android.webkit.CookieManager
import io.flutter.embedding.engine.FlutterEngine
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
object WebProfileChannel {

    private const val CHANNEL = "pixivfunc/webprofile"
    private const val PIXIV_WEB = "https://www.pixiv.net"

    fun configure(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        // Returns the raw Cookie header value for the web
                        // profile host (e.g. "PHPSESSID=...; device_token=...").
                        "readSession" -> result.success(
                            CookieManager.getInstance().getCookie(PIXIV_WEB)
                        )
                        // Clears the web session cookies (logout, switch
                        // account). Also clears the accounts host so the next
                        // login starts fresh.
                        "clearSession" -> {
                            val manager = CookieManager.getInstance()
                            manager.removeAllCookies(null)
                            manager.flush()
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("webprofile_error", error.message, null)
                }
            }
    }
}
