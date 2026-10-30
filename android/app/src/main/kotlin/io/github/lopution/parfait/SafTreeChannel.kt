package io.github.lopution.parfait

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID

/**
 * SAF tree picker bridge (D5). Opens the system directory chooser and
 * persists the granted tree URI permission so downloads can write into the
 * user-selected folder without broad storage permissions. Also opens single
 * documents for import: the pick returns only the URI, and [copyDocument]
 * copies it into the cache on the background queue under a byte limit.
 *
 * Dart [create] may send `ownerId`; this handler does not read it. Ownership
 * is not persisted on SAF documents today.
 */
internal interface SafTreeOperations {
    fun create(treeUri: String, displayName: String, mimeType: String, staged: Boolean): String

    fun write(uri: String, bytes: ByteArray)

    fun close(uri: String)

    fun delete(uri: String)

    fun resume(uri: String): Map<String, Any>?

    fun finalize(uri: String): String

    /** `{path, name, sizeBytes}` of a cache copy of [uri]; over [maxBytes] throws. */
    fun copyDocument(uri: String, maxBytes: Long): Map<String, Any>
}

/** The picked document is larger than the caller's limit. */
internal class DocumentTooLargeException(maxBytes: Long) :
    IOException("document is larger than $maxBytes bytes")

/** The `DocumentsContract` calls behind `create`, faked in JVM tests. */
internal interface SafDocumentProvider {
    /** The document URI of [treeUri]'s root: the parent `createDocument` needs. */
    fun treeRootDocument(treeUri: String): String

    fun createDocument(parentUri: String, mimeType: String, displayName: String): String?
}

internal fun interface SafTreeLauncher {
    /** Starts the directory picker. `false` when no Activity is available. */
    fun start(): Boolean
}

internal fun interface SafDocumentLauncher {
    /** Starts the document picker. `false` when no Activity is available. */
    fun start(mimeTypes: List<String>): Boolean
}

object SafTreeChannel {

    private const val CHANNEL = "parfait/saf_tree"
    private const val PREFIX = "saf_"
    private const val REQUEST_OPEN_TREE = 0x53AF
    private const val REQUEST_OPEN_DOCUMENT = 0x53B0
    private const val DOCUMENT_INPUTS = "document_inputs"

    // A copy Dart never read (process death in between) is swept by a later
    // copy; an hour is far longer than any copy-then-read.
    private const val STALE_INPUT_MILLIS = 60L * 60L * 1000L
    private const val STAGED_SUFFIX = ".part"

