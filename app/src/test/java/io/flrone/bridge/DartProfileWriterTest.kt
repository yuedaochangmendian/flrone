package io.flrone.bridge

import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.SubUserInfo
import io.nekohasekai.sagernet.database.SubscriptionOptions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Kotlin -> Dart write surface (ADR 0005 final stage). Every catalog write
 * maps an entity back to the exact Room column names Dart stores, so a row
 * written here reads back identically through DartProfileStore. A drift in
 * these mappers is silent data corruption on the next config build — pin every
 * nullable and sentinel column here.
 */
class DartProfileWriterTest {

    @Test
    fun `profile row carries every column present on the entity`() {
        val profile = ProxyEntity(
            id = 7L,
            type = "vless",
            name = "node-7",
            groupId = 3L,
            userOrder = 2L,
            latency = 120,
            latencyAt = 1700000000L,
            dlSpeed = "12Mbps",
            ulSpeed = null,
            testCountry = "US",
            ipOut = "1.2.3.4",
            outboundJson = "{\"type\":\"vless\"}",
            rx = 100L,
            tx = 200L,
            testError = null,
        )
        val row = DartProfileWriter.profileRow(profile)
        assertEquals(7L, row["id"])
        assertEquals("vless", row["type"])
        assertEquals("node-7", row["name"])
        assertEquals(3L, row["gid"])
        assertEquals(2L, row["user_order"])
        assertEquals(120, row["latency"])
        assertEquals(1700000000L, row["latency_at"])
        assertEquals("12Mbps", row["dl_speed"])
        assertEquals(null, row["ul_speed"])
        assertEquals("US", row["test_country"])
        assertEquals("1.2.3.4", row["ip_out"])
        assertEquals("{\"type\":\"vless\"}", row["outbound_json"])
        assertEquals(100L, row["traffic_dl"])
        assertEquals(200L, row["traffic_up"])
        assertEquals(null, row["test_error"])
        // The mapper must emit the Room column set exactly, no more and no less.
        assertEquals(15, row.size)
        assertTrue(row.containsKey("traffic_dl"))
    }

    @Test
    fun `group row carries both opaque codecs as text and the -1 sentinels`() {
        val group = ProxyGroup(
            id = 4L,
            archive = true,
            skipAutoUpdate = true,
            name = "sub",
            url = "https://example.test/sub",
            info = "",
            subLastUpdate = 42L,
            frontProxyId = -1L,
            landingProxyId = 9L,
            columnWidthJson = "{\"a\":1}",
            scrollLastProfile = -1,
            autoClearUnavailable = true,
            testSortBy = 1,
            trafficSortBy = 2,
            testItemsToShow = 3,
            typeSortBy = 1,
            subOptions = SubscriptionOptions().apply { updateInterval = 60 },
            subMetadata = SubUserInfo(),
            sortMethod = 2,
            sortDescending = true,
            displayOrder = 5L,
            routeId = -1L,
            importSubRoute = true,
        )
        val row = DartProfileWriter.groupRow(group)
        assertEquals(4L, row["id"])
        assertEquals(true, row["archive"])
        assertEquals(true, row["skip_auto_update"])
        assertEquals("sub", row["name"])
        assertEquals("https://example.test/sub", row["url"])
        assertEquals(42L, row["sub_last_update"])
        assertEquals(-1L, row["front_proxy_id"])
        assertEquals(9L, row["landing_proxy_id"])
        assertEquals(-1, row["scroll_last_profile"])
        assertEquals(-1L, row["route_id"])
        assertEquals(true, row["import_sub_route"])
        assertTrue((row["sub_options_json"] as String).contains("60"))
        assertTrue(row["sub_metadata_json"] is String)
        assertEquals(23, row.size)
    }

    @Test
    fun `without an attached engine writes are inert rather than throwing`() {
        // A JVM test never attaches a Flutter messenger; the writer must no-op
        // so pre-migration/Kotlin-only callers keep their in-memory entities.
        DartProfileWriter.detach()
        assertFalse(DartProfileWriter.attached())
        val p = ProxyEntity(id = 1L, type = "socks", groupId = 1L)
        val result = kotlinx.coroutines.runBlocking {
            DartProfileWriter.addProfiles(listOf(p), 1L)
        }
        assertEquals(1L, result.single().id) // unchanged: no id allocation happened
    }
}
