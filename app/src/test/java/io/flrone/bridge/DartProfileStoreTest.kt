package io.flrone.bridge

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
 * The Kotlin read view of the Dart-owned profiles.json (ADR 0005 final stage).
 *
 * The critical contract is that a row re-typed from the document is identical
 * to the Room row it replaced — every column, including the opaque codec text
 * and the -1 sentinels. A drift here would make config.build silently use a
 * different node than the one the UI shows. These tests write a document to a
 * temp dir and read it back through the exact mapping production uses.
 */
class DartProfileStoreTest {

    private lateinit var temp: File
    private var originalDirectory: File? = null
    private lateinit var originalLogger: (String, Throwable?) -> Unit

    @Before
    fun setUp() {
        temp = File.createTempFile("dart-profiles", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        originalDirectory = DartProfileStore.directory
        originalLogger = DartProfileStore.logger
        DartProfileStore.directory = temp
        DartProfileStore.logger = { _, _ -> }
        DartProfileStore.invalidate()
    }

    @After
    fun tearDown() {
        DartProfileStore.directory = originalDirectory
        DartProfileStore.logger = originalLogger
        DartProfileStore.invalidate()
        temp.deleteRecursively()
    }

    private fun writeDocument(json: String) {
        File(temp, "profiles.json").writeText(json)
        DartProfileStore.invalidate()
    }

    private val document = """
        {
          "version": 1,
          "name": "profiles",
          "nextProfileId": 4,
          "nextGroupId": 3,
          "profiles": [
            {
              "id": 1, "type": "vmess", "name": "node-1", "gid": 1, "user_order": 0,
              "latency": 120, "latency_at": 1700000000,
              "dl_speed": "12Mbps", "ul_speed": "5Mbps",
              "test_country": "US", "ip_out": "1.2.3.4",
              "outbound_json": "{\"tag\":\"node-1\"}",
              "traffic_dl": 100, "traffic_up": 200, "test_error": null
            },
            {
              "id": 2, "type": "trojan", "name": "node-2", "gid": 1, "user_order": 1,
              "latency": -1, "latency_at": 0,
              "dl_speed": null, "ul_speed": null,
              "test_country": null, "ip_out": null,
              "outbound_json": "{}",
              "traffic_dl": 0, "traffic_up": 0, "test_error": "timeout"
            }
          ],
          "groups": [
            {
              "id": 1, "archive": false, "skip_auto_update": true, "name": "sub",
              "url": "https://example.test/sub", "info": "", "sub_last_update": 42,
              "front_proxy_id": -1, "landing_proxy_id": 2, "column_width_json": "",
              "scroll_last_profile": -1, "auto_clear_unavailable": true,
              "test_sort_by": 1, "traffic_sort_by": 2, "test_items_to_show": 3,
              "type_sort_by": 1,
              "sub_options_json": "{\"update_interval\":60}",
              "sub_metadata_json": "{\"valid\":true,\"total\":1000}",
              "sort_method": 2, "sort_descending": true,
              "display_order": 1, "route_id": -1, "import_sub_route": false
            }
          ]
        }
    """.trimIndent()

    @Test
    fun `profiles map every Room column including nullable and traffic fields`() {
        writeDocument(document)
        assertTrue(DartProfileStore.available())

        val first = DartProfileStore.profile(1)!!
        assertEquals(1L, first.id)
        assertEquals("vmess", first.type)
        assertEquals("node-1", first.name)
        assertEquals(1L, first.groupId)
        assertEquals(0L, first.userOrder)
        assertEquals(120, first.latency)
        assertEquals(1700000000L, first.latencyAt)
        assertEquals("12Mbps", first.dlSpeed)
        assertEquals("5Mbps", first.ulSpeed)
        assertEquals("US", first.testCountry)
        assertEquals("1.2.3.4", first.ipOut)
        assertEquals("{\"tag\":\"node-1\"}", first.outboundJson)
        assertEquals(100L, first.rx)
        assertEquals(200L, first.tx)
        assertNull(first.testError)

        val second = DartProfileStore.profile(2)!!
        assertEquals(-1, second.latency)
        assertEquals("timeout", second.testError)
        assertNull(second.dlSpeed)
    }

    @Test
    fun `groups map every column and the opaque codecs through their Kotlin parsers`() {
        writeDocument(document)
        val group = DartProfileStore.group(1)!!
        assertEquals(1L, group.id)
        assertEquals("sub", group.name)
        assertTrue(group.isSubscription)
        assertTrue(group.skipAutoUpdate)
        assertTrue(group.autoClearUnavailable)
        assertEquals(-1L, group.frontProxyId)
        assertEquals(2L, group.landingProxyId)
        assertEquals(-1, group.scrollLastProfile)
        assertEquals(1, group.testSortBy)
        assertEquals(2, group.trafficSortBy)
        assertEquals(3, group.testItemsToShow)
        assertEquals(1, group.typeSortBy)
        assertEquals(2, group.sortMethod)
        assertTrue(group.sortDescending)
        assertEquals(-1L, group.routeId)
        // The codecs stayed in Kotlin and parsed the document's text columns.
        assertEquals(60, group.subOptions.updateInterval)
        assertTrue(group.subMetadata.valid)
        assertEquals(1000L, group.subMetadata.total)
    }

    @Test
    fun `members are ordered by userOrder then id, and next id never collides`() {
        writeDocument(document)
        assertEquals(listOf(1L, 2L), DartProfileStore.memberIds(1))
        assertTrue(DartProfileStore.nextProfileId() >= 4L)
    }

    @Test
    fun `a missing document reports unavailable with a clear reason, no Room fallback`() {
        File(temp, "profiles.json").delete()
        DartProfileStore.invalidate()
        assertFalse(DartProfileStore.available())
        assertTrue(DartProfileStore.unavailableReason().contains("missing"))
        // ADR 0005: reading a missing document throws instead of silently
        // returning stale Room rows; callers surface the error and may ask Dart
        // to re-migrate.
        assertThrows(ProfilesDocumentUnavailable::class.java) { DartProfileStore.profiles() }
    }

    @Test
    fun `a corrupt document reports unavailable rather than crashing config build`() {
        writeDocument("{ not json")
        assertFalse(DartProfileStore.available())
        // A present-but-corrupt document is NOT treated as pre-migration: every
        // read must fail loudly, never silently fall back to stale Room rows.
        assertTrue(DartProfileStore.documentExists())
        assertTrue(DartProfileStore.unavailableReason().contains("corrupt"))
        assertThrows(ProfilesDocumentUnavailable::class.java) { DartProfileStore.profile(1) }
        assertThrows(ProfilesDocumentUnavailable::class.java) { DartProfileStore.profiles() }
    }

    @Test
    fun `a wrong version is rejected rather than silently mis-mapped`() {
        writeDocument(document.replace("\"version\": 1", "\"version\": 99"))
        assertThrows(ProfilesDocumentUnavailable::class.java) { DartProfileStore.profile(1) }
    }

    @Test
    fun `a parse failure keeps its concrete cause for the in-app diagnostics`() {
        writeDocument("{ not json")
        assertFalse(DartProfileStore.available())
        // The host view shows this instead of a generic "unavailable": the
        // reason is what tells a path mistake apart from a JSON error.
        assertTrue(DartProfileStore.lastError?.isNotEmpty() == true)
        assertTrue(DartProfileStore.unavailableReason().startsWith("profiles.json is unreadable or corrupt: "))
    }

    @Test
    fun `a version mismatch reports the versions it saw`() {
        writeDocument(document.replace("\"version\": 1", "\"version\": 99"))
        assertFalse(DartProfileStore.available())
        assertTrue(DartProfileStore.lastError.orEmpty().contains("unsupported profiles.json version 99"))
    }

    @Test
    fun `a removed file drops the stale parse error`() {
        writeDocument("{ not json")
        assertFalse(DartProfileStore.available())
        assertTrue(DartProfileStore.lastError != null)
        File(temp, "profiles.json").delete()
        assertFalse(DartProfileStore.available())
        // "missing" must not be reported with the old file's JSON exception.
        assertNull(DartProfileStore.lastError)
        assertTrue(DartProfileStore.unavailableReason().contains("missing"))
    }
}
