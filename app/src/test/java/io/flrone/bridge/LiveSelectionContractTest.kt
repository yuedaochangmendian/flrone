package io.flrone.bridge

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The live-selector boundary after the Kotlin Clash API path was removed.
 *
 * The switch itself is the Go `groupsSelect` action (groups_actions.go): the running
 * core's outbound manager flips the selector, so no HTTP client, no `experimental.clash_api`
 * client and no channel arm may come back. Kotlin keeps only the persistence half, split in
 * two so a live switch cannot trigger the reload it exists to avoid.
 *
 * These are source contracts, like [AutoSelectorPinRefreshTest]: the functions need Android
 * data (the Dart-owned profiles document, a running service) that a JVM test cannot build.
 */
class LiveSelectionContractTest {

    private fun source(path: String): String {
        val file = File("src/main/java/io/flrone/$path")
        assertTrue("source not found: ${file.absolutePath}", file.exists())
        return file.readText()
    }

    /** One member's declaration plus body, bounded by the next member at class indent. */
    private fun memberBody(text: String, marker: String): String {
        val lines = text.lines()
        val start = lines.indexOfFirst { it.contains(marker) }
        assertTrue("$marker not found", start >= 0)
        var end = lines.size
        for (i in start + 1 until lines.size) {
            val line = lines[i]
            // Nested statements are indented deeper than the class body; only a
            // member-level declaration (or its KDoc) ends the slice.
            if (!line.startsWith("    ") || line.startsWith("        ")) continue
            val trimmed = line.trim()
            if (trimmed.startsWith("/**") ||
                trimmed.startsWith("fun ") ||
                trimmed.startsWith("suspend fun ") ||
                trimmed.startsWith("private fun ") ||
                trimmed.startsWith("internal fun ")
            ) {
                end = i
                break
            }
        }
        return lines.subList(start, end).joinToString("\n")
    }

    @Test
    fun `the clash api client and the groups select arm are gone`() {
        assertFalse(
            "FlroneApi.kt must stay deleted: the Clash API is served by the core for " +
                "external clients and settings, the app no longer calls it",
            File("src/main/java/io/flrone/bridge/FlroneApi.kt").exists(),
        )
        val bridge = source("flutter/FlronePlatformBridge.kt")
        assertFalse(
            "the groups.select channel arm must not come back: the switch is the Go groupsSelect action",
            bridge.contains("\"groups.select\""),
        )
        val commands = source("bridge/FlroneCommands.kt")
        assertFalse("selectProxy must stay deleted", commands.contains("selectProxy"))
        assertFalse("selectProxyAwait must stay deleted", commands.contains("selectProxyAwait"))
    }

    @Test
    fun `the kernel prepare no longer enables the Clash API for selection`() {
        val body = memberBody(source("bridge/FlroneKernel.kt"), "suspend fun prepareStart(")
        assertFalse(
            "prepareStart must not touch the Clash API: the live switch is a core action",
            body.contains("enableForLiveSelection") || body.contains("FlroneApi"),
        )
    }

    @Test
    fun `persistSelection writes the settings without a reload`() {
        val body = memberBody(source("bridge/FlroneCommands.kt"), "suspend fun persistSelection(")
        assertTrue(
            "the persistence half must write the selection without announcing it",
            body.contains("applySelection(profileId, announce = false)"),
        )
        assertFalse(
            "a live switch that broadcast SWITCH_PROFILE would rebuild the config it just skipped",
            body.contains("SWITCH_PROFILE"),
        )
        assertFalse("persistSelection must not take the reload path", body.contains("selectSuspend("))
        assertFalse("persistSelection must not reload", body.contains("reloadService"))
        assertTrue(
            "the catalog still needs to follow the new selection",
            body.contains("scheduleRefresh(immediate = true)"),
        )
    }

    @Test
    fun `selectMember keeps the reload path for every non-live status`() {
        val body = memberBody(source("bridge/FlroneCommands.kt"), "suspend fun selectMemberAwait(")
        assertTrue(
            "the fallback must still persist and raise the service's reload",
            body.contains("selectSuspend(profileId)"),
        )
    }

    @Test
    fun `the duty table exposes both halves of the selection`() {
        val duty = source("bridge/FlroneProfileDuty.kt")
        assertTrue("persistSelection must be reachable from Dart", duty.contains("\"persistSelection\" to"))
        assertTrue("selectMember must be reachable from Dart", duty.contains("\"selectMember\" to"))
    }
}