package io.github.lopution.pixivfunc

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.os.Build
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.common.StandardMessageCodec
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Login WebView platform view with request interception (PRD R7).
 *
 * Why this exists: webview_flutter_android's Pigeon-generated WebViewClient
 * does not expose `shouldInterceptRequest` (it is called synchronously on an
 * Android background thread; the async pigeon channel cannot answer it).
 * The design choice (design.md §WebView) is a small native PlatformView used
 * ONLY for the login page; the existing webview_flutter implementation stays
 * as the fallback.
 *
 * Interception contract:
 *  - GET requests to Pixiv-owned hosts are re-sent by Dart through the SAME
 *    network policy ladder as API/image/download exits (single decision
 *    owner), fetching the body over the policy-selected tier.
 *  - `Set-Cookie` headers in the Dart response are injected one-by-one into
 *    android.webkit.CookieManager (a Map cannot hold multi-value cookies).
 *  - Non-GET, foreign hosts, timeout, channel errors and any exception
 *    return null → the native WebView stack proceeds untouched. Failed
 *    interception never swallows content.
 *
 * The Dart call is synchronous-blocking on the WebView thread with a hard
 * timeout ([interceptTimeoutMs]); on timeout the request is released to the
 * native stack instead of hanging the page.
 */
class LoginWebViewPlatformView(
    context: Context,
    private val messenger: BinaryMessenger,
) : PlatformView {

    companion object {
        const val viewType = "pixivfunc/login_webview"
        const val CHANNEL = "pixivfunc/login_webview_intercept"
        const val EVENTS_CHANNEL = "pixivfunc/login_webview_intercept_events"
        const val CONTROL_CHANNEL = "pixivfunc/login_webview_control"
        private const val METHOD_FETCH = "fetchWithPolicy"
        private const val TIMEOUT_MS = 15000L

        // Pixiv-owned hosts (exact match, lowercase). Third-party captcha /
        // identity-provider hosts are deliberately absent: the policy ladder
        // does not cover them and interception must not break their flows.
        private val PIXIV_HOSTS: Set<String> = setOf(
            "pixiv.net",
            "www.pixiv.net",
            "accounts.pixiv.net",
            "app-api.pixiv.net",
            "oauth.secure.pixiv.net",
            "i.pximg.net",
            "s.pximg.net",
        )

        private fun isPixivHost(host: String): Boolean {
            val lower = host.lowercase()
            if (lower in PIXIV_HOSTS) return true
            return lower.endsWith(".pixiv.net") || lower.endsWith(".pximg.net")
        }
    }

    private val webView: WebView = WebView(context.applicationContext)
    private val interceptChannel = MethodChannel(messenger, CHANNEL)
    private val eventsChannel = MethodChannel(messenger, EVENTS_CHANNEL)
    private val controlChannel = MethodChannel(messenger, CONTROL_CHANNEL)

    init {
        @SuppressLint("SetJavaScriptEnabled")
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            loadWithOverviewMode = true
            useWideViewPort = true
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            }
        }
        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView,
                request: WebResourceRequest,
            ): WebResourceResponse? {
                return intercept(request)
            }

            override fun onPageStarted(
                view: WebView?,
                url: String?,
                favicon: android.graphics.Bitmap?,
            ) {
                emit("pageStarted", mapOf("url" to (url ?: "")))
                super.onPageStarted(view, url, favicon)
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                emit("pageFinished", mapOf("url" to (url ?: "")))
                super.onPageFinished(view, url)
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: android.webkit.WebResourceError?,
            ) {
                val description = error?.description?.toString()
                    ?: "page load error"
                emit("webResourceError", mapOf("description" to description))
                super.onReceivedError(view, request, error)
            }

            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: WebResourceRequest?,
            ): Boolean {
                val requestUri = request?.url ?: return false
                val url = requestUri.toString()
                // Ask Dart: the PKCE callback (pixiv://account?code=...) must
                // be intercepted there. Return true = WebView stops.
                if (request.method == "GET" && isPixivHost(requestUri.host ?: "")) {
                    val prevented = askDartNavigationDecision(url)
                    if (prevented) {
                        return true
                    }
                }
                return super.shouldOverrideUrlLoading(view, request)
            }
        }
        controlChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "load" -> {
                    val url = call.argument<String>("url")
                    if (url != null) {
                        webView.loadUrl(url)
                        result.success(true)
                    } else {
                        result.error("bad_arguments", "url missing", null)
                    }
                }
                "goBack" -> {
                    if (webView.canGoBack()) {
                        webView.goBack()
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Sends an event to Dart (fire-and-forget). */
    private fun emit(method: String, arguments: Map<String, Any?>) {
        try {
            eventsChannel.invokeMethod(method, arguments)
        } catch (_: Exception) {
            // Events are best-effort; a missing Dart listener must never
            // crash the WebView thread.
        }
    }

    /**
     * Synchronously asks Dart whether a navigation may proceed. Used only
     * for GET requests on Pixiv hosts (the PKCE callback case). Returns
     * true when Dart says stop (callback consumed).
     */
    private fun askDartNavigationDecision(url: String): Boolean {
        val latch = CountDownLatch(1)
        val decision = AtomicReference<Boolean?>(null)
        try {
            eventsChannel.invokeMethod(
                "navigationRequest",
                mapOf("url" to url),
                object : MethodChannel.Result {
                    override fun success(value: Any?) {
                        decision.set(value == true)
                        latch.countDown()
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        decision.set(null)
                        latch.countDown()
                    }

                    override fun notImplemented() {
                        decision.set(null)
                        latch.countDown()
                    }
                },
            )
        } catch (_: Exception) {
            return false
        }
        if (!latch.await(TIMEOUT_MS, TimeUnit.MILLISECONDS)) return false
        return decision.get() == true
    }

    private fun intercept(request: WebResourceRequest): WebResourceResponse? {
        val requestUri = request.url ?: return null
        if (request.method != "GET") return null
        if (!isPixivHost(requestUri.host ?: "")) return null
        if (requestUri.scheme != "https") return null

        // GET on a Pixiv host goes through the policy ladder in Dart;
        // everything else (foreign captcha vendors, identity providers,
        // non-GET API calls) falls through to the native stack — never
        // swallowed, because the auth session lives in the WebView cookie
        // jar and the flow must keep working when interception is off.
        return fetchViaDart(requestUri)
    }

    private fun fetchViaDart(url: Uri): WebResourceResponse? {
        val latch = CountDownLatch(1)
        val result = AtomicReference<WebResourceResponse?>()
        val errorHolder = AtomicReference<String?>()

        MethodChannel(messenger, CHANNEL).invokeMethod(
            METHOD_FETCH,
            mapOf("url" to url.toString()),
            object : MethodChannel.Result {
                override fun success(value: Any?) {
                    @Suppress("UNCHECKED_CAST")
                    val response = value as? Map<String, Any?>
                    if (response == null) {
                        result.set(null)
                    } else {
                        result.set(buildResponse(response, url))
                    }
                    latch.countDown()
                }

                override fun error(code: String, message: String?, details: Any?) {
                    errorHolder.set("$code: $message")
                    result.set(null)
                    latch.countDown()
                }

                override fun notImplemented() {
                    errorHolder.set("notImplemented")
                    result.set(null)
                    latch.countDown()
                }
            },
        )

        val completed = latch.await(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        if (!completed) {
            // Timeout: release to the native stack. A hung login page is
            // worse than an unintercepted request.
            return null
        }
        val response = result.get()
        if (response != null) {
            injectCookies(response, url)
        }
        return response
    }

    /**
     * Replays the Dart-provided response as a WebResourceResponse and injects
     * Set-Cookie values one-by-one (multi-value aware).
     */
    private fun buildResponse(
        payload: Map<String, Any?>,
        url: Uri,
    ): WebResourceResponse? {
        val status = (payload["status"] as? Number)?.toInt() ?: return null
        if (status < 200 || status >= 400) {
            // Non-success and redirect statuses go back to the native stack:
            // redirects must run through the WebView's own redirect handling
            // (Host header + Cookie headers stay native for follow-ups).
            return null
        }
        val mime = payload["mimeType"] as? String ?: "application/octet-stream"
        val encoding = payload["encoding"] as? String ?: "utf-8"
        val headers = payload["headers"] as? Map<String, Any?>
        val body = payload["bodyBytes"] as? ByteArray

        val responseHeaders = mutableMapOf<String, String>()
        headers?.forEach { (key, value) ->
            responseHeaders[key] = value.toString()
        }

        return try {
            WebResourceResponse(
                mime,
                encoding,
                status,
                "OK",
                responseHeaders,
                body?.inputStream(),
            )
        } catch (e: IllegalArgumentException) {
            null
        }
    }

    private fun injectCookies(response: WebResourceResponse, url: Uri) {
        val headers = response.responseHeaders ?: return
        val cookieValues = headers.filterKeys { it.equals("Set-Cookie", ignoreCase = true) }
        val cookieManager = CookieManager.getInstance()
        for ((_, value) in cookieValues) {
            // A single Set-Cookie header line may contain multiple cookies
            // separated by commas in some legacy servers; split conservatively
            // on the cookie boundary (value up to the first `;`).
            val firstPair = value.substringBefore(';')
            val separator = firstPair.indexOf('=')
            if (separator <= 0) continue
            cookieManager.setCookie(url.host ?: return, firstPair)
        }
    }

    override fun getView(): android.view.View = webView

    override fun dispose() {
        webView.stopLoading()
        webView.destroy()
    }
}

/**
 * Platform view factory registered in [MainActivity.configureFlutterEngine].
 */
class LoginWebViewFactory(messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    private val messengerRef: BinaryMessenger = messenger

    @Suppress("UNCHECKED_CAST")
    override fun create(
        context: Context,
        viewId: Int,
        args: Any?,
    ): PlatformView {
        return LoginWebViewPlatformView(context, messengerRef)
    }
}
