package io.flrone.flutter

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The dashboard/rates push split (D2).
 *
 * `pushState` builds a dashboard and a rates map on Main up to 1 Hz. `ui.visible` only gated
 * the forced sample, so a change in the byte counters still built and shipped both events to a
 * hidden app whose `RefreshGate` ignores them. These tests pin the split: a state field decides
 * on its own, a traffic field only counts while the UI is visible, and the first key always
 * goes through so the baselines start from a known sample.
 */
class UiWireKeyTest {

    private fun key(state: String = "state", traffic: String = "traffic") = UiWireKey(state, traffic)

    @Test
    fun `the first key always pushes`() {
        assertTrue(shouldPushUiWire(previous = null, next = key(), visible = false))
        assertTrue(shouldPushUiWire(previous = null, next = key(), visible = true))
    }

    @Test
    fun `an unchanged key never pushes`() {
        assertFalse(shouldPushUiWire(key(), key(), visible = false))
        assertFalse(shouldPushUiWire(key(), key(), visible = true))
    }

    @Test
    fun `a traffic-only change is skipped while hidden`() {
        assertFalse(shouldPushUiWire(key(), key(traffic = "more"), visible = false))
    }

    @Test
    fun `a traffic-only change pushes while visible`() {
        assertTrue(shouldPushUiWire(key(), key(traffic = "more"), visible = true))
    }

    @Test
    fun `a state change pushes while hidden`() {
        assertTrue(shouldPushUiWire(key(), key(state = "Started"), visible = false))
    }

    @Test
    fun `a state change pushes while visible`() {
        assertTrue(shouldPushUiWire(key(), key(state = "Started"), visible = true))
    }
}
