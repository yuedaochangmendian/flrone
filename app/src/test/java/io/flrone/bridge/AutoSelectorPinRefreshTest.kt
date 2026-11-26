package io.flrone.bridge

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A pin writes `outbound_json` straight to the Dart-owned profiles document, so no
 * GroupRepo/ProfileManager listener fires. The old `autoSelectorPin` saved the document
 * and then only called [AutoSelectorRuntime.select] + `autoSelectorInfo`, leaving the
 * catalog (and the selector card that reads it) stale until an unrelated refresh —
 * unlike `autoSelectorSave`, which already scheduled an immediate refresh.
 *
 * The pin path cannot be executed in a JVM unit test (it needs the auto-selector
 * profile in the Dart document and the running runtime), so this guard pins the
 * source contract: the immediate refresh must be part of `autoSelectorPin`.
 */
class AutoSelectorPinRefreshTest {

    @Test
    fun `autoSelectorPin schedules an immediate catalog refresh`() {
        val source = File("src/main/java/io/flrone/bridge/FlroneProfiles.kt")
        assertTrue("source not found: ${source.absolutePath}", source.exists())
        val lines = source.readLines()
        val start = lines.indexOfFirst { it.contains("suspend fun autoSelectorPin(") }
        assertTrue("autoSelectorPin not found", start >= 0)
        // The function ends at the next top-level declaration (next line starting with "    /**"
        // or "    suspend fun"/"    fun" at four-space member indentation).
        var end = lines.size
        for (i in start + 1 until lines.size) {
            val trimmed = lines[i].trimStart()
            if ((lines[i].startsWith("    suspend fun ") || lines[i].startsWith("    fun ")) && i > start) {
                end = i
                break
            }
        }
        val body = lines.subList(start, end).joinToString("\n")
        assertTrue(
            "autoSelectorPin must call FlroneBridge.scheduleRefresh(immediate = true) " +
                "after its document write, like autoSelectorSave",
            body.contains("FlroneBridge.scheduleRefresh(immediate = true)"),
        )
    }
}
