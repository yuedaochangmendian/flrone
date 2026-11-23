package io.nekohasekai.sagernet.database

import org.json.JSONObject
import java.io.File

/**
 * A READ-ONLY view of the route documents the kernel owns (ADR 0002, phase 3c).
 *
 * Phase 3b had Kotlin writing these files. Once the Go dispatcher answers the routing
 * actions, two writers on one document set is a lost-update waiting to happen — whichever
 * side cached a set first wins. So the writer is Go only (`route_store.go`, `route_actions.go`
 * in the core patch) and this object is the reader: `RouteManager` still needs to answer
 * `ConfigGenerator` and the group route picker synchronously, and it cannot call into Go.
 *
 * There are deliberately NO write methods here. A write goes through the action bus to the
 * kernel (`RouteActions`), never through a second file writer.
 *
 * A missing or unparseable document answers null; ADR 0006 stage C2c2b2 removed the Room
 * fallback, so a caller decides what absence means for it (`RouteManager` answers the
 * built-in Default, the global-rule build answers no rules, the editor reports the file).
 */
object RouteJsonStore {

    private const val PROFILES = "route_profiles"
    private const val RULES = "route_rules"
    private const val GLOBAL_RULES = "global_route_rules"

    /** Parsed rows per document path, with the file version they were parsed from. */
    private class ParsedRows(val modified: Long, val length: Long, val rows: List<JSONObject>?)

    private val parsed = HashMap<String, ParsedRows>()
    private val parsedLock = Any()

    /** Where the documents live; the host sets it once the kernel base path is known. */
    @Volatile
    var directory: File? = null
        set(value) {
            field = value
            // A different directory means different files under the same names; the parsed
            // rows are keyed by path, so this is belt and braces for the read-back below —
            // and it is what keeps the JVM tests (one temp dir per case) independent.
            synchronized(parsedLock) { parsed.clear() }
        }

    /**
     * Diagnostics sink. Injected rather than calling android.util.Log directly: the JVM
     * unit tests exercise the corrupt-file path, and an unmocked Log.w would fail them for
     * a reason that has nothing to do with the behaviour under test.
     */
    @Volatile
    var logger: (String, Throwable?) -> Unit = { message, error ->
        if (error != null) {
            io.nekohasekai.sagernet.ktx.Logs.w(message, error)
        } else {
            io.nekohasekai.sagernet.ktx.Logs.w(message)
        }
    }

    /**
     * True when the kernel has written the document set. Any one file is enough: the export
     * writes all three, and a profile set with no rules is a legitimate state (a fresh
     * Default profile).
     */
    val ready: Boolean
        get() {
            val dir = directory ?: return false
            return File(dir, "$PROFILES.json").isFile ||
                File(dir, "$RULES.json").isFile ||
                File(dir, "$GLOBAL_RULES.json").isFile
        }

    fun allProfiles(): List<RouteProfileEntity>? = readRows(PROFILES)?.mapNotNull(::rowToProfile)

    fun allRules(): List<RouteRuleEntity>? = readRows(RULES)?.mapNotNull(::rowToRule)

    /**
     * The global added-rules pool, in stored order, or null when no document exists.
     *
     * This is the pool `ConfigGenerator` prepends to every profile's own rules. The kernel
     * is its only writer (`route_actions.go`), so Kotlin must read the same document.
     */
    fun allGlobalRules(): List<GlobalRouteRuleEntity>? =
        readRows(GLOBAL_RULES)?.mapNotNull(::rowToGlobalRule)

    /** One profile without its rules, matching `RouteDao.getProfile`. */
    fun getProfile(id: Long): RouteProfileEntity? = allProfiles()?.firstOrNull { it.id == id }

    fun rulesOf(profileId: Long): List<RouteRuleEntity> =
        allRules()?.filter { it.routeProfileId == profileId }?.sortedBy { it.ruleOrder }.orEmpty()

    fun count(): Long = allProfiles()?.size?.toLong() ?: 0L

    fun allIds(): List<Long> = allProfiles()?.map { it.id }?.sorted().orEmpty()

    fun isUsable(id: Long): Boolean = allProfiles()?.firstOrNull { it.id == id }?.let { !it.isRaw } ?: false

    // --- row -> entity ----------------------------------------------------------

    private fun rowToProfile(row: JSONObject) = RouteProfileEntity().apply {
        id = row.optLong("id")
        name = row.optString("name")
        defaultOutboundId = row.optLong("default_outbound_id", -1L)
        isRemote = row.optInt("is_remote") != 0
        remoteUrl = row.optString("remote_url")
        autoUpdate = row.optInt("auto_update") != 0
        remoteLastUpdate = row.optLong("remote_last_update")
        isRaw = row.optInt("is_raw") != 0
        rawRoute = row.optString("raw_route")
        preventModifications = row.optInt("prevent_modifications") != 0
        endpointProfileIds = row.optString("endpoint_profile_ids", "[]")
        innerHopEndpointIds = row.optString("inner_hop_endpoint_ids", "[]")
        dnsJson = row.optString("dns_json")
        customDns = row.optInt("custom_dns") != 0
        sourceGid = row.optLong("source_gid", -1L)
        disabledGlobalRuleJson = row.optString("disabled_global_rule_json", "[]")
    }

