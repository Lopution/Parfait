package io.github.lopution.pixivfunc.appwidget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Path
import android.graphics.RectF
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import io.github.lopution.pixivfunc.R
import java.io.File

/**
 * RemoteViews rendering for the recommend and refresh widgets.
 *
 * All work happens from the local secret-free snapshot: no network, no
 * credential access. Decoded pixels and total bitmap memory are bounded by
 * [WidgetBudget]; a cover that cannot be decoded within budget renders the
 * open-app state instead of an oversized image.
 */
object WidgetRenderer {
    private const val CORNER_RADIUS_DP = 15f

    fun recommendIds(context: Context): IntArray =
        widgetIds(context, RecommendWidgetProvider::class.java)

    fun refreshIds(context: Context): IntArray =
        widgetIds(context, RefreshWidgetProvider::class.java)

    fun snapshotAccountRevision(context: Context): Long? =
        WidgetSnapshotReader.read(context, expectedAccountKey = null).accountRevision

    private fun widgetIds(context: Context, provider: Class<*>): IntArray =
        AppWidgetManager.getInstance(context)
            .getAppWidgetIds(ComponentName(context, provider))

    /** Re-renders every recommend and refresh instance from current state. */
    fun renderAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        renderRecommend(context, manager)
        for (id in refreshIds(context)) {
            manager.updateAppWidget(id, refreshViews(context, id))
        }
    }

    /** Renders every recommend widget instance from the snapshot store. */
    fun renderRecommend(
        context: Context,
        manager: AppWidgetManager,
        showProgress: Boolean = false,
    ) {
        val readState = WidgetSnapshotReader.read(context, expectedAccountKey = null)
        val state = if (readState.stale) WidgetRenderState.empty else readState
        val density = context.resources.displayMetrics.density
        val ids = recommendIds(context)
        var budgetBytes = 0
        for (id in ids) {
            val options = manager.getAppWidgetOptions(id)
            val widthPx = WidgetBudget.slotPixels(
                options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0),
                density,
            )
            val heightPx = WidgetBudget.slotPixels(
                options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0),
                density,
            )
            val entry = if (state.entries.isEmpty()) {
                null
            } else {
                state.entries[id % state.entries.size]
            }
            var overflow = false
            val views = recommendViews(
                context,
                entry,
                id,
                widthPx,
                heightPx,
                density,
                showProgress = showProgress,
                budgetTracker = { nextBytes ->
                    if (!WidgetBudget.withinTotalBudget(budgetBytes, nextBytes)) {
                        overflow = true
                        false
                    } else {
                        budgetBytes += nextBytes
                        true
                    }
                },
            )
            if (overflow) {
                // Total budget exhausted: degrade this instance to the
                // open-app state rather than exceed the IPC/memory bound.
                val fallback = recommendViews(
                    context,
                    null,
                    id,
                    0,
                    0,
                    density,
                    showProgress = false,
                    budgetTracker = { true },
                )
                manager.updateAppWidget(id, fallback)
                continue
            }
            manager.updateAppWidget(id, views)
        }
    }

    /**
     * Builds the recommend RemoteViews for one instance. A missing entry
     * shows the explicit open-app hint (plus progress while a first load is
     * expected); a present entry renders the bounded, rounded cover with a
     * click PendingIntent unique per illust.
     */
    fun recommendViews(
        context: Context,
        entry: WidgetSnapshotEntry?,
        slotIdentity: Int = 0,
        slotWidthPx: Int,
        slotHeightPx: Int,
        density: Float,
        showProgress: Boolean,
        budgetTracker: (Int) -> Boolean,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.recommend_app_widget)
        if (entry == null) {
            views.setViewVisibility(R.id.recommend_appwidget_image, View.GONE)
            views.setViewVisibility(
                R.id.appwidget_progress,
                if (showProgress) View.VISIBLE else View.GONE,
            )
            views.setViewVisibility(
                R.id.recommend_appwidget_open_hint,
                if (showProgress) View.GONE else View.VISIBLE,
            )
            // Open the app itself when there is nothing to route to.
            views.setOnClickPendingIntent(
                R.id.recommend_appwidget_open_hint,
                clickPendingIntent(context, -1, slotIdentity),
            )
            return views
        }
        views.setViewVisibility(R.id.appwidget_progress, View.GONE)
        views.setViewVisibility(R.id.recommend_appwidget_open_hint, View.GONE)
        val bitmap = decodeRoundedCover(
            entry.imageFile,
            slotWidthPx,
            slotHeightPx,
            density,
            budgetTracker,
        )
        if (bitmap == null) {
            views.setViewVisibility(R.id.recommend_appwidget_image, View.GONE)
            views.setViewVisibility(R.id.recommend_appwidget_open_hint, View.VISIBLE)
            views.setOnClickPendingIntent(
                R.id.recommend_appwidget_open_hint,
                clickPendingIntent(context, -1, slotIdentity),
            )
            return views
        }
        views.setImageViewBitmap(R.id.recommend_appwidget_image, bitmap)
        views.setViewVisibility(R.id.recommend_appwidget_image, View.VISIBLE)
        views.setOnClickPendingIntent(
            R.id.recommend_appwidget_image,
            clickPendingIntent(context, entry.illustId, slotIdentity),
        )
        return views
    }

    /** Builds the single refresh-button RemoteViews for one instance. */
    fun refreshViews(context: Context, appWidgetId: Int): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.refresh_app_widget)
        views.setOnClickPendingIntent(
            R.id.refresh_appwidget_image,
            refreshPendingIntent(context, appWidgetId),
        )
        return views
    }

    /**
     * Immutable, explicit-component PendingIntent with a data identity unique
     * per illust/slot so different widget instances can never collide
     * (PRD R9).
     *
     * Illust clicks launch the `pixivfunc://illusts/<id>` deep link through
     * [PendingIntent.getActivity]: the widget host (a foreground system app)
     * starts the activity, which keeps working after process death. A
     * broadcast intermediary would be blocked by background-activity-launch
     * rules on current Android.
     */
    fun clickPendingIntent(context: Context, illustId: Int, requestCode: Int): PendingIntent {
        val deepLink = if (illustId > 0) {
            Uri.parse("pixivfunc://illusts/$illustId")
        } else {
            // No renderable entry: use a normal explicit launch. An invalid
            // deep link would show an error snackbar instead of opening the
            // app as promised by the empty-state copy.
            return PendingIntent.getActivity(
                context,
                requestCode and 0x7fffffff,
                Intent(context, io.github.lopution.pixivfunc.MainActivity::class.java),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        val intent = Intent(Intent.ACTION_VIEW, deepLink)
            .setPackage(context.packageName)
        return PendingIntent.getActivity(
            context,
            requestCode and 0x7fffffff,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    fun refreshPendingIntent(context: Context, appWidgetId: Int): PendingIntent {
        val intent = Intent(WidgetClickReceiver.ACTION_REFRESH_CLICK)
            .setPackage(context.packageName)
            .setClass(context, WidgetClickReceiver::class.java)
            .setData(Uri.parse("pixivfunc-widget://refresh/$appWidgetId"))
        return PendingIntent.getBroadcast(
            context,
            (appWidgetId + 1_000_000) and 0x7fffffff,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    /**
     * Decodes the cover with a bounded sample size, then applies the beta56
     * 15dp rounded-corner mask on a scratch bitmap. Returns null when the
     * file cannot be read within budget.
     */
    fun decodeRoundedCover(
        file: File,
        slotWidthPx: Int,
        slotHeightPx: Int,
        density: Float,
        budgetTracker: (Int) -> Boolean,
    ): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val sample = WidgetBudget.sampleSizeFor(slotWidthPx, slotHeightPx, bounds.outWidth, bounds.outHeight)
        val decodedBytes = WidgetBudget.decodedBytes(bounds.outWidth, bounds.outHeight, sample)
        val perImageCap = WidgetBudget.MAX_PIXELS_PER_IMAGE.toLong() *
            WidgetBudget.BYTES_PER_PIXEL
        if (decodedBytes > perImageCap) return null
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val source = BitmapFactory.decodeFile(file.absolutePath, options) ?: return null
        val decodedPixels = source.width.toLong() * source.height.toLong()
        val roundedBytes = decodedPixels * WidgetBudget.BYTES_PER_PIXEL
        val budgetBytes = source.byteCount.toLong() + roundedBytes
        if (decodedPixels > WidgetBudget.MAX_PIXELS_PER_IMAGE.toLong() ||
            budgetBytes > Int.MAX_VALUE ||
            !budgetTracker(budgetBytes.toInt())
        ) {
            source.recycle()
            return null
        }
        val radius = CORNER_RADIUS_DP * density
        return rounded(source, radius)
    }

    /** Returns a copy of [source] clipped to rounded corners. */
    fun rounded(source: Bitmap, cornerRadiusPx: Float): Bitmap {
        val output = Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val path = Path()
        val rect = RectF(0f, 0f, source.width.toFloat(), source.height.toFloat())
        path.addRoundRect(rect, cornerRadiusPx, cornerRadiusPx, Path.Direction.CW)
        canvas.clipPath(path)
        canvas.drawBitmap(source, 0f, 0f, null)
        if (source !== output) source.recycle()
        return output
    }
}
