package io.github.lopution.pixivfunc

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.LruCache
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream

/**
 * MediaStore pending-write bridge for the download pipeline
 * (task 08-26-download-manager-mediastore).
 *
 * Requires API 29+ (scoped MediaStore with IS_PENDING/RELATIVE_PATH).
 * On older APIs the channel returns error "unsupported"; the Dart side
 * surfaces a failed task rather than requesting broad legacy storage
 * permissions.
 */
object MediaStoreChannel {

    private const val CHANNEL = "pixivfunc/mediastore"
    private const val RELATIVE_PATH = "Pictures/PixivFunc"
    private const val OWNER_PREFIX = "pixivfunc-owner:"

    private val streams = object : LruCache<Int, OutputStream>(32) {}
    private val uris = object : LruCache<Int, Uri>(32) {}

    fun configure(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "begin" -> {
                            val displayName = call.argument<String>("displayName")!!
                            val mimeType = call.argument<String>("mimeType")!!
                            val ownerId = call.argument<String>("ownerId")
                            result.success(begin(context, displayName, mimeType, ownerId))
                        }
                        "write" -> {
                            val id = call.argument<Int>("id")!!
                            val bytes = call.argument<ByteArray>("bytes")!!
                            write(id, bytes)
                            result.success(null)
                        }
                        "finalize" -> result.success(finalize(context, call.argument<Int>("id")!!))
                        "abort" -> {
                            abort(context, call.argument<Int>("id")!!)
                            result.success(null)
                        }
                        "listPending" -> result.success(listPending(context))
                        "abortPending" -> {
                            result.success(abortPending(
                                context,
                                call.argument<Int>("id")!!,
                                call.argument<String>("ownerId")!!,
                            ))
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("mediastore_error", error.message, null)
                }
            }
    }

    private fun requireApi29() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw UnsupportedOperationException("unsupported")
        }
    }

    private fun begin(
        context: Context,
        displayName: String,
        mimeType: String,
        ownerId: String? = null,
    ): Int {
        requireApi29()
        require(displayName.isNotEmpty() && displayName.length <= 255)
        require(!displayName.contains('/') && !displayName.contains('\\'))
        require(mimeType.isNotEmpty())
        if (ownerId != null) {
            require(ownerId.matches(Regex("[A-Za-z0-9_.-]{1,128}")))
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, RELATIVE_PATH)
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

    private fun write(id: Int, bytes: ByteArray) {
        val stream = streams.get(id)
            ?: throw IllegalStateException("no open stream for item $id")
        stream.write(bytes)
    }

    private fun finalize(context: Context, id: Int): String {
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

    private fun abort(context: Context, id: Int) {
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

    private fun abortPending(context: Context, id: Int, ownerId: String): Boolean {
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

    private fun listPending(context: Context): List<Map<String, Any?>> {
        requireApi29()
        val result = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.TITLE,
            MediaStore.MediaColumns.RELATIVE_PATH,
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
            val pathIndex = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.RELATIVE_PATH)
            while (cursor.moveToNext()) {
                val path = cursor.getString(pathIndex)
                if (path != RELATIVE_PATH && path != "$RELATIVE_PATH/") continue
                val description = cursor.getString(descriptionIndex)
                val ownerId = description?.takeIf { it.startsWith(OWNER_PREFIX) }
                    ?.removePrefix(OWNER_PREFIX)
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
