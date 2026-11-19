package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The staged-table wire parser for the host restore (P14).
 *
 * `_hostRestoreArgs` sends `{columns, rows}`; the first version of this object
 * parsed only a column-keyed row list, so every table arrived empty and a
 * restore reset the user's profiles/groups/routes before inserting nothing.
 * These tests pin the shape both sides actually exchange, and that a malformed
 * row fails loudly instead of being silently dropped.
 */
class BboxRoomSnapshotTest {

    @Test
    fun `columns and rows decode into column-keyed maps`() {
        val wire = mapOf(
            "columns" to listOf("id", "type", "name", "gid"),
            "rows" to listOf(
                listOf(1L, "ss", "node-a", 7L),
                listOf(2L, "vmess", null, 7L),
            ),
        )
        val rows = BboxRoomSnapshot.tableRows(wire)
        assertEquals(2, rows.size)
        assertEquals(1L, rows[0]["id"])
        assertEquals("ss", rows[0]["type"])
        assertEquals("node-a", rows[0]["name"])
        assertEquals(7L, rows[0]["gid"])
        assertEquals(null, rows[1]["name"])
    }

    @Test
    fun `an empty table map is an empty table`() {
        assertTrue(BboxRoomSnapshot.tableRows(emptyMap<String, Any?>()).isEmpty())
        assertTrue(
            BboxRoomSnapshot.tableRows(
                mapOf("columns" to listOf("id"), "rows" to emptyList<Any?>()),
            ).isEmpty(),
        )
    }

    @Test
    fun `a row that does not match the column list fails instead of being skipped`() {
        val wire = mapOf(
            "columns" to listOf("id", "name"),
            "rows" to listOf(listOf(1L)),
        )
        val failure = runCatching { BboxRoomSnapshot.tableRows(wire) }.exceptionOrNull()
        assertTrue("a short row must throw", failure is IllegalStateException)
    }

    @Test
    fun `a missing columns key fails loudly`() {
        val failure = runCatching {
            BboxRoomSnapshot.tableRows(mapOf("rows" to listOf(listOf(1L))))
        }.exceptionOrNull()
        assertTrue("a table without columns must throw", failure is IllegalStateException)
    }

    @Test
    fun `the legacy column-keyed list is still accepted`() {
        val rows = BboxRoomSnapshot.tableRows(
            listOf(mapOf("id" to 1L, "name" to "node-a")),
        )
        assertEquals(1, rows.size)
        assertEquals("node-a", rows[0]["name"])
    }
}
