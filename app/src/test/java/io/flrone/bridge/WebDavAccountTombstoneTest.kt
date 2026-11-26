package io.flrone.bridge

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * The explicit WebDAV clear (ADR 0005 phase 1).
 *
 * A null `webdavAccount` removes the key from the preferences document. Without
 * a marker the host's `ready` fold put the legacy Room rows straight back, so
 * the clear looked like it never happened. These tests drive the same state
 * machine the bridge uses against a temp preferences document and an in-memory
 * stand-in for the four legacy rows: clear survives `ready`, the rows are
 * emptied, and a new binding removes the marker and is returned on `ready`.
 */
class WebDavAccountTombstoneTest {

    private lateinit var temp: File
    private lateinit var preferences: File

    @Before
    fun setUp() {
        temp = File.createTempFile("webdav-tombstone", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        preferences = File(temp, "preferences.json")
    }

    @After
    fun tearDown() {
        temp.deleteRecursively()
    }

    private fun readPrefs(): Map<String, Any?> {
        if (!preferences.isFile) return emptyMap()
        val json = JSONObject(preferences.readText())
        return json.keys().asSequence().associateWith { key ->
            val value = json.get(key)
            if (value == JSONObject.NULL) null else value
        }
    }

    private fun writePrefs(rows: Map<String, Any?>) {
        val json = JSONObject()
        rows.forEach { (key, value) -> json.put(key, value ?: JSONObject.NULL) }
        preferences.writeText(json.toString())
    }

    /** The exact `writePreferences` path: policy computes the merged doc and the clear request. */
    private fun write(values: Map<String, Any?>, legacy: MutableMap<String, String?>) {
        val write = WebDavAccountTombstone.apply(values, readPrefs())
        writePrefs(write.rows)
        if (write.clearLegacy) {
            FlroneBackup.LEGACY_WEBDAV_KEYS.forEach { legacy[it] = null }
        }
    }

    /** The exact `preferencesWithLegacyWebDav` path on `ready`. */
    private fun ready(legacy: Map<String, String?>): Map<String, Any?> {
        val current = readPrefs()
        if (!WebDavAccountTombstone.mayFoldLegacy(current)) return current
        val server = legacy["webdavServer"]
        if (server.isNullOrBlank()) return current
        val folded = current.toMutableMap()
        folded[WebDavAccountTombstone.ACCOUNT_KEY] = mapOf(
            "uri" to server,
            "user" to legacy["webdavUsername"].orEmpty(),
            "password" to legacy["webdavPassword"].orEmpty(),
            "fileName" to legacy["webdavPath"].orEmpty(),
        )
        writePrefs(folded)
        return folded
    }

    @Test
    fun `clear survives ready and empties the legacy rows`() {
        val legacy = mutableMapOf<String, String?>(
            "webdavServer" to "https://dav.example.test",
            "webdavUsername" to "old-user",
            "webdavPassword" to "old-secret",
            "webdavPath" to "Throne",
        )
        // An upgrade folds the legacy account in once.
        val first = ready(legacy)
        assertEquals("https://dav.example.test",
            (first[WebDavAccountTombstone.ACCOUNT_KEY] as Map<*, *>)["uri"])

        // The user unbinds: the key is removed and the marker recorded.
        write(mapOf(WebDavAccountTombstone.ACCOUNT_KEY to null), legacy)
        assertFalse(readPrefs().containsKey(WebDavAccountTombstone.ACCOUNT_KEY))
        assertEquals(true, readPrefs()[WebDavAccountTombstone.CLEARED_KEY])
        assertTrue(FlroneBackup.LEGACY_WEBDAV_KEYS.all { legacy[it] == null })

        // A later `ready` must not resurrect it.
        val afterReady = ready(legacy)
        assertFalse(afterReady.containsKey(WebDavAccountTombstone.ACCOUNT_KEY))
        assertNull(readPrefs()[WebDavAccountTombstone.ACCOUNT_KEY])
    }

    @Test
    fun `setting a new account removes the tombstone and is returned on ready`() {
        val legacy = mutableMapOf<String, String?>()
        write(mapOf(WebDavAccountTombstone.ACCOUNT_KEY to null), legacy)
        assertEquals(true, readPrefs()[WebDavAccountTombstone.CLEARED_KEY])

        val account = mapOf<String, Any?>(
            "uri" to "https://new.example.test",
            "user" to "new-user",
            "password" to "enc:v1:token",
            "fileName" to "new.json",
        )
        write(
            mapOf(
                WebDavAccountTombstone.ACCOUNT_KEY to account,
                WebDavAccountTombstone.CLEARED_KEY to null,
            ),
            legacy,
        )
        assertFalse(readPrefs().containsKey(WebDavAccountTombstone.CLEARED_KEY))

        // With no legacy rows left, `ready` returns the Dart-owned account as-is.
        val payload = ready(legacy)
        @Suppress("UNCHECKED_CAST")
        val returned = FlroneBackup.jsonToWire(payload[WebDavAccountTombstone.ACCOUNT_KEY]) as Map<*, *>
        account.forEach { (key, value) -> assertEquals(value, returned[key]) }
    }

    @Test
    fun `an unrelated write does not clear legacy rows again`() {
        val legacy = mutableMapOf<String, String?>("webdavServer" to "https://dav.example.test")
        write(mapOf(WebDavAccountTombstone.ACCOUNT_KEY to null), legacy)
        legacy["webdavServer"] = "https://dav.example.test" // a stale row reappeared

        write(mapOf("theme" to "dark"), legacy)
        assertEquals("https://dav.example.test", legacy["webdavServer"])
        assertEquals(true, readPrefs()[WebDavAccountTombstone.CLEARED_KEY])
    }

    @Test
    fun `the backup excludes both the account and its clear marker`() {
        assertEquals(
            setOf("webdavAccount", "webdavAccountCleared"),
            WebDavAccountTombstone.backupExcludedKeys(),
        )
        assertTrue(WebDavAccountTombstone.mayFoldLegacy(emptyMap()))
        assertFalse(WebDavAccountTombstone.mayFoldLegacy(
            mapOf(WebDavAccountTombstone.CLEARED_KEY to true),
        ))
        assertFalse(WebDavAccountTombstone.mayFoldLegacy(
            mapOf(WebDavAccountTombstone.ACCOUNT_KEY to mapOf<String, Any?>()),
        ))
    }
}
