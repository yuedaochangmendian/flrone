package io.flrone.bridge

import okhttp3.Credentials
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetSocketAddress

/**
 * The egress probe's route contract: a connected session with no mixed inbound has no routed route, so the tunnel probe
 * must fail rather than answer over the device network. Before this guard `clientFor(direct = false)` fell back to the
 * no-proxy client in exactly those states, and the status card rendered the phone's own address as the tunnel's exit.
 *
 * Pure JVM: the decision is [FlroneEgress.hasTunnelRoute] / [FlroneEgress.clientFor] over a [FlroneEgress.TunnelRoute], with
 * no DataStore and no Android runtime (this project has no Robolectric).
 */
class FlroneEgressRouteTest {

    @After
    fun reset() {
        // The tunnel client is a process-wide cache; a stale entry would leak into the next case.
        FlroneEgress.invalidate()
    }

    // ------------------------------------------------------------------------------------------------ route guard

    @Test
    fun `connected without a mixed inbound has no tunnel route`() {
        // The three states the bug fell into: the inbound disabled in VPN mode, and a port that never bound.
        assertEquals(false, FlroneEgress.hasTunnelRoute(connected = true, mixedInboundDisabled = true, port = 2080))
        assertEquals(false, FlroneEgress.hasTunnelRoute(connected = true, mixedInboundDisabled = false, port = 0))
        assertEquals(false, FlroneEgress.hasTunnelRoute(connected = true, mixedInboundDisabled = false, port = -1))
    }

    @Test
    fun `only a connected session with a bound inbound has a tunnel route`() {
        assertEquals(true, FlroneEgress.hasTunnelRoute(connected = true, mixedInboundDisabled = false, port = 2080))
        // A stopped service is served by the direct probe instead; it must never borrow the tunnel's route.
        assertEquals(false, FlroneEgress.hasTunnelRoute(connected = false, mixedInboundDisabled = false, port = 2080))
        assertEquals(false, FlroneEgress.hasTunnelRoute(connected = false, mixedInboundDisabled = true, port = 2080))
    }

    // ------------------------------------------------------------------------------------------------ client choice

    @Test
    fun `tunnel probe without a route gets no client`() {
        // The regression: this used to return the direct client, whose answer is the phone's own address.
        assertNull(FlroneEgress.clientFor(direct = false, route = null))
        assertNull(FlroneEgress.clientFor(direct = false, route = tunnel(port = 0)))
    }

    @Test
    fun `a direct probe keeps the device network even while connected`() {
        val client = FlroneEgress.clientFor(direct = true, route = null)
        assertNotNull(client)
        assertNull("A direct probe must not be proxied", client!!.proxy)
    }

    @Test
    fun `no tunnel route answers empty and drops the stale exit`() {
        // The old bug: probeLocked returned the previous session's tunnel IP on an automatic refresh while the
        // current connection had no mixed inbound, so the card showed an exit that was no longer reachable.
        val answer = FlroneEgress.noTunnelRouteAnswer(direct = false)
        assertTrue("A route-less tunnel probe must not answer an address", answer.isEmpty)
        assertTrue("The stale tunnel cache must be cleared", FlroneEgress.cached(direct = false).isEmpty)
        assertEquals(0L, FlroneEgress.cachedAt(direct = false))
        // A direct probe always has a route; this branch is defensive and must not invent an address either.
        assertTrue(FlroneEgress.noTunnelRouteAnswer(direct = true).isEmpty)
    }

    @Test
    fun `a tunnel probe is proxied to the mixed inbound`() {
        val client = FlroneEgress.clientFor(direct = false, route = tunnel())
        assertNotNull(client)
        val address = client!!.proxy?.address() as InetSocketAddress
        assertEquals(2080, address.port)
        assertEquals("127.0.0.1", address.hostString)
    }

    @Test
    fun `a tunnel client is reused while the route is unchanged`() {
        val first = FlroneEgress.clientFor(direct = false, route = tunnel())
        val second = FlroneEgress.clientFor(direct = false, route = tunnel())
        assertSame("An unchanged route must reuse its client", first, second)
    }

    @Test
    fun `a changed route hands back a new client`() {
        val first = FlroneEgress.clientFor(direct = false, route = tunnel(port = 2080))
        val moved = FlroneEgress.clientFor(direct = false, route = tunnel(port = 2081))
        assertTrue("A moved port must not reuse the old client", first !== moved)
        assertEquals(2081, (moved!!.proxy?.address() as InetSocketAddress).port)

        val rehosted = FlroneEgress.clientFor(direct = false, route = tunnel(host = "127.0.0.2"))
        assertTrue("A moved host must not reuse the old client", moved !== rehosted)
        assertEquals("127.0.0.2", (rehosted!!.proxy?.address() as InetSocketAddress).hostString)
    }

    @Test
    fun `changed credentials hand back a new client`() {
        val first = FlroneEgress.clientFor(direct = false, route = tunnel(user = "u", password = "p"))
        val repass = FlroneEgress.clientFor(direct = false, route = tunnel(user = "u", password = "q"))
        assertTrue("New credentials must rebuild the client, or the old challenge answer rides on", first !== repass)
    }

    // ------------------------------------------------------------------------------------------------ proxy auth

    @Test
    fun `a route with credentials answers a proxy challenge`() {
        val client = FlroneEgress.applyRoute(OkHttpClient.Builder(), tunnel(user = "u", password = "p")).build()
        val answered = client.proxyAuthenticator.authenticate(null, challenge("http://probe.invalid/"))
        assertEquals(Credentials.basic("u", "p"), answered?.header("Proxy-Authorization"))
    }

    @Test
    fun `a route without credentials never answers a proxy challenge`() {
        val client = FlroneEgress.applyRoute(OkHttpClient.Builder(), tunnel()).build()
        assertNull(client.proxyAuthenticator.authenticate(null, challenge("http://probe.invalid/")))
    }

    @Test
    fun `an answered challenge is not answered twice`() {
        val client = FlroneEgress.applyRoute(OkHttpClient.Builder(), tunnel(user = "u", password = "p")).build()
        val retried = Request.Builder()
            .url("http://probe.invalid/")
            .header("Proxy-Authorization", Credentials.basic("u", "p"))
            .build()
        assertNull(
            "A second 407 means the credentials are wrong, so resending them cannot help",
            client.proxyAuthenticator.authenticate(null, challenge(retried)),
        )
    }

    @Test
    fun `applyRoute leaves a direct client on the device network`() {
        val client = FlroneEgress.applyRoute(OkHttpClient.Builder(), null).build()
        assertNull(client.proxy)
    }

    // ------------------------------------------------------------------------------------------------ fixtures

    private fun tunnel(port: Int = 2080, host: String = "127.0.0.1", user: String = "", password: String = "") =
        FlroneEgress.TunnelRoute(port = port, host = host, user = user, password = password)

    /** A minimal 407; the authenticator reads only the request and the code. */
    private fun challenge(url: String): Response = challenge(Request.Builder().url(url).build())

    private fun challenge(request: Request): Response = Response.Builder()
        .request(request)
        .protocol(Protocol.HTTP_1_1)
        .code(407)
        .message("Proxy Authentication Required")
        .body("".toResponseBody(null))
        .build()
}
