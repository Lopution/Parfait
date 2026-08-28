package io.github.lopution.pixivfunc

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/** F-Droid has store-managed updates. It intentionally exposes no updater
 * transport, signature verifier or installer implementation. */
object DistributionUpdaterChannel {
    private const val CHANNEL = "pixivfunc/updater"

    fun configure(context: Context, engine: FlutterEngine) {
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
                    "getPlatformInfo" -> result.success(platformInfo(context))
                    else -> result.error(
                        "disabled",
                        "updates are managed by the F-Droid store",
                        null,
                    )
                }
            }
    }

    private fun platformInfo(context: Context): Map<String, Any> {
        val packageInfo = packageInfo(context.packageManager, context.packageName)
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.longVersionCode.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode
        }
        return mapOf(
            "packageName" to context.packageName,
            "version" to (packageInfo.versionName ?: ""),
            "versionCode" to versionCode,
            "signingCertificateSha256" to signerSha256(packageInfo),
        )
    }

    private fun packageInfo(manager: PackageManager, packageName: String): PackageInfo {
        @Suppress("DEPRECATION")
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            manager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        } else {
            manager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
        }
    }

    private fun signerSha256(info: PackageInfo): String {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners ?: emptyArray()
        } else {
            @Suppress("DEPRECATION")
            info.signatures ?: emptyArray()
        }
        val signature = signatures.singleOrNull() ?: return ""
        return MessageDigest.getInstance("SHA-256")
            .digest(signature.toByteArray())
            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }
}
