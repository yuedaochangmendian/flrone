package io.flrone.bridge

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Single-consumer debouncer for catalog refresh notifications.
 *
 * The old bridge checked `refreshJob?.isActive` and then called `scope.launch` as two separate
 * steps: concurrent notifications could both see an inactive job and start two refreshes. Worse,
 * a notification landing after the drain loop's last `dirty` check but before the coroutine
 * actually finished was recorded yet nobody remained to consume it — the update was lost until a
 * later, unrelated change.
 *
 * Here one [lock] guards the "is a runner claimed" and "another pass pending" flags together.
 * Claiming the slot is atomic, so concurrent callers never start two runners. At the end of each
 * pass, clearing the pending flag (and looping) versus releasing the slot (and exiting) is a
 * single atomic decision: a notification either arrives before it and is consumed by this runner,
 * or after it and claims a fresh runner. There is no window in which a notification can be left
 * dirty with nobody running.
 *
 * @param scope scope the refresh coroutines run in; the bridge passes its Main.immediate scope.
 * @param delayMs debounce delay before the first pass of a burst (0 disables it). Trailing passes
 *   never delay — they must reflect the change that triggered them promptly.
 * @param onRefresh one refresh pass; safe to call repeatedly.
 * @param onBeforeExit test seam invoked once, after the runner has atomically released its slot
 *   and before its coroutine ends — the exact window in which the old implementation could lose a
 *   wakeup. Production callers leave it as the no-op default.
 */
class RefreshDebouncer(
    private val scope: CoroutineScope,
    private val delayMs: Long = DEFAULT_DELAY_MS,
    private val onRefresh: suspend () -> Unit,
    private val onBeforeExit: () -> Unit = {},
) {
    private val lock = Any()
    private var running = false
    private var dirty = false
    @Volatile private var currentJob: Job? = null

    /** Request a refresh. Concurrent calls coalesce into at most one trailing pass. */
    fun schedule(immediate: Boolean = false) {
        // Claim the slot (or mark the pending work) atomically, and decide the initial delay.
        val initialDelay = synchronized(lock) {
            if (running) {
                dirty = true
                null
            } else {
                running = true
                if (immediate) 0L else delayMs
            }
        }
        // Launch outside the lock: a Main.immediate scope may start the coroutine inline.
        if (initialDelay != null) launchRunner(initialDelay)
    }

    private fun launchRunner(initialDelay: Long) {
        currentJob = scope.launch {
            try {
                if (initialDelay > 0L) delay(initialDelay)
                while (true) {
                    onRefresh()
                    // Clear "pending" and loop, or release the slot and exit — one atomic step. A
                    // notification arriving before this sees running=true and only sets dirty; one
                    // arriving after it sees running=false and starts a fresh runner. Nothing is lost.
                    val again = synchronized(lock) {
                        if (dirty) {
                            dirty = false
                            true
                        } else {
                            running = false
                            false
                        }
                    }
                    if (!again) {
                        onBeforeExit()
                        break
                    }
                }
            } catch (t: Throwable) {
                // Never leave the slot claimed on an abnormal exit: a later notification must
                // still be able to start a runner (refreshNow handles its own DB errors already).
                synchronized(lock) {
                    running = false
                    dirty = false
                }
                throw t
            }
        }
    }

    /** Cancel any in-flight pass and forget pending notifications (process shutdown). */
    fun cancel() {
        val job = currentJob
        synchronized(lock) {
            running = false
            dirty = false
        }
        job?.cancel()
        currentJob = null
    }

    companion object {
        const val DEFAULT_DELAY_MS = 150L
    }
}
