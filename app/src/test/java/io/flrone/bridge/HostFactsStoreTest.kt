// HostFactsStore owns the one Kotlin-written document (host_facts.json).
// The contract is narrow: read a document the host wrote, answer empty on
// absent/corrupt, and write atomically through DocumentAtomicWrite.

package io.flrone.bridge

import java.io.File
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class HostFactsStoreTest {

    private lateinit var temp: File
    private lateinit var originalLogger: (String, Throwable?) -> Unit

    @Before
    fun setUp() {
        temp = File.createTempFile("host-facts", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        HostFactsStore.directory = temp
        originalLogger = HostFactsStore.logger
        HostFactsStore.logger = { _, _ -> }
    }

    @After
    fun tearDown() {
        HostFactsStore.directory = null
        HostFactsStore.logger = originalLogger
        temp.deleteRecursively()
    }

    private fun writeHostFacts(rows: Map<String, Any?>) {
        val payload = JSONObject().apply {
            put("version", 1)
            put("name", "host_facts")
            put("rows", JSONObject(rows))
        }
        File(temp, "host_facts.json").writeText(payload.toString())
    }

    @Test
    fun `reads host facts written by the host`() {
        writeHostFacts(mapOf("batteryExempt" to true, "locale" to "en"))
        val facts = HostFactsStore.readHostFacts()
        assertEquals(true, facts["batteryExempt"])
        assertEquals("en", facts["locale"])
    }

    @Test
    fun `missing document reads as empty`() {
        assertTrue(HostFactsStore.readHostFacts().isEmpty())
    }

    @Test
    fun `a corrupt document reads as empty`() {
        writeHostFacts(mapOf("batteryExempt" to true))
        assertEquals(true, HostFactsStore.readHostFacts()["batteryExempt"])

        File(temp, "host_facts.json").writeText("{ broken")
        assertTrue(HostFactsStore.readHostFacts().isEmpty())
    }

    @Test
    fun `write then read round-trips`() {
        HostFactsStore.writeHostFacts(mapOf("batteryExempt" to true, "count" to 42))
        val facts = HostFactsStore.readHostFacts()
        assertEquals(true, facts["batteryExempt"])
        assertEquals(42, facts["count"])
    }

    @Test
    fun `the document keeps the Go wire envelope`() {
        HostFactsStore.writeHostFacts(mapOf("batteryExempt" to true))
        val root = JSONObject(File(temp, "host_facts.json").readText())
        assertEquals(1, root.getInt("version"))
        assertEquals("host_facts", root.getString("name"))
    }
}
