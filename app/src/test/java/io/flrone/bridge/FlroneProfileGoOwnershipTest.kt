package io.flrone.bridge

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The S8 end state, pinned at the source level where a JVM test cannot run the
 * device-backed write path:
 *
 *  * the Kotlin outbound model/import package is gone; no production source
 *    imports `io.nekohasekai.sagernet.outbound` any more;
 *  * the node editor's codec is the Go action layer ([FlroneProfileActions]) —
 *    templates, importer, stored normalizer/validator/exporter — and a
 *    `supported:false` refusal is the error text, not a second implementation;
 *  * [FlroneNodeTuning] reads and writes the stored document itself;
 *  * `ProxyEntity` derives every label/address/dedup fact from the stored
 *    columns through `StoredProfile`.
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
    fun `no production source imports the deleted outbound model`() {
        val root = File("src/main/java")
        val offenders = root.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { it.readText().contains("io.nekohasekai.sagernet.outbound") }
            .map { it.relativeTo(root).path }
            .toList()
        assertTrue("the outbound model package must stay deleted; still imported by $offenders", offenders.isEmpty())
        assertFalse(
            "the legacy node-editor fallback must stay deleted",
            File("src/main/java/io/flrone/bridge/FlroneNodeEditorLegacy.kt").exists(),
        )
        assertFalse(
            "the outbound-hook settings mapper must stay deleted",
            File("src/main/java/io/nekohasekai/sagernet/database/SettingsMapper.kt").exists(),
        )
    }

    @Test
    fun `the node editor is served by the Go actions only`() {
        val profiles = source("bridge/FlroneProfiles.kt")
        for (legacy in listOf(
            "FlroneNodeEditorLegacy",
            "OutboundFactory",
            "ProfileImport",
            "SettingsMapper",
        )) {
            assertFalse("`$legacy` must not return to FlroneProfiles", profiles.contains(legacy))
        }

        val parseOne = body(profiles, "private fun parseOne(")
        assertTrue("parseOne uses the Go editor parse", parseOne.contains("FlroneProfileActions.parseEditorNode("))

        val create = body(profiles, "suspend fun createNode(")
        assertTrue(create.contains("FlroneProfileActions.newOutbound("))
        assertTrue(create.contains("FlroneProfileActions.createNodeDraft("))

        val parse = body(profiles, "suspend fun parseNodeText(")
        assertTrue(parse.contains("FlroneProfileActions.importText("))

        val commit = body(profiles, "suspend fun commitNode(")
        assertTrue(commit.contains("parseOne("))
        assertTrue(commit.contains("validateAndCanonicalize("))
        assertTrue(commit.contains("ProfileManager.addStoredProfile("))

        val update = body(profiles, "suspend fun updateNode(")
        assertTrue(update.contains("normalizeStored("))
        assertTrue(update.contains("renameNode("))
        assertTrue(update.contains("ProfileManager.updateProfile("))

        val config = body(profiles, "suspend fun nodeConfig(")
        assertTrue(config.contains("FlroneProfileActions.normalizeStored("))

        val info = body(profiles, "fun nodeInfo(")
        assertTrue(info.contains("FlroneProfileActions.exportStored("))
        assertTrue(info.contains("rawNodeInfo("))

        val decode = body(profiles, "private fun decode(")
        assertTrue(decode.contains("FlroneProfileActions.parseEditorNode("))

        val save = body(profiles, "suspend fun save(")
        assertTrue("the group content import goes through the same Go editor parse", save.contains("parseGroupContent("))
    }

    @Test
    fun `ProxyEntity keeps only the stored-column readers`() {
        val entity = source("../nekohasekai/sagernet/database/ProxyEntity.kt")
        for (modelAccessor in listOf(
            "fun parseOutbound(",
            "fun putOutbound(",
            "val outbound:",
            "fun exportLink(",
            "fun exportJsonLink(",
            "fun isEndpoint(",
        )) {
            assertFalse("`$modelAccessor` must not return to ProxyEntity", entity.contains(modelAccessor))
        }
        assertTrue(entity.contains("StoredProfile.displayName("))
        assertTrue(entity.contains("StoredProfile.dedupKey("))
    }

    @Test
    fun `tuning reads the stored document instead of the outbound model`() {
        val profiles = source("bridge/FlroneProfiles.kt")
        assertFalse(profiles.contains("suspend fun nodeTuningInfo("))
        assertFalse(profiles.contains("suspend fun nodeTuningSave("))

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

    @Test
    fun `the profile relay answers null for the method codec`() = runBlocking {
        // StandardMethodCodec cannot encode kotlin.Unit: the relayed write used
        // to answer Unit and the node page threw "Unsupported value".
        val original = DartProfileWriter.testTransport
        DartProfileWriter.testTransport = { _, _ -> true }
        try {
            assertNull(DartProfileWriter.relay("profiles.applyDocument", emptyMap()))
        } finally {
            DartProfileWriter.testTransport = original
        }
    }
}