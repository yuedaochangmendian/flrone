package io.nekohasekai.sagernet.database.preference

import io.nekohasekai.sagernet.database.SettingsJsonStore
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * [SettingsStore] over the settings documents (ADR 0006 stage C2b): the document is the
 * only store — Room's table is gone — and an unmounted store fails loudly instead of
 * answering defaults.
 */
class SettingsStoreTest {

    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = File.createTempFile("settings-store", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        SettingsJsonStore.logger = { _, _ -> }
        SettingsJsonStore.directory = dir
    }

    @After
    fun tearDown() {
        SettingsJsonStore.directory = null
        dir.deleteRecursively()
    }

    private fun store() = SettingsStore { null }

    @Test
    fun `writes land in the document`() {
        val store = store()
        store.putBoolean("mounted", true)
        store.putInt("port", 1080)
        store.putStringList("list", listOf("a", "b"))

        assertEquals("true", SettingsJsonStore.get("mounted"))
        assertEquals("1080", SettingsJsonStore.get("port"))

        // The typed getters read the same document back.
        assertEquals(true, store.getBoolean("mounted"))
        assertEquals(1080, store.getInt("port"))
        assertEquals(listOf("a", "b"), store.getStringList("list"))
    }

    @Test
    fun `reads come from the document`() {
        SettingsJsonStore.put("port", "2")
        assertEquals(2, store().getInt("port"))
    }

    @Test
    fun `all, putAll, remove and reset route to the document`() {
        val store = store()
        store.putAll(mapOf("a" to "1", "b" to "2"))
        assertEquals(mapOf("a" to "1", "b" to "2"), store.all())

        store.remove("a")
        assertNull(store.getRaw("a"))

        store.reset()
        assertTrue(store.all().isEmpty())
    }

    @Test
    fun `an unmounted store fails loudly instead of answering defaults`() {
        SettingsJsonStore.directory = null
        val store = store()

        val read = runCatching { store.getString("a") }.exceptionOrNull()
        assertTrue("a read on an unmounted store must throw: $read", read is IllegalStateException)
        assertTrue(
            "the message must name the mount: ${read?.message}",
            read?.message?.contains("not mounted") == true,
        )

        listOf(
            { store.all() },
            { store.putString("b", "2") },
            { store.putAll(mapOf("c" to "3")) },
            { store.remove("a") },
            { store.reset() },
        ).forEach { write ->
            val failure = runCatching { write() }.exceptionOrNull()
            assertTrue("a write on an unmounted store must throw: $failure", failure is IllegalStateException)
        }
    }

    @Test
    fun `a second store instance sees an external write`() {
        val first = store()
        first.putString("shared", "one")
        assertEquals("one", first.getString("shared"))

        // Another process rewrites the document in the same envelope (a restore does exactly
        // this); the second instance must answer the file, not a snapshot of the first read.
        val array = JSONArray().put(JSONObject().put("key", "shared").put("value", "two-two-two"))
        File(dir, "settings.json").writeText(
            JSONObject().apply {
                put("version", 1)
                put("name", "settings")
                put("written", true)
                put("rows", array)
            }.toString(),
        )
        assertEquals("two-two-two", store().getString("shared"))
    }
}
