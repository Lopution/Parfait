package io.github.lopution.pixivfunc

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException

/**
 * SAF tree picker bridge (D5). Opens the system directory chooser and
 * persists the granted tree URI permission so downloads can write into the
 * user-selected folder without broad storage permissions.
 *
 * Dart [create] may send `ownerId`; this handler does not read it. Ownership
 * is not persisted on SAF documents today.
 */
internal interface SafTreeOperations {
    fun create(treeUri: String, displayName: String, mimeType: String): String

    fun write(uri: String, bytes: ByteArray)

    fun close(uri: String)

    fun delete(uri: String)
}

internal fun interface SafTreeLauncher {
    /** Starts the directory picker. `false` when no Activity is available. */
    fun start(): Boolean
}

object SafTreeChannel {

    private const val CHANNEL = "pixivfunc/saf_tree"
    private const val PREFIX = "saf_"
    private const val REQUEST_OPEN_TREE = 0x53AF

    private val pendingLock = Any()
    private var pendingResult: MethodChannel.Result? = null

    @Volatile
    private var appContext: android.content.Context? = null

    fun configure(context: android.content.Context, engine: FlutterEngine) {
        appContext = context.applicationContext
        val ops = AndroidSafTreeOperations(context.applicationContext)
        val launcher = SafTreeLauncher {
            val activity = context as? Activity ?: return@SafTreeLauncher false
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
                )
            }
            activity.startActivityForResult(intent, REQUEST_OPEN_TREE)
            true
        }
        backgroundMethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                handle(call, result, ops, launcher, AndroidMainThreadPoster)
            }
    }

    internal fun handle(
        call: MethodCall,
        result: MethodChannel.Result,
        ops: SafTreeOperations,
        launcher: SafTreeLauncher,
        mainThread: MainThreadPoster = ImmediateMainThreadPoster,
    ) {
        try {
            when (call.method) {
                "pickTree" -> {
                    synchronized(pendingLock) {
                        if (pendingResult != null) {
                            result.error("saf_busy", "a picker is already open", null)
                            return
                        }
                        pendingResult = result
                    }
                    mainThread.post {
                        try {
                            if (!launcher.start()) {
                                clearPendingIfSame(result)
                                result.error(
                                    "saf_unavailable",
                                    "no activity to start picker",
                                    null,
                                )
                            }
                        } catch (error: Exception) {
                            clearPendingIfSame(result)
                            result.error("saf_launch_failed", error.message, null)
                        }
                    }
                }
                "create" -> {
                    val treeUri = ChannelArgs.requiredString(
                        call, result, "treeUri", PREFIX,
                    ) ?: return
                    val displayName = ChannelArgs.requiredString(
                        call, result, "displayName", PREFIX,
                    ) ?: return
                    val mimeType = ChannelArgs.requiredString(
                        call, result, "mimeType", PREFIX,
                    ) ?: return
                    result.success(ops.create(treeUri, displayName, mimeType))
                }
                "write" -> {
                    val uri = ChannelArgs.requiredString(call, result, "uri", PREFIX) ?: return
                    val bytes = ChannelArgs.requiredBytes(
                        call, result, "bytes", PREFIX,
                    ) ?: return
                    ops.write(uri, bytes)
                    result.success(null)
                }
                "close" -> {
                    val uri = ChannelArgs.requiredString(call, result, "uri", PREFIX) ?: return
                    ops.close(uri)
                    result.success(null)
                }
                "delete" -> {
                    val uri = ChannelArgs.requiredString(call, result, "uri", PREFIX) ?: return
                    ops.delete(uri)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error(safErrorCode(call.method, error), error.message, null)
        }
    }

    internal fun safErrorCode(method: String, error: Throwable): String {
        if (error is SecurityException) return "saf_permission"
        if (error is IllegalArgumentException) return "saf_invalid_argument"
        if (error is FileNotFoundException) return "saf_not_found"
        val message = error.message.orEmpty()
        if (error is IllegalStateException && message.contains("no open SAF")) {
            return "saf_not_found"
        }
        if (method == "create") return "saf_create_failed"
        if (method == "write") return "saf_write_failed"
        if (method == "delete") return "saf_delete_failed"
        return "saf_io_failed"
    }

    internal fun completePickTree(
        result: MethodChannel.Result,
        resultCode: Int,
        data: Intent?,
        persist: (Uri, Intent) -> Unit,
    ) {
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }
        val uri = data?.data
        if (uri == null) {
            result.error("saf_launch_failed", "picker returned no tree uri", null)
            return
        }
        try {
            persist(uri, data)
            result.success(uri.toString())
        } catch (error: SecurityException) {
            result.error("saf_permission", error.message, null)
        }
    }

    private class AndroidSafTreeOperations(
        private val context: android.content.Context,
    ) : SafTreeOperations {
        override fun create(
            treeUri: String,
            displayName: String,
            mimeType: String,
        ): String = createDocument(context, treeUri, displayName, mimeType)

        override fun write(uri: String, bytes: ByteArray) = writeDocument(uri, bytes)

        override fun close(uri: String) = closeDocument(uri)

        override fun delete(uri: String) = deleteDocument(context, uri)
    }

    // Handler-only: serial background TaskQueue. pickTree / onActivityResult
    // do not touch this map.
    private val streams = mutableMapOf<String, java.io.OutputStream>()

    private fun createDocument(
        context: android.content.Context,
        treeUri: String,
        displayName: String,
        mimeType: String,
    ): String {
        require(displayName.isNotEmpty() && displayName.length <= 255)
        require(!displayName.contains('/') && !displayName.contains('\\'))
        require(mimeType.isNotEmpty())
        val tree = Uri.parse(treeUri)
        val docUri = android.provider.DocumentsContract.createDocument(
            context.contentResolver,
            tree,
            mimeType,
            displayName,
        ) ?: throw IllegalStateException("SAF createDocument failed")
        val output = context.contentResolver.openOutputStream(docUri, "w")
            ?: run {
                runCatching { context.contentResolver.delete(docUri, null, null) }
                throw IllegalStateException("SAF openOutputStream failed")
            }
        streams[docUri.toString()] = output
        return docUri.toString()
    }

    private fun writeDocument(uri: String, bytes: ByteArray) {
        val stream = streams[uri]
            ?: throw IllegalStateException("no open SAF stream for $uri")
        stream.write(bytes)
    }

    private fun closeDocument(uri: String) {
        streams.remove(uri)?.close()
    }

    private fun deleteDocument(context: android.content.Context, uri: String) {
        closeDocument(uri)
        context.contentResolver.delete(Uri.parse(uri), null, null)
    }

    private fun clearPendingIfSame(expected: MethodChannel.Result) {
        synchronized(pendingLock) {
            if (pendingResult === expected) {
                pendingResult = null
            }
        }
    }

    internal fun abandonPendingPicker() {
        synchronized(pendingLock) {
            pendingResult = null
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_OPEN_TREE) return false
        val result = synchronized(pendingLock) {
            val pending = pendingResult
            pendingResult = null
            pending
        } ?: return true
        completePickTree(result, resultCode, data) { uri, intent ->
            val flags = intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            // Persistable permissions are required for writes after process
            // restart; a refused grant is a visible failure, not silent.
            appContext?.contentResolver?.takePersistableUriPermission(uri, flags)
        }
        return true
    }
}
