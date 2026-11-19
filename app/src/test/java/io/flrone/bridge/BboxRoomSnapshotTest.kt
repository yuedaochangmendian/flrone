package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import io.flrone.bridge.BboxRoomSnapshot.SqlHandleKind

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

    // -- data.roomSql whitelist (pure function; no Android API) ---------------

    private fun allowed(kind: SqlHandleKind, sql: String) =
        BboxRoomSnapshot.isAllowedSql(kind, sql)

    @Test
    fun `Room allows only SELECT and PRAGMA reads`() {
        assertTrue(allowed(SqlHandleKind.ROOM, "SELECT * FROM groups"))
        assertTrue(allowed(SqlHandleKind.ROOM, "PRAGMA table_info(`profiles`)"))
        assertFalse(allowed(SqlHandleKind.ROOM, "INSERT INTO groups (name) VALUES ('x')"))
        assertFalse(allowed(SqlHandleKind.ROOM, "DELETE FROM profiles"))
        assertFalse(allowed(SqlHandleKind.ROOM, "UPDATE profiles SET gid = 1"))
    }

    @Test
    fun `Temp allows every backup-rebuild statement type`() {
        val ok = listOf(
            "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY)",
            "CREATE INDEX IF NOT EXISTS ix ON t(id)",
            "INSERT INTO t (id) VALUES (1)",
            "DELETE FROM t",
            "UPDATE t SET id = 2",
            "DROP TABLE t",
            "ALTER TABLE t ADD COLUMN name TEXT",
            "PRAGMA defer_foreign_keys = ON",
            "SELECT * FROM t",
            "BEGIN IMMEDIATE",
            "COMMIT",
            "ROLLBACK",
        )
        ok.forEach { assertTrue("expected allowed: $it", allowed(SqlHandleKind.TEMP, it)) }
    }

    @Test
    fun `Temp rejects statements outside the whitelist`() {
        assertFalse(allowed(SqlHandleKind.TEMP, "ATTACH DATABASE '/x' AS x"))
        assertFalse(allowed(SqlHandleKind.TEMP, "VACUUM"))
        assertFalse(allowed(SqlHandleKind.TEMP, "CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END"))
        assertFalse(allowed(SqlHandleKind.TEMP, "PRAGMA writable_schema = ON"))
        assertFalse(allowed(SqlHandleKind.TEMP, "DROP VIEW v"))
    }

    @Test
    fun `multi statements are rejected and a trailing semicolon is tolerated`() {
        assertTrue(allowed(SqlHandleKind.TEMP, "SELECT * FROM t;"))
        assertTrue(allowed(SqlHandleKind.TEMP, "  SELECT * FROM t ;  "))
        assertFalse(allowed(SqlHandleKind.TEMP, "SELECT 1; DROP TABLE t"))
        assertFalse(allowed(SqlHandleKind.TEMP, "SELECT 1;SELECT 2"))
        assertFalse(allowed(SqlHandleKind.ROOM, "SELECT 1; PRAGMA writable_schema = ON"))
    }

    @Test
    fun `leading whitespace and comments do not hide the keyword or the semicolon`() {
        assertTrue(allowed(SqlHandleKind.TEMP, "  -- leading line comment\n SELECT * FROM t"))
        assertTrue(allowed(SqlHandleKind.TEMP, "/* block */ SELECT * FROM t"))
        assertTrue(allowed(SqlHandleKind.TEMP, "/* a */ /* b */ SELECT * FROM t;"))
        // Semicolons inside string literals and comments are not separators.
        assertTrue(allowed(SqlHandleKind.TEMP, "SELECT ';' AS semi FROM t"))
        assertTrue(allowed(SqlHandleKind.TEMP, "SELECT 1 -- note; not a separator\n"))
        // A trailing comment after the semicolon must not smuggle a second statement.
        assertFalse(allowed(SqlHandleKind.TEMP, "SELECT 1; /* x */ DROP TABLE t"))
    }
}
