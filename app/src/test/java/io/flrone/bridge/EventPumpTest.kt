package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the transport contract every host event goes through: three lanes with their own
 * eviction rules, the 32-message / 16 ms batch, priority preference with the bulk starvation
 * guard, and an encode that never runs without a listener. A fake scheduler stands in for the
 * main looper, so these run on a plain JVM with no Android runtime.
 */
class EventPumpTest {

    /** Records the posts a `Handler` adapter would make, and runs them on demand. */
    private class FakeScheduler : EventPump.Scheduler {

        private class Tick(val delayMillis: Long, val task: Runnable)

        private val pending = ArrayList<Tick>()
        private val cancelled = HashSet<Tick>()

        override fun post(delayMillis: Long, task: Runnable): () -> Unit {
            val tick = Tick(delayMillis, task)
            pending.add(tick)
            return { cancelled.add(tick) }
        }

        private fun live() = pending.filter { it !in cancelled }

        /** The delay of the one armed drain; fails when none or several are armed. */
        fun armedDelay(): Long {
            val live = live()
            assertEquals("expected exactly one armed drain, got $live", 1, live.size)
            return live.single().delayMillis
        }

        fun assertNoArmedDrain() {
            assertTrue("a drain is still armed: ${live()}", live().isEmpty())
        }

        /** Runs every armed drain, including ones a drain re-arms. */
        fun runAll() {
            while (true) {
                val tick = live().firstOrNull() ?: return
                cancelled.add(tick)
                tick.task.run()
            }
        }
    }

    private class Harness {
        val scheduler = FakeScheduler()
        val delivered = ArrayList<Map<String, Any?>>()
        val pump = EventPump(scheduler) { delivered.add(it) }

        fun types(): List<String> = delivered.map { it["type"] as String }
    }

    @Test
    fun `the thirty-second message flushes the batch without waiting out the window`() {
        val harness = Harness()
        harness.pump.attach()
        repeat(31) { harness.pump.enqueue("p$it", it) }
        assertTrue(harness.delivered.isEmpty())
        assertEquals(EventPump.BATCH_MILLIS, harness.scheduler.armedDelay())

        harness.pump.enqueue("p31", 31)
        // The pending 16 ms timer is replaced by one that fires on the next turn.
        assertEquals(0L, harness.scheduler.armedDelay())
        assertTrue(harness.delivered.isEmpty())

        harness.scheduler.runAll()
        assertEquals(32, harness.delivered.size)
        assertEquals("p0", harness.delivered.first()["type"])
        assertEquals("p31", harness.delivered.last()["type"])
    }

    @Test
    fun `a quiet lane flushes on the sixteen millisecond timer`() {
        val harness = Harness()
        harness.pump.attach()
        harness.pump.enqueue("rates", mapOf("upload" to 1L))
        assertTrue(harness.delivered.isEmpty())
        assertEquals(EventPump.BATCH_MILLIS, harness.scheduler.armedDelay())

        harness.scheduler.runAll()
        assertEquals(listOf("rates"), harness.types())
        assertEquals(1L, (harness.delivered.single()["value"] as Map<*, *>)["upload"])
    }

    @Test
    fun `priority is delivered before bulk from the same batch`() {
        val harness = Harness()
        harness.pump.attach()
        harness.pump.enqueue("connections", listOf(1), EventPump.Lane.BULK) { ByteArray(3) }
        harness.pump.enqueue("dashboard", mapOf("running" to true))

        harness.scheduler.runAll()
        assertEquals(listOf("dashboard", "connections"), harness.types())
    }

