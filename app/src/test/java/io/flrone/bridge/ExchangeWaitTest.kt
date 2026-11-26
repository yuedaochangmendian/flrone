package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The blocking local-DNS exchange has four completion paths — answer, error, cancel and the hard
 * timeout — racing on different threads. [ExchangeWait] is the pure part: exactly one path may
 * report to the native ctx, and every path releases the waiting caller. The Android DnsResolver
 * itself cannot run in a JVM test, but the race this defects live in is pinned here.
 */
class ExchangeWaitTest {

    @Test
    fun `only the first claimant reports a result`() {
        val wait = ExchangeWait()
        assertTrue(wait.claim())
        assertFalse(wait.claim())
        assertFalse(wait.claim())
    }

    @Test
    fun `a timeout is bounded and reports exactly once`() {
        val wait = ExchangeWait()
        val started = System.nanoTime()
        val timeouts = AtomicInteger()
        // Much shorter than the production 5 s: the helper must honour whatever bound it is given.
        assertFalse(wait.awaitBounded(50L) { timeouts.incrementAndGet() })
        assertTrue("timeout took too long", System.nanoTime() - started < TimeUnit.SECONDS.toNanos(2))
        assertEquals(1, timeouts.get())
        // A late answer must not complete the removed ctx a second time.
        assertFalse(wait.claim())
    }

    @Test
    fun `an answer before the bound wins and no timeout fires`() {
        val wait = ExchangeWait()
        val timeouts = AtomicInteger()
        val armed = CountDownLatch(1)
        val answered = CountDownLatch(1)
        val reporter = Thread {
            armed.countDown()
            if (wait.claim()) wait.release()
            answered.countDown()
        }
        reporter.start()
        armed.await(1, TimeUnit.SECONDS)
        assertTrue(wait.awaitBounded(2000L) { timeouts.incrementAndGet() })
        assertTrue(answered.await(1, TimeUnit.SECONDS))
        assertEquals(0, timeouts.get())
        assertFalse(wait.claim())
    }

    @Test
    fun `a late callback after cancel cannot claim and always releases`() {
        val wait = ExchangeWait()
        // dns_cancel: claim + release without a second exchange call.
        assertTrue(wait.claim())
        wait.release()
        // DnsResolver still calls back later; it sees the claimed flag and skips Core.exchange*.
        assertFalse(wait.claim())
        assertTrue(wait.done.await(1, TimeUnit.SECONDS))
    }
}
