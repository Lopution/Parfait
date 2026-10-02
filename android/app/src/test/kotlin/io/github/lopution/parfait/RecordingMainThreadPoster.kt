package io.github.lopution.parfait

/** Records [MainThreadPoster] posts so JVM tests can assert main-thread hops. */
internal class RecordingMainThreadPoster : MainThreadPoster {
    val posted = mutableListOf<Runnable>()

    override fun post(action: Runnable) {
        posted.add(action)
    }

    fun runAll() {
        posted.toList().forEach { it.run() }
    }
}
