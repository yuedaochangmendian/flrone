// Which foreground service a mode start means, and which one it stops first (S3).
//
// The mapping is the whole "one tunnel at a time" invariant: `SagerNet.startService` starts
// `forMode` and stops `other`, and `VpnService.onStartCommand` applies `other` too for a
// platform-started always-on VPN. Swapping a pair here silently brings back the ghost tunnel
// the alignment item removed, so the four cases are pinned.

package io.nekohasekai.sagernet.bg

import io.nekohasekai.sagernet.Key
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class ServiceClassesTest {

    @Test
    fun `vpn mode runs the vpn service and stops the proxy`() {
        assertEquals(VpnService::class.java, ServiceClasses.forMode(Key.MODE_VPN))
        assertEquals(ProxyService::class.java, ServiceClasses.other(Key.MODE_VPN))
    }

    @Test
    fun `proxy mode runs the proxy service and stops the vpn`() {
        assertEquals(ProxyService::class.java, ServiceClasses.forMode(Key.MODE_PROXY))
        assertEquals(VpnService::class.java, ServiceClasses.other(Key.MODE_PROXY))
    }

    @Test
    fun `the two answers never name the same class`() {
        assertNotEquals(ServiceClasses.other(Key.MODE_VPN), ServiceClasses.forMode(Key.MODE_VPN))
        assertNotEquals(ServiceClasses.other(Key.MODE_PROXY), ServiceClasses.forMode(Key.MODE_PROXY))
    }

    @Test(expected = UnknownError::class)
    fun `an unknown mode is refused instead of guessed`() {
        ServiceClasses.forMode("quic")
    }
}
