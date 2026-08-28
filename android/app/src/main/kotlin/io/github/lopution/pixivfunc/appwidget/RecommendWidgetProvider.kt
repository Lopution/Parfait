package io.github.lopution.pixivfunc.appwidget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context

/**
 * The recommend widget (beta56 RecommendAppWidget): one bounded cover per
 * instance, click routes to the illust detail via the pixivfunc deep link.
 *
 * onUpdate renders only from the local snapshot — never from the network —
 * so resize storms cannot start work or repeat IPC-heavy fetches (PRD R9).
 */
class RecommendWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        WidgetRenderer.renderRecommend(context, manager, showProgress = true)
        // First widget appeared (or app update): make sure the unique
        // periodic maintenance exists. KEEP keeps any existing schedule.
        WidgetUpdateCoordinator.ensurePeriodic(
            context,
            WidgetRenderer.snapshotAccountRevision(context) ?: 0L,
        )
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle,
    ) {
        // Resize: re-render this instance from the snapshot with new bounds.
        WidgetRenderer.renderRecommend(context, manager)
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        if (WidgetRenderer.recommendIds(context).isEmpty()) {
            WidgetUpdateCoordinator.cancelPeriodic(context)
        }
    }

    override fun onDisabled(context: Context) {
        WidgetUpdateCoordinator.cancelPeriodic(context)
    }
}
