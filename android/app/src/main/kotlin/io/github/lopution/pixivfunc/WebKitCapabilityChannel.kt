package io.github.lopution.pixivfunc

import android.content.Context
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Reports AndroidX WebKit support without changing proxy or TLS settings. */
object WebKitCapabilityChannel {
    private const val CHANNEL = "pixivfunc/webkit_capabilities"

    fun configure(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "probe") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    result.success(
                        mapOf(
                            "proxyController" to WebViewFeature.isFeatureSupported(
                                WebViewFeature.PROXY_OVERRIDE,
                            ),
                            "proxyReverseBypass" to WebViewFeature.isFeatureSupported(
                                WebViewFeature.PROXY_OVERRIDE_REVERSE_BYPASS,
                            ),
                            "serviceWorkerController" to WebViewFeature.isFeatureSupported(
                                WebViewFeature.SERVICE_WORKER_SHOULD_INTERCEPT_REQUEST,
                            ),
                            "webViewPackage" to WebViewCompat.getCurrentWebViewPackage(
                                context,
                            )?.packageName,
                        ),
                    )
                } catch (error: Exception) {
                    result.error(
                        "webkit_capability_error",
                        error.message,
                        null,
                    )
                }
            }
    }
}
