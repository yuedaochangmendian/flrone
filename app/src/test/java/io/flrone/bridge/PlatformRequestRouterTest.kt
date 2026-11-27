package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ADR 0004 P2: the three duties that moved onto the single platform_request
 * facade. Exercises the real dispatcher (the very `when` FlroneCorePlatform uses
 * in production) with injected host fakes, so no Android runtime is needed.
 * Guards the method names/payload shape the Go side sends.
 */
class PlatformRequestRouterTest {

    private var cleared = 0
    private fun router() = PlatformRequestDispatcher(PlatformRequestDispatcher.Hosts(
        appendCoreLog = { _, _ -> },
        openTun = { 0 },
        usePlatformAutoDetectInterfaceControl = { true },
        useProcFS = { true },
        findConnectionOwner = { _: Int, _: String, _: Int, _: String, _: Int -> "" },
        packageNamesByUid = { uid -> """["app.$uid"]""" },
        startDefaultInterfaceMonitor = { "" },
        closeDefaultInterfaceMonitor = { "" },
        getInterfaces = { "[]" },
        readWifiState = { "" },
        clearDnsCache = { cleared++ },
        sendNotification = { "" },
        cancelNotification = { _, _ -> "" },
        localDnsRaw = { "true" },
        localDnsLookup = { _, _, _ -> "" },
        localDnsExchange = { _, _ -> "" },
        cancelDnsExchange = { "" },
        testSession = { _, _ -> "" },
    ))::dispatch

    @Test
    fun `use_proc_fs returns a JSON boolean`() {
        val dispatch = router()
        assertEquals("true", dispatch("use_proc_fs", "{}"))
        assertEquals("true", dispatch("use_proc_fs", "null"))
    }

    @Test
    fun `package_names_by_uid decodes the uid payload`() {
        val dispatch = router()
        assertEquals("""["app.10042"]""", dispatch("package_names_by_uid", """{"uid":10042}"""))
        // Missing/malformed uid must not throw into the Go-owned JNI thread.
        assertEquals("""["app.-1"]""", dispatch("package_names_by_uid", "{}"))
        assertEquals("""["app.-1"]""", dispatch("package_names_by_uid", "not json"))
    }

    @Test
    fun `clear_dns_cache calls through and returns empty`() {
        cleared = 0
        val dispatch = router()
        assertEquals("", dispatch("clear_dns_cache", "{}"))
        assertEquals(1, cleared)
    }

    @Test
    fun `unknown method returns an error string, never throws`() {
        val out = router()("no_such_duty", "{}")
        assertTrue(out.startsWith("unknown platform_request method"))
    }
}
