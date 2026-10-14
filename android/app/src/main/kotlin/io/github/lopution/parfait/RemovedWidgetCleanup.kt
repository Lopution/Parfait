package io.github.lopution.parfait

import android.app.job.JobScheduler
import android.content.Context
import android.os.Build
import android.os.Process
import android.util.Log
import java.io.File

/**
 * Clears what the removed home widget left with the system: the periodic
 * refresh WorkManager scheduled through JobScheduler and WorkManager's own
 * database. With WorkManager gone nothing in the app cancels the job, and
 * an app update is not guaranteed to drop a job whose service no longer
 * exists.
 *
 * WorkManager schedules into its own JobScheduler namespace from API 34
 * and into the default one before; both are checked, and in the default
 * one only jobs that point at WorkManager's service are cancelled. Its
 * database lives in the no-backup directory (older versions kept it in
 * the default database directory). Runs off the main thread on every cold
 * start; once nothing is left it costs two binder calls and a few stats.
 */
object RemovedWidgetCleanup {
    private const val TAG = "RemovedWidgetCleanup"
    private const val WORK_MANAGER_SERVICE =
        "androidx.work.impl.background.systemjob.SystemJobService"
    private const val WORK_MANAGER_NAMESPACE = "androidx.work.systemjobscheduler"
    private const val WORK_MANAGER_DATABASE = "androidx.work.workdb"
    private val DATABASE_SUFFIXES = listOf("", "-journal", "-shm", "-wal")
    private const val WORK_MANAGER_PREFERENCES = "androidx.work.util.preferences"

    fun runInBackground(context: Context) {
        val app = context.applicationContext
        Thread(
            {
                Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
                try {
                    run(app)
                } catch (error: RuntimeException) {
                    Log.w(TAG, "cleanup failed", error)
                }
            },
            "widget-cleanup",
        ).start()
    }

    private fun run(context: Context) {
        val jobs = cancelJobs(context)
        val noBackup = DATABASE_SUFFIXES.count {
            File(context.noBackupFilesDir, WORK_MANAGER_DATABASE + it).delete()
        }
        val database = context.deleteDatabase(WORK_MANAGER_DATABASE) || noBackup > 0
        val preferences = context.deleteSharedPreferences(WORK_MANAGER_PREFERENCES)
        if (jobs > 0 || database || preferences) {
            Log.i(TAG, "cancelled $jobs job(s), database $database, preferences $preferences")
        }
    }

    private fun cancelJobs(context: Context): Int {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return 0
        val jobs = scheduler.allPendingJobs.filter {
            it.service.className == WORK_MANAGER_SERVICE
        }
        jobs.forEach { scheduler.cancel(it.id) }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return jobs.size
        val namespaced = scheduler.forNamespace(WORK_MANAGER_NAMESPACE)
        val count = namespaced.allPendingJobs.size
        namespaced.cancelAll()
        return jobs.size + count
    }
}
