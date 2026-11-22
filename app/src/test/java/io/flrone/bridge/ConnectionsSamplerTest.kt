package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The clash-api reports a connection's **cumulative** bytes; the connections page renders a
 * per-second rate beside that total. The bridge used to map the cumulative value into both,
 * so every row read `1.2 MB · 1.2 MB/s`. These tests pin the sampling contract: the rate is a
 * diff over the elapsed time, a reset restarts the window, and a connection the core stops
 * reporting becomes one closed row.
 */
class ConnectionsSamplerTest {

    private fun row(id: String, upload: Long, download: Long) = mapOf<String, Any?>(
        "id" to id,
        "uploadTotal" to upload,
        "downloadTotal" to download,
        "upload" to upload,
        "download" to download,
    )

    private fun List<Map<String, Any?>>.live() = filter { ((it["closedAt"] as? Number)?.toLong() ?: 0L) == 0L }
    private fun List<Map<String, Any?>>.closed() = filter { ((it["closedAt"] as? Number)?.toLong() ?: 0L) != 0L }

    @Test
    fun `the first sample reports the totals and zero rates`() {
        val rows = ConnectionsSampler().sample(listOf(row("1", 100, 50)), 1_000, 9_000)
        assertEquals(1, rows.size)
        assertEquals(0L, (rows[0]["upload"] as Number).toLong())
        assertEquals(0L, (rows[0]["download"] as Number).toLong())
        assertEquals(100L, (rows[0]["uploadTotal"] as Number).toLong())
        assertEquals(50L, (rows[0]["downloadTotal"] as Number).toLong())
    }

    @Test
    fun `a rate is the delta over the elapsed time`() {
        val sampler = ConnectionsSampler()
        sampler.sample(listOf(row("1", 100, 50)), 1_000, 9_000)
        val rows = sampler.sample(listOf(row("1", 1_100, 250)), 3_000, 9_000)
        // Two seconds passed: 1000 bytes up and 200 down per second.
        assertEquals(500L, (rows[0]["upload"] as Number).toLong())
        assertEquals(100L, (rows[0]["download"] as Number).toLong())
        assertEquals(1_100L, (rows[0]["uploadTotal"] as Number).toLong())
    }

    @Test
    fun `a counter that goes backwards reports zero instead of a negative rate`() {
        val sampler = ConnectionsSampler()
        sampler.sample(listOf(row("1", 5_000, 5_000)), 1_000, 9_000)
        val rows = sampler.sample(listOf(row("1", 1_000, 4_000)), 2_000, 9_000)
        assertEquals(0L, (rows[0]["upload"] as Number).toLong())
        assertEquals(0L, (rows[0]["download"] as Number).toLong())
    }

    @Test
    fun `a connection the core stops reporting becomes one closed row`() {
        val sampler = ConnectionsSampler()
        sampler.sample(listOf(row("1", 100, 10), row("2", 200, 20)), 1_000, 9_000)
        val after = sampler.sample(listOf(row("1", 300, 30)), 2_000, 9_500)
        assertEquals(listOf("1"), after.live().map { it["id"] })
        val closed = after.closed()
        assertEquals(1, closed.size)
        assertEquals("2", closed.single()["id"])
        assertEquals(9_500L, (closed.single()["closedAt"] as Number).toLong())
        assertEquals(0L, (closed.single()["upload"] as Number).toLong())
        // The ring is the page's history: the next tick must not report it a second time.
        val later = sampler.sample(listOf(row("1", 400, 40)), 3_000, 9_600)
        assertEquals(1, later.closed().size)
    }

    @Test
    fun `the closed ring is bounded and drops the oldest`() {
        val sampler = ConnectionsSampler(maxClosed = 2)
        sampler.sample(listOf(row("1", 1, 1), row("2", 2, 2), row("3", 3, 3)), 1_000, 9_000)
        val rows = sampler.sample(emptyList(), 2_000, 9_500)
        assertEquals(listOf("2", "3"), rows.closed().map { it["id"] })
    }

    @Test
    fun `a reset restarts the rate window and keeps the closed history`() {
        val sampler = ConnectionsSampler()
        sampler.sample(listOf(row("1", 100, 10), row("2", 200, 20)), 1_000, 9_000)
        sampler.sample(listOf(row("1", 1_000, 100)), 2_000, 9_500)
        sampler.resetWindow()
        sampler.resetRows()
        // Reopening the page: id 1 is sampled fresh (0 B/s), and the closed row is still there.
        val rows = sampler.sample(listOf(row("1", 9_000, 900)), 20_000, 9_900)
        assertEquals(0L, (rows.live().single()["upload"] as Number).toLong())
        assertEquals(1, rows.closed().size)
        assertTrue((rows.closed().single()["closedAt"] as Number).toLong() > 0L)
    }
}
