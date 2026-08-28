package io.github.lopution.pixivfunc.appwidget

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import org.json.JSONException
import org.json.JSONObject

/** One renderable snapshot entry (secret-free by construction). */
data class WidgetSnapshotEntry(
    val illustId: Int,
    val title: String,
    val userId: Int,
    val userName: String,
    val imageFile: File,
)

/**
 * The render state a widget may consume.
 *
 * [entries] is non-empty only for a current, well-formed, same-account
 * snapshot; every other condition is [empty] with a reason so the widget can
 * show the explicit open-app state.
 */
data class WidgetRenderState(
    val entries: List<WidgetSnapshotEntry>,
    val stale: Boolean,
    val accountRevision: Long?,
) {
    companion object {
        val empty = WidgetRenderState(emptyList(), stale = false, accountRevision = null)
    }
}

/**
 * Reads the Dart-owned snapshot store (`filesDir/support/widget_snapshot`).
 *
 * The store holds no secrets by design (see
 * `lib/core/widget/widget_snapshot.dart`); this reader additionally bounds
 * every read: unknown schema versions, malformed JSON, oversized payloads and
 * path-traversal image names all degrade to [WidgetRenderState.empty].
 */
object WidgetSnapshotReader {
    const val MAX_SNAPSHOT_BYTES = 64 * 1024
    const val MAX_IMAGE_BYTES = 1024 * 1024
    const val MAX_AGE_MS = 24 * 60 * 60 * 1000L

    /**
     * Snapshot store root. Dart's `getApplicationSupportDirectory()` maps to
     * `filesDir` on Android, so the store lives at `files/widget_snapshot`
     * (see `lib/core/widget/widget_snapshot_store.dart`).
     */
    fun snapshotDirectory(context: Context): File =
        File(context.filesDir, "widget_snapshot")

    /** Deletes render state under the same lock used by the Dart writer. */
    fun clear(context: Context) {
        val dir = snapshotDirectory(context)
        if (!dir.exists()) return
        require(dir.isDirectory) { "widget snapshot path is not a directory" }
        val lockFile = File(dir, ".write.lock")
        FileOutputStream(lockFile, true).use { output ->
            output.channel.lock().use {
                deleteIfPresent(File(dir, "active.json"))
                deleteIfPresent(File(dir, "images"))
                dir.listFiles()?.forEach { child ->
                    if (child.name != lockFile.name) deleteIfPresent(child)
                }
            }
        }
    }

