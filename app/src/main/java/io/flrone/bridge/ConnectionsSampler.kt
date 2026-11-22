package io.flrone.bridge

/**
 * Turns the clash-api's connection rows into the shape the connections page renders.
 *
 * Every clash-api row carries the connection's **cumulative** `upload`/`download` (mihomo's
 * shape). The page shows a per-second rate beside the cumulative total, so each row is
 * sampled against the previous tick: `upload`/`download` become rates over the elapsed wall
 * time while `uploadTotal`/`downloadTotal` keep the cumulative values. Mapping the totals
 * into both fields — what the bridge used to do — printed a connection's whole volume as its
 * rate (`1.2 MB · 1.2 MB/s`).
 *
 * A connection the core stops reporting has closed: the API lists only live ones, so its
 * last row is kept with `closedAt` stamped. That is what makes the page's Active / Closed /
 * All filters mean what they say. The ring is bounded and survives closing the page.
 *
 * Pure JVM (no Android, no clock of its own): the caller passes the monotonic sample instant
 * and the wall-clock close stamp, so a unit test drives this directly.
 */
internal class ConnectionsSampler(private val maxClosed: Int = 200) {

    /** Cumulative byte totals as of the previous tick, keyed by connection id. */
    private val totals = HashMap<String, LongArray>()

    /** Monotonic instant of the previous tick; 0 until the first sample of a window. */
    private var sampledAt = 0L

    /** Recently closed connections, oldest first. */
    private val closed = ArrayDeque<Map<String, Any?>>()

    /** What [sample] returned last time, so a closing connection keeps the row it had. */
    private var lastRows: List<Map<String, Any?>>? = null

    /**
     * Starts a fresh rate window — opening the page, or coming back to it. The first sample
     * then reports 0 B/s instead of averaging the time the page was closed. The closed ring
     * is kept: it is the page's history, not the live window's.
     */
    fun resetWindow() {
        sampledAt = 0L
        totals.clear()
    }

    /** Drops the emitted baseline (the bridge clears it when the page closes). */
    fun resetRows() {
        lastRows = null
    }

    /**
     * One tick: [live] rows straight from the API, [nowMs] the monotonic instant, [closedAt]
     * the wall-clock stamp for rows that just closed. Returns the live rows with rates plus
     * the closed ring.
     */
    fun sample(live: List<Map<String, Any?>>, nowMs: Long, closedAt: Long): List<Map<String, Any?>> {
        val seconds = if (sampledAt == 0L) 0.0 else ((nowMs - sampledAt) / 1000.0).coerceAtLeast(0.001)
        val seen = HashSet<String>(live.size)
        val rows = ArrayList<Map<String, Any?>>(live.size + closed.size)
        for (row in live) {
            val id = row["id"]?.toString().orEmpty()
            if (id.isNotEmpty()) seen += id
            val upload = (row["uploadTotal"] as? Number)?.toLong() ?: 0L
            val download = (row["downloadTotal"] as? Number)?.toLong() ?: 0L
            val previous = if (seconds > 0) totals[id] else null
            totals[id] = longArrayOf(upload, download)
            rows += row.toMutableMap().apply {
                this["upload"] = rate(upload, previous?.get(0), seconds)
                this["download"] = rate(download, previous?.get(1), seconds)
            }
        }
        // Forget a gone connection's totals so a reused id cannot inherit them, and give it a
        // closed row built from the last one the page saw.
        for (id in totals.keys - seen) {
            totals.remove(id)
            val last = lastRows?.firstOrNull { it["id"]?.toString() == id } ?: continue
            closed.addLast(last.toMutableMap().apply {
                this["upload"] = 0L
                this["download"] = 0L
                this["closedAt"] = closedAt
            })
        }
        sampledAt = nowMs
        while (closed.size > maxClosed) closed.removeFirst()
        rows += closed
        lastRows = rows
        return rows
    }

    private fun rate(current: Long, previous: Long?, seconds: Double): Long {
        if (previous == null || seconds <= 0) return 0L
        val delta = current - previous
        if (delta <= 0) return 0L
        return (delta / seconds).toLong()
    }
}
