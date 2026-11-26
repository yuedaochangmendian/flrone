package io.flrone.bridge

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pure half of FlroneCorePlatform's default-interface report. The Android half now runs
 * off the network callback thread (no `Thread.sleep` on the Connectivity handler); these
 * tests pin the result side: an unchanged interface is not re-reported, and any change of
 * name, index, network token or meteredness is, so Go never keeps dialing a stale link.
 */
class InterfaceReportDecisionTest {

    private val snapshot = FlroneCorePlatform.IfaceSnapshot("wlan0", 42, false)

    @Test
    fun `an unchanged interface is not re-reported`() {
        assertFalse(
            FlroneCorePlatform.InterfaceReportDecision.changed(
                previousName = "wlan0",
                previousIndex = 42,
                previousNetwork = "net0",
                previousExpensive = false,
                network = "net0",
                snapshot = snapshot,
            )
        )
    }

    @Test
    fun `a changed name index network or meteredness is reported`() {
        assertTrue(
            FlroneCorePlatform.InterfaceReportDecision.changed(
                previousName = "rmnet0", previousIndex = 42, previousNetwork = "net0",
                previousExpensive = false, network = "net0", snapshot = snapshot,
            )
        )
        assertTrue(
            FlroneCorePlatform.InterfaceReportDecision.changed(
                previousName = "wlan0", previousIndex = 7, previousNetwork = "net0",
                previousExpensive = false, network = "net0", snapshot = snapshot,
            )
        )
        assertTrue(
            FlroneCorePlatform.InterfaceReportDecision.changed(
                previousName = "wlan0", previousIndex = 42, previousNetwork = "net0",
                previousExpensive = false, network = "net1", snapshot = snapshot,
            )
        )
        assertTrue(
            FlroneCorePlatform.InterfaceReportDecision.changed(
                previousName = "wlan0", previousIndex = 42, previousNetwork = "net0",
                previousExpensive = true, network = "net0", snapshot = snapshot,
            )
        )
    }

    @Test
    fun `a first report after a loss is always sent`() {
        assertTrue(
            FlroneCorePlatform.InterfaceReportDecision.changed(
                previousName = null,
                previousIndex = Int.MIN_VALUE,
                previousNetwork = null,
                previousExpensive = false,
                network = "net0",
                snapshot = snapshot,
            )
        )
    }
}
