package io.github.lopution.pixivfunc

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.LruCache
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException
import java.io.OutputStream

/**
 * MediaStore pending-write bridge for the download pipeline
 * (task 08-26-download-manager-mediastore).
 *
 * Requires API 29+ (scoped MediaStore with IS_PENDING/RELATIVE_PATH).
 * On older APIs the channel returns error "mediastore_unsupported"; the Dart
 * side surfaces a failed task rather than requesting broad legacy storage
 * permissions.
 */
internal interface MediaStoreOperations {
    fun begin(
        displayName: String,
        mimeType: String,
        ownerId: String?,
        relativePath: String?,
    ): Int

    fun write(id: Int, bytes: ByteArray)

    fun finalize(id: Int): String

    fun abort(id: Int)

    fun listPending(): List<Map<String, Any?>>

    fun abortPending(id: Int, ownerId: String): Boolean
}

object MediaStoreChannel {

    private const val CHANNEL = "pixivfunc/mediastore"
    private const val PREFIX = "mediastore_"
    private const val RELATIVE_PATH = "Pictures/PixivFunc"
    private const val OWNER_PREFIX = "pixivfunc-owner:"

    private val streams = object : LruCache<Int, OutputStream>(32) {}
    private val uris = object : LruCache<Int, Uri>(32) {}

