package io.nekohasekai.sagernet.bg.test

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The profile a test-current speed run measures.
 *
 * ffiMode is the case that matters: BaseService marks Connected without launching an instance on this side, so
 * `CoreRuntime.running` is null for the whole session while the Go core is live in `lastInstance`. The run used to
 * dead-end on that null with "instance is not running"; it now falls back to the id the service recorded and passes a
 * 0 instance handle, which the bridge resolves to the live box. A stopped service must still report NOT_RUNNING.
 *
 * Pure functions, no core and no database.
 */
class SpeedTestCurrentTest {

    @Test
    fun `a live instance names its own profile`() {
        assertEquals(7L, currentSpeedProfileId(instanceProfileId = 7L, runningProfileId = 9L))
    }

    @Test
    fun `ffiMode without an instance falls back to the running profile`() {
        // running == null reaches here as 0; the service still recorded the profile it marked Connected for.
        assertEquals(7L, currentSpeedProfileId(instanceProfileId = 0L, runningProfileId = 7L))
    }

    @Test
    fun `a stopped service has no profile to test`() {
        // Both empty is VPN-off: the caller reports ERROR_NOT_RUNNING and starts nothing.
        assertEquals(0L, currentSpeedProfileId(instanceProfileId = 0L, runningProfileId = 0L))
    }

    @Test
    fun `negative ids are not profiles`() {
        assertEquals(7L, currentSpeedProfileId(instanceProfileId = -1L, runningProfileId = 7L))
        assertEquals(0L, currentSpeedProfileId(instanceProfileId = -1L, runningProfileId = -2L))
    }
}
