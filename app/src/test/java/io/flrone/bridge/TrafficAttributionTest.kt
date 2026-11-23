package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The attribution math is pure, so the deltas are testable without the clash API. */
class TrafficAttributionTest {

    private fun row(
        id: String,
        up: Long,
        down: Long,
        host: String = "a.example",
        outbound: String = "Proxy",
        rule: String = "geosite-example",
        path: String? = "/data/app/~~x/com.example-1/base.apk",
    ) = mapOf(
        "id" to id,
        "uploadTotal" to up,
        "downloadTotal" to down,
        "displayDestination" to host,
        "outbound" to outbound,
        "rule" to rule,
        "process" to path?.let { mapOf("path" to it) },
    )

    @Test
    fun `the first sighting only sets a baseline`() {
        val previous = HashMap<String, LongArray>()
        assertNull(TrafficAttribution.tick(listOf(row("1", 100, 200)), previous, details = true))
        assertEquals(100L, previous["1"]!![0])
    }

    @Test
    fun `deltas are split by proxy and attributed per host node rule and app`() {
        val previous = HashMap<String, LongArray>()
        TrafficAttribution.tick(
            listOf(row("1", 100, 200), row("2", 10, 20, host = "direct.example", outbound = "DIRECT", rule = "geosite-direct")),
            previous,
            details = true,
        )
        val payload = TrafficAttribution.tick(
            listOf(row("1", 300, 500), row("2", 30, 40, host = "direct.example", outbound = "DIRECT", rule = "geosite-direct")),
            previous,
            details = true,
        )!!
        // Both connections contributed: 200 + 20 up and 300 + 20 down.
        assertEquals(220L, payload["totalUp"])
        assertEquals(320L, payload["totalDown"])
        assertEquals(200L, payload["proxyUp"])
        assertEquals(300L, payload["proxyDown"])
        assertEquals(20L, payload["directUp"])
        assertEquals(20L, payload["directDown"])
        @Suppress("UNCHECKED_CAST")
        val hosts = payload["hosts"] as Map<String, LongArray>
        assertEquals(200L, hosts["a.example"]!![0])
        assertEquals(20L, hosts["direct.example"]!![0])
        @Suppress("UNCHECKED_CAST")
        val nodes = payload["nodes"] as Map<String, LongArray>
        assertEquals(setOf("Proxy"), nodes.keys)
        @Suppress("UNCHECKED_CAST")
        val rules = payload["rules"] as Map<String, LongArray>
        assertEquals(2, rules.size)
        @Suppress("UNCHECKED_CAST")
        val processes = payload["processes"] as Map<String, LongArray>
        assertEquals(setOf("com.example"), processes.keys)
    }

    @Test
    fun `a connection that disappears stops contributing`() {
        val previous = HashMap<String, LongArray>()
        TrafficAttribution.tick(listOf(row("1", 100, 100)), previous, details = true)
        TrafficAttribution.tick(listOf(row("1", 150, 150)), previous, details = true)
        assertNull(TrafficAttribution.tick(emptyList(), previous, details = true))
        assertEquals(0, previous.size)
    }

    @Test
    fun `details off keeps the split and drops the maps`() {
        val previous = HashMap<String, LongArray>()
        TrafficAttribution.tick(listOf(row("1", 0, 0)), previous, details = false)
        val payload = TrafficAttribution.tick(listOf(row("1", 10, 20)), previous, details = false)!!
        assertEquals(10L, payload["proxyUp"])
        assertNull(payload["hosts"])
    }
}
