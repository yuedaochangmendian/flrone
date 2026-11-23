// The single-flight state machine behind the VPN consent dialog (S2).
//
// `KernelServiceActions.startServiceAndAwaitTun` waits for the consent *answer* instead of
// spending its readiness budget on the dialog. Two starts that overlap must share one dialog,
// a caller that gives up must not poison the next start, and an answer that arrives after its
// request was dropped must not resolve a newer one. Those four properties are pinned here; the
// Android half (prepare/startActivity/results) is VpnPermission and has no JVM-runnable state.

package io.nekohasekai.sagernet.utils

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnConsentGateTest {

    private val gate = VpnConsentGate()

    /** Only for a ticket that is known to be completed: an uncompleted await would block. */
    private fun answer(ticket: VpnConsentGate.Ticket) = runBlocking { ticket.result.await() }

    @Test
    fun `the first caller asks, the second joins the same request`() {
        val first = gate.begin()
        val second = gate.begin()
        assertTrue("the first caller must put the dialog up", first.mustAsk)
        assertFalse("an overlapping start must not open a second dialog", second.mustAsk)
        assertSame("both callers must await one answer", first.result, second.result)
        assertTrue(gate.inFlight)
    }

    @Test
    fun `one answer reaches every waiter`() {
        val first = gate.begin()
        val second = gate.begin()
        assertTrue(gate.complete(VpnConsentOutcome.GRANTED))
        assertEquals(VpnConsentOutcome.GRANTED, answer(first))
        assertEquals(VpnConsentOutcome.GRANTED, answer(second))
        assertFalse("the request is finished", gate.inFlight)
    }

    @Test
    fun `a denial is a refusal, not a timeout`() {
        val ticket = gate.begin()
        gate.complete(VpnConsentOutcome.DENIED)
        assertEquals(VpnConsentOutcome.DENIED, answer(ticket))
    }

    @Test
    fun `after one request settles the next start asks again`() {
        val first = gate.begin()
        gate.complete(VpnConsentOutcome.DENIED)
        val next = gate.begin()
        assertTrue("a settled request must not answer a newer start", next.mustAsk)
        assertNotSame(first.result, next.result)
    }

    @Test
    fun `an answer with no request in flight resolves nothing`() {
        assertFalse(gate.complete(VpnConsentOutcome.GRANTED))
        assertFalse(gate.inFlight)
    }

    @Test
    fun `a caller that gives up before the dialog opened drops the request`() {
        val first = gate.begin()
        gate.abandon(first)
        assertFalse("no dialog exists, so nothing can answer it", gate.inFlight)
        val next = gate.begin()
        assertTrue("the next start must launch its own dialog", next.mustAsk)
    }

    @Test
    fun `a caller that gives up while another waits keeps the request`() {
        val first = gate.begin()
        val second = gate.begin()
        gate.abandon(first)
        assertTrue(gate.inFlight)
        gate.complete(VpnConsentOutcome.GRANTED)
        assertEquals(VpnConsentOutcome.GRANTED, answer(second))
    }

    @Test
    fun `a dialog on screen outlives its last waiter`() {
        val first = gate.begin()
        gate.markLaunched(first)
        gate.abandon(first)
        assertTrue("an on-screen consent still has an answer to give", gate.inFlight)
        val late = gate.begin()
        assertFalse("a late start joins the open dialog", late.mustAsk)
        assertSame(first.result, late.result)
        gate.complete(VpnConsentOutcome.GRANTED)
        assertEquals(VpnConsentOutcome.GRANTED, answer(late))
    }

    @Test
    fun `an abandoned request cannot be completed twice`() {
        val first = gate.begin()
        gate.abandon(first)
        assertFalse(gate.complete(VpnConsentOutcome.GRANTED))
    }

    @Test
    fun `concurrent callers register exactly one dialog`() {
        val threads = 8
        val pool = Executors.newFixedThreadPool(threads)
        val start = CountDownLatch(1)
        val done = CountDownLatch(threads)
        val tickets = java.util.Collections.synchronizedList(mutableListOf<VpnConsentGate.Ticket>())
        repeat(threads) {
            pool.execute {
                start.await()
                tickets.add(gate.begin())
                done.countDown()
            }
        }
        start.countDown()
        assertTrue("workers did not finish", done.await(20, TimeUnit.SECONDS))
        pool.shutdown()
        assertEquals(threads, tickets.size)
        assertEquals("exactly one caller opens the dialog", 1, tickets.count { it.mustAsk })
        assertEquals("all callers await one answer", 1, tickets.map { it.result }.toSet().size)
    }
}