    fun read(context: Context, expectedAccountKey: String?): WidgetRenderState {
        val dir = snapshotDirectory(context)
        val pointer = File(dir, "active.json")
        if (!pointer.isFile) return WidgetRenderState.empty
        val raw = try {
            readCapped(pointer, MAX_SNAPSHOT_BYTES) ?: return WidgetRenderState.empty
        } catch (_: Exception) {
            return WidgetRenderState.empty
        }
        val json = try {
            JSONObject(raw)
        } catch (_: JSONException) {
            return WidgetRenderState.empty
        }
        val schemaVersion = integerValue(json.opt("schemaVersion"))
        if (schemaVersion != 1L) {
            return WidgetRenderState.empty
        }
        val accountKey = json.opt("accountKey") as? String ?: return WidgetRenderState.empty
        if (accountKey.isEmpty() ||
            accountKey.length > 128 ||
            !accountKey.matches(ACCOUNT_KEY_PATTERN)
        ) return WidgetRenderState.empty
        if (expectedAccountKey != null && accountKey != expectedAccountKey) {
            return WidgetRenderState.empty
        }
        val accountRevision = integerValue(json.opt("accountRevision"))
            ?: return WidgetRenderState.empty
        if (accountRevision < 0L) return WidgetRenderState.empty
        val generatedAtMs = integerValue(json.opt("generatedAtMs"))
            ?: return WidgetRenderState.empty
        val stale = isStaleAt(generatedAtMs, System.currentTimeMillis())
        val items = json.optJSONArray("items") ?: return WidgetRenderState.empty
        if (items.length() > MAX_ITEMS) return WidgetRenderState.empty
        val imagesDir = File(dir, "images")
        val entries = ArrayList<WidgetSnapshotEntry>(items.length())
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: return WidgetRenderState.empty
            val illustIdValue = integerValue(item.opt("illustId"))
            val userIdValue = integerValue(item.opt("userId"))
            val title = item.opt("title") as? String ?: return WidgetRenderState.empty
            val userName = item.opt("userName") as? String ?: return WidgetRenderState.empty
            val imageFile = item.opt("imageFile") as? String ?: return WidgetRenderState.empty
            if (illustIdValue == null || userIdValue == null ||
                illustIdValue <= 0L ||
                illustIdValue > Int.MAX_VALUE.toLong() ||
                userIdValue <= 0L ||
                userIdValue > Int.MAX_VALUE.toLong() ||
                title.length > MAX_TEXT_LENGTH || userName.length > MAX_TEXT_LENGTH ||
                imageFile.isEmpty() ||
                imageFile.contains('/') || imageFile.contains('\\') || imageFile.contains("..")
            ) {
                return WidgetRenderState.empty
            }
            val resolved = File(imagesDir, imageFile)
            val canonicalImagesDir = try {
                imagesDir.canonicalFile
            } catch (_: Exception) {
                return WidgetRenderState.empty
            }
            val canonicalResolved = try {
                resolved.canonicalFile
            } catch (_: Exception) {
                return WidgetRenderState.empty
            }
            if (canonicalResolved.parentFile != canonicalImagesDir ||
                !canonicalResolved.isFile ||
                canonicalResolved.length() == 0L ||
                canonicalResolved.length() > MAX_IMAGE_BYTES
            ) {
                return WidgetRenderState.empty
            }
            entries.add(
                WidgetSnapshotEntry(
                    illustIdValue.toInt(),
                    title,
                    userIdValue.toInt(),
                    userName,
                    canonicalResolved,
                ),
            )
        }
        if (entries.isEmpty()) return WidgetRenderState.empty
        return WidgetRenderState(entries, stale, accountRevision)
    }

    internal fun isStaleAt(generatedAtMs: Long, nowMs: Long): Boolean {
        if (generatedAtMs >= nowMs) return false
        // A wrapped subtraction is also an invalidly old timestamp. Treat it
        // as stale instead of allowing hostile JSON to look fresh.
        val ageMs = nowMs - generatedAtMs
        return ageMs < 0L || ageMs > MAX_AGE_MS
    }

    /** JSONObject may decode a fractional JSON number as Double; reject it. */
    private fun integerValue(value: Any?): Long? = when (value) {
        is Byte -> value.toLong()
        is Short -> value.toLong()
        is Int -> value.toLong()
        is Long -> value
        is Float ->
            if (value.isFinite() && value >= Long.MIN_VALUE &&
                value <= Long.MAX_VALUE && value == value.toLong().toFloat()
            ) value.toLong() else null
        is Double ->
            if (value.isFinite() && value >= Long.MIN_VALUE &&
                value <= Long.MAX_VALUE && value == value.toLong().toDouble()
            ) value.toLong() else null
        else -> null
    }

    private fun deleteIfPresent(file: File) {
        if (file.exists() && !file.deleteRecursively()) {
            error("failed to clear widget snapshot path")
        }
    }

    /** Reads at most [cap] bytes and rejects only files above the cap. */
    private fun readCapped(file: File, cap: Int): String? {
        if (file.length() > cap) return null
        val bytes = file.readBytes()
        if (bytes.size > cap) return null
        return bytes.toString(Charsets.UTF_8)
    }

    private const val MAX_ITEMS = 8
    private const val MAX_TEXT_LENGTH = 512
    private val ACCOUNT_KEY_PATTERN = Regex("[0-9a-fA-F]{1,128}")
}
