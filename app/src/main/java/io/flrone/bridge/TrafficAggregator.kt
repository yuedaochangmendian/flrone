package io.flrone.bridge

import io.nekohasekai.sagernet.ktx.Logs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Per-connection attribution for the traffic ledger.
 *
 * The core's cumulative totals give an exact grand total but no idea where the bytes went; the
 * clash API's connection list has the destination, outbound, rule and process for every live
 * connection, so one poll every few seconds can turn totals into a breakdown. The math here is
 * pure ([tick]) and the coroutine shell is [TrafficAggregator].
 *
 * The list only contains live connections: a connection that opens and closes between two polls
 * is missing from the breakdown (its bytes are still in the core total). Bettbox sees every
 * connection because its tracker lives in the core; this poller is the closest the host can get
 * without a core change, and the grand total stays exact.
 */
internal object TrafficAttribution {

    private const val maxEntries = 128

    data class Totals(var up: Long = 0, var down: Long = 0) {
        val sum: Long get() = up + down
    }

    /**
     * One tick. [previous] holds each connection's last seen cumulative totals and is updated in
     * place; a connection seen for the first time only sets its baseline (its bytes before the
     * first sighting are not attributed, so the breakdown never exceeds the core total).
     */
    fun tick(
        rows: List<Map<String, Any?>>,
        previous: MutableMap<String, LongArray>,
        details: Boolean,
    ): Map<String, Any?>? {
        val seen = HashSet<String>(rows.size)
        var up = 0L
        var down = 0L
        var proxyUp = 0L
        var proxyDown = 0L
        var directUp = 0L
        var directDown = 0L
        val hosts = HashMap<String, Totals>()
        val nodes = HashMap<String, Totals>()
        val rules = HashMap<String, Totals>()
        val processes = HashMap<String, Totals>()
        for (row in rows) {
            val id = row["id"]?.toString().orEmpty()
            if (id.isEmpty()) continue
            seen += id
            val currentUp = (row["uploadTotal"] as? Number)?.toLong() ?: 0L
            val currentDown = (row["downloadTotal"] as? Number)?.toLong() ?: 0L
            val last = previous[id]
            previous[id] = longArrayOf(currentUp, currentDown)
            if (last == null) continue
            val deltaUp = (currentUp - last[0]).coerceAtLeast(0)
            val deltaDown = (currentDown - last[1]).coerceAtLeast(0)
            if (deltaUp == 0L && deltaDown == 0L) continue
            up += deltaUp
            down += deltaDown
            val outbound = row["outbound"]?.toString().orEmpty()
            val direct = outbound.isBlank() || outbound.equals("DIRECT", true)
            if (direct) {
                directUp += deltaUp
                directDown += deltaDown
            } else {
                proxyUp += deltaUp
                proxyDown += deltaDown
            }
            if (!details) continue
            val host = (row["displayDestination"]?.toString().orEmpty())
                .ifBlank { row["destination"]?.toString().orEmpty() }
                .ifBlank { row["domain"]?.toString().orEmpty() }
            if (host.isNotEmpty()) hosts.add(host, deltaUp, deltaDown)
            if (!direct && outbound.isNotEmpty()) nodes.add(outbound, deltaUp, deltaDown)
            val rule = row["rule"]?.toString().orEmpty()
            if (rule.isNotEmpty()) rules.add(rule, deltaUp, deltaDown)
            val path = (row["process"] as? Map<*, *>)?.get("path")?.toString().orEmpty()
            if (path.isNotEmpty()) {
                val packageName = ProcessPaths.packageFromApkPath(path) ?: path.substringAfterLast('/')
                if (packageName.isNotEmpty()) processes.add(packageName, deltaUp, deltaDown)
            }
        }
        previous.keys.retainAll(seen)
        if (up + down == 0L) return null
        return buildMap {
            put("totalUp", up)
            put("totalDown", down)
            put("proxyUp", proxyUp)
            put("proxyDown", proxyDown)
            put("directUp", directUp)
            put("directDown", directDown)
            if (details) {
                if (hosts.isNotEmpty()) put("hosts", hosts.wire())
                if (nodes.isNotEmpty()) put("nodes", nodes.wire())
                if (rules.isNotEmpty()) put("rules", rules.wire())
                if (processes.isNotEmpty()) put("processes", processes.wire())
            }
        }
    }

    private fun MutableMap<String, Totals>.add(key: String, up: Long, down: Long) {
        val value = getOrPut(key) { Totals() }
        value.up += up
        value.down += down
    }

    private fun Map<String, Totals>.wire(): Map<String, LongArray> =
        entries.sortedByDescending { it.value.sum }.take(maxEntries)
            .associate { it.key to longArrayOf(it.value.up, it.value.down) }
}

/**
 * Polls the clash API's connection list while traffic statistics are on and emits one compact
 * delta per tick. Started and stopped through `trafficStats.watch`; a missing/unreachable API
 * leaves the ledger on the dashboard totals (the breakdown simply stays empty).
 */
internal class TrafficAggregator(
    private val scope: CoroutineScope,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private var job: Job? = null
    private var details = true
    private val previous = HashMap<String, LongArray>()

    fun start(details: Boolean) {
        this.details = details
        if (job != null) return
        job = scope.launch {
            while (isActive) {
                delay(intervalMs)
                val payload = runCatching {
                    if (!BboxApi.enabled()) return@runCatching null
                    val rows = withContext(Dispatchers.IO) {
                        runCatching { BboxApi.connections() }.onFailure { Logs.w(it) }.getOrDefault(emptyList())
                    }
                    withContext(Dispatchers.Default) { TrafficAttribution.tick(rows, previous, details) }
                }.getOrNull()
                if (payload != null) emit(payload)
            }
        }
    }

    fun stop() {
        job?.cancel()
        job = null
        previous.clear()
    }

    companion object {
        /** Five seconds: small enough to lose little of a short connection, cheap for the API. */
        const val intervalMs = 5_000L
    }
}
