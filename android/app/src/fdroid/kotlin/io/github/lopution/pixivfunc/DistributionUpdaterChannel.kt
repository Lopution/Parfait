package io.github.lopution.pixivfunc

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.github.lopution.pixivfunc.updater.UpdaterPlatformInfo

/** F-Droid has store-managed updates. It intentionally exposes no updater
 * transport, signature verifier or installer implementation. */
object DistributionUpdaterChannel {
    private const val CHANNEL = "pixivfunc/updater"

    fun configure(context: Context, engine: FlutterEngine) {
        // No archive IO on this flavor; stay on the platform thread.
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCapability" -> result.success(
                        mapOf(
                            "flavor" to "fdroid",
                            "enabled" to false,
                            "storeManaged" to true,
                        ),
                    )
                    "getPlatformInfo" -> result.success(
                        UpdaterPlatformInfo.platformInfo(context),
                    )
                    else -> result.error(
                        "disabled",
                        "updates are managed by the F-Droid store",
                        null,
                    )
                }
            }
    }
}
