package io.flrone.bridge

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger

/**
 * The one-shot gate that settles a `profiles_doc` channel call.
 *
 * `detach()` fails every pending call while a reply may still be in flight; the
 * late callback used to resume the already-completed continuation and threw
 * from the platform thread. Every path now claims this gate first, so exactly
 * one of them resumes.
 */
class ReplyGateTest {

    @Test
    fun `only the first claim wins`() {
        val gate = ReplyGate()
        assertTrue(gate.claim())
        assertFalse(gate.claim())
    }

    @Test
    fun `concurrent claims settle exactly once`() {
        repeat(100) {
            val gate = ReplyGate()
            val winners = AtomicInteger(0)
            val start = CountDownLatch(1)
            val threads = List(8) {
                Thread {
                    start.await()
                    if (gate.claim()) winners.incrementAndGet()
                }.apply { start() }
            }
            start.countDown()
            threads.forEach { it.join() }
            assertTrue("one winner, got ${winners.get()}", winners.get() == 1)
        }
    }
}