    @Test
    fun `bulk gets one turn after eight priority messages`() {
        val harness = Harness()
        harness.pump.attach()
        // 13 messages: below the batch size, so one timer flush delivers all of them and the
        // burst counter alone decides where the bulk message lands.
        repeat(6) { harness.pump.enqueue("p$it", it) }
        harness.pump.enqueue("logcat", listOf(1), EventPump.Lane.BULK) { ByteArray(3) }
        repeat(6) { harness.pump.enqueue("q$it", it) }

        harness.scheduler.runAll()
        val types = harness.types()
        assertEquals(13, types.size)
        // Without the guard the bulk message would be last: twelve priority messages would
        // drain first because that lane never empties.
        assertEquals("logcat", types[8])
        assertEquals(listOf("p0", "p1", "p2", "p3", "p4", "p5", "q0", "q1"), types.take(8))
    }

    @Test
    fun `a full priority lane evicts its own oldest message`() {
        val harness = Harness()
        harness.pump.attach()
        repeat(260) { harness.pump.enqueue("p$it", it) }

        val snapshot = harness.pump.snapshot()
        assertEquals(256, snapshot["depth"])
        assertEquals(256, snapshot["priority.depth"])
        assertEquals(260, snapshot["priority.enqueued"])
        assertEquals(4, snapshot["priority.dropped"])
        assertEquals(0, snapshot["bulk.dropped"])

        harness.scheduler.runAll()
        assertEquals(256, harness.delivered.size)
        assertEquals("p4", harness.delivered.first()["type"])
        assertEquals("p259", harness.delivered.last()["type"])
    }

    @Test
    fun `a full bulk lane evicts its own oldest message`() {
        val harness = Harness()
        harness.pump.attach()
        repeat(258) {
            harness.pump.enqueue("logs", listOf(it), EventPump.Lane.BULK) { value ->
                (value as List<*>).single().toString().toByteArray()
            }
        }
        assertEquals(2, harness.pump.snapshot()["bulk.dropped"])

        harness.scheduler.runAll()
        assertEquals(256, harness.delivered.size)
        // The payload is the encoder's bytes; the first surviving batch is row 2, not row 0.
        fun row(event: Map<String, Any?>) = String(event["value"] as ByteArray)
        assertEquals("2", row(harness.delivered.first()))
        assertEquals("257", row(harness.delivered.last()))
    }

    @Test
    fun `the state lane is not evicted by a priority or bulk flood`() {
        val harness = Harness()
        harness.pump.attach()
        repeat(300) { harness.pump.enqueue("state$it", it, EventPump.Lane.STATE) }
        repeat(300) { harness.pump.enqueue("prio$it", it) }
        repeat(300) {
            harness.pump.enqueue("bulk$it", it, EventPump.Lane.BULK) { ByteArray(1) }
        }

        harness.scheduler.runAll()
        val state = harness.delivered.filter { (it["type"] as String).startsWith("state") }
        val priority = harness.delivered.filter { (it["type"] as String).startsWith("prio") }
        val bulk = harness.delivered.filter { (it["type"] as String).startsWith("bulk") }

        assertEquals("every state message is delivered", 300, state.size)
        assertEquals(listOf(0, 299), listOf(state.first()["value"], state.last()["value"]))
        assertEquals("priority keeps its bound", 256, priority.size)
        assertEquals("priority evicted its oldest four dozen", 44, priority.first()["value"])
        assertEquals("bulk keeps its bound", 256, bulk.size)
        // The state lane goes first, so nothing from the other lanes overtook it.
        assertTrue(harness.types().take(300).all { it.startsWith("state") })
    }

    @Test
    fun `no listener means the encoder is never called`() {
        val harness = Harness()
        var encodes = 0
        val encode = { _: Any? -> encodes++; ByteArray(4) }
        fun bulk() = harness.pump.enqueue("logcat", listOf(1), EventPump.Lane.BULK, encode)

        bulk()
        assertEquals("a detached pump must not encode", 0, encodes)
        assertEquals(1, harness.pump.snapshot()["bulk.dropped"])

        harness.pump.attach()
        bulk()
        assertEquals(1, encodes)

        harness.pump.detach()
        bulk()
        assertEquals("the pump detached again", 1, encodes)
        assertEquals(2, harness.pump.snapshot()["bulk.dropped"])
    }

