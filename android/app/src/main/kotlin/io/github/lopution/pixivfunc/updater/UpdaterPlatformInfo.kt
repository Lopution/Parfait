package io.github.lopution.pixivfunc.updater

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import java.security.MessageDigest

/**
 * Package / signing helpers shared by both flavor
 * `DistributionUpdaterChannel` implementations.
 *
 * `packageInfoFromArchive` stays on the github flavor: only `verifyApk`
 * reads an on-disk APK, and compiling that path into fdroid would add
 * unused archive parsing to the store-managed build.
 */
internal object UpdaterPlatformInfo {
    fun platformInfo(context: Context): Map<String, Any> {
        val packageInfo = packageInfo(context.packageManager, context.packageName)
        val versionCode = packageInfo.longVersionCode
            .coerceAtMost(Int.MAX_VALUE.toLong())
            .toInt()
        return mapOf(
            "packageName" to context.packageName,
            "version" to (packageInfo.versionName ?: ""),
            "versionCode" to versionCode,
            "signingCertificateSha256" to signerSha256(packageInfo),
            "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
        )
    }

    fun packageInfo(manager: PackageManager, packageName: String): PackageInfo {
        return manager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
    }

    fun signerSha256(info: PackageInfo): String {
        val signatures = info.signingInfo?.apkContentsSigners ?: emptyArray()
        val signature = signatures.singleOrNull() ?: return ""
        return sha256Hex(signature.toByteArray())
    }

    internal fun sha256Hex(bytes: ByteArray): String {
        return MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }
}
