package io.github.lopution.pixivfunc

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Base64
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec

/** GitHub-only updater bridge. The flavor owns every network-independent
 * verifier and installer operation; the manifest/asset transport stays in
 * Dart so the signed-manifest policy is shared and testable. */
object DistributionUpdaterChannel {
    private const val CHANNEL = "pixivfunc/updater"
    private const val UPDATE_DIRECTORY = "updates"
    private const val APK_MIME = "application/vnd.android.package-archive"

    fun configure(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCapability" -> result.success(
                        mapOf(
                            "flavor" to "github",
                            "enabled" to BuildConfig.UPDATE_SELF_UPDATER_ENABLED,
                            "storeManaged" to false,
                        ),
                    )
                    "getPlatformInfo" -> result.success(platformInfo(context))
                    "verifyManifestSignature" -> result.success(verifyManifestSignature(call))
                    "verifyApk" -> result.success(verifyApk(context, call))
                    "installApk" -> result.success(installApk(context, call))
                    "deleteApk" -> result.success(deleteApk(context, call))
                    else -> result.notImplemented()
                }
            }
    }

    private fun verifyManifestSignature(call: MethodCall): Boolean {
        val encodedKey = BuildConfig.UPDATE_PUBLIC_KEY_DER_B64.trim()
        val message = call.argument<ByteArray>("message")
        val signature = call.argument<ByteArray>("signature")
        if (!BuildConfig.UPDATE_SELF_UPDATER_ENABLED || encodedKey.isEmpty() ||
            message == null || message.isEmpty() || signature == null || signature.size != 64
        ) {
            return false
        }
        return try {
            val keyBytes = Base64.decode(encodedKey, Base64.DEFAULT)
            val key = KeyFactory.getInstance("Ed25519")
                .generatePublic(X509EncodedKeySpec(keyBytes))
            Signature.getInstance("Ed25519").run {
                initVerify(key)
                update(message)
                verify(signature)
            }
        } catch (_: Exception) {
            false
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

    private fun verifyApk(context: Context, call: MethodCall): Map<String, Any> {
        val path = call.argument<String>("path") ?: return invalid("apk_path_invalid")
        val expectedPackage = call.argument<String>("packageName")
            ?: return invalid("apk_identity_missing")
        val expectedSigner = call.argument<String>("signingCertificateSha256")
            ?.lowercase()
            ?: return invalid("apk_identity_missing")
        val apk = ownedApk(context, path) ?: return invalid("apk_path_invalid")
        if (!apk.isFile || apk.length() <= 0L) return invalid("apk_missing")
        return try {
            val archive = packageInfoFromArchive(context.packageManager, apk.path)
                ?: return invalid("apk_parse_failed")
            if (archive.packageName != expectedPackage || archive.packageName != context.packageName) {
                return invalid("apk_package_mismatch")
            }
            val archiveSigner = signerSha256(archive)
            val installedSigner = signerSha256(
                packageInfo(context.packageManager, context.packageName),
            )
            if (archiveSigner != expectedSigner || installedSigner != expectedSigner) {
                return invalid("apk_signer_mismatch")
            }
            mapOf("valid" to true)
        } catch (_: Exception) {
            invalid("apk_verification_failed")
        }
    }

    private fun installApk(context: Context, call: MethodCall): Map<String, Any> {
        val path = call.argument<String>("path") ?: return installFailed("apk_path_invalid")
        val apk = ownedApk(context, path) ?: return installFailed("apk_path_invalid")
        if (!apk.isFile) return installFailed("apk_missing")
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !context.packageManager.canRequestPackageInstalls()
            ) {
                val settingsIntent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${context.packageName}"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(settingsIntent)
                mapOf("status" to "permission_required")
            } else {
                val contentUri = FileProvider.getUriForFile(
                    context,
                    "${context.packageName}.fileProvider",
                    apk,
                )
                val installIntent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(contentUri, APK_MIME)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(installIntent)
                mapOf("status" to "started")
            }
        } catch (_: Exception) {
            installFailed("installer_unavailable")
        }
    }

    private fun deleteApk(context: Context, call: MethodCall): Map<String, Any> {
        val path = call.argument<String>("path") ?: return mapOf("deleted" to false)
        val apk = ownedApk(context, path) ?: return mapOf("deleted" to false)
        return mapOf("deleted" to (!apk.exists() || apk.delete()))
    }

    private fun ownedApk(context: Context, path: String): File? {
        if (path.length > 4096) return null
        return try {
            val base = File(context.filesDir, UPDATE_DIRECTORY).canonicalFile
            val candidate = File(path).canonicalFile
            if (!candidate.path.startsWith(base.path + File.separator)) return null
            if (candidate.extension.lowercase() != "apk") return null
            candidate
        } catch (_: Exception) {
            null
        }
    }

    private fun packageInfo(manager: PackageManager, packageName: String): PackageInfo {
        @Suppress("DEPRECATION")
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            manager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        } else {
            manager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
        }
    }

    private fun packageInfoFromArchive(manager: PackageManager, path: String): PackageInfo? {
        @Suppress("DEPRECATION")
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            manager.getPackageArchiveInfo(path, PackageManager.GET_SIGNING_CERTIFICATES)
        } else {
            manager.getPackageArchiveInfo(path, PackageManager.GET_SIGNATURES)
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

    private fun invalid(code: String): Map<String, Any> =
        mapOf("valid" to false, "errorCode" to code)

    private fun installFailed(code: String): Map<String, Any> =
        mapOf("status" to "failed", "errorCode" to code)
}
