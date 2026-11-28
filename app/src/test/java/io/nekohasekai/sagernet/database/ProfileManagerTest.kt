package io.nekohasekai.sagernet.database

import io.flrone.bridge.DartProfileStore
import io.flrone.bridge.DartProfileWriter
import io.flrone.bridge.ProfilesDocumentUnavailable
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
 * [ProfileManager] over the Dart-owned `profiles.json` (ADR 0006 stage C2c2b1).
 *
 * Reads map the document (members in `user_order`); a missing/corrupt document throws instead of
 * answering Room. Writes cross [DartProfileWriter] only: the test transport stands in for the Dart
 * engine, so the op and the ids Dart assigns are asserted without a device and without Room.
 */
class ProfileManagerTest {

    private lateinit var dir: File
    private var originalDirectory: File? = null
    private var originalLogger: (String, Throwable?) -> Unit = { _, _ -> }

    @Before
    fun setUp() {
        dir = File.createTempFile("profile-manager", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        originalDirectory = DartProfileStore.directory
        originalLogger = DartProfileStore.logger
        DartProfileStore.directory = dir
        DartProfileStore.logger = { _, _ -> }
        DartProfileStore.invalidate()
    }

    @After
    fun tearDown() {
        DartProfileWriter.testTransport = null
        DartProfileStore.directory = originalDirectory
        DartProfileStore.logger = originalLogger
        DartProfileStore.invalidate()
        dir.deleteRecursively()
    }

    private fun writeDocument(profiles: String = "[]", groups: String = "[]") {
        writeRaw("""{"version":1,"nextProfileId":10,"nextGroupId":10,"profiles":$profiles,"groups":$groups}""")
    }

    private fun writeRaw(json: String) {
        File(dir, "profiles.json").writeText(json)
        DartProfileStore.invalidate()
    }

    private val document = """
        {
          "version": 1,
          "nextProfileId": 4,
          "nextGroupId": 3,
          "profiles": [
            {"id":1,"type":"vmess","name":"n1","gid":1,"user_order":0,"outbound_json":"{}"},
            {"id":2,"type":"trojan","name":"n2","gid":2,"user_order":0,"outbound_json":"{}"},
            {"id":3,"type":"socks","name":"n3","gid":1,"user_order":1,"outbound_json":"{}"}
          ],
          "groups": [
            {"id":1,"name":"first","display_order":1},
            {"id":2,"name":"second","display_order":2}
          ]
        }
    """.trimIndent()

    @Test
    fun `an empty document reads as an empty catalog`() {
        writeDocument()

        assertNull(ProfileManager.getProfile(1))
        assertNull(ProfileManager.getProfile(0))
        assertTrue(ProfileManager.getProfiles(listOf(1, 2)).isEmpty())
        assertTrue(ProfileManager.members(1).isEmpty())
        assertTrue(ProfileManager.memberIds(1).isEmpty())
        assertTrue(ProfileManager.documentAvailable())
    }

    @Test
    fun `profiles map their columns and members follow user_order`() {
        writeRaw(document)

        val one = ProfileManager.getProfile(1)!!
        assertEquals("vmess", one.type)
        assertEquals("n1", one.name)
        assertEquals(1L, one.groupId)

        assertEquals(listOf(1L, 3L), ProfileManager.memberIds(1))
        assertEquals(listOf(1L, 3L), ProfileManager.members(1).map { it.id })
        assertEquals(listOf(2L), ProfileManager.memberIds(2))
        // Ids the caller names are answered from the document (skipping the missing ones).
        assertEquals(listOf(1L, 3L), ProfileManager.getProfiles(listOf(3, 1, 99)).map { it.id })
    }

    @Test
    fun `a missing document throws ProfilesDocumentUnavailable and never falls back to Room`() {
        File(dir, "profiles.json").delete()
        DartProfileStore.invalidate()

        assertFalse(ProfileManager.documentAvailable())
        assertThrows(ProfilesDocumentUnavailable::class.java) { ProfileManager.getProfile(1) }
        assertThrows(ProfilesDocumentUnavailable::class.java) { ProfileManager.getProfiles(listOf(1)) }
        assertThrows(ProfilesDocumentUnavailable::class.java) { ProfileManager.members(1) }
        assertThrows(ProfilesDocumentUnavailable::class.java) { ProfileManager.memberIds(1) }
    }

    @Test
    fun `a corrupt document throws rather than answering an empty catalog`() {
        File(dir, "profiles.json").writeText("{ not json")
        DartProfileStore.invalidate()

        assertTrue(ProfileManager.documentAvailable())
        assertThrows(ProfilesDocumentUnavailable::class.java) { ProfileManager.getProfile(1) }
        assertThrows(ProfilesDocumentUnavailable::class.java) { ProfileManager.members(1) }
    }

    @Test
    fun `an add batch crosses the writer and takes the ids Dart assigns`() {
        writeDocument()
        var request: Map<*, *>? = null
        DartProfileWriter.testTransport = { method, args ->
            assertEquals("applyDocument", method)
            request = args as Map<*, *>
            mapOf(
                "nextProfileId" to 12,
                "nextGroupId" to 10,
                "profileIds" to mapOf("-1" to 11L, "-2" to 12L),
                "groupIds" to emptyMap<String, Long>(),
            )
        }

        val added = runBlocking {
            ProfileManager.addStoredProfileBatch(
                listOf(
                    ProfileManager.StoredRow("invalid", "test-a", "{}"),
                    ProfileManager.StoredRow("invalid", "test-b", "{}"),
                ),
                groupId = 1L,
            )
        }

        assertEquals(listOf(11L, 12L), added.map { it.id })
        assertEquals(listOf(1L, 1L), added.map { it.groupId })
        val rows = request!!["profiles"] as List<*>
        assertEquals(2, rows.size)
        val first = rows.first() as Map<*, *>
        assertEquals(1L, first["gid"])
        assertEquals(0L, first["user_order"])
        assertEquals(1L, (rows.last() as Map<*, *>)["user_order"])
        assertEquals(true, request["allocateIds"])
    }

    @Test
    fun `a canonical stored row is added without constructing the outbound model`() {
        writeDocument()
        var request: Map<*, *>? = null
        DartProfileWriter.testTransport = { method, args ->
            assertEquals("applyDocument", method)
            request = args as Map<*, *>
            mapOf(
                "nextProfileId" to 12,
                "nextGroupId" to 10,
                "profileIds" to mapOf("-1" to 11L),
                "groupIds" to emptyMap<String, Long>(),
            )
        }

        val stored = """{"method":"aes-256-gcm","password":"secret","server":"h","server_port":8388,"type":"shadowsocks"}"""
        val added = runBlocking {
            ProfileManager.addStoredProfile(
                type = "shadowsocks",
                name = "Node A",
                outboundJson = stored,
                groupId = 1L,
            )
        }

        assertEquals(11L, added.id)
        assertEquals(1L, added.groupId)
        assertEquals("shadowsocks", added.type)
        assertEquals("Node A", added.name)
        assertEquals(stored, added.outboundJson)
        val row = (request!!["profiles"] as List<*>).single() as Map<*, *>
        assertEquals("shadowsocks", row["type"])
        assertEquals("Node A", row["name"])
        assertEquals(stored, row["outbound_json"])
        assertEquals(0L, row["user_order"])
    }

    @Test
    fun `an update crosses the writer and no Dart engine leaves the document untouched`() {
        writeRaw(document)
        val before = File(dir, "profiles.json").readText()

        // No transport and no channel: the write is inert (never Room). The test would fail
        // loudly if a Room path remained, because Room cannot open in a JVM test.
        runBlocking { ProfileManager.updateProfile(ProxyEntity(id = 1L, type = "vmess", name = "renamed", groupId = 1L)) }
        assertEquals(before, File(dir, "profiles.json").readText())

        var request: Map<*, *>? = null
        DartProfileWriter.testTransport = { _, args ->
            request = args as Map<*, *>
            mapOf("nextProfileId" to 10, "nextGroupId" to 10)
        }
        runBlocking { ProfileManager.updateProfile(ProxyEntity(id = 1L, type = "vmess", name = "renamed", groupId = 1L)) }
        val row = ((request!!["profiles"] as List<*>).single() as Map<*, *>)
        assertEquals(1L, row["id"])
        assertEquals("renamed", row["name"])
    }
}
