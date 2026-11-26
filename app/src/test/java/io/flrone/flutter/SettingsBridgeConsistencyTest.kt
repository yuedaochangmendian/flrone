package io.flrone.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The two confirmed settings-bridge gaps (Phase 1 WP1.4):
 *  1. `settings.set` of an unknown key writes SharedPreferences, but `settingsWire()`
 *     used to read only the seeded document — the new value vanished on the wire.
 *  2. `settings.restore` replaced the authoritative document but emitted no `settings`
 *     event, so a profiles-scope restore left Dart rendering pre-restore settings.
 *
 * The helpers are deliberately pure so the cases are pinned without an Android bridge.
 */
class SettingsBridgeConsistencyTest {

    @Test
    fun `a later prefs write wins over the seeded document`() {
        // The upgrade seed writes fontSize=14 into ui_settings.json. A subsequent
        // settings.set of an unknown key lives in SharedPreferences. Both must be on the wire.
        val seeded = mapOf<String, Any?>("fontSize" to 14, "seedOnly" to "from-document")
        val written = mapOf<String, Any?>("customKey" to true, "fontSize" to 18)

        val merged = mergeSettingsOverlay(seeded, written)

        assertEquals(18, merged["fontSize"])
        assertEquals(true, merged["customKey"])
        assertEquals("from-document", merged["seedOnly"])
    }

    @Test
    fun `merge keeps the document when prefs are empty`() {
        val merged = mergeSettingsOverlay(mapOf("fontSize" to 14), emptyMap())
        assertEquals(14, merged["fontSize"])
    }

    @Test
    fun `merge keeps prefs when the document was never seeded`() {
        val merged = mergeSettingsOverlay(emptyMap(), mapOf("customKey" to "value"))
        assertEquals("value", merged["customKey"])
    }

    @Test
    fun `restore publishes the post-write wire once with warnings preserved`() {
        val seen = ArrayList<Map<String, Any?>>()
        val warnings = listOf("LAN guard applied")
        var restoreCalls = 0
        var wireCalls = 0

        val answer = restoreAndPublishSettings(
            restore = {
                restoreCalls++
                mapOf("warnings" to warnings)
            },
            wire = {
                wireCalls++
                mapOf("theme" to "dark")
            },
            publish = { seen += it },
        )

        assertEquals(mapOf("warnings" to warnings), answer)
        assertEquals(1, restoreCalls)
        assertEquals(1, wireCalls)
        assertEquals(listOf(mapOf("theme" to "dark")), seen)
        // A reply (warnings) does not replace the push: the UI needs both.
        assertTrue(seen.isNotEmpty())
    }
}
