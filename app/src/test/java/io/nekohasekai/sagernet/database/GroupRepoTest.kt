package io.nekohasekai.sagernet.database

import io.flrone.bridge.DartProfileStore
import io.flrone.bridge.DartProfileWriter
import io.flrone.bridge.ProfilesDocumentUnavailable
import io.nekohasekai.sagernet.database.preference.SettingsStore
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * [GroupRepo] over the Dart-owned `profiles.json` (ADR 0006 stage C2c2b1).
 *
 * The document is the only store: a read maps the file, a missing/corrupt file throws instead of
 * answering Room, and a pure listing never creates the "Default" group (the hidden-empty-group
 * report). Writes cross [DartProfileWriter]; the writer's in-process test transport stands in for
 * the Dart engine so the op and the assigned ids are asserted without a device or Room.
 */
class GroupRepoTest {

    private lateinit var dir: File
    private var originalDirectory: File? = null
    private var originalLogger: (String, Throwable?) -> Unit = { _, _ -> }
    private var originalSettingsDir: File? = null
    private var originalDefaultName: String? = null
    private var originalLegacySettings: () -> Map<String, String> = { emptyMap() }
    private var originalLegacyMarkers: () -> Map<String, Long> = { emptyMap() }

    @Before
    fun setUp() {
        dir = File.createTempFile("group-repo", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        originalDirectory = DartProfileStore.directory
        originalLogger = DartProfileStore.logger
        DartProfileStore.directory = dir
        DartProfileStore.logger = { _, _ -> }
        DartProfileStore.invalidate()

        originalSettingsDir = SettingsJsonStore.directory
        SettingsJsonStore.directory = dir
        originalLegacySettings = SettingsJsonStore.legacySettings
        originalLegacyMarkers = SettingsJsonStore.legacyMarkers
        // The default seed reads the retired Room file through Android; a JVM test has none.
        SettingsJsonStore.legacySettings = { emptyMap() }
        SettingsJsonStore.legacyMarkers = { emptyMap() }
        GroupRepo.settingsStore = SettingsStore { null }
        originalDefaultName = GroupRepo.defaultGroupNameOverride
        GroupRepo.defaultGroupNameOverride = "Default"
    }

    @After
    fun tearDown() {
        GroupRepo.settingsStore = null
        GroupRepo.defaultGroupNameOverride = originalDefaultName
        DartProfileWriter.testTransport = null
        DartProfileStore.directory = originalDirectory
        DartProfileStore.logger = originalLogger
        DartProfileStore.invalidate()
        SettingsJsonStore.directory = originalSettingsDir
        SettingsJsonStore.legacySettings = originalLegacySettings
        SettingsJsonStore.legacyMarkers = originalLegacyMarkers
        dir.deleteRecursively()
    }

    private fun writeDocument(groups: String = "[]", profiles: String = "[]") {
        File(dir, "profiles.json").writeText(
            """{"version":1,"nextProfileId":10,"nextGroupId":10,"profiles":$profiles,"groups":$groups}"""
        )
        DartProfileStore.invalidate()
    }

    private fun documentText(): String = File(dir, "profiles.json").readText()

    private val twoGroups = """
        [
          {"id":2,"name":"second","display_order":2},
          {"id":1,"name":"first","display_order":1}
        ]
    """.trimIndent()

    @Test
    fun `an empty document is a pure read and never creates the Default group`() {
        writeDocument()
        val before = documentText()
        var writes = 0
        DartProfileWriter.testTransport = { _, _ ->
            writes++
            null
        }

        assertTrue(GroupRepo.all().isEmpty())
        assertTrue(GroupRepo.ids().isEmpty())
        assertNull(GroupRepo.get(1))
        // A listing must not seed a group even when a writer is available; and the file
        // is byte-identical. This is the "hidden empty Default" regression guard.
        assertEquals(0, writes)
        assertEquals(before, documentText())
    }

    @Test
    fun `groups come from the document in tab order`() {
        writeDocument(groups = twoGroups)

        assertEquals(listOf(1L, 2L), GroupRepo.ids())
        assertEquals(listOf(1L, 2L), GroupRepo.all().map { it.id })
        assertEquals("first", GroupRepo.get(1)?.name)
        assertNull(GroupRepo.get(3))
        assertNull(GroupRepo.get(0))
    }

    @Test
    fun `current group is stored in the settings document and resolved from the document`() {
        writeDocument(groups = twoGroups)

        assertEquals(1L, GroupRepo.currentId())
        assertEquals("1", SettingsJsonStore.get("current_group"))
        assertEquals(1L, GroupRepo.current().id)

        GroupRepo.setCurrent(2L)
        assertEquals(2L, GroupRepo.currentId())
        assertEquals(2L, GroupRepo.current().id)
    }

    @Test
    fun `a missing document throws ProfilesDocumentUnavailable and never falls back to Room`() {
        File(dir, "profiles.json").delete()
        DartProfileStore.invalidate()

        assertThrows(ProfilesDocumentUnavailable::class.java) { GroupRepo.all() }
        assertThrows(ProfilesDocumentUnavailable::class.java) { GroupRepo.ids() }
        assertThrows(ProfilesDocumentUnavailable::class.java) { GroupRepo.get(1) }
        assertThrows(ProfilesDocumentUnavailable::class.java) { GroupRepo.currentId() }
    }

    @Test
    fun `a corrupt document throws rather than answering an empty catalog`() {
        File(dir, "profiles.json").writeText("{ not json")
        DartProfileStore.invalidate()

        assertTrue(DartProfileStore.documentExists())
        assertThrows(ProfilesDocumentUnavailable::class.java) { GroupRepo.all() }
    }

    @Test
    fun `an add crosses the document writer and takes the id Dart assigns`() {
        writeDocument()
        var request: Map<*, *>? = null
        DartProfileWriter.testTransport = { method, args ->
            assertEquals("applyDocument", method)
            request = args as Map<*, *>
            mapOf(
                "nextProfileId" to 10,
                "nextGroupId" to 10,
                "profileIds" to emptyMap<String, Long>(),
                "groupIds" to mapOf("-1" to 4L),
            )
        }

        val group = runBlocking { GroupRepo.add(ProxyGroup(name = "sub", url = "https://example.test/sub")) }

        assertEquals(4L, group.id)
        assertEquals(1L, group.displayOrder)
        val row = ((request!!["groups"] as List<*>).single() as Map<*, *>)
        assertEquals("sub", row["name"])
        assertEquals(1L, row["display_order"])
        assertEquals(true, request["allocateIds"])
    }

    @Test
    fun `ensureDefault returns the first group without writing when one exists`() {
        writeDocument(groups = twoGroups)
        val before = documentText()
        var calls = 0
        DartProfileWriter.testTransport = { _, _ ->
            calls++
            null
        }

        val group = GroupRepo.ensureDefault()

        assertEquals(1L, group.id)
        assertEquals(0, calls)
        assertEquals(before, documentText())
    }

    @Test
    fun `ensureDefault creates the single-node container only on the explicit path`() {
        writeDocument()
        var request: Map<*, *>? = null
        DartProfileWriter.testTransport = { _, args ->
            request = args as Map<*, *>
            mapOf("nextProfileId" to 10, "nextGroupId" to 10, "groupIds" to mapOf("-1" to 1L))
        }

        val group = GroupRepo.ensureDefault()

        assertEquals(1L, group.id)
        assertTrue(group.single)
        val row = ((request!!["groups"] as List<*>).single() as Map<*, *>)
        assertEquals("Default", row["name"])
        assertEquals(1L, row["display_order"])
        assertEquals(true, row["single"])
    }

    @Test
    fun `an unnamed local group is the single-node container, not a profile`() {
        // The document seeds a group with no name when its last group is deleted; it
        // renders with the localized default label. Recognising it keeps an import
        // from creating a second "Default" beside it.
        assertTrue(ProxyGroup(name = "").isSingleNodeGroup())
        assertTrue(ProxyGroup(name = "Default").isSingleNodeGroup())
        assertTrue(ProxyGroup(name = "").apply { single = true }.isSingleNodeGroup())
        assertFalse(ProxyGroup(name = "", url = "https://example.test/sub").isSingleNodeGroup())
        assertFalse(ProxyGroup(name = "work").isSingleNodeGroup())
    }
}
