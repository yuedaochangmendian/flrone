// The service engine's automatic-start gate (wave 4).
//
// BootGate answers two questions from a file the UI wrote: whether the previous launch died
// before the UI came up (the mirrored boot marker), and which engine args a gated start gets
// (PREWARM, so the fresh engine's 300 ms auto-start stays idle). Both are pure functions over a
// temp file, which is the point of the object: BaseService reads the marker with no Flutter
// engine and no Android API in reach.

package io.flrone.bridge

import io.flrone.flutter.ServiceEngineManager
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class BootGateTest {

    private lateinit var filesDir: File
    private lateinit var marker: File
    private val now = 1_767_000_000_000L

    @Before
    fun setUp() {
        filesDir = File.createTempFile("bootgate", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        marker = BootGate.mirrorFile(filesDir)
    }

    @After
    fun tearDown() {
        filesDir.deleteRecursively()
    }

    /** The exact shape Dart's `BootRecord.encode()` writes. */
    private fun record(stage: String, startedAt: Long): String =
        """{"stage":"$stage","profileId":7,"startedAt":$startedAt,"failureCount":1}"""

    private fun write(raw: String) {
        marker.parentFile!!.mkdirs()
        marker.writeText(raw)
    }

    // --- shouldSkipAutoStart -------------------------------------------------

    @Test
    fun `the marker sits beside the other documents`() {
        assertEquals(File(File(filesDir, "documents"), "boot_guard.json"), marker)
    }

    @Test
    fun `no marker means no evidence`() {
        assertFalse(BootGate.shouldSkipAutoStart(marker, now))
    }

    @Test
    fun `a fresh starting marker is evidence`() {
        write(record("starting", now - 30_000))
        assertTrue(BootGate.shouldSkipAutoStart(marker, now))
    }

    @Test
    fun `a running marker is not evidence`() {
        write(record("running", now - 30_000))
        assertFalse(BootGate.shouldSkipAutoStart(marker, now))
    }

    @Test
    fun `a stale starting marker is not evidence`() {
        write(record("starting", now - BootGate.FRESHNESS_MS - 1))
        assertFalse(BootGate.shouldSkipAutoStart(marker, now))
    }

    @Test
    fun `the freshness window is inclusive`() {
        write(record("starting", now - BootGate.FRESHNESS_MS))
        assertTrue(BootGate.shouldSkipAutoStart(marker, now))
    }

    @Test
    fun `the default freshness is the boot guard window`() {
        write(record("starting", now - 9 * 60_000))
        assertTrue(BootGate.shouldSkipAutoStart(marker, now))
        write(record("starting", now - 11 * 60_000))
        assertFalse(BootGate.shouldSkipAutoStart(marker, now))
    }

    @Test
    fun `a marker dated in the future is not evidence`() {
        write(record("starting", now + 1))
        assertFalse(BootGate.shouldSkipAutoStart(marker, now))
    }

    @Test
    fun `a zero start time is not evidence`() {
        write(record("starting", 0))
        assertFalse(BootGate.shouldSkipAutoStart(marker, now))
    }

    @Test
    fun `malformed json is not evidence`() {
        write("{ broken")
        assertFalse(BootGate.shouldSkipAutoStart(marker, now))
        write("[]")
        assertFalse(BootGate.shouldSkipAutoStart(marker, now))
    }

    @Test
    fun `a wrong-typed record is not evidence`() {
        write("""{"stage":1,"startedAt":${now - 1000}}""")
        assertFalse(BootGate.shouldSkipAutoStart(marker, now))
        write("""{"stage":"starting","startedAt":"${now - 1000}"}""")
        assertFalse(BootGate.shouldSkipAutoStart(marker, now))
        write("""{"stage":"starting"}""")
        assertFalse(BootGate.shouldSkipAutoStart(marker, now))
    }

    // --- mirror --------------------------------------------------------------

    @Test
    fun `mirroring a string writes the record verbatim`() {
        val raw = record("starting", now - 1000)
        assertTrue(BootGate.mirror(marker, raw))
        assertEquals(raw, marker.readText())
        assertTrue(BootGate.shouldSkipAutoStart(marker, now))
    }

    @Test
    fun `mirroring creates the documents directory`() {
        assertFalse(marker.parentFile!!.isDirectory)
        assertTrue(BootGate.mirror(marker, record("starting", now)))
        assertTrue(marker.isFile)
    }

    @Test
    fun `a rewrite replaces the previous record`() {
        assertTrue(BootGate.mirror(marker, record("starting", now - 1000)))
        assertTrue(BootGate.mirror(marker, record("running", now)))
        assertFalse(BootGate.shouldSkipAutoStart(marker, now))
    }

    @Test
    fun `mirroring a non-string deletes the file`() {
        assertTrue(BootGate.mirror(marker, record("starting", now)))
        assertTrue(marker.isFile)
        assertTrue(BootGate.mirror(marker, null))
        assertFalse(marker.exists())
        // An absent record is already the intended state.
        assertTrue(BootGate.mirror(marker, null))
    }

    @Test
    fun `a value the mirror cannot reproduce deletes the file`() {
        assertTrue(BootGate.mirror(marker, record("starting", now)))
        assertTrue(BootGate.mirror(marker, mapOf("stage" to "starting")))
        assertFalse(marker.exists())
    }

    @Test
    fun `mirroring leaves no temp file behind`() {
        assertTrue(BootGate.mirror(marker, record("starting", now)))
        val leftovers = marker.parentFile!!.listFiles().orEmpty().filter { it.name.endsWith(".tmp") }
        assertTrue("temp files left: $leftovers", leftovers.isEmpty())
    }

    // --- gateEngineArgs ------------------------------------------------------

    @Test
    fun `a blocked silent start gains prewarm`() {
        assertEquals(
            listOf(ServiceEngineManager.ARG_QUICK, ServiceEngineManager.ARG_PREWARM),
            BootGate.gateEngineArgs(listOf(ServiceEngineManager.ARG_QUICK), true),
        )
        assertEquals(
            listOf(ServiceEngineManager.ARG_QUICK, ServiceEngineManager.ARG_BOOT, ServiceEngineManager.ARG_PREWARM),
            BootGate.gateEngineArgs(listOf(ServiceEngineManager.ARG_QUICK, ServiceEngineManager.ARG_BOOT), true),
        )
        assertEquals(
            listOf(ServiceEngineManager.ARG_BOOT, ServiceEngineManager.ARG_PREWARM),
            BootGate.gateEngineArgs(listOf(ServiceEngineManager.ARG_BOOT), true),
        )
    }

    @Test
    fun `a deliberate start is never gated`() {
        assertEquals(emptyList<String>(), BootGate.gateEngineArgs(emptyList(), true))
        assertEquals(listOf("other"), BootGate.gateEngineArgs(listOf("other"), true))
    }

    @Test
    fun `an unblocked start keeps its args`() {
        assertEquals(
            listOf(ServiceEngineManager.ARG_QUICK),
            BootGate.gateEngineArgs(listOf(ServiceEngineManager.ARG_QUICK), false),
        )
    }

    @Test
    fun `a start that is already a prewarm is left alone`() {
        assertEquals(
            listOf(ServiceEngineManager.ARG_PREWARM),
            BootGate.gateEngineArgs(listOf(ServiceEngineManager.ARG_PREWARM), true),
        )
        assertEquals(
            listOf(ServiceEngineManager.ARG_QUICK, ServiceEngineManager.ARG_PREWARM),
            BootGate.gateEngineArgs(listOf(ServiceEngineManager.ARG_QUICK, ServiceEngineManager.ARG_PREWARM), true),
        )
    }
}
