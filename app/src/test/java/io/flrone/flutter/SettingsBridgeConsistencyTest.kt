package io.flrone.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `settings.restore` used to replace the authoritative document but emit no `settings`
 * event, so a profiles-scope restore left Dart rendering pre-restore settings. The
 * helper is deliberately pure so the case is pinned without an Android bridge.
 */
class SettingsBridgeConsistencyTest {

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
