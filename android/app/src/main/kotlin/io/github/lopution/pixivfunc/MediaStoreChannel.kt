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

    private val streams = object : LruCache<Int, OutputStream>(32) {}

    fun configure(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "begin" -> {
                            val displayName = call.argument<String>("displayName")!!
                            val mimeType = call.argument<String>("mimeType")!!
                            result.success(begin(context, displayName, mimeType))
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

    private fun begin(context: Context, displayName: String, mimeType: String): Int {
        requireApi29()
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, RELATIVE_PATH)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("MediaStore insert failed")
        val id = uri.lastPathSegment?.toIntOrNull()
            ?: throw IllegalStateException("MediaStore id parse failed")
        streams.put(id, resolver.openOutputStream(uri, "w")
            ?: throw IllegalStateException("openOutputStream failed"))
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
        context.contentResolver.update(uri, values, null, null)
        return uri.toString()
    }

    private fun abort(context: Context, id: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return
        }
        streams.remove(id)?.let {
            runCatching { it.close() }
        }
        val uri = pendingUri(context, id) ?: return
        context.contentResolver.delete(uri, null, null)
    }

    private fun pendingUri(context: Context, id: Int): Uri? {
        val resolver = context.contentResolver
        resolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns._ID} = ? AND ${MediaStore.MediaColumns.IS_PENDING} = 1",
            arrayOf(id.toString()),
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                return Uri.withAppendedPath(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    cursor.getLong(0).toString(),
                )
            }
        }
        return null
    }
}
