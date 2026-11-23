package io.nekohasekai.sagernet.database

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The retired-tables seed (ADR 0006 stage C2b).
 *
 * [AndroidLegacySettingsReader.read] over a [AndroidLegacySettingsReader.Source]
 * is plain Kotlin, so the decisions — which tables count, which rows survive,
 * what a failing read degrades to — are covered here. The framework
 * `SQLiteDatabase` open in `read(file)` is a device/CI path: the JVM unit tests
 * have no Android SQLite, so only its first guard (a missing file seeds nothing)
 * is asserted.
 */
class AndroidLegacySettingsReaderTest {

    private class FakeSource(
        private val tables: Set<String> = setOf("settings", "markers"),
        private val settings: List<Pair<String?, String?>> = emptyList(),
        private val markers: List<Pair<String?, Long?>> = emptyList(),
        private val failTables: Boolean = false,
        private val failSettings: Boolean = false,
        private val failMarkers: Boolean = false,
    ) : AndroidLegacySettingsReader.Source {
        override fun tables(): Set<String> {
            if (failTables) error("unreadable schema")
            return tables
        }

        override fun settingsRows(): List<Pair<String?, String?>> {
            if (failSettings) error("unreadable rows")
            return settings
        }

        override fun markerRows(): List<Pair<String?, Long?>> {
            if (failMarkers) error("unreadable rows")
            return markers
        }
    }

    @Before
    fun setUp() {
        AndroidLegacySettingsReader.logger = { _, _ -> }
    }

    @Test
    fun `both tables seed their maps`() {
        val legacy = AndroidLegacySettingsReader.read(
            FakeSource(
                settings = listOf("theme" to "dark", "port" to "1080"),
                markers = listOf("marker-a" to 42L),
            ),
        )
        assertEquals(mapOf("theme" to "dark", "port" to "1080"), legacy.settings)
        assertEquals(mapOf("marker-a" to 42L), legacy.markers)
    }

    @Test
    fun `a database without the tables seeds nothing`() {
        val legacy = AndroidLegacySettingsReader.read(FakeSource(tables = setOf("groups")))
        assertTrue(legacy.settings.isEmpty())
        assertTrue(legacy.markers.isEmpty())
    }

    @Test
    fun `only the settings table present leaves markers empty`() {
        val legacy = AndroidLegacySettingsReader.read(
            FakeSource(tables = setOf("settings"), settings = listOf("keep" to "1")),
        )
        assertEquals(mapOf("keep" to "1"), legacy.settings)
        assertTrue(legacy.markers.isEmpty())
    }

    @Test
    fun `a null value is an empty string, a null key is skipped`() {
        val legacy = AndroidLegacySettingsReader.read(
            FakeSource(settings = listOf(null to "x", "blank" to null)),
        )
        assertEquals(mapOf("blank" to ""), legacy.settings)
    }

    @Test
    fun `a marker without a timestamp is not carried forward`() {
        val legacy = AndroidLegacySettingsReader.read(
            FakeSource(markers = listOf(null to 1L, "no-time" to null, "ok" to 7L)),
        )
        assertEquals(mapOf("ok" to 7L), legacy.markers)
    }

    @Test
    fun `a failing read degrades to empty maps instead of throwing`() {
        assertTrue(AndroidLegacySettingsReader.read(FakeSource(failTables = true)).settings.isEmpty())

        val settingsFailed = AndroidLegacySettingsReader.read(
            FakeSource(settings = listOf("theme" to "dark"), markers = listOf("m" to 1L), failSettings = true),
        )
        assertTrue(settingsFailed.settings.isEmpty())
        // One unreadable table does not cost the other one its rows.
        assertEquals(mapOf("m" to 1L), settingsFailed.markers)

        val markersFailed = AndroidLegacySettingsReader.read(
            FakeSource(settings = listOf("theme" to "dark"), markers = listOf("m" to 1L), failMarkers = true),
        )
        assertEquals(mapOf("theme" to "dark"), markersFailed.settings)
        assertTrue(markersFailed.markers.isEmpty())
    }

    @Test
    fun `a missing database file seeds nothing`() {
        // The first-install case, and the only part of the framework open the JVM
        // tests can reach: nothing is created, nothing is opened.
        val missing = File(System.getProperty("java.io.tmpdir"), "no-such-sager-net-${System.nanoTime()}.db")
        val legacy = AndroidLegacySettingsReader.read(missing)
        assertTrue(legacy.settings.isEmpty())
        assertTrue(legacy.markers.isEmpty())
        assertTrue(!missing.exists())
    }
}
