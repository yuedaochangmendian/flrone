package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The persisted record must survive a JSON round trip type-exactly: the kernel casts
 * `autoSelectorIntervalSec` and the profile ids back to int, and a JSON double there fails
 * every start instead of skipping a build.
 */
class AppliedConfigStoreTest {

    /** The shape `BboxKernel.StartOptionsCapture` actually produces. */
    private fun buildOptions(): Map<String, Any?> = mapOf(
        "coreConfig" to "{\"log\":{\"level\":\"info\"}}",
        "needXray" to true,
        "xrayConfig" to "",
        "xrayDnsStrategy" to "UseIPv4",
        "xrayFullConfigs" to listOf("{\"a\":1}", "{\"b\":2}"),
        "deferRuleSets" to false,
        "autoSelectorIntervalSec" to 0,
        "involvedProfileIds" to listOf(3L, 7L),
        "routeId" to 42L,
    )

    @Test
    fun aRoundTripKeepsEveryTypeTheKernelReads() {
        val decoded = AppliedConfigStore.decode(AppliedConfigStore.encode(buildOptions()))

        assertEquals("{\"log\":{\"level\":\"info\"}}", decoded!!["coreConfig"])
        assertEquals(true, decoded["needXray"])
        assertEquals(false, decoded["deferRuleSets"])
        // `as int?` downstream: an Integer/Long survives, a Double would not.
        assertTrue(decoded["autoSelectorIntervalSec"] is Int || decoded["autoSelectorIntervalSec"] is Long)
        assertEquals(0L, (decoded["autoSelectorIntervalSec"] as Number).toLong())
        assertEquals(42L, (decoded["routeId"] as Number).toLong())
        assertEquals(listOf(3L, 7L), (decoded["involvedProfileIds"] as List<*>).map { (it as Number).toLong() })
        assertEquals(listOf("{\"a\":1}", "{\"b\":2}"), decoded["xrayFullConfigs"])
    }

    @Test
    fun anEmptyOrBrokenRecordReadsAsAbsent() {
        assertNull(AppliedConfigStore.decode(null))
        assertNull(AppliedConfigStore.decode(""))
        assertNull(AppliedConfigStore.decode("   "))
        assertNull(AppliedConfigStore.decode("{oops"))
        assertNull(AppliedConfigStore.decode("{}"))
        // A record holding only JSON nulls has nothing to hand to createInstance.
        assertNull(AppliedConfigStore.decode("{\"coreConfig\":null}"))
    }

    @Test
    fun aNullValuedKeyIsDroppedNotResurrected() {
        val decoded = AppliedConfigStore.decode(AppliedConfigStore.encode(mapOf(
            "coreConfig" to "{}",
            "xrayConfig" to null,
        )))
        assertEquals("{}", decoded!!["coreConfig"])
        assertTrue(decoded.containsKey("xrayConfig").not())
    }
}
