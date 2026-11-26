package io.flrone.flutter

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The fail-closed engine decision. A cached FlutterEngine object is not proof
 * its isolate is alive: only a start that could not be delivered within a
 * bounded window flips the failed flag. A normal stop leaves the engine warm.
 */
class EngineLivenessTest {

    @Test
    fun `a fresh engine is reusable`() {
        val liveness = EngineLiveness()
        assertTrue("a healthy engine is reused", liveness.canReuse())
    }

    @Test
    fun `an undeliverable start marks the engine failed`() {
        val liveness = EngineLiveness()
        liveness.markFailed()
        assertFalse("a dead isolate must not be reused", liveness.canReuse())
    }

    @Test
    fun `a fresh engine clears a previous failure`() {
        val liveness = EngineLiveness()
        liveness.markFailed()
        assertFalse(liveness.canReuse())
        // ensureStarted destroys the failed object and builds a replacement;
        // the replacement is healthy from the start.
        liveness.markHealthy()
        assertTrue(liveness.canReuse())
    }

    @Test
    fun `repeated failure reports are idempotent`() {
        val liveness = EngineLiveness()
        repeat(10) { liveness.markFailed() }
        assertFalse(liveness.canReuse())
    }
}
