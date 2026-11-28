package io.flrone.core

import org.json.JSONObject

/**
 * C-ABI instance handle owned by the Kotlin host.
 *
 * The gomobile `Instance` class is gone from this path: the handle is the
 * registry id returned by `throne_Mobile_newInstance`, and every operation is
 * one JSON host call. Methods keep the blocking behavior of their typed
 * counterparts; callers run them on the same dispatchers/binder threads.
 */
class CoreInstance internal constructor(val handle: Long) {

    @Volatile
    private var closed = false

    private fun call(method: String, params: JSONObject = JSONObject()): Any? {
        check(!closed) { "instance closed" }
        return CoreHost.call(method, params.put("handle", handle))
    }

    fun start() {
        call("instance_start")
    }

    fun close() {
        if (closed) return
        closed = true
        CoreHost.call("instance_close", JSONObject().put("handle", handle))
    }

    fun updateRuleSets(): RuleSetUpdate {
        val data = call("instance_update_rule_sets") as? JSONObject ?: return RuleSetUpdate(0, "")
        return RuleSetUpdate(data.optInt("updated"), data.optString("error"))
    }

    fun localDNSFailure(): LocalDnsFailure? {
        val data = call("instance_local_dns_failure") as? JSONObject ?: return null
        return LocalDnsFailure(data.optString("servers"))
    }

    fun queryOutboundStats(tag: String, direction: String): Long =
        (call("instance_outbound_stats", JSONObject().put("tag", tag).put("direction", direction)) as? Number)?.toLong() ?: 0L

    fun querySpeedTest(): SpeedTest? {
        val data = CoreHost.call("query_speed_test") as? JSONObject ?: return null
        return SpeedTest(
            tag = data.optString("tag"),
            dlSpeed = data.optString("dlSpeed"),
            ulSpeed = data.optString("ulSpeed"),
            latency = data.optInt("latency"),
            serverName = data.optString("serverName"),
            serverCountry = data.optString("serverCountry"),
            error = data.optString("error"),
            cancelled = data.optBoolean("cancelled"),
            dlBytes = data.optLong("dlBytes"),
            ulBytes = data.optLong("ulBytes"),
            running = data.optBoolean("running"),
        )
    }

    companion object {
        fun stopTests() {
            CoreHost.call("stop_tests")
        }
    }
}

data class RuleSetUpdate(val updated: Int, val error: String)

data class LocalDnsFailure(val servers: String)

/** The kernel's current speed-test snapshot, independent of any instance handle. */
fun querySpeedTest(): SpeedTest {
    val data = CoreHost.call("query_speed_test") as? JSONObject ?: return SpeedTest()
    return SpeedTest(
        tag = data.optString("tag"),
        dlSpeed = data.optString("dlSpeed"),
        ulSpeed = data.optString("ulSpeed"),
        latency = data.optInt("latency"),
        serverName = data.optString("serverName"),
        serverCountry = data.optString("serverCountry"),
        error = data.optString("error"),
        cancelled = data.optBoolean("cancelled"),
        dlBytes = data.optLong("dlBytes"),
        ulBytes = data.optLong("ulBytes"),
        running = data.optBoolean("running"),
    )
}

data class SpeedTest(
    val tag: String = "",
    val dlSpeed: String = "",
    val ulSpeed: String = "",
    val latency: Int = 0,
    val serverName: String = "",
    val serverCountry: String = "",
    val error: String = "",
    val cancelled: Boolean = false,
    val dlBytes: Long = 0L,
    val ulBytes: Long = 0L,
    val running: Boolean = false,
)