    // A staged document is created untyped: providers then keep the
    // `.part` name as given instead of appending the MIME's extension
    // (`x.jpg.part.jpg`), and nothing indexes the partial file as an image.
    // The rename on commit lets local providers derive the type again.
    private const val STAGED_MIME = "application/octet-stream"

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
        val documentLauncher = SafDocumentLauncher { mimeTypes ->
            val activity = context as? Activity ?: return@SafDocumentLauncher false
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
            }
            activity.startActivityForResult(intent, REQUEST_OPEN_DOCUMENT)
            true
        }
        backgroundMethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                handle(call, result, ops, launcher, AndroidMainThreadPoster, documentLauncher)
            }
    }

    internal fun handle(
        call: MethodCall,
        result: MethodChannel.Result,
        ops: SafTreeOperations,
        launcher: SafTreeLauncher,
        mainThread: MainThreadPoster = ImmediateMainThreadPoster,
        documentLauncher: SafDocumentLauncher = SafDocumentLauncher { false },
    ) {
        try {
            when (call.method) {
                "pickTree" -> startPicker(result, mainThread) { launcher.start() }
                "pickDocument" -> {
                    val mimeTypes = ChannelArgs.requiredStrings(
                        call, result, "mimeTypes", PREFIX,
                    ) ?: return
                    startPicker(result, mainThread) { documentLauncher.start(mimeTypes) }
                }
                "copyDocument" -> {
                    val uri = ChannelArgs.requiredString(call, result, "uri", PREFIX) ?: return
                    val maxBytes = ChannelArgs.requiredInt(
                        call, result, "maxBytes", PREFIX,
                    ) ?: return
                    require(maxBytes > 0) { "maxBytes must be positive" }
                    result.success(ops.copyDocument(uri, maxBytes.toLong()))
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
                    val staged = call.argument<Boolean>("staged") ?: false
                    result.success(ops.create(treeUri, displayName, mimeType, staged))
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
                "resume" -> {
                    val uri = ChannelArgs.requiredString(call, result, "uri", PREFIX) ?: return
                    result.success(ops.resume(uri))
                }
                "finalize" -> {
                    val uri = ChannelArgs.requiredString(call, result, "uri", PREFIX) ?: return
                    result.success(ops.finalize(uri))
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error(safErrorCode(call.method, error), error.message, null)
        }
    }

    /** One picker at a time, tree or document: they share the pending slot. */
    private fun startPicker(
        result: MethodChannel.Result,
        mainThread: MainThreadPoster,
        launch: () -> Boolean,
    ) {
        synchronized(pendingLock) {
            if (pendingResult != null) {
                result.error("saf_busy", "a picker is already open", null)
                return
            }
            pendingResult = result
        }
        mainThread.post {
            try {
                if (!launch()) {
                    clearPendingIfSame(result)
                    result.error("saf_unavailable", "no activity to start picker", null)
                }
            } catch (error: Exception) {
                clearPendingIfSame(result)
                result.error("saf_launch_failed", error.message, null)
            }
        }
    }

    internal fun safErrorCode(method: String, error: Throwable): String {
        if (error is DocumentTooLargeException) return "saf_too_large"
        if (isNoSpaceLeft(error)) return "saf_no_space"
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
        if (method == "finalize") return "saf_finalize_failed"
        if (method == "resume") return "saf_resume_failed"
        return "saf_io_failed"
    }

    internal fun completePick(
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
            result.error("saf_launch_failed", "picker returned no uri", null)
            return
        }
        try {
            persist(uri, data)
            result.success(uri.toString())
        } catch (error: SecurityException) {
            result.error("saf_permission", error.message, null)
        }
    }

    /**
     * Creates the document under the tree's root document and returns its
     * URI. D8: staged downloads land under `<name>.part` and only get the
     * final display name when [finalizeDocument] renames on commit.
     */
    internal fun createInTree(
        provider: SafDocumentProvider,
        treeUri: String,
        displayName: String,
        mimeType: String,
        staged: Boolean,
    ): String {
        require(displayName.isNotEmpty() && displayName.length <= 255)
        require(!displayName.contains('/') && !displayName.contains('\\'))
        require(mimeType.isNotEmpty())
        val parent = provider.treeRootDocument(treeUri)
        return if (staged) {
            provider.createDocument(parent, STAGED_MIME, displayName + STAGED_SUFFIX)
        } else {
            provider.createDocument(parent, mimeType, displayName)
        } ?: throw IllegalStateException("SAF createDocument failed")
    }

    /** The grant bits worth persisting from the picker's result flags. */
    internal fun persistableGrant(intentFlags: Int): Int =
        intentFlags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)

    private class AndroidSafDocumentProvider(
        private val context: android.content.Context,
    ) : SafDocumentProvider {
        override fun treeRootDocument(treeUri: String): String {
            val tree = Uri.parse(treeUri)
            require(DocumentsContract.isTreeUri(tree)) { "not a SAF tree uri" }
            return DocumentsContract.buildDocumentUriUsingTree(
                tree,
                DocumentsContract.getTreeDocumentId(tree),
            ).toString()
        }

        override fun createDocument(
            parentUri: String,
            mimeType: String,
            displayName: String,
        ): String? = DocumentsContract.createDocument(
            context.contentResolver,
            Uri.parse(parentUri),
            mimeType,
            displayName,
        )?.toString()
    }

    private class AndroidSafTreeOperations(
        private val context: android.content.Context,
    ) : SafTreeOperations {
        private val provider = AndroidSafDocumentProvider(context)

        override fun create(
            treeUri: String,
            displayName: String,
            mimeType: String,
            staged: Boolean,
        ): String = openCreated(
            context,
            createInTree(provider, treeUri, displayName, mimeType, staged),
        )

        override fun write(uri: String, bytes: ByteArray) = writeDocument(uri, bytes)

        override fun close(uri: String) = closeDocument(uri)

        override fun delete(uri: String) = deleteDocument(context, uri)

        override fun resume(uri: String): Map<String, Any>? = resumeDocument(context, uri)

        override fun finalize(uri: String): String = finalizeDocument(context, uri)

        override fun copyDocument(uri: String, maxBytes: Long): Map<String, Any> =
            copyDocument(context, uri, maxBytes)
    }

    /** Copies [input] into [output]; more than [maxBytes] throws. */
    private fun copyCapped(input: InputStream, output: OutputStream, maxBytes: Long): Long {
        val buffer = ByteArray(64 * 1024)
        var copied = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) return copied
            copied += count
            if (copied > maxBytes) throw DocumentTooLargeException(maxBytes)
            output.write(buffer, 0, count)
        }
    }

    /** Deletes cache copies older than [STALE_INPUT_MILLIS] at [now]. */
    internal fun sweepStaleInputs(directory: File, now: Long) {
        directory.listFiles()?.forEach { file ->
            if (now - file.lastModified() > STALE_INPUT_MILLIS) file.delete()
        }
    }

    private fun copyDocument(
        context: android.content.Context,
        uri: String,
        maxBytes: Long,
    ): Map<String, Any> {
        val parsed = Uri.parse(uri)
        val directory = File(context.cacheDir, DOCUMENT_INPUTS)
        check(directory.mkdirs() || directory.isDirectory) { "document cache unavailable" }
        sweepStaleInputs(directory, System.currentTimeMillis())
        var name: String? = null
        context.contentResolver.query(
            parsed,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) return@use
            val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (nameColumn >= 0) name = cursor.getString(nameColumn)
            // The declared size only refuses early; the copy enforces the
            // limit on the bytes actually read.
            val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (sizeColumn >= 0 && !cursor.isNull(sizeColumn) &&
                cursor.getLong(sizeColumn) > maxBytes
            ) {
                throw DocumentTooLargeException(maxBytes)
            }
        }
        val (target, copied) = copyIntoCache(directory, maxBytes) {
            context.contentResolver.openInputStream(parsed)
        }
        return mapOf(
            "path" to target.absolutePath,
            "name" to (name ?: parsed.lastPathSegment ?: "document"),
            "sizeBytes" to copied,
        )
    }

    /** Copies the opened stream into a new file in [directory]; a failed copy leaves nothing. */
    internal fun copyIntoCache(
        directory: File,
        maxBytes: Long,
        open: () -> InputStream?,
    ): Pair<File, Long> {
        val target = File(directory, "input-${UUID.randomUUID()}")
        try {
            val input = open() ?: throw FileNotFoundException("document could not be opened")
            val copied = input.use { source ->
                target.outputStream().use { copyCapped(source, it, maxBytes) }
            }
            return target to copied
        } catch (error: Throwable) {
            target.delete()
            throw error
        }
    }

    // Handler-only: serial background TaskQueue. pickTree / onActivityResult
    // do not touch this map.
    private val streams = mutableMapOf<String, java.io.OutputStream>()

    private fun openCreated(context: android.content.Context, uri: String): String {
        val docUri = Uri.parse(uri)
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

    /**
     * D8 resume: reopen a detached document in append mode ("wa") and
     * report its durable byte count. A missing document or a provider
     * refusing append mode is a safe refusal (null), never a delete.
     */
    private fun resumeDocument(
        context: android.content.Context,
        uri: String,
    ): Map<String, Any>? {
        val parsed = Uri.parse(uri)
        val size = try {
            context.contentResolver.openFileDescriptor(parsed, "r")?.use { it.statSize }
        } catch (error: FileNotFoundException) {
            null
        } ?: return null
        val output = try {
            context.contentResolver.openOutputStream(parsed, "wa")
        } catch (error: FileNotFoundException) {
            null
        } ?: return null
        streams[uri] = output
        return mapOf("uri" to uri, "storedBytes" to size)
    }

    /**
     * D8 staged commit: close the stream and rename `<name>.part` to the
     * final display name. Documents without the `.part` suffix are
     * already final — close and report their URI unchanged.
     */
    private fun finalizeDocument(context: android.content.Context, uri: String): String {
        streams.remove(uri)?.close()
        val parsed = Uri.parse(uri)
        val name = context.contentResolver.query(
            parsed,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        } ?: return uri
        if (!name.endsWith(STAGED_SUFFIX)) return uri
        val renamed = DocumentsContract.renameDocument(
            context.contentResolver,
            parsed,
            name.removeSuffix(STAGED_SUFFIX),
        ) ?: throw IllegalStateException("SAF rename failed")
        return renamed.toString()
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
        if (requestCode != REQUEST_OPEN_TREE && requestCode != REQUEST_OPEN_DOCUMENT) return false
        val result = synchronized(pendingLock) {
            val pending = pendingResult
            pendingResult = null
            pending
        } ?: return true
        // A picked document is only read by copyDocument on the background
        // queue; its grant lasts as long as this activity.
        if (requestCode == REQUEST_OPEN_DOCUMENT) {
            completePick(result, resultCode, data) { _, _ -> }
            return true
        }
        completePick(result, resultCode, data) { uri, intent ->
            val flags = persistableGrant(intent.flags)
            // Persistable permissions are required for writes after process
            // restart; a refused grant is a visible failure, not silent.
            appContext?.contentResolver?.takePersistableUriPermission(uri, flags)
        }
        return true
    }
}
