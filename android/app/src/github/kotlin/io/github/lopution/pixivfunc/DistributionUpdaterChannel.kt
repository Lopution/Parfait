package io.github.lopution.pixivfunc

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.util.Base64
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.lopution.pixivfunc.updater.UpdaterPlatformInfo
import java.io.File
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.X509EncodedKeySpec

/** GitHub-only updater bridge. The flavor owns every network-independent
 * verifier and installer operation; the manifest/asset transport stays in
 * Dart so the signed-manifest policy is shared and testable. */
object DistributionUpdaterChannel {
    private const val CHANNEL = "pixivfunc/updater"
    private const val UPDATE_DIRECTORY = "updates"
    private const val APK_MIME = "application/vnd.android.package-archive"

    // Signature errors are diagnosable codes, never a collapsed `false` (R2).
    private const val ERR_PUBLIC_KEY_MISSING = "public_key_missing"
    private const val ERR_ALGORITHM_UNAVAILABLE = "algorithm_unavailable"
    private const val ERR_SIGNATURE_MISMATCH = "signature_mismatch"
    private const val ERR_MESSAGE_MISSING = "message_missing"
    private const val ERR_SIGNATURE_MISSING = "signature_missing"

    fun configure(context: Context, engine: FlutterEngine) {
        backgroundMethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCapability" -> result.success(
                        mapOf(
                            "flavor" to "github",
                            "enabled" to BuildConfig.UPDATE_SELF_UPDATER_ENABLED,
                            "storeManaged" to false,
                        ),
                    )
                    "getPlatformInfo" -> result.success(
                        UpdaterPlatformInfo.platformInfo(context),
                    )
                    "verifyManifestSignature" -> result.success(verifyManifestSignature(call))
                    "verifyApk" -> result.success(verifyApk(context, call))
                    "installApk" -> installApk(context, call, result)
                    "deleteApk" -> result.success(deleteApk(context, call))
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Verifies the manifest signature with SHA256withECDSA (P-256), the
     * provider contract available since API 29 (D-3). Ed25519 is NOT available
     * on API 29-32 and must never be used here. Returns a diagnosable result
     * instead of a collapsed boolean.
     */
    private fun verifyManifestSignature(call: MethodCall): Map<String, Any> {
        val encodedKey = BuildConfig.UPDATE_PUBLIC_KEY_DER_B64.trim()
        val message = call.argument<ByteArray>("message")
        val signature = call.argument<ByteArray>("signature")
        if (!BuildConfig.UPDATE_SELF_UPDATER_ENABLED) {
            return mapOf("valid" to false, "errorCode" to ERR_PUBLIC_KEY_MISSING)
        }
        if (encodedKey.isEmpty()) {
            return mapOf("valid" to false, "errorCode" to ERR_PUBLIC_KEY_MISSING)
        }
        if (message == null || message.isEmpty()) {
            return mapOf("valid" to false, "errorCode" to ERR_MESSAGE_MISSING)
        }
        if (signature == null || signature.isEmpty()) {
            return mapOf("valid" to false, "errorCode" to ERR_SIGNATURE_MISSING)
        }
        return try {
            val keyBytes = Base64.decode(encodedKey, Base64.DEFAULT)
            val key = KeyFactory.getInstance("EC")
                .generatePublic(X509EncodedKeySpec(keyBytes))
            val algorithm = "SHA256withECDSA"
            val valid = Signature.getInstance(algorithm).run {
                initVerify(key)
                update(message)
                verify(signature)
            }
            if (valid) {
                mapOf("valid" to true)
            } else {
                mapOf("valid" to false, "errorCode" to ERR_SIGNATURE_MISMATCH)
            }
        } catch (_: java.security.NoSuchAlgorithmException) {
            mapOf("valid" to false, "errorCode" to ERR_ALGORITHM_UNAVAILABLE)
        } catch (_: Exception) {
            mapOf("valid" to false, "errorCode" to ERR_SIGNATURE_MISMATCH)
        }
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
            val archiveSigner = UpdaterPlatformInfo.signerSha256(archive)
            val installedSigner = UpdaterPlatformInfo.signerSha256(
                UpdaterPlatformInfo.packageInfo(
                    context.packageManager,
                    context.packageName,
                ),
            )
            if (archiveSigner != expectedSigner || installedSigner != expectedSigner) {
                return invalid("apk_signer_mismatch")
            }
            mapOf("valid" to true)
        } catch (_: Exception) {
            invalid("apk_verification_failed")
        }
    }

    private fun installApk(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val path = call.argument<String>("path") ?: run {
            result.success(installFailed("apk_path_invalid"))
            return
        }
        val apk = ownedApk(context, path) ?: run {
            result.success(installFailed("apk_path_invalid"))
            return
        }
        if (!apk.isFile) {
            result.success(installFailed("apk_missing"))
            return
        }
        AndroidMainThreadPoster.post {
            result.success(launchInstall(context, apk))
        }
    }

    private fun launchInstall(context: Context, apk: File): Map<String, Any> {
        return try {
            if (!context.packageManager.canRequestPackageInstalls()) {
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

    private fun packageInfoFromArchive(manager: PackageManager, path: String): PackageInfo? {
        return manager.getPackageArchiveInfo(path, PackageManager.GET_SIGNING_CERTIFICATES)
    }

    private fun invalid(code: String): Map<String, Any> =
        mapOf("valid" to false, "errorCode" to code)

    private fun installFailed(code: String): Map<String, Any> =
        mapOf("status" to "failed", "errorCode" to code)
}