    fun configure(context: Context, engine: FlutterEngine) {
        val ops = AndroidMediaStoreOperations(context)
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                handle(call, result, ops)
            }
    }

    internal fun handle(
        call: MethodCall,
        result: MethodChannel.Result,
        ops: MediaStoreOperations,
    ) {
        try {
            when (call.method) {
                "begin" -> {
                    val displayName = ChannelArgs.requiredString(
                        call, result, "displayName", PREFIX,
                    ) ?: return
                    val mimeType = ChannelArgs.requiredString(
                        call, result, "mimeType", PREFIX,
                    ) ?: return
                    val ownerId = ChannelArgs.optionalString(
                        call, result, "ownerId", PREFIX,
                    )
                    if (!ownerId.ok) return
                    val relativePath = ChannelArgs.optionalString(
                        call, result, "relativePath", PREFIX,
                    )
                    if (!relativePath.ok) return
                    result.success(
                        ops.begin(
                            displayName,
                            mimeType,
                            ownerId.value,
                            relativePath.value,
                        ),
                    )
                }
                "write" -> {
                    val id = ChannelArgs.requiredInt(call, result, "id", PREFIX) ?: return
                    val bytes = ChannelArgs.requiredBytes(
                        call, result, "bytes", PREFIX,
                    ) ?: return
                    ops.write(id, bytes)
                    result.success(null)
                }
                "finalize" -> {
                    val id = ChannelArgs.requiredInt(call, result, "id", PREFIX) ?: return
                    result.success(ops.finalize(id))
                }
                "abort" -> {
                    val id = ChannelArgs.requiredInt(call, result, "id", PREFIX) ?: return
                    ops.abort(id)
                    result.success(null)
                }
                "listPending" -> result.success(ops.listPending())
                "abortPending" -> {
                    val id = ChannelArgs.requiredInt(call, result, "id", PREFIX) ?: return
                    val ownerId = ChannelArgs.requiredString(
                        call, result, "ownerId", PREFIX,
                    ) ?: return
                    result.success(ops.abortPending(id, ownerId))
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error(mediastoreErrorCode(call.method, error), error.message, null)
        }
    }

    internal fun mediastoreErrorCode(method: String, error: Throwable): String {
        if (error is SecurityException) return "mediastore_permission"
        if (error is UnsupportedOperationException) return "mediastore_unsupported"
        if (error is IllegalArgumentException) return "mediastore_invalid_argument"
        if (error is FileNotFoundException) return "mediastore_not_found"
        val message = error.message.orEmpty()
        if (error is IllegalStateException) {
            if (message.contains("no open stream") || message.contains("no pending")) {
                return "mediastore_not_found"
            }
            if (method == "begin") return "mediastore_insert_failed"
            if (method == "finalize") return "mediastore_finalize_failed"
        }
        if (method == "write") return "mediastore_write_failed"
        if (method == "finalize") return "mediastore_finalize_failed"
        if (method == "begin") return "mediastore_insert_failed"
        return "mediastore_io_failed"
    }

    private class AndroidMediaStoreOperations(
        private val context: Context,
    ) : MediaStoreOperations {
        override fun begin(
            displayName: String,
            mimeType: String,
            ownerId: String?,
            relativePath: String?,
        ): Int = beginPending(context, displayName, mimeType, ownerId, relativePath)

        override fun write(id: Int, bytes: ByteArray) = writePending(id, bytes)

        override fun finalize(id: Int): String = finalizePending(context, id)

        override fun abort(id: Int) = abortPendingRow(context, id)

        override fun listPending(): List<Map<String, Any?>> = listPendingRows(context)

        override fun abortPending(id: Int, ownerId: String): Boolean =
            abortOwnedPending(context, id, ownerId)
    }

    private fun requireApi29() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw UnsupportedOperationException("unsupported")
        }
    }

    private fun beginPending(
        context: Context,
        displayName: String,
        mimeType: String,
        ownerId: String? = null,
        relativePath: String? = null,
    ): Int {
        requireApi29()
        require(displayName.isNotEmpty() && displayName.length <= 255)
        require(!displayName.contains('/') && !displayName.contains('\\'))
        require(mimeType.isNotEmpty())
        if (ownerId != null) {
            require(ownerId.matches(Regex("[A-Za-z0-9_.-]{1,128}")))
        }
        // D5: custom album destination. Only a normalized `Pictures/<name>`
        // relative path is accepted; traversal and separators are rejected.
        val effectiveRelativePath = if (relativePath.isNullOrBlank()) {
            RELATIVE_PATH
        } else {
            require(relativePath.startsWith("Pictures/"))
            require(!relativePath.contains(".."))
            require(relativePath.length <= 128)
            require(!relativePath.split("/").any { it.isEmpty() || it == "." })
            relativePath
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, effectiveRelativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
            if (ownerId != null) {
                put(MediaStore.MediaColumns.TITLE, OWNER_PREFIX + ownerId)
            }
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("MediaStore insert failed")
        val id = uri.lastPathSegment?.toIntOrNull() ?: run {
            runCatching { resolver.delete(uri, null, null) }
            throw IllegalStateException("MediaStore id parse failed")
        }
        val output = try {
            resolver.openOutputStream(uri, "w")
                ?: throw IllegalStateException("openOutputStream failed")
        } catch (error: Exception) {
            // The Dart side has no handle when begin fails, so the bridge
            // owns rollback of the just-inserted pending row.
            runCatching { resolver.delete(uri, null, null) }
            throw error
        }
        streams.put(id, output)
        uris.put(id, uri)
        return id
    }

    private fun writePending(id: Int, bytes: ByteArray) {
        val stream = streams.get(id)
            ?: throw IllegalStateException("no open stream for item $id")
        stream.write(bytes)
    }

    private fun finalizePending(context: Context, id: Int): String {
        requireApi29()
        val uri = pendingUri(context, id)
            ?: throw IllegalStateException("no pending item $id")
        streams.remove(id)?.close()
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.IS_PENDING, 0)
        }
        val updated = context.contentResolver.update(uri, values, null, null)
        if (updated != 1) {
            throw IllegalStateException("MediaStore finalize update failed")
        }
        uris.remove(id)
        return uri.toString()
    }

    private fun abortPendingRow(context: Context, id: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return
        }
        val uri = pendingUri(context, id)
        streams.remove(id)?.let {
            runCatching { it.close() }
        }
        if (uri != null) {
            context.contentResolver.delete(uri, null, null)
        }
        uris.remove(id)
    }

    private fun abortOwnedPending(context: Context, id: Int, ownerId: String): Boolean {
        require(ownerId.matches(Regex("[A-Za-z0-9_.-]{1,128}")))
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val uri = pendingUri(context, id, ownerId) ?: return false
        streams.remove(id)?.let {
            runCatching { it.close() }
        }
        val deleted = context.contentResolver.delete(uri, null, null) == 1
        uris.remove(id)
        return deleted
    }

    private fun listPendingRows(context: Context): List<Map<String, Any?>> {
        requireApi29()
        val result = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.TITLE,
        )
        context.contentResolver.query(
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
            projection,
            "${MediaStore.MediaColumns.IS_PENDING} = 1",
            null,
            null,
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameIndex = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val descriptionIndex = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.TITLE)
            while (cursor.moveToNext()) {
                val description = cursor.getString(descriptionIndex)
                val ownerId = description?.takeIf { it.startsWith(OWNER_PREFIX) }
                    ?.removePrefix(OWNER_PREFIX)
                // Custom album paths are user-selected and cannot be known at
                // scan time. Return every pending row, but expose only the
                // opaque owner marker; Dart cleanup still requires an exact
                // owner match and cannot delete unrelated rows.
                result += mapOf(
                    "id" to cursor.getLong(idIndex).toInt(),
                    "displayName" to cursor.getString(nameIndex),
                    "ownerId" to ownerId,
                )
            }
        }
        return result
    }

    private fun pendingUri(context: Context, id: Int, ownerId: String? = null): Uri? {
        val resolver = context.contentResolver
        // MuMu API 35 exposes its large synthetic MediaStore ids through a
        // row URI but omits them from collection queries. Query the exact row
        // so finalize/owner-checked abort work both on stock Android and this
        // emulator implementation.
        val uri = uris.get(id) ?: Uri.withAppendedPath(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            id.toString(),
        )
        val projection = if (ownerId == null) {
            arrayOf(MediaStore.MediaColumns._ID)
        } else {
            arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.TITLE)
        }
        resolver.query(
            uri,
            projection,
            "${MediaStore.MediaColumns.IS_PENDING} = 1",
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                if (ownerId != null) {
                    val title = cursor.getString(1)
                    if (title != OWNER_PREFIX + ownerId) return null
                }
                return uri
            }
        }
        return null
    }
}
