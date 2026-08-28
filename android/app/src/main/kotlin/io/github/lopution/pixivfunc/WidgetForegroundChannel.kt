package io.github.lopution.pixivfunc

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.github.lopution.pixivfunc.appwidget.WidgetRenderer
import io.github.lopution.pixivfunc.appwidget.WidgetSnapshotReader
import io.github.lopution.pixivfunc.appwidget.WidgetUpdateCoordinator

/**
 * Foreground widget maintenance channel (`pixivfunc/widget`).
 *
 * Dart reports render-state changes and account revisions; this side only
 * re-renders from the secret-free snapshot store and keys WorkManager
 * schedules. It never receives or stores account ids, tokens or images.
 */
object WidgetForegroundChannel {
    private const val CHANNEL = "pixivfunc/widget"

    fun configure(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
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
                    else -> result.notImplemented()
                }
            }
    }
}
