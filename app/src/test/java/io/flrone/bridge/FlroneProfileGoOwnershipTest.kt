package io.flrone.bridge

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The S8 routing split, pinned at the source level where a JVM test cannot run
 * the device-backed write path:
 *
 *  * `FlroneProfiles` asks the Go profile actions first for every node-editor
 *    operation Go covers and names the legacy fallback only on a refusal;
 *  * the Kotlin outbound model/import references live in exactly one clearly
 *    named fallback file ([FlroneNodeEditorLegacy]); the tuning helper
 *    ([FlroneNodeTuning]) reads and writes the stored document and holds none of
 *    them, so the final S8 batch knows exactly what is left;
 *  * the group-content import (`save`) still uses the multi-node Kotlin
 *    importer and keeps that dependency explicit.
 */
class FlroneProfileGoOwnershipTest {

    private fun source(path: String): String {
        val file = File("src/main/java/io/flrone/$path")
        assertTrue("source not found: ${file.absolutePath}", file.exists())
        return file.readText()
    }

    /** The function body from its declaration line to the next top-level member. */
    private fun body(source: String, marker: String): String {
        val lines = source.lines()
        val start = lines.indexOfFirst { it.contains(marker) }
        assertTrue("`$marker` not found", start >= 0)
        val memberStart = Regex("^    (private |internal )?(suspend )?fun |^    /\\*\\*|^    // ---")
        var end = lines.size
        for (index in start + 1 until lines.size) {
            if (memberStart.containsMatchIn(lines[index])) {
                end = index
                break
            }
        }
        return lines.subList(start, end).joinToString("\n")
    }

    @Test
    fun `the node editor asks the Go actions first`() {
        val profiles = source("bridge/FlroneProfiles.kt")
        for (import in listOf(
            "import io.nekohasekai.sagernet.outbound.Outbound",
            "import io.nekohasekai.sagernet.outbound.OutboundFactory",
            "import io.nekohasekai.sagernet.outbound.import.ProfileImport",
            "import io.nekohasekai.sagernet.database.SettingsMapper",
            "import io.nekohasekai.sagernet.document.json.JsonInput",
        )) {
            assertFalse("`$import` must not return to FlroneProfiles", profiles.contains(import))
        }

        val create = body(profiles, "suspend fun createNode(")
        assertTrue("createNode routes Go-first", create.contains("FlroneProfileActions.newOutbound("))
        assertTrue("createNode routes Go-first", create.contains("FlroneProfileActions.createNodeDraft("))
        assertTrue("createNode routes Go-first", create.contains("FlroneNodeEditorLegacy.createNode("))

        val parse = body(profiles, "suspend fun parseNodeText(")
        assertTrue("parseNodeText routes Go-first", parse.contains("FlroneProfileActions.importText("))
        assertTrue("parseNodeText routes Go-first", parse.contains("FlroneNodeEditorLegacy.parseNodeText("))

        val commit = body(profiles, "suspend fun commitNode(")
        assertTrue("commitNode routes Go-first", commit.contains("FlroneProfileActions.parseEditorNode("))
        assertTrue("commitNode routes Go-first", commit.contains("FlroneProfileActions.validateStored("))
        assertTrue("commitNode routes Go-first", commit.contains("ProfileManager.addStoredProfile("))
        assertTrue("commitNode routes Go-first", commit.contains("FlroneNodeEditorLegacy.commitNode("))
        assertTrue("commitNode routes Go-first", commit.contains("FlroneNodeEditorLegacy.commitImportedNode("))

        val update = body(profiles, "suspend fun updateNode(")
        assertTrue("updateNode routes Go-first", update.contains("FlroneProfileActions.parseEditorNode("))
        assertTrue("updateNode routes Go-first", update.contains("FlroneProfileActions.validateStored("))
        assertTrue("updateNode routes Go-first", update.contains("FlroneProfileActions.renameStored("))
        assertTrue("updateNode routes Go-first", update.contains("FlroneProfileActions.rowTypeMatches("))
        assertTrue("updateNode routes Go-first", update.contains("FlroneNodeEditorLegacy.updateNode("))
        assertTrue("updateNode routes Go-first", update.contains("FlroneNodeEditorLegacy.updateImportedNode("))

        val config = body(profiles, "suspend fun nodeConfig(")
        assertTrue("nodeConfig routes Go-first", config.contains("FlroneProfileActions.rowTypeMatches("))
        assertTrue("nodeConfig routes Go-first", config.contains("FlroneProfileActions.normalizeStored("))
        assertTrue("nodeConfig routes Go-first", config.contains("FlroneNodeEditorLegacy.nodeConfig("))

        val info = body(profiles, "fun nodeInfo(")
        assertTrue("nodeInfo routes Go-first", info.contains("FlroneProfileActions.rowTypeMatches("))
        assertTrue("nodeInfo routes Go-first", info.contains("FlroneProfileActions.exportStored("))
        assertTrue("nodeInfo routes Go-first", info.contains("FlroneNodeEditorLegacy.nodeInfo("))

        val decode = body(profiles, "private fun decode(")
        assertTrue("decode routes Go-first", decode.contains("FlroneProfileActions.parseEditorNode("))
        assertTrue("decode routes Go-first", decode.contains("FlroneNodeEditorLegacy.decode("))

        val save = body(profiles, "suspend fun save(")
        assertTrue(
            "the group's multi-node content import must stay on the isolated legacy importer",
            save.contains("FlroneNodeEditorLegacy.parseOutbounds("),
        )
    }

