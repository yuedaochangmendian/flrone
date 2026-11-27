package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The persisted record must survive a JSON round trip type-exactly: the kernel casts the
 * profile ids back to long, and a JSON double there fails every start instead of skipping a build.
 */
class AppliedConfigStoreTest {

    /** The shape `FlroneKernel.buildStartOptions` (via BoxInstance) actually produces. */
    private fun buildOptions(): Map<String, Any?> = mapOf(
        "coreConfig" to "{\"log\":{\"level\":\"info\"}}",
        "deferRuleSets" to false,
        "involvedProfileIds" to listOf(3L, 7L),
        "routeId" to 42L,
    )

    @Test
    fun aRoundTripKeepsEveryTypeTheKernelReads() {
        val decoded = AppliedConfigStore.decode(AppliedConfigStore.encode(buildOptions()))

        assertEquals("{\"log\":{\"level\":\"info\"}}", decoded!!["coreConfig"])
        assertEquals(false, decoded["deferRuleSets"])
        assertEquals(42L, (decoded["routeId"] as Number).toLong())
        assertEquals(listOf(3L, 7L), (decoded["involvedProfileIds"] as List<*>).map { (it as Number).toLong() })
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
            "deferRuleSets" to null,
        )))
        assertEquals("{}", decoded!!["coreConfig"])
        assertTrue(decoded.containsKey("deferRuleSets").not())
    }
}
