package io.github.lopution.pixivfunc

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.util.UUID

/**
 * Controlled image picker/content-URI copier for reverse image search.
 *
 * The channel never sends image bytes to Dart. It validates a granted content
 * URI, streams it into the app-private cache with a hard byte limit, and only
 * returns opaque metadata/path handles.
 */
object ReverseImageInputChannel {
    private const val CHANNEL = "pixivfunc/reverse_image_input"
    private const val PICK_IMAGE_REQUEST = 5041
    private const val MAX_BYTES = 10L * 1024L * 1024L
    private const val CONTENT_SCHEME = "content"

    private var pendingPickerResult: MethodChannel.Result? = null

    fun configure(activity: MainActivity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickImage" -> pickImage(activity, result)
                    "copyToTemp" -> {
                        val rawUri = call.argument<String>("uri")
                        if (rawUri.isNullOrBlank()) {
                            result.error("invalid_uri", "image reference is invalid", null)
                        } else {
                            runCatching { copyToTemp(activity, rawUri) }
                                .onSuccess(result::success)
                                .onFailure { result.error(codeFor(it), messageFor(it), null) }
                        }
                    }
                    "deleteTemp" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("invalid_path", "temporary image path is invalid", null)
                        } else {
                            runCatching { deleteTemp(activity, path) }
                                .onSuccess(result::success)
                                .onFailure { result.error("cleanup_failed", messageFor(it), null) }
                        }
                    }
                    "openExternal" -> {
                        val rawUrl = call.argument<String>("url")
                        if (rawUrl.isNullOrBlank()) {
                            result.error("invalid_url", "external URL is invalid", null)
                        } else {
                            runCatching { openExternal(activity, rawUrl) }
                                .onSuccess(result::success)
                                .onFailure { result.error("external_unavailable", "external browser is unavailable", null) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    fun onActivityResult(
        activity: MainActivity,
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ): Boolean {
        if (requestCode != PICK_IMAGE_REQUEST) return false
        val result = pendingPickerResult
        pendingPickerResult = null
        if (result == null) return true
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return true
        }
        val uri = data?.data
        if (uri == null) {
            result.error("malformed_response", "image picker returned no image", null)
            return true
        }
        runCatching { encodeReference(activity, uri, data.flags) }
            .onSuccess(result::success)
            .onFailure { result.error(codeFor(it), messageFor(it), null) }
        return true
    }

    private fun pickImage(activity: MainActivity, result: MethodChannel.Result) {
        if (pendingPickerResult != null) {
            result.error("picker_busy", "image picker is already active", null)
            return
        }
        pendingPickerResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            activity.startActivityForResult(intent, PICK_IMAGE_REQUEST)
        } catch (error: Exception) {
            pendingPickerResult = null
            result.error("picker_failed", "image picker could not be opened", null)
        }
    }

    private fun encodeReference(
        context: Context,
        uri: Uri,
        intentFlags: Int,
    ): Map<String, Any> {
        requireSafeContentUri(uri)
        val mimeType = context.contentResolver.getType(uri)
            ?: throw FileNotFoundException("image MIME type is unavailable")
        val sizeBytes = contentSize(context, uri)
            ?: throw FileNotFoundException("image size is unavailable")
        val hasReadPermission =
            intentFlags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0 &&
                canRead(context, uri)
        return mapOf(
            "uri" to uri.toString(),
            "mimeType" to mimeType,
            "sizeBytes" to sizeBytes,
            "hasReadUriPermission" to hasReadPermission,
        )
    }

    private fun copyToTemp(context: Context, rawUri: String): Map<String, Any> {
        val uri = Uri.parse(rawUri)
        requireSafeContentUri(uri)
        require(canRead(context, uri)) { "image permission is unavailable" }
        val mimeType = context.contentResolver.getType(uri)
            ?: throw FileNotFoundException("image MIME type is unavailable")
        val declaredSize = contentSize(context, uri)
        require(declaredSize == null || declaredSize in 1..MAX_BYTES) {
            "image size is outside the limit"
        }
        val directory = File(context.cacheDir, "reverse_image_inputs")
        require(directory.mkdirs() || directory.isDirectory) { "image cache unavailable" }
        val file = File(directory, "input-${UUID.randomUUID()}.bin")
        try {
            var copied = 0L
            context.contentResolver.openInputStream(uri)?.use { input ->
                file.outputStream().buffered().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        copied += count
                        require(copied <= MAX_BYTES) { "image size is outside the limit" }
                        output.write(buffer, 0, count)
                    }
                }
            } ?: throw FileNotFoundException("image could not be opened")
            require(copied > 0) { "image is empty" }
            return mapOf(
                "path" to file.absolutePath,
                "mimeType" to mimeType,
                "sizeBytes" to copied,
            )
        } catch (error: Throwable) {
            file.delete()
            throw error
        }
    }

    private fun deleteTemp(context: Context, rawPath: String): Boolean {
        val root = File(context.cacheDir, "reverse_image_inputs").canonicalFile
        val target = File(rawPath).canonicalFile
        val rootPrefix = root.path + File.separator
        require(target.path.startsWith(rootPrefix)) { "temporary image path is outside the owner" }
        return !target.exists() || target.delete()
    }

    private fun openExternal(activity: Activity, rawUrl: String): Boolean {
        val uri = Uri.parse(rawUrl)
        require(uri.scheme == "https" && !uri.host.isNullOrBlank()) {
            "external URL is not HTTPS"
        }
        require(uri.userInfo.isNullOrEmpty() && uri.port == -1 && uri.fragment.isNullOrEmpty()) {
            "external URL contains unsafe metadata"
        }
        val intent = Intent(Intent.ACTION_VIEW, uri)
        activity.startActivity(intent)
        return true
    }

    private fun canRead(context: Context, uri: Uri): Boolean = try {
        context.contentResolver.openFileDescriptor(uri, "r")?.use { } ?: return false
        true
    } catch (_: SecurityException) {
        false
    } catch (_: FileNotFoundException) {
        false
    }

    private fun contentSize(context: Context, uri: Uri): Long? = try {
        context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
            descriptor.length.takeIf { it >= 0L }
        }
    } catch (_: SecurityException) {
        null
    } catch (_: FileNotFoundException) {
        null
    }

    private fun codeFor(error: Throwable): String = when (error) {
        is SecurityException -> "permission_denied"
        is FileNotFoundException -> "input_unavailable"
        else -> "input_failed"
    }

    private fun messageFor(error: Throwable): String = when (error) {
        is SecurityException -> "image permission is unavailable"
        is FileNotFoundException -> "selected image is unavailable"
        else -> "image input operation failed"
    }

    private fun requireSafeContentUri(uri: Uri) {
        require(
            uri.scheme == CONTENT_SCHEME &&
                !uri.authority.isNullOrBlank() &&
                uri.userInfo.isNullOrEmpty() &&
                uri.port == -1 &&
                uri.fragment == null,
        ) { "image reference is not a clean content URI" }
    }
}
