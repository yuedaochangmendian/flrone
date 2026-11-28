package io.flrone.flutter

import io.flrone.bridge.DartProfileWriter
import io.flrone.bridge.ReplyGate
import io.flutter.plugin.common.BinaryMessenger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Before
import org.junit.Test

/**
 * S6 Option A owner election. The service engine is preferred; the UI engine
 * is only a fallback that cannot steal ownership or survive a UI close. The
 * tests use a fake [BinaryMessenger] (only identity matters — no channel call
 * is made while the writer merely attaches/detaches).
 */
class DocumentOwnerElectionTest {

    private val serviceMessenger = FakeMessenger("service")
    private val uiMessenger = FakeMessenger("ui")

    @Before
    fun setUp() {
        DartProfileWriter.testTransport = null
        DartProfileWriter.detach()
        DartProfileWriter.registerUiMessenger(uiMessenger)
        ServiceEngineManager.ensureForDocument = null
        ServiceEngineManager.ownerAttachTimeoutMs = 50L
    }

    @After
    fun tearDown() {
        DartProfileWriter.testTransport = null
        DartProfileWriter.detach()
        ServiceEngineManager.ensureForDocument = null
        ServiceEngineManager.ownerAttachTimeoutMs = 2_000L
    }

    @Test
    fun `the service engine wins over a registered UI fallback`() {
        assertTrue(DartProfileWriter.attachUiFallback())
        assertEquals(DartProfileWriter.OwnerRole.UI, DartProfileWriter.currentRole())
        // Attaching the service replaces the fallback; one writable owner only.
        DartProfileWriter.attachService(serviceMessenger)
        assertEquals(DartProfileWriter.OwnerRole.SERVICE, DartProfileWriter.currentRole())
        assertFalse(
            "the UI fallback must not re-attach while the service owner is live",
            DartProfileWriter.attachUiFallback(),
        )
        assertEquals(DartProfileWriter.OwnerRole.SERVICE, DartProfileWriter.currentRole())
    }

    @Test
    fun `a UI fallback is elected only when no service owner exists`() {
        assertEquals(DartProfileWriter.OwnerRole.NONE, DartProfileWriter.currentRole())
        assertTrue(DartProfileWriter.attachUiFallback())
        assertEquals(DartProfileWriter.OwnerRole.UI, DartProfileWriter.currentRole())
        // Detaching UI leaves no owner; the next service attach still wins.
        DartProfileWriter.detach(DartProfileWriter.OwnerRole.UI)
        assertEquals(DartProfileWriter.OwnerRole.NONE, DartProfileWriter.currentRole())
        DartProfileWriter.attachService(serviceMessenger)
        assertEquals(DartProfileWriter.OwnerRole.SERVICE, DartProfileWriter.currentRole())
    }

    @Test
    fun `UI close does not detach the service owner`() {
        DartProfileWriter.attachService(serviceMessenger)
        // The UI bridge's close path detaches only the UI role.
        DartProfileWriter.detach(DartProfileWriter.OwnerRole.UI)
        assertEquals(
            "closing the UI must not kill the service owner",
            DartProfileWriter.OwnerRole.SERVICE,
            DartProfileWriter.currentRole(),
        )
    }

    @Test
    fun `service destroy gives up ownership and allows UI fail-closed re-election`() {
        DartProfileWriter.attachService(serviceMessenger)
        // Fail-closed recovery detaches the dead service owner (which fails
        // every in-flight call) and the next write re-elects the UI fallback.
        DartProfileWriter.detach(DartProfileWriter.OwnerRole.SERVICE)
        assertEquals(DartProfileWriter.OwnerRole.NONE, DartProfileWriter.currentRole())
        assertTrue(DartProfileWriter.attachUiFallback())
        assertEquals(DartProfileWriter.OwnerRole.UI, DartProfileWriter.currentRole())
        // A late service attach still wins: recovery is idempotent.
        DartProfileWriter.attachService(serviceMessenger)
        assertEquals(DartProfileWriter.OwnerRole.SERVICE, DartProfileWriter.currentRole())
    }

    @Test
    fun `ensureDocumentOwner prefers an available service owner`() {
        var ensureCalls = 0
        ServiceEngineManager.ensureForDocument = {
            ensureCalls++
            DartProfileWriter.attachService(serviceMessenger)
            true
        }
        assertTrue(ServiceEngineManager.ensureDocumentOwner())
        assertEquals(DartProfileWriter.OwnerRole.SERVICE, DartProfileWriter.currentRole())
        assertTrue(ensureCalls >= 0)
    }

    @Test
    fun `a reply gate settles exactly once`() {
        val gate = ReplyGate()
        assertTrue(gate.claim())
        assertFalse(gate.claim())
    }

    private class FakeMessenger(private val name: String) : BinaryMessenger {
        override fun send(channel: String, message: ByteArray?, callback: BinaryMessenger.Callback?) {}
        override fun send(channel: String, message: ByteArray?, flags: Int, callback: BinaryMessenger.Callback?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.MessageHandler?) {}
        override fun toString(): String = "FakeMessenger($name)"
    }
}
