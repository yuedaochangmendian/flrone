package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ADR 0004 P2: the three duties that moved onto the single platform_request
 * facade. Exercises the real dispatch code (PlatformRequestRouter is the pure
 * part of FlroneCorePlatform.platformRequest) with injected duties, so no Android
 * runtime is needed. Guards the method names/payload shape the Go side sends.
 */
class PlatformRequestRouterTest {

    private var cleared = 0
    private val router = { method: String, payload: String ->
        PlatformRequestRouter.dispatch(
            method,
            payload,
            useProcFS = { true },
            packageNamesByUid = { uid -> """["app.$uid"]""" },
            clearDnsCache = { cleared++ },
        )
    }

    @Test
    fun `use_proc_fs returns a JSON boolean`() {
        assertEquals("true", router("use_proc_fs", "{}"))
        assertEquals("true", router("use_proc_fs", "null"))
    }

    @Test
    fun `package_names_by_uid decodes the uid payload`() {
        assertEquals("""["app.10042"]""", router("package_names_by_uid", """{"uid":10042}"""))
        // Missing/malformed uid must not throw into the Go-owned JNI thread.
        assertEquals("""["app.-1"]""", router("package_names_by_uid", "{}"))
        assertEquals("""["app.-1"]""", router("package_names_by_uid", "not json"))
    }

    @Test
    fun `clear_dns_cache calls through and returns empty`() {
        cleared = 0
        assertEquals("", router("clear_dns_cache", "{}"))
        assertEquals(1, cleared)
    }

    @Test
    fun `unknown method returns an error string, never throws`() {
        val out = router("no_such_duty", "{}")
        assertTrue(out.startsWith("unknown platform_request method"))
    }
}
