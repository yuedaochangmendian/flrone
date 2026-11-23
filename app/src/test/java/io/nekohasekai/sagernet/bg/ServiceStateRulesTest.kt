package io.nekohasekai.sagernet.bg

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `Connected` is the Dart kernel's report (`state.markRunning`), never the host's own start
 * request. These are the two rules the surfaces depend on, kept pure so they can be checked
 * without a service, a notification or a tile.
 */
class ServiceStateRulesTest {

    @Test
    fun onlyConnectedIsAnActiveTunnel() {
        assertFalse(ServiceStateRules.isActiveState(BaseService.State.Idle))
        assertFalse(ServiceStateRules.isActiveState(BaseService.State.Connecting))
        assertTrue(ServiceStateRules.isActiveState(BaseService.State.Connected))
        assertFalse(ServiceStateRules.isActiveState(BaseService.State.Stopping))
        assertFalse(ServiceStateRules.isActiveState(BaseService.State.Stopped))
    }

    @Test
    fun aStartAndAStopAreTransitions() {
        assertTrue(ServiceStateRules.isTransitioningState(BaseService.State.Connecting))
        assertTrue(ServiceStateRules.isTransitioningState(BaseService.State.Stopping))
        assertFalse(ServiceStateRules.isTransitioningState(BaseService.State.Connected))
        assertFalse(ServiceStateRules.isTransitioningState(BaseService.State.Stopped))
        assertFalse(ServiceStateRules.isTransitioningState(BaseService.State.Idle))
    }

    @Test
    fun onlyAStartWaitingForTheKernelIsPromoted() {
        assertTrue(ServiceStateRules.canPromoteToConnected(BaseService.State.Connecting))
        assertFalse(ServiceStateRules.canPromoteToConnected(BaseService.State.Connected))
        assertFalse(ServiceStateRules.canPromoteToConnected(BaseService.State.Stopping))
        assertFalse(ServiceStateRules.canPromoteToConnected(BaseService.State.Stopped))
        assertFalse(ServiceStateRules.canPromoteToConnected(BaseService.State.Idle))
    }

    @Test
    fun aKernelStopOnlyTakesDownAStartThatNeverHeld() {
        assertTrue(ServiceStateRules.shouldStopAfterKernelStopped(BaseService.State.Connecting))
        // A connected tunnel's stop path owns its own teardown; a stop already in flight, or
        // nothing running at all, must not be bounced here.
        assertFalse(ServiceStateRules.shouldStopAfterKernelStopped(BaseService.State.Connected))
        assertFalse(ServiceStateRules.shouldStopAfterKernelStopped(BaseService.State.Stopping))
        assertFalse(ServiceStateRules.shouldStopAfterKernelStopped(BaseService.State.Stopped))
        assertFalse(ServiceStateRules.shouldStopAfterKernelStopped(BaseService.State.Idle))
    }
}
