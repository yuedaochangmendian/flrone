package io.flrone.bridge

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * S7 moved the auto-selector editor's document state into Dart's
 * `ProfileDocumentService`: the selector row is the same `profiles.json` document
 * Dart owns, so `info`/`save`/`pin`/`create` must not come back on the host side.
 *
 * What legitimately remains in Kotlin is the runtime shadow only — the live status
 * read, the pin notice the host reports, and a recheck request — because the core
 * itself belongs to the service engine. These are source contracts (the code needs
 * Android and a running kernel to execute), so they pin the split.
 */
class AutoSelectorRuntimeBoundaryTest {

    private val root = File("").absoluteFile

    private fun source(path: String): String {
        val file = File(root, path)
        assertTrue("source not found: ${file.absolutePath}", file.exists())
        return file.readText()
    }

    @Test
    fun `FlroneProfiles keeps only the runtime auto-selector boundary`() {
        val text = source("src/main/java/io/flrone/bridge/FlroneProfiles.kt")
        for (runtime in listOf(
            "suspend fun autoSelectorStatus(",
            "suspend fun autoSelectorRuntimePin(",
            "suspend fun autoSelectorRecheck(",
        )) {
            assertTrue("missing runtime boundary $runtime", text.contains(runtime))
        }
        for (documentOp in listOf(
            "suspend fun autoSelectorInfo(",
            "suspend fun autoSelectorSave(",
            "suspend fun autoSelectorPin(",
            "suspend fun createAutoSelector(",
        )) {
            assertFalse(
                "$documentOp is Dart-owned (ProfileDocumentService) and must not return to Kotlin",
                text.contains(documentOp),
            )
        }
        val runtimePin = functionBody(text, "suspend fun autoSelectorRuntimePin(")
        assertTrue(
            "autoSelectorRuntimePin must forward the pin to AutoSelectorRuntime.select",
            runtimePin.contains("AutoSelectorRuntime.select("),
        )
    }

    @Test
    fun `the duty table exposes only the runtime selector ops`() {
        val text = source("src/main/java/io/flrone/bridge/FlroneProfileDuty.kt")
        for (runtime in listOf(
            "\"autoSelectorStatus\" to",
            "\"autoSelectorRuntimePin\" to",
            "\"autoSelectorRecheck\" to",
        )) {
            assertTrue("missing runtime duty $runtime", text.contains(runtime))
        }
        for (documentOp in listOf(
            "\"autoSelectorInfo\" to",
            "\"autoSelectorSave\" to",
            "\"autoSelectorPin\" to",
            "\"autoSelectorCreate\" to",
        )) {
            assertFalse(
                "$documentOp must not be a profiles.platform duty any more",
                text.contains(documentOp),
            )
        }
        // The pin op reads exactly the key Dart sends; a rename would only surface at runtime.
        val pinHandler = functionBody(text, "\"autoSelectorRuntimePin\" to")
        assertTrue(
            "autoSelectorRuntimePin must read the Dart payload key memberId",
            pinHandler.contains("requireLong(\"memberId\")"),
        )
    }

    @Test
    fun `the selector writes no longer claim the document owner`() {
        val text = source("src/main/java/io/flrone/bridge/FlroneProfileDuty.kt")
        val writes = functionBody(text, "private val documentWriteOps")
        assertFalse(
            "the selector's document writes are Dart's; no Kotlin op may require the owner for them",
            writes.contains("autoSelector"),
        )
    }

    /** The text from [declaration] up to the next member declaration at the same indent. */
    private fun functionBody(text: String, declaration: String): String {
        val start = text.indexOf(declaration)
        assertTrue("declaration not found: $declaration", start >= 0)
        val rest = text.substring(start + declaration.length)
        val next = Regex("(?m)^    (?:suspend fun|fun|private val|val|private fun) ")
            .find(rest)
        return if (next == null) rest else rest.substring(0, next.range.first)
    }
}
