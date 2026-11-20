package io.nekohasekai.sagernet.database

import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The settings documents (ADR 0006 stage C1): seed-from-legacy, the read/write
 * round trip, corrupt-document re-seeding and the markers companion. Pure JVM —
 * the legacy seams are injected, so no Room and no Android types load.
 */
class SettingsJsonStoreTest {

    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = File.createTempFile("settings-json", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        SettingsJsonStore.logger = { _, _ -> }
        SettingsJsonStore.legacySettings = { mapOf("theme" to "dark", "keep" to "1") }
        SettingsJsonStore.legacyMarkers = { mapOf("marker-a" to 42L) }
        SettingsJsonStore.directory = dir
    }

    @After
    fun tearDown() {
        SettingsJsonStore.directory = null
        SettingsJsonStore.legacySettings = { emptyMap() }
        SettingsJsonStore.legacyMarkers = { emptyMap() }
        dir.deleteRecursively()
    }

    @Test
    fun `first access seeds the documents from the legacy rows`() {
        assertEquals("dark", SettingsJsonStore.get("theme"))
        assertTrue(File(dir, "settings.json").isFile)
        assertTrue(File(dir, "markers.json").isFile)
        assertEquals(mapOf("marker-a" to 42L), SettingsJsonStore.markers())
    }

    @Test
    fun `writes round-trip through the document`() {
        SettingsJsonStore.put("theme", "light")
        SettingsJsonStore.putAll(mapOf("added" to "x"))
        assertEquals("light", SettingsJsonStore.get("theme"))
        assertEquals("x", SettingsJsonStore.get("added"))
        SettingsJsonStore.remove("keep")
        assertNull(SettingsJsonStore.get("keep"))
        assertEquals(mapOf("theme" to "light", "added" to "x"), SettingsJsonStore.all())
        SettingsJsonStore.reset()
        assertTrue(SettingsJsonStore.all().isEmpty())
    }

    @Test
    fun `a corrupt document re-seeds instead of losing rows`() {
        SettingsJsonStore.put("theme", "light")
        File(dir, "settings.json").writeText("{ not json")
        // The next read treats the document as missing and re-seeds from the
        // legacy rows — the property that makes the switch loss-free.
        assertEquals("dark", SettingsJsonStore.get("theme"))
    }

    @Test
    fun `markers round-trip and reset`() {
        SettingsJsonStore.putMarkers(mapOf("marker-b" to 7L))
        assertEquals(mapOf("marker-a" to 42L, "marker-b" to 7L), SettingsJsonStore.markers())
        SettingsJsonStore.resetMarkers()
        assertTrue(SettingsJsonStore.markers().isEmpty())
    }

    @Test
    fun `unmounted answers null and never touches the legacy rows`() {
        SettingsJsonStore.directory = null
        assertNull(SettingsJsonStore.get("theme"))
        assertNull(SettingsJsonStore.get("missing"))
    }
}
