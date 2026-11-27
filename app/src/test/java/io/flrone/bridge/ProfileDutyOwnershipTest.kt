package io.flrone.bridge

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The ownership split of the document-only `profiles.platform` ops.
 *
 * `stats`, `reorder`, `clearTestResults`, `nodeList`, `nodeReorder` and the
 * configuration editor's `config`/`read`/`write` are Dart-owned now
 * (`flutter/lib/data/profile_document_service.dart`): they read and write the
 * same `profiles.json` document the ConfigurationStore already owns, so a Kotlin
 * handler would be a second reader/writer. What stays are the side effects a
 * document write cannot perform itself: `sort.reposition` (GroupSort's
 * BY_TEST_RESULT/BY_LATENCY reposition after Dart cleared the columns, because
 * the sort keys are the parsed outbound model Dart does not have),
 * `revision.edit` (the `GroupRevisions` newest-intent bump that must precede the
 * configuration write) and `subscription.schedule` (the poller re-plan after a
 * URL edit).
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
        for (op in listOf(
            "stats",
            "reorder",
            "clearTestResults",
            "nodeList",
            "nodeReorder",
            "config",
            "read",
            "write",
        )) {
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
            "suspend fun config(",
            "suspend fun read(",
            "suspend fun write(",
            "suspend fun stats(",
            "private suspend fun document(",
            "private fun canonicalJson(",
            "data class Config(",
        )) {
            assertFalse(
                "`$helper` has no caller once the op is Dart-owned and must stay deleted",
                profiles.contains(helper),
            )
        }
    }

    @Test
    fun `the narrow side-effect duties stay`() {
        val duty = source("bridge/FlroneProfileDuty.kt")
        assertTrue(
            "clearTestResults' GroupSort half must still be reachable from Dart",
            duty.contains("\"sort.reposition\" to {"),
        )
        assertTrue(
            "the configuration write's newest-intent bump must still be reachable from Dart",
            duty.contains("\"revision.edit\" to {") &&
                duty.contains("GroupRevisions.edit("),
        )
        assertTrue(
            "the URL edit's poller re-plan must still be reachable from Dart",
            duty.contains("\"subscription.schedule\" to {") &&
                duty.contains("SubscriptionScheduler.schedule()"),
        )
        val profiles = source("bridge/FlroneProfiles.kt")
        assertTrue(
            "the reposition duty calls the kept GroupSort path, not a second sort",
            profiles.contains("suspend fun repositionTestResults(") &&
                profiles.contains("GroupSort.repositionLater("),
        )
    }
}