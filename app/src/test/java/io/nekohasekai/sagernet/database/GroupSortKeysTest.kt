package io.nekohasekai.sagernet.database

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * S8: the group sort's four type-based orders (BY_TYPE / BY_NAME / BY_ADDRESS / BY_SECURITY) read
 * the stored columns through [StoredProfile] instead of a parsed outbound. These pin the orders the
 * old model produced.
 */
class GroupSortKeysTest {

    private fun key(
        profile: ProxyEntity?,
        method: GroupSortMethod,
        testBy: TestBy = TestBy.LATENCY,
        trafficBy: TrafficBy = TrafficBy.TOTAL,
        skipCert: Boolean = false,
    ): GroupSort.SortKey = GroupSort.Keys.of(profile, method, testBy, trafficBy, skipCert)

    private val http = ProxyEntity(
        id = 1, type = "http", name = "Beta",
        outboundJson = """{"type":"http","server":"a.example.com","server_port":8080}""",
    )
    private val shadowsocks = ProxyEntity(
        id = 2, type = "shadowsocks", name = "Alpha",
        outboundJson = """{"type":"shadowsocks","method":"aes-256-gcm","server":"b.example.com","server_port":8388}""",
    )

    @Test
    fun `BY_TYPE orders by the display label`() {
        val httpKey = key(http, GroupSortMethod.BY_TYPE)
        val ssKey = key(shadowsocks, GroupSortMethod.BY_TYPE)

        assertEquals("HTTP", httpKey.text)
        assertEquals("Shadowsocks", ssKey.text)
        assertTrue(GroupSort.Keys.less(httpKey, ssKey, descending = false))
        assertTrue(GroupSort.Keys.less(ssKey, httpKey, descending = true))
    }

    @Test
    fun `BY_NAME orders by the stored name`() {
        val a = key(shadowsocks, GroupSortMethod.BY_NAME)
        val b = key(http, GroupSortMethod.BY_NAME)

        assertEquals("Alpha", a.text)
        assertTrue(GroupSort.Keys.less(a, b, descending = false))
    }

    @Test
    fun `BY_ADDRESS orders by the rendered address`() {
        val a = key(http, GroupSortMethod.BY_ADDRESS)
        val b = key(shadowsocks, GroupSortMethod.BY_ADDRESS)

        assertEquals("a.example.com:8080", a.text)
        assertEquals("b.example.com:8388", b.text)
        assertTrue(GroupSort.Keys.less(a, b, descending = false))
    }

    @Test
    fun `BY_SECURITY orders by the verdict level`() {
        val raw = key(http, GroupSortMethod.BY_SECURITY)
        val encrypted = key(shadowsocks, GroupSortMethod.BY_SECURITY)

        assertEquals(StoredProfile.Level.None.ordinal, raw.level)
        assertEquals(StoredProfile.Level.Secure.ordinal, encrypted.level)
        assertTrue(GroupSort.Keys.less(raw, encrypted, descending = false))
    }

    @Test
    fun `skip_cert moves a CA-verified TLS profile below a raw one`() {
        val tls = ProxyEntity(id = 3, type = "trojan", name = "Tls", outboundJson = """{"type":"trojan","tls":{"enabled":true}}""")
        val raw = ProxyEntity(id = 4, type = "socks", name = "Raw", outboundJson = """{"type":"socks","server":"s.example.com","server_port":1080}""")

        val strict = key(tls, GroupSortMethod.BY_SECURITY, skipCert = false)
        val skipped = key(tls, GroupSortMethod.BY_SECURITY, skipCert = true)
        val rawKey = key(raw, GroupSortMethod.BY_SECURITY)

        assertEquals(StoredProfile.Level.Secure.ordinal, strict.level)
        assertEquals(StoredProfile.Level.Weak.ordinal, skipped.level)
        assertTrue(GroupSort.Keys.less(rawKey, strict, descending = false))
        assertTrue(GroupSort.Keys.less(rawKey, skipped, descending = false))
    }

    @Test
    fun `a profile that cannot be loaded goes last either way`() {
        val present = key(http, GroupSortMethod.BY_TYPE)
        val missing = key(null, GroupSortMethod.BY_TYPE)

        assertTrue(missing.missing)
        assertTrue(GroupSort.Keys.less(present, missing, descending = false))
        assertTrue(GroupSort.Keys.less(present, missing, descending = true))
        assertFalse(GroupSort.Keys.less(missing, present, descending = false))
    }

    @Test
    fun `the test-result orders still read the stored result columns`() {
        val fast = key(http.copy(latency = 50), GroupSortMethod.BY_LATENCY)
        val untested = key(shadowsocks.copy(latency = 0), GroupSortMethod.BY_LATENCY)

        assertEquals(50.0, fast.number, 0.0)
        assertEquals(100000.0, untested.number, 0.0)
        assertTrue(GroupSort.Keys.less(fast, untested, descending = false))
    }
}
