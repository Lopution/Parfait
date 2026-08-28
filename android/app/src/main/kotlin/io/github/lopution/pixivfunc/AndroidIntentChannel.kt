package io.github.lopution.pixivfunc

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException

/**
 * Narrow Android VIEW/SEND handoff. The Dart side performs the final typed
 * validation; this bridge only extracts opaque metadata and verifies that a
 * granted content URI can actually be opened.
 */
object AndroidIntentChannel {
    private const val METHOD_CHANNEL = "pixivfunc/android_intents"
    private const val EVENT_CHANNEL = "pixivfunc/android_intents/events"

    private var eventSink: EventChannel.EventSink? = null

    fun configure(activity: MainActivity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialIntent" -> result.success(encode(activity, activity.intent))
                    else -> result.notImplemented()
                }
            }
        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    fun dispatch(context: Context, intent: Intent) {
        eventSink?.success(encode(context, intent))
    }

    private fun encode(context: Context, intent: Intent): Map<String, Any?> {
        val action = intent.action ?: ""
        val uri = if (action == Intent.ACTION_SEND) streamUri(intent) else intent.data
        val isContentUri = uri?.scheme == CONTENT_SCHEME
        val hasReadUriPermission = isContentUri &&
            intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0 &&
            canRead(context, uri)
        val sizeBytes = if (isContentUri) contentSize(context, uri) else null
        val extraKeys = intent.extras?.keySet()?.toList() ?: emptyList<String>()
        return mapOf(
            "action" to action,
            "uri" to uri?.toString(),
            "mimeType" to intent.type,
            "hasReadUriPermission" to hasReadUriPermission,
            "sizeBytes" to sizeBytes,
            "extraKeys" to extraKeys,
        )
    }

    private fun streamUri(intent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
        }
    }

    private fun canRead(context: Context, uri: Uri?): Boolean {
        if (uri == null) return false
        return try {
            val descriptor = context.contentResolver.openFileDescriptor(uri, "r")
                ?: return false
            descriptor.use { }
            true
        } catch (_: SecurityException) {
            false
        } catch (_: FileNotFoundException) {
            false
        }
    }

    private fun contentSize(context: Context, uri: Uri?): Long? {
        if (uri == null) return null
        return try {
            context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
                descriptor.length.takeIf { it >= 0 }
            }
        } catch (_: SecurityException) {
            null
        } catch (_: FileNotFoundException) {
            null
        }
    }

    private const val CONTENT_SCHEME = "content"
}
