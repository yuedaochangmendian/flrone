package io.flrone.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * The command revision is the host half of the stale-stop contract: a stop
 * report carries the revision that was in force when the stop arrived
 * (`BaseService.stopRunner`), and the Dart kernel ignores it when a later start
 * has claimed a higher one. These pin the counter the contract rests on — the
 * start/stop ordering itself is covered by the Dart kernel tests.
 */
class ServiceEngineManagerRevisionTest {

    @Test
    fun `a start claims a higher revision than an earlier stop`() {
        val stopRevision = ServiceEngineManager.currentCommandRevision()
        val startRevision = ServiceEngineManager.nextCommandRevision()
        assertTrue(
            "a start must outrank the stop it overlaps",
            startRevision > stopRevision,
        )
        assertEquals(startRevision, ServiceEngineManager.currentCommandRevision())
    }

    @Test
    fun `every claimed revision is strictly newer than the previous one`() {
        var previous = ServiceEngineManager.currentCommandRevision()
        repeat(500) {
            val next = ServiceEngineManager.nextCommandRevision()
            assertTrue("revision went backwards: $next <= $previous", next > previous)
            previous = next
        }
    }

    @Test
    fun `concurrent claims never repeat`() {
        val threads = 8
        val perThread = 500
        val claimed = ConcurrentHashMap.newKeySet<Long>()
        val start = CountDownLatch(1)
        val done = CountDownLatch(threads)
        val pool = Executors.newFixedThreadPool(threads)
        repeat(threads) {
            pool.execute {
                start.await()
                repeat(perThread) { claimed.add(ServiceEngineManager.nextCommandRevision()) }
                done.countDown()
            }
        }
        start.countDown()
        assertTrue("workers did not finish", done.await(20, TimeUnit.SECONDS))
        pool.shutdown()
        assertEquals(threads * perThread, claimed.size)
    }

    @Test
    fun `the engine starts idle`() {
        // Diagnostic state, not a control flag: nothing has asked for an engine
        // in this JVM, so the observable must be idle.
        assertEquals(ServiceEngineManager.EngineState.idle, ServiceEngineManager.state)
    }
}
