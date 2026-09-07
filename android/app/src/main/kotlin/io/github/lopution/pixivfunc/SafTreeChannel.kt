package io.github.lopution.pixivfunc

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * SAF tree picker bridge (D5). Opens the system directory chooser and
 * persists the granted tree URI permission so downloads can write into the
 * user-selected folder without broad storage permissions.
 */
object SafTreeChannel {

    private const val CHANNEL = "pixivfunc/saf_tree"
    private const val REQUEST_OPEN_TREE = 0x53AF

    private var pendingResult: MethodChannel.Result? = null
    private var appContext: android.content.Context? = null

    fun configure(context: android.content.Context, engine: FlutterEngine) {
        appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "pickTree" -> {
                            if (pendingResult != null) {
                                result.error("saf_busy", "a picker is already open", null)
                                return@setMethodCallHandler
                            }
                            pendingResult = result
                            try {
                                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                    addFlags(
                                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                                            Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
                                    )
                                }
                                (context as? android.app.Activity)?.startActivityForResult(
                                    intent,
                                    REQUEST_OPEN_TREE,
                                ) ?: run {
                                    pendingResult = null
                                    result.error("saf_unavailable", "no activity to start picker", null)
                                }
                            } catch (error: Exception) {
                                pendingResult = null
                                result.error("saf_launch_failed", error.message, null)
                            }
                        }
                        "create" -> {
                            val treeUri = call.argument<String>("treeUri")!!
                            val displayName = call.argument<String>("displayName")!!
                            val mimeType = call.argument<String>("mimeType")!!
                            result.success(create(context, treeUri, displayName, mimeType))
                        }
                        "write" -> {
                            val uri = call.argument<String>("uri")!!
                            val bytes = call.argument<ByteArray>("bytes")!!
                            write(uri, bytes)
                            result.success(null)
                        }
                        "close" -> {
                            val uri = call.argument<String>("uri")!!
                            close(uri)
                            result.success(null)
                        }
                        "delete" -> {
                            val uri = call.argument<String>("uri")!!
                            delete(context, uri)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("saf_error", error.message, null)
                }
            }
    }

    private val streams = mutableMapOf<String, java.io.OutputStream>()

    private fun create(
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

    private fun write(uri: String, bytes: ByteArray) {
        val stream = streams[uri]
            ?: throw IllegalStateException("no open SAF stream for $uri")
        stream.write(bytes)
    }

    private fun close(uri: String) {
        streams.remove(uri)?.close()
    }

    private fun delete(context: android.content.Context, uri: String) {
        close(uri)
        context.contentResolver.delete(Uri.parse(uri), null, null)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_OPEN_TREE) return false
        val result = pendingResult ?: return true
        pendingResult = null
        if (resultCode != android.app.Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return true
        }
        val uri: Uri = data.data!!
        try {
            val flags = data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            // Persistable permissions are required for writes after process
            // restart; a refused grant is a visible failure, not silent.
            appContext?.contentResolver?.takePersistableUriPermission(uri, flags)
            result.success(uri.toString())
        } catch (error: SecurityException) {
            result.error("saf_permission", error.message, null)
        }
        return true
    }
}
