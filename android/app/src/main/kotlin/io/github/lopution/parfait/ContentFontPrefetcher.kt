package io.github.lopution.parfait

import android.os.Process
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import java.io.File
import java.io.InputStream
import java.util.concurrent.Executors
import javax.xml.parsers.SAXParserFactory
import org.xml.sax.Attributes
import org.xml.sax.helpers.DefaultHandler

/**
 * Reads the system font files Flutter lays out user content with into the
 * page cache, on a background thread.
 *
 * Flutter shapes text with its own Skia + FreeType stack on the UI thread,
 * straight from the mmap-ed files that /system/etc/fonts.xml lists. A page
 * nobody touched lately — Japanese glyphs on a Chinese device, emoji, the
 * cmap of a rare-script fallback — comes from storage synchronously, and a
 * fling frame laying out new card titles stalled 2–8 ms per title. Native
 * apps rarely meet such pages: their text is in the system language, whose
 * font every app keeps hot. Reading the files first leaves layout only CPU
 * work.
 *
 * Runs when the activity starts (cold start and every return to the
 * foreground) and when a feed loads a page, at most once per
 * [MIN_INTERVAL_MS]: reclaim drops the pages again under memory pressure.
 */
object ContentFontPrefetcher {
    private const val CHANNEL = "parfait/fonts"
    private const val TAG = "ContentFontPrefetch"
    private const val FONTS_XML = "/system/etc/fonts.xml"
    private const val FONTS_DIR = "/system/fonts"
    private const val MIN_INTERVAL_MS = 10_000L
    private const val READ_BUFFER_BYTES = 1 shl 20

    private val executor =
        Executors.newSingleThreadExecutor { task ->
            Thread(
                {
                    Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
                    task.run()
                },
                "font-prefetch",
            )
        }

    // Executor-confined.
    private var files: List<File>? = null
    private var lastRunAt: Long? = null

    fun configure(engine: FlutterEngine) {
        backgroundMethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prefetch" -> {
                        prefetch()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    fun prefetch() {
        executor.execute {
            val now = SystemClock.elapsedRealtime()
            val last = lastRunAt
            if (last != null && now - last < MIN_INTERVAL_MS) return@execute
            lastRunAt = now
            readAll(files ?: listFiles().also { files = it })
        }
    }

    private fun listFiles(): List<File> =
        try {
            File(FONTS_XML).inputStream().use { config ->
                contentFontFiles(config) { File(FONTS_DIR, it).length() }
            }.map { File(FONTS_DIR, it) }
                // OEM builds list fonts they do not ship; Skia skips them too.
                .filter { it.isFile }
        } catch (error: Exception) {
            Log.w(TAG, "cannot read $FONTS_XML", error)
            emptyList()
        }

    private fun readAll(files: List<File>) {
        val start = SystemClock.elapsedRealtime()
        val buffer = ByteArray(READ_BUFFER_BYTES)
        var bytes = 0L
        for (file in files) {
            try {
                file.inputStream().use { stream ->
                    while (true) {
                        val n = stream.read(buffer)
                        if (n < 0) break
                        bytes += n
                    }
                }
            } catch (error: Exception) {
                Log.w(TAG, "cannot read $file", error)
            }
        }
        val elapsed = SystemClock.elapsedRealtime() - start
        Log.i(TAG, "read ${bytes shr 20} MB from ${files.size} fonts in $elapsed ms")
    }
}

/** Largest fallback font read even though its script is not a content one. */
internal const val SMALL_FONT_BYTES = 2L shl 20

/**
 * Names of the font files in a fonts.xml [config] that Flutter may lay out
 * user content with, read the way Skia's parser reads them: the fallback
 * families (unnamed, outside a `family-list`) of Chinese, Japanese, Korean
 * and emoji in full, plus any other fallback font of at most
 * [SMALL_FONT_BYTES] by [sizeOf] — Skia probes their cmaps for symbols the
 * locale fonts lack. Serif-only fallbacks (`fallbackFor`) are skipped, as
 * content is sans-serif. Skia ignores the `ignore` attribute; so does this.
 */
internal fun contentFontFiles(config: InputStream, sizeOf: (String) -> Long): List<String> {
    val names = LinkedHashSet<String>()
    val handler =
        object : DefaultHandler() {
            private var familyListDepth = 0
            private var family: FamilyKind? = null
            private var font: StringBuilder? = null

            override fun startElement(uri: String, local: String, qName: String, attrs: Attributes) {
                when (qName) {
                    "family-list" -> familyListDepth++
                    "family" ->
                        family =
                            when {
                                familyListDepth > 0 || attrs.getValue("name") != null -> FamilyKind.NAMED
                                isContentLanguage(attrs.getValue("lang")) -> FamilyKind.CONTENT
                                else -> FamilyKind.OTHER
                            }
                    "font" -> font = if (attrs.getValue("fallbackFor") == null) StringBuilder() else null
                }
            }

            override fun characters(ch: CharArray, start: Int, length: Int) {
                font?.append(ch, start, length)
            }

            override fun endElement(uri: String, local: String, qName: String) {
                when (qName) {
                    "family-list" -> familyListDepth--
                    "family" -> family = null
                    "font" -> {
                        val name = font?.trim()?.toString()
                        font = null
                        if (name.isNullOrEmpty()) return
                        when (family) {
                            FamilyKind.CONTENT -> names += name
                            FamilyKind.OTHER -> if (sizeOf(name) <= SMALL_FONT_BYTES) names += name
                            FamilyKind.NAMED, null -> {}
                        }
                    }
                }
            }
        }
    SAXParserFactory.newInstance().newSAXParser().parse(config, handler)
    return names.toList()
}

private enum class FamilyKind { NAMED, CONTENT, OTHER }

private val CONTENT_LANGUAGES = setOf("zh", "ja", "ko")

/** Skia splits `lang` on spaces; OEM files also use commas. */
private fun isContentLanguage(lang: String?): Boolean =
    lang.orEmpty().split(' ', ',').any { tag ->
        tag.substringBefore('-') in CONTENT_LANGUAGES || tag.startsWith("und-Zsye")
    }