    @Test
    fun `a payload the encoder refuses is dropped`() {
        val harness = Harness()
        harness.pump.attach()
        harness.pump.enqueue("logs", listOf(1), EventPump.Lane.BULK) { ByteArray(0) }
        harness.scheduler.runAll()
        assertTrue(harness.delivered.isEmpty())
        assertEquals(1, harness.pump.snapshot()["bulk.dropped"])
    }

    @Test
    fun `counters report one batch`() {
        val harness = Harness()
        harness.pump.attach()
        harness.pump.enqueue("dashboard", mapOf("running" to true))
        harness.pump.enqueue("rates", mapOf("upload" to 0L))
        harness.pump.enqueue("logs", listOf(1, 2), EventPump.Lane.BULK) { ByteArray(5) }
        harness.scheduler.runAll()

        val snapshot = harness.pump.snapshot()
        assertEquals(true, snapshot["attached"])
        assertEquals(0, snapshot["depth"])
        assertEquals(3, snapshot["maxDepth"])
        assertEquals(2, snapshot["priority.enqueued"])
        assertEquals(2, snapshot["priority.flushed"])
        assertEquals(1, snapshot["bulk.enqueued"])
        assertEquals(1, snapshot["bulk.flushed"])
        assertEquals(5L, snapshot["bulk.bytes"])
        assertEquals(0, snapshot["state.enqueued"])
    }

    @Test
    fun `detach discards the queue and stops the timer`() {
        val harness = Harness()
        harness.pump.attach()
        harness.pump.enqueue("dashboard", mapOf("running" to true))
        harness.pump.enqueue("rates", mapOf("upload" to 0L))
        harness.pump.detach()

        harness.scheduler.assertNoArmedDrain()
        val snapshot = harness.pump.snapshot()
        assertEquals(0, snapshot["depth"])
        assertEquals(2, snapshot["priority.dropped"])
        assertEquals(0, snapshot["priority.flushed"])
        assertFalse(snapshot["attached"] as Boolean)

        harness.pump.enqueue("dashboard", mapOf("running" to false))
        assertEquals(3, harness.pump.snapshot()["priority.dropped"])
        harness.scheduler.runAll()
        assertTrue(harness.delivered.isEmpty())

        // A new listener starts from zero: it has seen nothing the previous one queued.
        harness.pump.attach()
        val reset = harness.pump.snapshot()
        assertEquals(0, reset["priority.enqueued"])
        assertEquals(0, reset["priority.dropped"])
        assertEquals(0, reset["maxDepth"])
    }

    @Test
    fun `flushNow delivers everything at once for a stop`() {
        val harness = Harness()
        harness.pump.attach()
        repeat(40) { harness.pump.enqueue("p$it", it) }
        // Forty wait for the timer; the batch cap is not the stop path's concern.
        harness.pump.flushNow()

        assertEquals(40, harness.delivered.size)
        assertEquals("p39", harness.delivered.last()["type"])
        harness.scheduler.assertNoArmedDrain()
        assertEquals(0, harness.pump.snapshot()["depth"])
    }

    @Test
    fun `a throwing deliver does not lose the rest of the batch`() {
        val delivered = ArrayList<String>()
        var calls = 0
        val pump = EventPump(FakeScheduler()) { event ->
            calls++
            if (calls == 2) error("sink torn down")
            delivered.add(event["type"] as String)
        }
        pump.attach()
        pump.enqueue("dashboard", mapOf("running" to true))
        pump.enqueue("rates", mapOf("upload" to 0L))
        pump.enqueue("profiles", emptyList<Any>())
        pump.flushNow()

        assertEquals(listOf("dashboard", "profiles"), delivered)
        assertEquals(3, pump.snapshot()["priority.flushed"])
    }
}