    @Test
    fun `the model implementation stays in the fallback helper`() {
        val legacy = source("bridge/FlroneNodeEditorLegacy.kt")
        for (reference in listOf(
            "import io.nekohasekai.sagernet.outbound.OutboundFactory",
            "import io.nekohasekai.sagernet.outbound.import.ProfileImport",
            "import io.nekohasekai.sagernet.outbound.Outbound",
            "import io.nekohasekai.sagernet.database.SettingsMapper",
        )) {
            assertTrue("`$reference` belongs to the fallback helper", legacy.contains(reference))
        }
        for (function in listOf(
            "suspend fun createNode(",
            "suspend fun parseNodeText(",
            "suspend fun commitNode(",
            "suspend fun commitImportedNode(",
            "suspend fun updateNode(",
            "suspend fun updateImportedNode(",
            "suspend fun nodeConfig(",
            "suspend fun nodeInfo(",
            "fun decode(",
            "fun parseOutbounds(",
        )) {
            assertTrue("legacy `$function` must stay reachable", legacy.contains(function))
        }
    }

    @Test
    fun `tuning reads the stored document instead of the outbound model`() {
        val profiles = source("bridge/FlroneProfiles.kt")
        assertFalse(profiles.contains("suspend fun nodeTuningInfo("))
        assertFalse(profiles.contains("suspend fun nodeTuningSave("))

        // The final S8 batch: the mux/fragment/TLS-tricks overrides are read from and written into
        // the stored outbound_json, so no outbound model class or reflection is left here.
        val tuning = source("bridge/FlroneNodeTuning.kt")
        for (reference in listOf(
            "import io.nekohasekai.sagernet.outbound",
            "MUX_CUSTOM",
            "javaClass.fields",
            "getMux()",
            "getTls()",
        )) {
            assertFalse("`$reference` must not return to FlroneNodeTuning", tuning.contains(reference))
        }
        assertTrue(tuning.contains("outbound_json"))
        assertTrue(tuning.contains("suspend fun info("))
        assertTrue(tuning.contains("suspend fun save("))

        val duty = source("bridge/FlroneProfileDuty.kt")
        assertTrue(duty.contains("\"nodeTuningInfo\" to { payload -> FlroneNodeTuning.info("))
        assertTrue(duty.contains("\"nodeTuningSave\" to {"))
        assertTrue(duty.contains("FlroneNodeTuning.save("))
    }

    @Test
    fun `the raw row writer exists for canonical Go documents`() {
        val manager = source("../nekohasekai/sagernet/database/ProfileManager.kt")
        val add = body(manager, "suspend fun addStoredProfile(")
        assertTrue(add.contains("ProxyEntity("))
        assertTrue(add.contains("outboundJson = outboundJson"))
        assertTrue(add.contains("DartProfileWriter.addProfiles("))
        assertTrue(add.contains("GroupSort.repositionLater("))
    }
}