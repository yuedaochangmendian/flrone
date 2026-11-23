package io.flrone.bridge

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import io.nekohasekai.sagernet.database.SettingsJsonStore
import java.io.File
import java.nio.file.Files

/**
 * The staged-table wire parser for the host restore (P14) and the settings/
 * markers document ops (ADR 0006 stage C2c2a).
 *
 * `_tableToMaps`/`_hostMarkers` send `{columns, rows}`; the first version of
 * this object parsed only a column-keyed row list, so every table arrived empty
 * and a restore reset the user's profiles/groups/routes before inserting
 * nothing. These tests pin the shape both sides actually exchange, and that a
 * malformed row fails loudly instead of being silently dropped.
 *
 * The document ops run against a temp [SettingsJsonStore] directory (the
 * document store is pure Kotlin + org.json, both available to JVM tests).
 */
class BboxRoomSnapshotTest {

    private lateinit var directory: File
    private lateinit var legacySettings: () -> Map<String, String>
    private lateinit var legacyMarkers: () -> Map<String, Long>

    @Before
    fun setUp() {
        directory = Files.createTempDirectory("settings-doc-").toFile()
        legacySettings = SettingsJsonStore.legacySettings
        legacyMarkers = SettingsJsonStore.legacyMarkers
        SettingsJsonStore.legacySettings = { emptyMap() }
        SettingsJsonStore.legacyMarkers = { emptyMap() }
        SettingsJsonStore.directory = directory
        SettingsJsonStore.reset()
        SettingsJsonStore.resetMarkers()
    }

    @After
    fun tearDown() {
        SettingsJsonStore.directory = null
        SettingsJsonStore.legacySettings = legacySettings
        SettingsJsonStore.legacyMarkers = legacyMarkers
        directory.deleteRecursively()
    }

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

    // -- backup.container whitelist (pure function; no Android API) -----------

    private fun allowed(sql: String) = BboxRoomSnapshot.isAllowedSql(sql)

    @Test
    fun `the container handle is a rebuild target, not a read-only view`() {
        // C2c1: the transport has one handle kind — the backup's own container
        // file. The statement types the export/restore rebuild needs are allowed;
        // nothing else reaches SQLite.
        val ok = listOf(
            "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY)",
            "CREATE INDEX IF NOT EXISTS ix ON t(id)",
            "INSERT INTO t (id) VALUES (1)",
            "DELETE FROM t",
            "UPDATE t SET id = 2",
            "DROP TABLE t",
            "ALTER TABLE t ADD COLUMN name TEXT",
            "PRAGMA defer_foreign_keys = ON",
            "PRAGMA table_info(`profiles`)",
            "SELECT * FROM t",
            "BEGIN IMMEDIATE",
            "COMMIT",
            "ROLLBACK",
        )
        ok.forEach { assertTrue("expected allowed: $it", allowed(it)) }
    }

    @Test
    fun `the container handle rejects statements outside the whitelist`() {
        assertFalse(allowed("ATTACH DATABASE '/x' AS x"))
        assertFalse(allowed("VACUUM"))
        assertFalse(allowed("CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END"))
        assertFalse(allowed("PRAGMA writable_schema = ON"))
        assertFalse(allowed("DROP VIEW v"))
    }

    @Test
    fun `multi statements are rejected and a trailing semicolon is tolerated`() {
        assertTrue(allowed("SELECT * FROM t;"))
        assertTrue(allowed("  SELECT * FROM t ;  "))
        assertFalse(allowed("SELECT 1; DROP TABLE t"))
        assertFalse(allowed("SELECT 1;SELECT 2"))
        assertFalse(allowed("SELECT 1; PRAGMA writable_schema = ON"))
    }

    @Test
    fun `leading whitespace and comments do not hide the keyword or the semicolon`() {
        assertTrue(allowed("  -- leading line comment\n SELECT * FROM t"))
        assertTrue(allowed("/* block */ SELECT * FROM t"))
        assertTrue(allowed("/* a */ /* b */ SELECT * FROM t;"))
        // Semicolons inside string literals and comments are not separators.
        assertTrue(allowed("SELECT ';' AS semi FROM t"))
        assertTrue(allowed("SELECT 1 -- note; not a separator\n"))
        // A trailing comment after the semicolon must not smuggle a second statement.
        assertFalse(allowed("SELECT 1; /* x */ DROP TABLE t"))
    }

    // -- settings / markers document ops (C2c2a) ------------------------------

    private fun restore(
        hasSettings: Boolean,
        settings: Map<String, String>,
        fromAndroid: Boolean = true,
        restoredProfiles: Boolean = false,
        groups: List<Long>? = null,
        profiles: List<Long>? = null,
        routes: List<Long>? = null,
    ): List<String> {
        val args = HashMap<String, Any?>()
        args["hasSettings"] = hasSettings
        args["settings"] = settings
        args["fromAndroid"] = fromAndroid
        args["restoredProfiles"] = restoredProfiles
        if (groups != null) args["restoredGroupIds"] = groups
        if (profiles != null) args["restoredProfileIds"] = profiles
        if (routes != null) args["restoredRouteIds"] = routes
        val reply = BboxRoomSnapshot.restoreSettings(args)
        @Suppress("UNCHECKED_CAST")
        return reply["warnings"] as List<String>
    }

