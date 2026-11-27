package io.flrone.bridge

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The ownership split of the old document-only `profiles.platform` ops.
 *
 * `stats`, `reorder`, `clearTestResults`, `nodeList` and `nodeReorder` are
 * Dart-owned now (`flutter/lib/data/profile_document_service.dart`): they read
 * and write the same `profiles.json` document the ConfigurationStore already
 * owns, so a Kotlin handler would be a second reader/writer. One narrow Kotlin
 * remainder stays: `sort.reposition` runs GroupSort's BY_TEST_RESULT/BY_LATENCY
 * reposition after Dart cleared the columns (the sort keys are the parsed
 * outbound model, which Dart does not have).
 *
 * Like the other source contracts in this package these functions need a
 * device document store, so the JVM test pins the source shape.
 */
class ProfileDutyOwnershipTest {

    private fun source(path: String): String {
        val file = File("src/main/java/io/flrone/$path")
        assertTrue("source not found: ${file.absolutePath}", file.exists())
        return file.readText()
    }

    @Test
    fun `the document-only ops are no longer platform duties`() {
        val duty = source("bridge/FlroneProfileDuty.kt")
        for (op in listOf("stats", "reorder", "clearTestResults", "nodeList", "nodeReorder")) {
            assertFalse(
                "`$op` must not return to the Kotlin duty table: Dart owns the document read/write",
                duty.contains("\"$op\" to {"),
            )
        }
        val profiles = source("bridge/FlroneProfiles.kt")
        for (helper in listOf(
            "suspend fun reorder(",
            "suspend fun reorderNodes(",
            "suspend fun clearGroupTestResults(",
            "suspend fun listNodes(",
        )) {
            assertFalse(
                "`$helper` has no caller once the op is Dart-owned and must stay deleted",
                profiles.contains(helper),
            )
        }
    }

    @Test
    fun `the narrow sort reposition duty stays`() {
        val duty = source("bridge/FlroneProfileDuty.kt")
        assertTrue(
            "clearTestResults' GroupSort half must still be reachable from Dart",
            duty.contains("\"sort.reposition\" to {"),
        )
        val profiles = source("bridge/FlroneProfiles.kt")
        assertTrue(
            "the reposition duty calls the kept GroupSort path, not a second sort",
            profiles.contains("suspend fun repositionTestResults(") &&
                profiles.contains("GroupSort.repositionLater("),
        )
    }
}