    private fun rowToRule(row: JSONObject) = RouteRuleEntity().apply {
        routeProfileId = row.optLong("route_profile_id")
        fillRuleColumns(row)
    }

    /**
     * A global-pool row. The pool has no owning profile, and its primary key is `rule_id`
     * where the kernel writes `id` (`route_actions.go` sets `stored["id"]`); everything
     * else is the same column set as a profile rule.
     */
    private fun rowToGlobalRule(row: JSONObject) = GlobalRouteRuleEntity().apply {
        ruleId = row.optLong("id")
        fillRuleColumns(row)
    }

    /** The columns [RouteRuleColumns] declares, which both rule entities extend. */
    private fun RouteRuleColumns.fillRuleColumns(row: JSONObject) {
        ruleOrder = row.optInt("rule_order")
        name = row.optString("name")
        type = row.optInt("type")
        ipVersion = row.optString("ip_version")
        network = row.optString("network")
        protocol = row.optString("protocol")
        inboundJson = row.optString("inbound_json", "[]")
        domainJson = row.optString("domain_json", "[]")
        domainSuffixJson = row.optString("domain_suffix_json", "[]")
        domainKeywordJson = row.optString("domain_keyword_json", "[]")
        domainRegexJson = row.optString("domain_regex_json", "[]")
        sourceIpCidrJson = row.optString("source_ip_cidr_json", "[]")
        sourceIpIsPrivate = row.optInt("source_ip_is_private") != 0
        ipCidrJson = row.optString("ip_cidr_json", "[]")
        ipIsPrivate = row.optInt("ip_is_private") != 0
        sourcePortJson = row.optString("source_port_json", "[]")
        sourcePortRangeJson = row.optString("source_port_range_json", "[]")
        portJson = row.optString("port_json", "[]")
        portRangeJson = row.optString("port_range_json", "[]")
        processNameJson = row.optString("process_name_json", "[]")
        processPathJson = row.optString("process_path_json", "[]")
        processPathRegexJson = row.optString("process_path_regex_json", "[]")
        packageNameJson = row.optString("package_name_json", "[]")
        packageNameRegexJson = row.optString("package_name_regex_json", "[]")
        networkTypeJson = row.optString("network_type_json", "[]")
        wifiSsidJson = row.optString("wifi_ssid_json", "[]")
        wifiBssidJson = row.optString("wifi_bssid_json", "[]")
        ruleSetJson = row.optString("rule_set_json", "[]")
        sniffersJson = row.optString("sniffers_json", "[]")
        action = row.optString("action")
        outboundId = row.optLong("outbound_id", -1L)
        rejectMethod = row.optString("reject_method")
        overrideAddress = row.optString("override_address")
        overridePort = row.optString("override_port")
        tlsFragment = row.optInt("tls_fragment") != 0
        tlsFragmentFallbackDelay = row.optString("tls_fragment_fallback_delay")
        tlsRecordFragment = row.optInt("tls_record_fragment") != 0
        tlsSpoof = row.optString("tls_spoof")
        tlsSpoofMethod = row.optString("tls_spoof_method")
        strategy = row.optString("strategy")
        disabled = row.optInt("disabled") != 0
        invert = row.optInt("invert") != 0
        noDrop = row.optInt("no_drop") != 0
        sniffOverrideDest = row.optInt("sniff_override_dest") != 0
        networkIsExpensive = row.optInt("network_is_expensive") != 0
    }

    /**
     * Rows of one document, or null when it is absent/unreadable (caller falls back).
     *
     * Parsed once per file version. Callers ask for the same document several times per screen
     * — `RouteManager.get` is `allProfiles()` + `rulesOf()` (two full reads), `groupSettings`
     * walks `current()` and `usable()`, and `ConfigGenerator` re-reads on every build — so a
     * 2000-rule document (about 280 KB, 46 keys a row) was being read and parsed several times
     * for one action, on the IO thread but serially. The kernel is the document's only writer
     * (Go, atomic rename), so the file's timestamp and size are the invalidation signal: it
     * changes whenever the content does, and Kotlin never writes here.
     */
    private fun readRows(name: String): List<JSONObject>? {
        val dir = directory ?: return null
        val file = File(dir, "$name.json")
        if (!file.isFile) return null
        val modified = file.lastModified()
        val length = file.length()
        synchronized(parsedLock) {
            parsed[file.path]?.let {
                if (it.modified == modified && it.length == length) return it.rows
            }
        }
        val rows: List<JSONObject>? = try {
            val root = JSONObject(file.readText())
            val array = root.optJSONArray("rows")
            // Typed explicitly: the two arms of this `if` are `null` and a builder, which Kotlin
            // cannot infer an element type from.
            if (array == null) null else buildList<JSONObject> {
                for (i in 0 until array.length()) array.optJSONObject(i)?.let { add(it) }
            }
        } catch (e: Exception) {
            logger("unreadable $name.json; the caller sees it as absent", e)
            null
        }
        synchronized(parsedLock) { parsed[file.path] = ParsedRows(modified, length, rows) }
        return rows
    }
}
