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

    fun pause() = call("instance_pause")

    fun wake() = call("instance_wake")

    fun resetNetwork() = call("instance_reset_network")

    fun needWIFIState(): Boolean = call("instance_need_wifi_state") as? Boolean ?: false

    fun updateWIFIState() = call("instance_update_wifi_state")

    fun updateRuleSets(): RuleSetUpdate {
        val data = call("instance_update_rule_sets") as? JSONObject ?: return RuleSetUpdate(0, "")
        return RuleSetUpdate(data.optInt("updated"), data.optString("error"))
    }

    fun localDNSFailure(): LocalDnsFailure? {
        val data = call("instance_local_dns_failure") as? JSONObject ?: return null
        return LocalDnsFailure(data.optString("servers"))
    }

    fun status(): Status? {
        val data = call("instance_status") as? JSONObject ?: return null
        return Status(
            memory = data.optLong("memory"),
            goroutines = data.optInt("goroutines"),
            connectionsIn = data.optInt("connectionsIn"),
            connectionsOut = data.optInt("connectionsOut"),
            trafficAvailable = data.optBoolean("trafficAvailable"),
            uplink = data.optLong("uplink"),
            downlink = data.optLong("downlink"),
            uplinkTotal = data.optLong("uplinkTotal"),
            downlinkTotal = data.optLong("downlinkTotal"),
        )
    }

    fun queryOutboundStats(tag: String, direction: String): Long =
        (call("instance_outbound_stats", JSONObject().put("tag", tag).put("direction", direction)) as? Number)?.toLong() ?: 0L

    fun queryAutoSelectors(): List<AutoSelectorStatus> {
        val data = call("instance_query_auto_selectors") as? JSONObject ?: return emptyList()
        val selectors = data.optJSONArray("selectors") ?: return emptyList()
        return buildList(selectors.length()) {
            for (i in 0 until selectors.length()) {
                val row = selectors.optJSONObject(i) ?: continue
                val memberRows = row.optJSONArray("members") ?: org.json.JSONArray()
                val members = buildList(memberRows.length()) {
                    for (j in 0 until memberRows.length()) {
                        val member = memberRows.optJSONObject(j) ?: continue
                        add(
                            AutoSelectorMember(
                                tag = member.optString("tag"),
                                rank = member.optInt("rank"),
                                state = member.optString("state"),
                                selected = member.optBoolean("selected"),
                                selectedUdp = member.optBoolean("selectedUdp"),
                                qualified = member.optBoolean("qualified"),
                                active = member.optBoolean("active"),
                                averageMs = member.optInt("averageMs"),
                                deviationMs = member.optInt("deviationMs"),
                                minMs = member.optInt("minMs"),
                                maxMs = member.optInt("maxMs"),
                                samples = member.optInt("samples"),
                                failures = member.optInt("failures"),
                                probes = member.optInt("probes"),
                                dialTotal = member.optInt("dialTotal"),
                                dialFail = member.optInt("dialFail"),
                                lastOkMs = member.optLong("lastOkMs"),
                                lastProbeMs = member.optLong("lastProbeMs"),
                                cooldownUntilMs = member.optLong("cooldownUntilMs"),
                                lastError = member.optString("lastError"),
                            ),
                        )
                    }
                }
                add(
                    AutoSelectorStatus(
                        tag = row.optString("tag"),
                        phase = row.optString("phase"),
                        selected = row.optString("selected"),
                        selectedUdp = row.optString("selectedUdp"),
                        pinned = row.optString("pinned"),
                        balance = row.optBoolean("balance"),
                        balanceMode = row.optString("balanceMode"),
                        suspended = row.optBoolean("suspended"),
                        suspendedSinceMs = row.optLong("suspendedSinceMs"),
                        membersTotal = row.optInt("membersTotal"),
                        membersProbed = row.optInt("membersProbed"),
                        membersAlive = row.optInt("membersAlive"),
                        membersQualified = row.optInt("membersQualified"),
                        membersCooldown = row.optInt("membersCooldown"),
                        probesInFlight = row.optInt("probesInFlight"),
                        roundsCompleted = row.optInt("roundsCompleted"),
                        lastRoundMs = row.optLong("lastRoundMs"),
                        nextRoundMs = row.optLong("nextRoundMs"),
                        lastSwitchMs = row.optLong("lastSwitchMs"),
                        lastSwitchReason = row.optString("lastSwitchReason"),
                        members = members,
                    ),
                )
            }
        }
    }

    fun autoSelectorAction(tag: String, action: String, member: String) {
        call("instance_auto_selector_action", JSONObject().put("tag", tag).put("action", action).put("member", member))
    }

    fun isAlive(): Boolean = runCatching { call("instance_alive") as? Boolean ?: false }.getOrDefault(false)

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

data class Status(
    val memory: Long,
    val goroutines: Int,
    val connectionsIn: Int,
    val connectionsOut: Int,
    val trafficAvailable: Boolean,
    val uplink: Long,
    val downlink: Long,
    val uplinkTotal: Long,
    val downlinkTotal: Long,
)

data class AutoSelectorStatus(
    val tag: String,
    val phase: String,
    val selected: String,
    val selectedUdp: String,
    val pinned: String,
    val balance: Boolean,
    val balanceMode: String,
    val suspended: Boolean,
    val suspendedSinceMs: Long,
    val membersTotal: Int,
    val membersProbed: Int,
    val membersAlive: Int,
    val membersQualified: Int,
    val membersCooldown: Int,
    val probesInFlight: Int,
    val roundsCompleted: Int,
    val lastRoundMs: Long,
    val nextRoundMs: Long,
    val lastSwitchMs: Long,
    val lastSwitchReason: String,
    val members: List<AutoSelectorMember>,
)

data class AutoSelectorMember(
    val tag: String,
    val rank: Int,
    val state: String,
    val selected: Boolean,
    val selectedUdp: Boolean,
    val qualified: Boolean,
    val active: Boolean,
    val averageMs: Int,
    val deviationMs: Int,
    val minMs: Int,
    val maxMs: Int,
    val samples: Int,
    val failures: Int,
    val probes: Int,
    val dialTotal: Int,
    val dialFail: Int,
    val lastOkMs: Long,
    val lastProbeMs: Long,
    val cooldownUntilMs: Long,
    val lastError: String,
)

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