    @Test
    fun `settings restore replaces rows and never overwrites device-local keys`() {
        SettingsJsonStore.putAll(
            mapOf(
                "remote_dns" to "old",
                "deviceId" to "phone",
                "webdavServer" to "phone-webdav",
                "appTheme" to "light",
            ),
        )

        restore(
            true,
            mapOf(
                "remote_dns" to "https://8.8.8.8/dns-query",
                "deviceId" to "desktop",
                "webdavServer" to "desktop-webdav",
                "appTheme" to "dark",
            ),
            fromAndroid = false,
            groups = listOf(1L),
            profiles = listOf(2L),
            routes = listOf(1L),
        )

        val settings = SettingsJsonStore.all()
        assertEquals("https://8.8.8.8/dns-query", settings["remote_dns"])
        assertEquals("phone", settings["deviceId"])
        // Desktop backup on Android: Android-only keys keep this phone's value.
        assertEquals("phone-webdav", settings["webdavServer"])
        // A non-android-only key is replaced by the container's.
        assertEquals("dark", settings["appTheme"])
        assertEquals("1", settings["current_group"])
    }

    @Test
    fun `an android backup replaces android-only keys`() {
        SettingsJsonStore.putAll(mapOf("appTheme" to "light", "deviceId" to "phone"))
        restore(true, mapOf("appTheme" to "dark", "deviceId" to "other"), fromAndroid = true)
        val settings = SettingsJsonStore.all()
        assertEquals("dark", settings["appTheme"])
        // device-local wins even for an Android container.
        assertEquals("phone", settings["deviceId"])
    }

    @Test
    fun `restore without a settings block only repairs the selection`() {
        SettingsJsonStore.putAll(
            mapOf("remote_dns" to "kept", "current_group" to "9", "current_route_id" to "9",
                "profileId" to "9", "profileCurrent" to "9"),
        )
        restore(
            false,
            emptyMap(),
            groups = listOf(3L),
            profiles = listOf(1L, 2L),
            routes = listOf(5L),
        )
        val settings = SettingsJsonStore.all()
        assertEquals("kept", settings["remote_dns"])
        assertEquals("3", settings["current_group"])
        assertEquals("5", settings["current_route_id"])
        assertNull(settings["profileId"])
        assertNull(settings["profileCurrent"])
    }

    @Test
    fun `a desktop profiles restore translates remember_id`() {
        SettingsJsonStore.putAll(mapOf("profileId" to "1", "profileCurrent" to "1"))
        restore(
            true,
            mapOf("remember_id" to "2"),
            fromAndroid = false,
            restoredProfiles = true,
            groups = listOf(1L),
            profiles = listOf(1L, 2L),
            routes = listOf(1L),
        )
        val settings = SettingsJsonStore.all()
        assertEquals("2", settings["profileId"])
        assertEquals("2", settings["profileCurrent"])
    }

    @Test
    fun `the LAN guard resets a non-loopback inbound address`() {
        SettingsJsonStore.putAll(mapOf("inbound_address" to "0.0.0.0"))
        val warnings = restore(true, mapOf("inbound_address" to "0.0.0.0"))
        assertEquals("127.0.0.1", SettingsJsonStore.get("inbound_address"))
        assertTrue(warnings.single().contains("lets other devices connect"))
    }

    @Test
    fun `markers restore replaces the whole set`() {
        SettingsJsonStore.replaceMarkers(mapOf("old" to 1L))
        BboxRoomSnapshot.restoreMarkers(mapOf("rows" to listOf(
            mapOf("key" to "a", "marked_at" to 10L),
            mapOf("key" to "b", "marked_at" to 20L),
        )))
        assertEquals(mapOf("a" to 10L, "b" to 20L), SettingsJsonStore.markers())
    }

    @Test
    fun `the snapshots expose the live documents as column rows`() {
        SettingsJsonStore.putAll(mapOf("remote_dns" to "x"))
        val settings = (BboxRoomSnapshot.settingsSnapshot()["rows"] as List<*>)
            .filterIsInstance<Map<String, Any?>>()
        assertEquals("remote_dns", settings.single { it["key"] == "remote_dns" }["value"])
        SettingsJsonStore.replaceMarkers(mapOf("seen" to 42L))
        val markers = (BboxRoomSnapshot.markersSnapshot()["rows"] as List<*>)
            .filterIsInstance<Map<String, Any?>>()
        assertEquals(42L, markers.single()["marked_at"])
    }
}
