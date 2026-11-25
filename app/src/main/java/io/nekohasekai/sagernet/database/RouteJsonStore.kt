package io.nekohasekai.sagernet.database

import org.json.JSONObject
import java.io.File

/**
 * A READ-ONLY view of `global_route_rules.json`, the single global rule table the Go kernel
 * owns (the "unique global rule table" model).
 *
 * Go is the only writer. Kotlin needs a synchronous read here because `ConfigGenerator` cannot
 * call into Go; [RouteManager] attaches these rows to the built-in Default profile for every
 * build. The retired per-profile documents (`route_profiles.json` / `route_rules.json`) are no
 * longer read — only migrated once from an old install (see LegacyDocumentSeed / LegacyRoomReader).
 *
 * A missing or unparseable document answers null; the caller decides what absence means (no
 * global rules for the build). There are deliberately NO write methods here.
 */
object RouteJsonStore {

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

    /** True when the kernel has written the global table. */
    val ready: Boolean
        get() = directory?.let { File(it, "$GLOBAL_RULES.json").isFile } == true

    /**
     * The global rule table, in stored order, or null when no document exists.
     *
     * The kernel is its only writer, so this document is the only source for the build.
     */
    fun allGlobalRules(): List<GlobalRouteRuleEntity>? =
        readRows(GLOBAL_RULES)?.mapNotNull(::rowToGlobalRule)

    // --- row -> entity ----------------------------------------------------------

    /**
     * A global row. The table has no owning profile; its primary key is `rule_id` where the
     * kernel writes `id`; everything else is the shared [RouteRuleColumns] set.
     */
    private fun rowToGlobalRule(row: JSONObject) = GlobalRouteRuleEntity().apply {
        ruleId = row.optLong("id")
        fillRuleColumns(row)
    }

    /** The columns [RouteRuleColumns] declares. */
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
     * Parsed once per file version (mtime + length). The kernel is the document's only writer
     * (Go, atomic rename), so the file's timestamp and size are the invalidation signal.
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
