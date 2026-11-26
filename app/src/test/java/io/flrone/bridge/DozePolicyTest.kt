package io.flrone.bridge

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Truth table for device doze. Doze requires BOTH the screen off and the device
 * idle; every other combination is a normal (non-doze) state. This is the policy
 * the host's BroadcastReceiver applies to PowerManager facts, kept pure so the
 * table is pinned without an emulator.
 */
class DozePolicyTest {
    @Test
    fun `screen off and idle means doze`() {
        assertTrue(DozePolicy.shouldDoze(screenOn = false, idle = true))
    }

    @Test
    fun `screen on is never doze even when idle`() {
        assertFalse(DozePolicy.shouldDoze(screenOn = true, idle = true))
    }

    @Test
    fun `screen off without idle is not doze`() {
        // An app-backgrounding hint only; pause here would starve periodic work.
        assertFalse(DozePolicy.shouldDoze(screenOn = false, idle = false))
    }

    @Test
    fun `screen on and not idle is not doze`() {
        assertFalse(DozePolicy.shouldDoze(screenOn = true, idle = false))
    }
}
