package io.flrone.bridge

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The one-shot completion of a blocking native exchange (local DNS): an answer, an error, a
 * cancellation and the timeout race on separate threads, and exactly one of them may report the
 * result to the kernel. The latch always counts down — including for the losers and for a late
 * callback after the state was removed — so no caller can wait forever.
 *
 * Extracted from [FlroneCorePlatform] so the race can be driven on a plain JVM; the Android
 * `DnsResolver` itself needs a device.
 */
internal class ExchangeWait {
    private val completed = AtomicBoolean(false)
    val done = CountDownLatch(1)

    /**
     * Claims the right to complete the exchange. Only the first caller wins; everyone after it
     * (a late answer after a timeout, a second error, a cancel after an answer) must not touch the
     * native ctx again.
     */
    fun claim(): Boolean = completed.compareAndSet(false, true)

    /** Unblocks the waiting caller, once, no matter who won [claim]. */
    fun release() {
        done.countDown()
    }

    /**
     * Bounded wait. [timeoutMs] is a hard bound even if no callback ever arrives (a cancelled
     * DnsResolver query never calls back). [onTimeout] runs only for the winner, and always after
     * the latch has been released so the waiting caller cannot outlive the state being removed.
     */
    fun awaitBounded(timeoutMs: Long, onTimeout: () -> Unit): Boolean {
        try {
            if (!done.await(timeoutMs, TimeUnit.MILLISECONDS)) {
                if (claim()) onTimeout()
                return false
            }
            return true
        } finally {
            release()
        }
    }
}
