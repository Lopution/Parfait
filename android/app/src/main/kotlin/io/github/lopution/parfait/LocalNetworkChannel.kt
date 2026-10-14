package io.github.lopution.parfait

import android.app.Activity
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** What the channel reads from and asks of the system; faked in JVM tests. */
internal interface LocalNetworkSignals {
    fun isGranted(): Boolean

    /** Shows the system permission dialog; the answer comes back through
     *  [LocalNetworkChannel.onPermissionResult]. */
    fun requestPermission()

    fun proxyHost(): String?
}

/**
 * Android 17's local network permission (`ACCESS_LOCAL_NETWORK`, in the
 * "nearby devices" group). An app that targets 37 cannot reach a local
 * network address without it, and a TCP connect there hangs until it times
 * out — so Dart asks only when a configured address is local, through the
 * system dialog.
 *
 * Also reports the system HTTP proxy: WebView connects through it, and a
 * proxy on another computer at home is a local network address too.
 */
class LocalNetworkChannel internal constructor(
    private val signals: LocalNetworkSignals,
) {
    private var pending: MethodChannel.Result? = null

    internal fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isGranted" -> result.success(signals.isGranted())
            "proxyHost" -> result.success(signals.proxyHost())
            "request" -> request(result)
            else -> result.notImplemented()
        }
    }

    private fun request(result: MethodChannel.Result) {
        if (signals.isGranted()) {
            result.success(true)
            return
        }
        if (pending != null) {
            result.error("local_network_busy", "a request is already showing", null)
            return
        }
        pending = result
        signals.requestPermission()
    }

    /** Returns whether [requestCode] was this channel's request. */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pending ?: return true
        pending = null
        result.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        return true
    }

    companion object {
        private const val CHANNEL = "parfait/local_network"
        private const val PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"

        // API 37: the permission exists, and a target of 37 enforces it.
        private const val FIRST_RESTRICTED_SDK = 37
        internal const val REQUEST_CODE = 0x4C4E

        fun configure(activity: Activity, engine: FlutterEngine): LocalNetworkChannel {
            val connectivity = activity.getSystemService(ConnectivityManager::class.java)
            val signals =
                object : LocalNetworkSignals {
                    override fun isGranted() =
                        Build.VERSION.SDK_INT < FIRST_RESTRICTED_SDK ||
                            activity.checkSelfPermission(PERMISSION) ==
                            PackageManager.PERMISSION_GRANTED

                    override fun requestPermission() =
                        activity.requestPermissions(arrayOf(PERMISSION), REQUEST_CODE)

                    override fun proxyHost(): String? =
                        connectivity?.defaultProxy?.host?.takeIf { it.isNotEmpty() }
                }
            val channel = LocalNetworkChannel(signals)
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler(channel::handle)
            return channel
        }
    }
}
