package io.github.lopution.pixivfunc.appwidget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context

/**
 * The refresh widget (beta56 RefreshAppWidget): a single button that asks
 * the unique worker for one bounded generation pass. It renders no artwork
 * and holds no state.
 */
class RefreshWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            manager.updateAppWidget(appWidgetId, WidgetRenderer.refreshViews(context, appWidgetId))
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        if (WidgetRenderer.refreshIds(context).isEmpty() &&
            WidgetRenderer.recommendIds(context).isEmpty()
        ) {
            WidgetUpdateCoordinator.cancelAll(context)
        }
    }

    override fun onDisabled(context: Context) {
        if (WidgetRenderer.recommendIds(context).isEmpty()) {
            WidgetUpdateCoordinator.cancelAll(context)
        }
    }
}
