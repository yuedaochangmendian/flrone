package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `platform_request` is called from Go-owned threads through JNI. The guard must turn any
 * thrown exception — from JSON parsing, Base64 decoding, notification calls or the tun bridge
 * — into a plain error string so nothing crosses back into C, while leaving success shapes
 * exactly as the duty produced them.
 */
class PlatformRequestGuardTest {

    @Test
    fun `a successful dispatch returns its exact answer`() {
        assertEquals("true", PlatformRequestGuard.guard("use_proc_fs") { "true" })
        assertEquals("", PlatformRequestGuard.guard("clear_dns_cache") { "" })
        assertEquals("""["x"]""", PlatformRequestGuard.guard("package_names_by_uid") { """["x"]""" })
    }

    @Test
    fun `an exception becomes a non-empty error string, never rethrown`() {
        val out = PlatformRequestGuard.guard("dns_exchange") {
            throw IllegalArgumentException("bad base64")
        }
        assertTrue(out.startsWith("platform_request failed: dns_exchange:"))
        assertTrue(out.contains("bad base64"))
    }

    @Test
    fun `an exception with no message still names the method and type`() {
        val out = PlatformRequestGuard.guard("send_notification") {
            throw NullPointerException()
        }
        assertTrue(out.startsWith("platform_request failed: send_notification:"))
        assertTrue(out.contains("NullPointerException"))
    }
}
