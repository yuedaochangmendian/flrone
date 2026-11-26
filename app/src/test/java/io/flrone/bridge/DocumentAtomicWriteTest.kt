package io.flrone.bridge

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.io.IOException

/**
 * A rename/move failure must never truncate the authoritative document (Phase 1 WP1.4).
 * The old fallback `file.writeText(payload)` wrote straight into `settings.json` /
 * `host_facts.json`, so a failed rename on Windows (or a locked target) could
 * leave a half-written file where the only copy used to be.
 *
 * [DocumentAtomicWrite.move] is the seam: a forced failure proves the target is
 * untouched, a transient failure proves one fresh-name retry is enough, and
 * the default NIO move with REPLACE_EXISTING must work on Windows too.
 */
class DocumentAtomicWriteTest {

    private lateinit var dir: File
    private lateinit var original: DocumentAtomicWrite.Move

    @Before
    fun setUp() {
        dir = File.createTempFile("atomic-write", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        original = DocumentAtomicWrite.move
    }

    @After
    fun tearDown() {
        DocumentAtomicWrite.move = original
        dir.deleteRecursively()
    }

    @Test
    fun `a successful move replaces the target`() {
        val target = File(dir, "host_facts.json")
        target.writeText("old")
        DocumentAtomicWrite.write(target, "new")
        assertEquals("new", target.readText())
        assertFalse(dir.listFiles()!!.any { it.name.endsWith(".tmp") })
    }

    @Test
    fun `a transient move failure retries with a fresh temp and succeeds`() {
        val target = File(dir, "host_facts.json")
        target.writeText("old")
        var calls = 0
        DocumentAtomicWrite.move = DocumentAtomicWrite.Move { from, to ->
            calls++
            if (calls == 1) throw IOException("simulated transient failure")
            original.invoke(from, to)
        }
        DocumentAtomicWrite.write(target, "new")
        assertEquals("new", target.readText())
        assertEquals(2, calls)
    }

    @Test
    fun `a persistent move failure keeps the old target intact`() {
        val target = File(dir, "settings.json")
        target.writeText("the-only-good-copy")
        DocumentAtomicWrite.move = DocumentAtomicWrite.Move { _, _ -> throw IOException("simulated failure") }

        val error = runCatching { DocumentAtomicWrite.write(target, "corrupt-half") }.exceptionOrNull()

        assertTrue("the failed write must surface an error", error != null)
        assertEquals("the-only-good-copy", target.readText())
        assertFalse("temp files must be cleaned up", dir.listFiles()!!.any { it.name.endsWith(".tmp") })
    }

    @Test
    fun `a move failure leaves a missing document missing`() {
        val target = File(dir, "markers.json")
        DocumentAtomicWrite.move = DocumentAtomicWrite.Move { _, _ -> throw IOException("simulated failure") }

        val error = runCatching { DocumentAtomicWrite.write(target, "payload") }.exceptionOrNull()

        assertTrue(error != null)
        assertFalse("a failed first write must not leave a partial document", target.exists())
    }

    @Test
    fun `HostFactsStore write surfaces the error rather than truncating the document`() {
        val originalDirectory = HostFactsStore.directory
        val originalLogger = HostFactsStore.logger
        try {
            HostFactsStore.directory = dir
            HostFactsStore.logger = { _, _ -> }
            val target = File(dir, "host_facts.json")
            val originalPayload = """{"rows":{"batteryExempt":true}}"""
            target.writeText(originalPayload)
            DocumentAtomicWrite.move = DocumentAtomicWrite.Move { _, _ -> throw IOException("simulated failure") }

            val error = runCatching { HostFactsStore.writeHostFacts(mapOf("batteryExempt" to false)) }.exceptionOrNull()

            assertTrue(error != null)
            assertEquals(originalPayload, target.readText())
        } finally {
            HostFactsStore.directory = originalDirectory
            HostFactsStore.logger = originalLogger
        }
    }
}
