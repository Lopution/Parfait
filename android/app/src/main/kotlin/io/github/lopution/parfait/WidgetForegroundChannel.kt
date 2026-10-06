package io.github.lopution.parfait

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.github.lopution.parfait.appwidget.RecommendWidgetProvider
import io.github.lopution.parfait.appwidget.RefreshWidgetProvider
import io.github.lopution.parfait.appwidget.WidgetRenderer
import io.github.lopution.parfait.appwidget.WidgetSnapshotReader
import io.github.lopution.parfait.appwidget.WidgetUpdateCoordinator

/**
 * Foreground widget maintenance channel (`parfait/widget`).
 *
 * Dart reports render-state changes and account revisions; this side only
 * re-renders from the secret-free snapshot store and keys WorkManager
 * schedules. It never receives or stores account ids, tokens or images.
 */
object WidgetForegroundChannel {
    private const val CHANNEL = "parfait/widget"

    fun configure(context: Context, engine: FlutterEngine) {
        // Rendering decodes covers from disk. Flutter runs Dart on the
        // Android main thread, so that work must not happen there; the
        // WorkManager worker already calls renderAll off the main thread.
        backgroundMethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "notifySnapshotChanged" -> {
                        val revision = (call.arguments as? Number)?.toLong() ?: 0L
                        WidgetRenderer.renderAll(context)
                        WidgetUpdateCoordinator.ensurePeriodic(
                            context,
                            WidgetRenderer.snapshotAccountRevision(context) ?: revision,
                        )
                        result.success(null)
                    }
                    "clearSnapshot" -> {
                        WidgetSnapshotReader.clear(context)
                        WidgetUpdateCoordinator.cancelAll(context)
                        WidgetRenderer.renderAll(context)
                        result.success(null)
                    }
                    "requestRefresh" -> {
                        WidgetUpdateCoordinator.requestOneShotRefresh(context)
                        result.success(null)
                    }
                    "hasAnyWidget" -> {
                        result.success(hasAnyWidget(context))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * True when at least one live instance of either widget provider exists
     * (C6). Provider metadata alone only says that a receiver is installed;
     * querying ids is the authoritative way to detect an actual instance.
     */
    fun hasAnyWidget(context: Context): Boolean {
        val manager = AppWidgetManager.getInstance(context)
        return listOf(
            ComponentName(context, RecommendWidgetProvider::class.java),
            ComponentName(context, RefreshWidgetProvider::class.java),
        ).any { provider -> manager.getAppWidgetIds(provider).isNotEmpty() }
    }
}
