package io.github.lopution.parfait

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService

/** What the channel reads from an Intent on main: plain values, no IO. */
internal data class IntentSnapshot(
    val action: String,
    val uri: String?,
    val isContentUri: Boolean,
    val mimeType: String?,
    val grantsRead: Boolean,
    val extraKeys: List<String>,
)

/** Calls into the provider behind a content URI; may block or throw. */
internal interface ContentProber {
    fun canRead(uri: String): Boolean

    fun sizeBytes(uri: String): Long?
}

/**
 * Encodes snapshots off the main thread. Initial and new intents share one
 * serial [io] executor, so they reach Dart in the order they arrived.
 */
internal class IntentRelay(
    private val io: Executor,
    private val mainThread: MainThreadPoster,
    private val prober: ContentProber,
) {
    /** Main thread only: set by the stream handler, read by posted events. */
    var sink: EventChannel.EventSink? = null

    fun answer(snapshot: IntentSnapshot, result: MethodChannel.Result) {
        io.execute { result.success(encode(snapshot)) }
    }

    /**
     * Goes only to the listener that was there when the intent arrived: an
     * event whose listener cancelled, or was replaced, is dropped.
     */
    fun emit(snapshot: IntentSnapshot) {
        val target = sink ?: return
        io.execute {
            val payload = encode(snapshot)
            mainThread.post { if (sink === target) target.success(payload) }
        }
    }

    // A provider can throw anything; an escaped exception would kill the
    // executor thread. Unreadable or unknown values are rejected in Dart.
    private fun encode(snapshot: IntentSnapshot): Map<String, Any?> {
        val uri = snapshot.uri
        val content = snapshot.isContentUri && uri != null
        val hasReadUriPermission = content && snapshot.grantsRead &&
            runCatching { prober.canRead(uri) }.getOrDefault(false)
        val sizeBytes = if (content) runCatching { prober.sizeBytes(uri) }.getOrNull() else null
        return mapOf(
            "action" to snapshot.action,
            "uri" to uri,
            "mimeType" to snapshot.mimeType,
            "hasReadUriPermission" to hasReadUriPermission,
            "sizeBytes" to sizeBytes,
            "extraKeys" to snapshot.extraKeys,
        )
    }
}

/**
 * Narrow Android VIEW/SEND handoff. The Dart side performs the final typed
 * validation; this bridge only extracts opaque metadata and verifies that a
 * granted content URI can actually be opened.
 */
object AndroidIntentChannel {
    private const val METHOD_CHANNEL = "parfait/android_intents"
    private const val EVENT_CHANNEL = "parfait/android_intents/events"

    private var relay: IntentRelay? = null
    private var io: ExecutorService? = null

    fun configure(activity: MainActivity, engine: FlutterEngine) {
        io?.shutdownNow()
        val io = foreignContentExecutor("parfait-intent-probe")
        this.io = io
        val relay = IntentRelay(
            io,
            AndroidMainThreadPoster,
            AndroidContentProber(activity.applicationContext),
        )
        this.relay = relay
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialIntent" -> relay.answer(snapshot(activity.intent), result)
                    "openUrl" -> openUrl(activity, call, result)
                    else -> result.notImplemented()
                }
            }
        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    relay.sink = events
                }

                override fun onCancel(arguments: Any?) {
                    relay.sink = null
                }
            })
    }

    fun dispatch(intent: Intent) {
        relay?.emit(snapshot(intent))
    }

    private fun openUrl(activity: MainActivity, call: MethodCall, result: MethodChannel.Result) {
        val raw = call.argument<String>("url")
        val uri = runCatching { Uri.parse(raw?.trim() ?: "") }.getOrNull()
        // Only http(s) targets leave the app. Anything else (javascript:,
        // file:, custom schemes) is refused; this native check is the last
        // gate before an external intent.
        if (uri == null || (uri.scheme != "http" && uri.scheme != "https")) {
            result.error("invalid_url", "only http(s) URLs may be opened", null)
            return
        }
        val intent = Intent(Intent.ACTION_VIEW, uri)
        try {
            activity.startActivity(intent)
            result.success(true)
        } catch (_: Exception) {
            result.error("no_handler", "no activity can open this URL", null)
        }
    }

    // Extras are another app's Parcelables: unparcelling a malformed one
    // throws on main. An intent with any unreadable part is sent without
    // its URI, which IntentRouter rejects observably (DROID-07) — empty
    // extras alone would let a VIEW link through.
    private fun snapshot(intent: Intent): IntentSnapshot {
        val action = intent.action ?: ""
        val read = runCatching {
            val uri = if (action == Intent.ACTION_SEND) streamUri(intent) else intent.data
            uri to (intent.extras?.keySet()?.toList() ?: emptyList())
        }.getOrNull()
        val uri = read?.first
        return IntentSnapshot(
            action = action,
            uri = uri?.toString(),
            isContentUri = uri?.scheme == CONTENT_SCHEME,
            mimeType = intent.type,
            grantsRead = intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0,
            extraKeys = read?.second ?: emptyList(),
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

    private class AndroidContentProber(private val context: Context) : ContentProber {
        override fun canRead(uri: String): Boolean =
            context.contentResolver.openFileDescriptor(Uri.parse(uri), "r")?.use { true } ?: false

        override fun sizeBytes(uri: String): Long? =
            context.contentResolver.openAssetFileDescriptor(Uri.parse(uri), "r")?.use {
                it.length.takeIf { length -> length >= 0 }
            }
    }

    private const val CONTENT_SCHEME = "content"
}
