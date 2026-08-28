package io.github.lopution.pixivfunc.appwidget

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * Owns all widget-related WorkManager state (PRD R4/R9).
 *
 * - One unique periodic work per widget family + account revision, 30 min
 *   (beta56 `updatePeriodMillis=1800000`), network-constrained, KEEP policy.
 * - One-shot refresh requests run with KEEP so a storm of refresh clicks
 *   collapses into one in-flight pass without cancelling it.
 * - The actual feed generation runs in a controlled headless Flutter engine
 *   ([WidgetBackgroundWorker]) that reuses the app's Dart auth/network stack;
 *   this class never builds its own credential, DNS, proxy or TLS logic.
 */
object WidgetUpdateCoordinator {
    private const val WORK_TAG = "pixivfunc_widget_maintenance"
    private const val PERIODIC_PREFIX = "widget_recommend_periodic_r"
    private const val ONE_SHOT_PREFIX = "widget_recommend_refresh_now_r"

    /** beta56 updatePeriodMillis = 1800000 ms. */
    private const val PERIOD_MINUTES = 30L

    /** Holds only the last scheduled unique-work name (no secrets, R2). */
    private const val STATE_PREFS = "pixivfunc_widget_state"
    private const val KEY_SCHEDULED_NAME = "periodic_unique_name"

    private fun constraints(): Constraints = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .build()

    /**
     * Idempotent periodic schedule; revision keys the unique name (R9).
     *
     * Only the previous revision's chain is retired, and only when it changed:
     * a blanket tag cancel here would reset the periodic clock on every
     * system `APPWIDGET_UPDATE` (updatePeriodMillis) and kill any in-flight
     * one-shot refresh, so the schedule could never fire.
     */
    fun ensurePeriodic(context: Context, accountRevision: Long = 0) {
        if (WidgetRenderer.recommendIds(context).isEmpty()) {
            cancelPeriodic(context)
            return
        }
        val manager = WorkManager.getInstance(context)
        val name = periodicWorkName(accountRevision)
        val previous = scheduledName(context)
        if (previous != null && previous != name) {
            manager.cancelUniqueWork(previous)
        }
        val request = PeriodicWorkRequestBuilder<WidgetBackgroundWorker>(
            PERIOD_MINUTES,
            TimeUnit.MINUTES,
        )
            .setConstraints(constraints())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.MINUTES)
            .addTag(WORK_TAG)
            .build()
        manager.enqueueUniquePeriodicWork(
            name,
            ExistingPeriodicWorkPolicy.KEEP,
            request,
        )
        recordScheduledName(context, name)
    }

    /** One bounded pass; a burst of requests collapses into one (R9). */
    fun requestOneShotRefresh(context: Context): Boolean {
        val revision = WidgetRenderer.snapshotAccountRevision(context) ?: 0L
        val name = oneShotWorkName(revision)
        val request = OneTimeWorkRequestBuilder<WidgetBackgroundWorker>()
            .setConstraints(constraints())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
            .addTag(WORK_TAG)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            name,
            ExistingWorkPolicy.KEEP,
            request,
        )
        return true
    }

    /** Last widget removed / account cleared: stop all widget work. */
    fun cancelAll(context: Context) {
        WorkManager.getInstance(context).cancelAllWorkByTag(WORK_TAG)
        context
            .getSharedPreferences(STATE_PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_SCHEDULED_NAME)
            .apply()
    }

    fun cancelPeriodic(context: Context) {
        val previous = scheduledName(context)
        if (previous != null) {
            WorkManager.getInstance(context).cancelUniqueWork(previous)
        }
        context
            .getSharedPreferences(STATE_PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_SCHEDULED_NAME)
            .apply()
    }

    internal fun periodicWorkName(accountRevision: Long): String =
        "$PERIODIC_PREFIX$accountRevision"

    internal fun oneShotWorkName(accountRevision: Long): String =
        "$ONE_SHOT_PREFIX$accountRevision"

    private fun scheduledName(context: Context): String? =
        context
            .getSharedPreferences(STATE_PREFS, Context.MODE_PRIVATE)
            .getString(KEY_SCHEDULED_NAME, null)

    private fun recordScheduledName(context: Context, name: String) {
        context
            .getSharedPreferences(STATE_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_SCHEDULED_NAME, name)
            .apply()
    }
}

/**
 * Runs the controlled headless Flutter entrypoint (`widgetBackgroundMain`)
 * and maps its classified outcome onto WorkManager semantics.
 *
 * Native never parses tokens or account data here; Dart reports only the
 * outcome string. Bounded retries: at most [MAX_ATTEMPTS] before giving up
 * until the next scheduled run.
 */
class WidgetBackgroundWorker(
    context: Context,
    parameters: WorkerParameters,
) : Worker(context, parameters) {

    override fun doWork(): Result {
        val outcome = WidgetHeadlessRunner.runGeneration(applicationContext)
        return when (outcome) {
            // The snapshot store changed (new snapshot, or Dart cleared it on
            // no-account/auth-required): re-render now, otherwise the new
            // state would only reach the home screen at the next system
            // update tick.
            WidgetHeadlessRunner.Outcome.WRITTEN,
            WidgetHeadlessRunner.Outcome.NO_ACCOUNT,
            WidgetHeadlessRunner.Outcome.AUTH_REQUIRED,
            -> {
                WidgetRenderer.renderAll(applicationContext)
                Result.success()
            }

            // Same-account last-good stays visible while the bounded retry
            // runs; re-rendering would only repeat identical work.
            WidgetHeadlessRunner.Outcome.TRANSIENT ->
                if (shouldRetry(runAttemptCount)) Result.retry() else Result.success()
        }
    }

    companion object {
        const val MAX_ATTEMPTS = 3

        internal fun shouldRetry(runAttemptCount: Int): Boolean =
            runAttemptCount + 1 < MAX_ATTEMPTS
    }
}
