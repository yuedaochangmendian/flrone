package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * ADR 0008 P1-5: Kotlin is a read-only consumer of Dart's selection document.
 * A missing, malformed or stale file is a silent null so `config.prepare` falls
 * back to DataStore.selectedProxy; a valid document wins.
 */
class ProfileSelectionStoreTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun write(content: String): File {
        val dir = temp.newFolder()
        File(dir, "profile_selection.json").writeText(content)
        return dir
    }

    @Test
    fun aValidDocumentWins() {
        val dir = write(
            """{"version":1,"selectedProfileId":42,"currentGroupId":7,"updatedAt":1700000000123}"""
        )
        assertEquals(42L, ProfileSelectionStore.selectedProfileId(dir))
    }

    @Test
    fun missingDirectoryOrFileIsNull() {
        assertNull(ProfileSelectionStore.selectedProfileId(null))
        assertNull(ProfileSelectionStore.selectedProfileId(temp.newFolder()))
    }

    @Test
    fun malformedOrInvalidDocumentsFallBack() {
        for (content in listOf(
            "{",
            """{"version":2,"selectedProfileId":5,"currentGroupId":7,"updatedAt":1}""",
            """{"version":1,"currentGroupId":7,"updatedAt":1}""",
            """{"version":1,"selectedProfileId":0,"currentGroupId":7,"updatedAt":1}""",
            """{"version":1,"selectedProfileId":-3,"currentGroupId":7,"updatedAt":1}""",
            """{"version":1,"selectedProfileId":5,"currentGroupId":-1,"updatedAt":1}""",
            """{"version":1,"selectedProfileId":5,"currentGroupId":7}""",
            """{"version":1,"selectedProfileId":5,"currentGroupId":7,"updatedAt":0}""",
        )) {
            assertNull("expected fallback for $content", ProfileSelectionStore.selectedProfileId(write(content)))
        }
    }

    @Test
    fun extraKeysDoNotBreakTheReader() {
        val dir = write(
            """{"version":1,"selectedProfileId":9,"currentGroupId":7,"updatedAt":1,"future":"ignored"}"""
        )
        assertEquals(9L, ProfileSelectionStore.selectedProfileId(dir))
    }
}
