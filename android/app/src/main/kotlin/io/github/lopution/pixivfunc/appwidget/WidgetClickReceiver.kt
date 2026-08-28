package io.github.lopution.pixivfunc.appwidget

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.widget.Toast

import io.github.lopution.pixivfunc.R

/**
 * Receives the widget refresh broadcast.
 *
 * Illust clicks no longer go through a broadcast: they launch the deep link
 * with [android.app.PendingIntent.getActivity] directly (see
 * [WidgetRenderer.clickPendingIntent]) so process-death clicks are not
 * blocked by background-activity-launch rules. This receiver only schedules
 * a bounded one-shot refresh, which is legitimate background work.
 */
class WidgetClickReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_REFRESH_CLICK -> handleRefreshClick(context)
        }
    }

    private fun handleRefreshClick(context: Context) {
        val scheduled = WidgetUpdateCoordinator.requestOneShotRefresh(context)
        if (scheduled) {
            Toast.makeText(context, R.string.widget_refresh_toast, Toast.LENGTH_LONG).show()
        }
    }

    companion object {
        const val ACTION_REFRESH_CLICK = "io.github.lopution.pixivfunc.action.WIDGET_REFRESH_CLICK"
    }
}
