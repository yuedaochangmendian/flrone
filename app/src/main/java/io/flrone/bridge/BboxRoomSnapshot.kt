package io.flrone.bridge

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import androidx.sqlite.db.SupportSQLiteDatabase
import io.nekohasekai.sagernet.database.GlobalRouteRuleEntity
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.RouteProfileEntity
import io.nekohasekai.sagernet.database.RouteRuleEntity
import io.nekohasekai.sagernet.database.SagerDatabase
import io.nekohasekai.sagernet.database.SettingsJsonStore
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import java.io.File
import java.util.Collections
import java.util.concurrent.atomic.AtomicLong

/**
 * Host side of the P14 backup write path.
 *
 * An Android app may only dlopen libraries in public.libraries.txt: AOSP ships
 * no libsqlite3.so and libsqlite.so is not public, so the Dart-side `dart:ffi`
 * reader/writer is null on a stock device and backups cannot open either Room
 * or the temporary snapshot file. This object is the row pump that owns those
 * operations in the process that already owns Room:
 *
 *  - [snapshot] reads Room's live tables through their DAOs (no SQL authored
 *    here), the same column shape #152's `data.roomProfiles` hands Dart;
 *  - [sql] opens a temp snapshot file with the framework SQLiteDatabase (an
 *    in-process platform API, not an app dlopen) or Room's own SupportSQLite
 *    connection, and executes only the parameterized SQL Dart sends — every
 *    `?` is bound by [bind]; this file never composes a SQL string itself;
 *  - [applyRoomSnapshot] commits the staged routes to Room through the DAOs and
 *    the staged settings/markers to their documents (profiles/groups never come
 *    through here: ADR 0006 stage B writes them straight into Dart's
 *    `profiles.json`; settings/markers left Room in stage C2b — schema 21).
 */
object BboxRoomSnapshot {

    /**
     * The two SQL handle kinds [isAllowedSql] validates. Mirrors the [Handle]
     * subtypes: [ROOM] is Room's own read-only connection, [TEMP] is the
     * framework SQLite connection to a throwaway snapshot file. Kept as a plain
     * enum (not [Handle], which carries Android database objects) so the
     * whitelist stays a pure function that JVM tests can call.
     */
    internal enum class SqlHandleKind { ROOM, TEMP }

    // ------------------------------------------------------------------ wire helpers

    private fun value(i: Int, c: Cursor): Any? = when (c.getType(i)) {
        Cursor.FIELD_TYPE_NULL -> null
        Cursor.FIELD_TYPE_INTEGER -> c.getLong(i)
        Cursor.FIELD_TYPE_FLOAT -> c.getDouble(i)
        Cursor.FIELD_TYPE_BLOB -> c.getBlob(i)
        else -> c.getString(i)
    }

    /** Normalize a reply value to the MethodChannel primitive set. */
    private fun wire(v: Any?): Any? = when (v) {
        is Long -> v
        is Int -> v.toLong()
        is Boolean -> if (v) 1L else 0L
        is Short -> v.toLong()
        is Byte -> v.toLong()
        is Float -> v.toDouble()
        is ByteArray -> v
        is String -> v
        is Map<*, *> -> v.entries.associate { it.key.toString() to wire(it.value) }
        is Iterable<*> -> v.map(::wire)
        is Array<*> -> v.map(::wire)
        else -> v
    }

    private fun num(v: Any?, default: Long = 0L): Long = when (v) {
        is Number -> v.toLong()
        is String -> v.trim().toLongOrNull() ?: default
        else -> default
    }

    private fun int(v: Any?, default: Int = 0): Int = num(v, default.toLong()).toInt()
    private fun bool(v: Any?): Boolean = v == true || v == 1 || v == 1L || v == "true" || v == "1"
    private fun text(v: Any?): String = v?.toString() ?: ""

    @Suppress("UNCHECKED_CAST")
    private fun map(v: Any?): Map<String, Any?> =
        (v as? Map<String, Any?>) ?: emptyMap()

    @Suppress("UNCHECKED_CAST")
    private fun list(v: Any?): List<Map<String, Any?>> =
        (v as? List<*>)?.mapNotNull { it as? Map<String, Any?> } ?: emptyList()

    // ------------------------------------------------------------------ DAO reads (create)

    /** Room's live tables as column-keyed row maps, read only through DAOs. */
    fun snapshot(docProfiles: List<Map<String, Any?>>?, docGroups: List<Map<String, Any?>>?): Map<String, Any?> {
        // Profiles/groups: the Dart document is the authority (ADR 0005). When
        // Dart supplies it, echo it back so the desktop snapshot is built from
        // the same rows; otherwise fall back to Room's pre-migration tables.
        val profiles = docProfiles ?: SagerDatabase.proxyDao.getAll().map(::profileRow)
        val groups = docGroups ?: SagerDatabase.groupDao.allGroups().map(::groupRow)
        val routeProfiles = SagerDatabase.routeDao.allProfiles().map(::routeProfileRow)
        val routeRules = SagerDatabase.routeDao.allRules().map(::routeRuleRow)
        val globalRules = SagerDatabase.routeDao.globalRules().map(::globalRuleRow)
        val settings = settingRows()
        val markers = markerRows()
        // AUTOINCREMENT high-water ids from DAO reads (max id). Dart folds these
        // as a lower bound against document-supplied counters, so no sqlite_sequence
        // access is needed here.
        val sequences = mapOf<String, Any?>(
            "profiles" to (profiles.maxOfOrNull { num(it["id"]) } ?: 0L),
            "groups" to (groups.maxOfOrNull { num(it["id"]) } ?: 0L),
            "route_profiles" to (routeProfiles.maxOfOrNull { num(it["id"]) } ?: 0L),
        )
        return mapOf(
            "profiles" to profiles.map(::wire),
            "groups" to groups.map(::wire),
            "routeProfiles" to routeProfiles.map(::wire),
            "routeRules" to routeRules.map(::wire),
            "globalRouteRules" to globalRules.map(::wire),
            "settings" to settings.map(::wire),
            "markers" to markers.map(::wire),
            "sequences" to wire(sequences),
        )
    }

    /** Column shape mirrors `DartProfileWriter.profileRow/groupRow` (#152). */
    private fun profileRow(p: ProxyEntity): Map<String, Any?> = mapOf(
        "id" to p.id, "type" to p.type, "name" to p.name, "gid" to p.groupId,
        "user_order" to p.userOrder, "latency" to p.latency, "latency_at" to p.latencyAt,
        "dl_speed" to p.dlSpeed, "ul_speed" to p.ulSpeed, "test_country" to p.testCountry,
        "ip_out" to p.ipOut, "outbound_json" to p.outboundJson, "traffic_dl" to p.rx,
        "traffic_up" to p.tx, "test_error" to p.testError,
    )

    private fun groupRow(g: ProxyGroup): Map<String, Any?> = mapOf(
        "id" to g.id, "archive" to g.archive, "skip_auto_update" to g.skipAutoUpdate,
        "name" to g.name, "url" to g.url, "info" to g.info,
        "sub_last_update" to g.subLastUpdate, "front_proxy_id" to g.frontProxyId,
        "landing_proxy_id" to g.landingProxyId, "column_width_json" to g.columnWidthJson,
        "scroll_last_profile" to g.scrollLastProfile,
        "auto_clear_unavailable" to g.autoClearUnavailable, "test_sort_by" to g.testSortBy,
        "traffic_sort_by" to g.trafficSortBy, "test_items_to_show" to g.testItemsToShow,
        "type_sort_by" to g.typeSortBy, "sub_options_json" to g.subOptions.toJsonString(),
        "sub_metadata_json" to g.subMetadata.toJsonString(), "sort_method" to g.sortMethod,
        "sort_descending" to g.sortDescending, "display_order" to g.displayOrder,
        "route_id" to g.routeId, "import_sub_route" to g.importSubRoute,
    )

    private fun routeProfileRow(p: RouteProfileEntity): Map<String, Any?> = mapOf(
        "id" to p.id, "name" to p.name, "default_outbound_id" to p.defaultOutboundId,
        "is_raw" to p.isRaw, "raw_route" to p.rawRoute,
        "prevent_modifications" to p.preventModifications, "is_remote" to p.isRemote,
        "remote_url" to p.remoteUrl, "auto_update" to p.autoUpdate,
        "remote_last_update" to p.remoteLastUpdate,
        "endpoint_profile_ids" to p.endpointProfileIds,
        "inner_hop_endpoint_ids" to p.innerHopEndpointIds, "dns_json" to p.dnsJson,
        "custom_dns" to p.customDns, "source_gid" to p.sourceGid,
    )

    private fun routeRuleRow(r: RouteRuleEntity): Map<String, Any?> = mapOf(
        "route_profile_id" to r.routeProfileId, "rule_order" to r.ruleOrder,
        "name" to r.name, "type" to r.type, "ip_version" to r.ipVersion,
        "network" to r.network, "protocol" to r.protocol, "inbound_json" to r.inboundJson,
        "domain_json" to r.domainJson, "domain_suffix_json" to r.domainSuffixJson,
        "domain_keyword_json" to r.domainKeywordJson, "domain_regex_json" to r.domainRegexJson,
        "source_ip_cidr_json" to r.sourceIpCidrJson,
        "source_ip_is_private" to r.sourceIpIsPrivate, "ip_cidr_json" to r.ipCidrJson,
        "ip_is_private" to r.ipIsPrivate, "source_port_json" to r.sourcePortJson,
        "source_port_range_json" to r.sourcePortRangeJson, "port_json" to r.portJson,
        "port_range_json" to r.portRangeJson, "process_name_json" to r.processNameJson,
        "process_path_json" to r.processPathJson,
        "process_path_regex_json" to r.processPathRegexJson,
        "package_name_json" to r.packageNameJson, "rule_set_json" to r.ruleSetJson,
        "invert" to r.invert, "outbound_id" to r.outboundId, "action" to r.action,
        "reject_method" to r.rejectMethod, "no_drop" to r.noDrop,
        "override_address" to r.overrideAddress, "override_port" to r.overridePort,
        "sniffers_json" to r.sniffersJson, "sniff_override_dest" to r.sniffOverrideDest,
        "strategy" to r.strategy, "wifi_ssid_json" to r.wifiSsidJson,
        "wifi_bssid_json" to r.wifiBssidJson, "tls_spoof" to r.tlsSpoof,
        "tls_spoof_method" to r.tlsSpoofMethod, "network_type_json" to r.networkTypeJson,
        "network_is_expensive" to r.networkIsExpensive,
        "package_name_regex_json" to r.packageNameRegexJson,
        "tls_fragment" to r.tlsFragment,
        "tls_fragment_fallback_delay" to r.tlsFragmentFallbackDelay,
        "tls_record_fragment" to r.tlsRecordFragment, "disabled" to r.disabled,
    )

    /** The global pool row: `rule_id` instead of the owner column, the same rule columns. */
    private fun globalRuleRow(r: GlobalRouteRuleEntity): Map<String, Any?> = mapOf(
        "rule_id" to r.ruleId, "rule_order" to r.ruleOrder,
        "name" to r.name, "type" to r.type, "ip_version" to r.ipVersion,
        "network" to r.network, "protocol" to r.protocol, "inbound_json" to r.inboundJson,
        "domain_json" to r.domainJson, "domain_suffix_json" to r.domainSuffixJson,
        "domain_keyword_json" to r.domainKeywordJson, "domain_regex_json" to r.domainRegexJson,
        "source_ip_cidr_json" to r.sourceIpCidrJson,
        "source_ip_is_private" to r.sourceIpIsPrivate, "ip_cidr_json" to r.ipCidrJson,
        "ip_is_private" to r.ipIsPrivate, "source_port_json" to r.sourcePortJson,
        "source_port_range_json" to r.sourcePortRangeJson, "port_json" to r.portJson,
        "port_range_json" to r.portRangeJson, "process_name_json" to r.processNameJson,
        "process_path_json" to r.processPathJson,
        "process_path_regex_json" to r.processPathRegexJson,
        "package_name_json" to r.packageNameJson, "rule_set_json" to r.ruleSetJson,
        "invert" to r.invert, "outbound_id" to r.outboundId, "action" to r.action,
        "reject_method" to r.rejectMethod, "no_drop" to r.noDrop,
        "override_address" to r.overrideAddress, "override_port" to r.overridePort,
        "sniffers_json" to r.sniffersJson, "sniff_override_dest" to r.sniffOverrideDest,
        "strategy" to r.strategy, "wifi_ssid_json" to r.wifiSsidJson,
        "wifi_bssid_json" to r.wifiBssidJson, "tls_spoof" to r.tlsSpoof,
        "tls_spoof_method" to r.tlsSpoofMethod, "network_type_json" to r.networkTypeJson,
        "network_is_expensive" to r.networkIsExpensive,
        "package_name_regex_json" to r.packageNameRegexJson,
        "tls_fragment" to r.tlsFragment,
        "tls_fragment_fallback_delay" to r.tlsFragmentFallbackDelay,
        "tls_record_fragment" to r.tlsRecordFragment, "disabled" to r.disabled,
    )

    // ------------------------------------------------------------------ DAO writes (restore)

    /**
     * Commits the Dart-staged routes to Room and the staged settings/markers to
     * their documents. Rows are keyed by column names; entity construction is a
     * straight field copy (no SQL). Device-local settings are never overwritten,
     * matching the Dart writer's `backupDeviceLocalKeys` merge (Dart already
     * filtered them out).
     *
     * ADR 0006 stage B: profiles/groups are deliberately absent. The restore
     * writes them straight into the Dart-owned `profiles.json` (their only
     * copy), so this call only repairs the selection settings — and it does so
     * from the ids Dart sends (`restoredGroupIds`/`restoredProfileIds`), never
     * from Room's now-unwritten profile tables, which stop being the catalog
     * once the document exists.
     *
     * ADR 0006 stage C2b: settings and markers left Room (schema 21), so they
     * cannot join the Room transaction: the routes commit in it, and the
     * document writes follow it. A document failure therefore leaves the routes
     * committed — the restore is retryable from the same container, which is
     * the same contract as the rest of the host path.
     */
    @Suppress("UNCHECKED_CAST")
    fun applyRoomSnapshot(args: Map<String, Any?>): Map<String, Any?> {
        val db = SagerDatabase.instance
        val doProfiles = bool(args["doProfiles"])
        val doRoutes = bool(args["doRoutes"])
        val doSettings = bool(args["doSettings"])
        val fromAndroid = bool(args["fromAndroid"])
        // ADR 0006 stage C2b: an absent block means "the container carried
        // nothing for this part", not "empty it" — a blank `settings` table in a
        // container must not wipe the phone's settings. An older Dart build
        // sends neither key; then the old behaviour (apply what arrived) holds.
        val hasSettings = if (args.containsKey("hasSettings")) bool(args["hasSettings"]) else true
        val hasMarkers = if (args.containsKey("hasMarkers")) bool(args["hasMarkers"]) else true
        val androidOnlyKeys = ANDROID_ONLY_SETTINGS
        val warnings = ArrayList<String>()

        db.runInTransaction {
            if (doRoutes) {
                val profiles = table(args["routeProfiles"]).map(::toRouteProfile)
                val rules = table(args["routeRules"]).map(::toRouteRule)
                SagerDatabase.routeDao.reset()
                profiles.forEach { SagerDatabase.routeDao.insertProfile(it) }
                if (rules.isNotEmpty()) SagerDatabase.routeDao.insertRules(rules)
                if (profiles.none { !it.isRaw }) {
                    // Parity with Dart's `_insertDefaultRoute`: the Default
                    // route ships with its DNS-hijack rule. The empty shell the
                    // host used to insert let DNS past the tunnel on restores
                    // that reached this path (Android/host) only.
                    val defaultId = SagerDatabase.routeDao.insertProfile(
                        RouteProfileEntity(name = "Default", defaultOutboundId = -1L),
                    )
                    SagerDatabase.routeDao.insertRules(listOf(RouteRuleEntity().apply {
                        routeProfileId = defaultId
                        ruleOrder = 0
                        name = "Route DNS"
                        protocol = "dns"
                        action = "hijack-dns"
                    }))
                }
            }
            // Dart's `_commit`: a one-sided restore clears the references into the
            // side that was replaced. For a profiles-only restore that is Room's
            // seed copy of the groups (the live groups' `route_id` reset happens
            // in the document Dart just wrote); for a routes-only restore the
            // routes' `source_gid` loses the groups they named.
            if (doProfiles != doRoutes) {
                SagerDatabase.groupDao.resetRouteIds()
                SagerDatabase.routeDao.resetSourceGids()
            }
            // Parity with Dart's `_commit`: a backup that leaves dangling
            // references must fail the restore instead of committing a
            // half-consistent database. The throw rolls the Room transaction
            // back, exactly like the FFI path's foreign_key_check gate.
            db.openHelper.writableDatabase.query("PRAGMA foreign_key_check").use { cursor ->
                if (cursor.count > 0) {
                    error("restore rejected: the backup leaves ${cursor.count} dangling reference(s)")
                }
            }
            // Counters: @Insert with explicit ids advances sqlite_sequence to
            // the highest id automatically; no separate counter write needed.
        }
        if (doSettings) {
            // ADR 0006 stage C2b: the settings/markers documents are the store;
            // SettingsJsonStore is mounted in every process (SagerNet.onCreate).
            // A blank container part replaces nothing (see hasSettings/hasMarkers
            // above), so the phone's values survive a restore from a container
            // that carried no settings rows.
            if (hasSettings) {
                val incoming = map(args["settings"]).mapValues { text(it.value) }
                for (existing in settings().keys) {
                    if (DEVICE_LOCAL_SETTINGS.contains(existing)) continue
                    if (!fromAndroid && androidOnlyKeys.contains(existing)) continue
                    if (!incoming.containsKey(existing)) deleteSetting(existing)
                }
                for ((key, v) in incoming) {
                    if (DEVICE_LOCAL_SETTINGS.contains(key)) continue
                    if (!fromAndroid && androidOnlyKeys.contains(key)) {
                        // Desktop backup on Android: Android-only keys are
                        // INSERT OR IGNORE - keep the phone's value if present.
                        if (setting(key) == null) putSetting(key, v)
                        continue
                    }
                    putSetting(key, v)
                }
            }
            if (hasMarkers) replaceMarkers(table(args["markers"]))
            // Same guard as Dart's `_lanWasOn`: a backup that allowed other
            // devices to connect is restored with the host closed and the
            // caller told, instead of silently re-exposing the proxy.
            val inbound = if (hasSettings) setting("inbound_address")?.trim() else null
            if (!inbound.isNullOrEmpty() && inbound != "127.0.0.1") {
                putSetting("inbound_address", "127.0.0.1")
                warnings += "The backup lets other devices connect (inbound address $inbound); " +
                    "this was turned off. Turn it on again in the inbound settings if you need it."
            }
        }
        // Selection repair (Dart's `_fixSelection`): point the selection
        // settings at rows that actually exist after the replacement. A
        // restored profiles document is the live catalog, so Dart sends its
        // ids; without them (a container with no profiles part, or a
        // pre-migration install with no document) Room is still the catalog.
        // All reads/writes go through the routed store, never hand-written SQL.
        if (doProfiles || doSettings) {
            val groups = restoredIds(args["restoredGroupIds"])
                ?: SagerDatabase.groupDao.allGroups().map { it.id }
            val currentGroup = setting("current_group")
            if (currentGroup == null || groups.none { it.toString() == currentGroup.trim() }) {
                putOrDeleteSetting("current_group", groups.firstOrNull()?.toString())
            }
            val profileIds = restoredIds(args["restoredProfileIds"])?.toSet()
                ?: SagerDatabase.proxyDao.getAll().map { it.id }.toSet()
            // Desktop backup: the desktop's `remember_id` is the selected
            // node; translate it to Android's profileId/profileCurrent only
            // when it names a row that actually made it into the restore.
            if (doSettings && doProfiles && !fromAndroid) {
                val remember = map(args["settings"])["remember_id"]?.toString()?.trim()?.toLongOrNull()
                if (remember != null && remember in profileIds) {
                    putOrDeleteSetting("profileId", remember.toString())
                    putOrDeleteSetting("profileCurrent", remember.toString())
                }
            }
            for (key in listOf("profileId", "profileCurrent")) {
                val id = setting(key)?.trim()?.toLongOrNull()
                if (id != null && id > 0 && id !in profileIds) {
                    deleteSetting(key)
                }
            }
        }
        if (doRoutes || doSettings) {
            val usable = SagerDatabase.routeDao.allProfiles().filter { !it.isRaw }.map { it.id }
            val currentRoute = setting("current_route_id")
            if (currentRoute == null || usable.none { it.toString() == currentRoute.trim() }) {
                putOrDeleteSetting("current_route_id", usable.firstOrNull()?.toString())
            }
        }

        // Any warning the host produced while committing (e.g. the LAN reset
        // above). Dart owns the document outcome now, so no rows come back.
        return mapOf("warnings" to warnings)
    }

    /** The ids Dart sent, or null when it sent none (Room stays the source). */
    private fun restoredIds(v: Any?): List<Long>? {
        val list = v as? List<*> ?: return null
        return list.map { num(it) }
    }

    /**
     * ADR 0006 stage C2b: settings and markers live in the documents
     * (`settings.json` / `markers.json`) — Room's tables were dropped in schema
     * 21 — so every read/write in this file routes through these, and the
     * document is required: the restore has no second store to write.
     */
    private fun documents(): Unit = check(SettingsJsonStore.mounted) {
        "the settings document is not mounted; the host restore needs it"
    }

    private fun setting(key: String): String? {
        documents()
        return SettingsJsonStore.get(key)
    }

    private fun settings(): Map<String, String> {
        documents()
        return SettingsJsonStore.all()
    }

    private fun putSetting(key: String, value: String) {
        documents()
        SettingsJsonStore.put(key, value)
    }

    private fun deleteSetting(key: String) {
        documents()
        SettingsJsonStore.remove(key)
    }

    private fun settingRows(): List<Map<String, Any?>> =
        settings().map { (key, value) -> mapOf<String, Any?>("key" to key, "value" to value) }

    private fun markerRows(): List<Map<String, Any?>> {
        documents()
        return SettingsJsonStore.markers().map { (key, at) ->
            mapOf<String, Any?>("key" to key, "marked_at" to at)
        }
    }

    private fun replaceMarkers(rows: List<Map<String, Any?>>) {
        documents()
        SettingsJsonStore.replaceMarkers(
            rows.associate { text(it["key"]) to num(it["marked_at"]) },
        )
    }

    private fun putOrDeleteSetting(key: String, value: String?) {
        if (value == null) deleteSetting(key)
        else putSetting(key, value)
    }

    /**
     * One staged table from Dart. `_hostRestoreArgs` sends
     * `{columns: [name...], rows: [[v...]...]}`; a column-keyed row list is
     * still accepted for an older Dart build.
     *
     * A malformed row fails loudly instead of being skipped: the caller has
     * already reset the live table, so a silently short table would commit the
     * reset and wipe the user's nodes/routes (the P14 wire-shape bug this
     * parser exists to prevent).
     */
    internal fun tableRows(v: Any?): List<Map<String, Any?>> {
        if (v is Map<*, *>) {
            if (v.isEmpty()) return emptyList()
            val columns = (v["columns"] as? List<*>)?.map { it.toString() }
                ?: error("staged table has no columns")
            val rows = v["rows"] as? List<*>
                ?: error("staged table has no rows")
            return rows.mapIndexed { index, row ->
                val values = row as? List<*>
                    ?: error("staged row $index is not a list")
                if (values.size != columns.size) {
                    error("staged row $index has ${values.size} values for ${columns.size} columns")
                }
                val out = LinkedHashMap<String, Any?>(columns.size * 2)
                columns.forEachIndexed { i, name -> out[name] = values[i] }
                out
            }
        }
        return list(v)
    }

    private fun table(v: Any?): List<Map<String, Any?>> = tableRows(v)

    private fun toRouteProfile(m: Map<String, Any?>) = RouteProfileEntity(
        id = num(m["id"]), name = text(m["name"]),
        defaultOutboundId = num(m["default_outbound_id"], -1L),
        isRaw = bool(m["is_raw"]), rawRoute = text(m["raw_route"]),
        preventModifications = bool(m["prevent_modifications"]),
        isRemote = bool(m["is_remote"]), remoteUrl = text(m["remote_url"]),
        autoUpdate = bool(m["auto_update"]), remoteLastUpdate = num(m["remote_last_update"]),
        endpointProfileIds = text(m["endpoint_profile_ids"]),
        innerHopEndpointIds = text(m["inner_hop_endpoint_ids"]),
        dnsJson = text(m["dns_json"]), customDns = bool(m["custom_dns"]),
        sourceGid = num(m["source_gid"], -1L),
    )

    private fun toRouteRule(m: Map<String, Any?>) = RouteRuleEntity().apply {
        routeProfileId = num(m["route_profile_id"]); ruleOrder = int(m["rule_order"])
        name = text(m["name"]); type = int(m["type"]); ipVersion = text(m["ip_version"])
        network = text(m["network"]); protocol = text(m["protocol"])
        inboundJson = text(m["inbound_json"]); domainJson = text(m["domain_json"])
        domainSuffixJson = text(m["domain_suffix_json"])
        domainKeywordJson = text(m["domain_keyword_json"])
        domainRegexJson = text(m["domain_regex_json"])
        sourceIpCidrJson = text(m["source_ip_cidr_json"])
        sourceIpIsPrivate = bool(m["source_ip_is_private"]); ipCidrJson = text(m["ip_cidr_json"])
        ipIsPrivate = bool(m["ip_is_private"]); sourcePortJson = text(m["source_port_json"])
        sourcePortRangeJson = text(m["source_port_range_json"]); portJson = text(m["port_json"])
        portRangeJson = text(m["port_range_json"]); processNameJson = text(m["process_name_json"])
        processPathJson = text(m["process_path_json"])
        processPathRegexJson = text(m["process_path_regex_json"])
        packageNameJson = text(m["package_name_json"]); ruleSetJson = text(m["rule_set_json"])
        invert = bool(m["invert"]); outboundId = num(m["outbound_id"], -2L)
        action = text(m["action"]); rejectMethod = text(m["reject_method"])
        noDrop = bool(m["no_drop"]); overrideAddress = text(m["override_address"])
        overridePort = text(m["override_port"]); sniffersJson = text(m["sniffers_json"])
        sniffOverrideDest = bool(m["sniff_override_dest"]); strategy = text(m["strategy"])
        wifiSsidJson = text(m["wifi_ssid_json"]); wifiBssidJson = text(m["wifi_bssid_json"])
        tlsSpoof = text(m["tls_spoof"]); tlsSpoofMethod = text(m["tls_spoof_method"])
        networkTypeJson = text(m["network_type_json"])
        networkIsExpensive = bool(m["network_is_expensive"])
        packageNameRegexJson = text(m["package_name_regex_json"])
        tlsFragment = bool(m["tls_fragment"])
        tlsFragmentFallbackDelay = text(m["tls_fragment_fallback_delay"])
        tlsRecordFragment = bool(m["tls_record_fragment"]); disabled = bool(m["disabled"])
    }

    // ------------------------------------------------------------------ parameterized SQL transport (temp DB + Room)

    private sealed class Handle {
        class Temp(val db: SQLiteDatabase) : Handle()
        class Room(val db: SupportSQLiteDatabase) : Handle()
    }

    private val handles = Collections.synchronizedMap(HashMap<String, Handle>())
    private val handleSeq = AtomicLong(1)

    /**
     * The one door Dart has to a file through `data.roomSql`, so it only opens files inside the
     * app's own storage.
     *
     * The paths are Dart's (a staged restore snapshot, an embedded backup database). A
     * path-construction bug upstream must not become a read or write of anything else — the live
     * Room database next door included — so every path is canonicalized and checked against the
     * private roots before it is used. `SubscriptionQueue.importFile` applies the same rule to
     * the other file door.
     */
    fun confinedFile(path: String): File {
        require(path.isNotBlank()) { "data.roomSql needs a path" }
        val file = File(path).canonicalFile
        val roots = listOfNotNull(
            app.filesDir,
            app.cacheDir,
            app.noBackupFilesDir,
            app.getExternalFilesDir(null),
        ).mapNotNull { runCatching { it.canonicalFile }.getOrNull() }
        require(roots.any { root -> file == root || file.path.startsWith(root.path + File.separator) }) {
            "data.roomSql path is outside the app's private storage: $path"
        }
        return file
    }

    /** Opens a temp snapshot DB (framework SQLite) or Room's own connection. */
    fun openSql(args: Map<String, Any?>): Map<String, Any?> {
        val write = bool(args["write"])
        val path = text(args["path"])
        val handle = if (args["op"] == "openRoom") {
            // Room's handle is only ever used for schema/row reads on the host
            // path: the restore commit goes through data.applyRoomSnapshot's
            // DAOs. Opening it read-only keeps a Dart-authored statement from
            // writing the live database.
            Handle.Room(SagerDatabase.instance.openHelper.readableDatabase)
        } else {
            val flags = if (write) {
                SQLiteDatabase.CREATE_IF_NECESSARY or SQLiteDatabase.NO_LOCALIZED_COLLATORS
            } else {
                SQLiteDatabase.NO_LOCALIZED_COLLATORS
            }
            Handle.Temp(SQLiteDatabase.openDatabase(confinedFile(path).path, null, flags))
        }
        val id = "sql-${handleSeq.getAndIncrement()}"
        handles[id] = handle
        return mapOf("handle" to id)
    }

    fun closeSql(args: Map<String, Any?>) {
        val handle = handles.remove(text(args["handle"])) ?: return
        when (handle) {
            is Handle.Temp -> runCatching { handle.db.close() }
            is Handle.Room -> Unit // Room owns this connection; never close it here.
        }
    }

    private fun bindStatement(stmt: android.database.sqlite.SQLiteStatement, params: List<Any?>) {
        params.forEachIndexed { i, v ->
            val index = i + 1
            when (v) {
                null -> stmt.bindNull(index)
                is Number -> stmt.bindLong(index, v.toLong())
                is Boolean -> stmt.bindLong(index, if (v) 1L else 0L)
                is String -> stmt.bindString(index, v)
                is ByteArray -> stmt.bindBlob(index, v)
                else -> stmt.bindString(index, v.toString())
            }
        }
    }

    private fun bindStatement(stmt: androidx.sqlite.db.SupportSQLiteStatement, params: List<Any?>) {
        params.forEachIndexed { i, v ->
            val index = i + 1
            when (v) {
                null -> stmt.bindNull(index)
                is Number -> stmt.bindLong(index, v.toLong())
                is Boolean -> stmt.bindLong(index, if (v) 1L else 0L)
                is String -> stmt.bindString(index, v)
                is ByteArray -> stmt.bindBlob(index, v)
                else -> stmt.bindString(index, v.toString())
            }
        }
    }

    // ------------------------------------------------------------------ SQL whitelist

    /** Leading keywords permitted on Room's read-only connection (query only). */
    private val ROOM_KEYWORDS = setOf("SELECT", "PRAGMA")

    /**
     * The pragmas a backup read may ask Room. Every one is a read; scalar
     * pragmas must be bare (`PRAGMA journal_mode` reads, `journal_mode(WAL)`
     * writes), see [ROOM_ARGUMENT_PRAGMAS] for the schema-introspection forms.
     */
    private val ROOM_READ_PRAGMAS = setOf(
        "table_info", "table_xinfo", "index_list", "index_info", "index_xinfo",
        "foreign_key_list", "foreign_key_check", "database_list", "collation_list",
        "compile_options", "integrity_check", "quick_check",
        "user_version", "schema_version", "page_count", "page_size",
        "freelist_count", "journal_mode", "cache_size", "synchronous",
        "temp_store", "locking_mode", "auto_vacuum", "mmap_size",
        "wal_autocheckpoint", "busy_timeout",
    )

    /** Pragmas whose function-call argument is a read (a table/index name). */
    private val ROOM_ARGUMENT_PRAGMAS = setOf(
        "table_info", "table_xinfo", "index_list", "index_info", "index_xinfo",
        "foreign_key_list", "integrity_check", "quick_check",
    )

    /**
     * Leading keywords permitted on the temp snapshot handle: the statement
     * types the backup rebuild actually needs. Anything else (ATTACH, VACUUM,
     * triggers, ...) is refused before it ever reaches SQLite.
     */
    private val TEMP_KEYWORDS = setOf(
        "CREATE", "INSERT", "DELETE", "UPDATE", "DROP", "ALTER",
        "PRAGMA", "SELECT", "BEGIN", "COMMIT", "ROLLBACK",
    )

    /**
     * Blanks out string literals ('...', "...", `...`) and comments (`--`,
     * `/{asterisk} ... {asterisk}/`), keeping the same length, so a `;` inside
     * them cannot be mistaken for a statement separator. Pure: no Android API.
     */
    private fun maskSql(sql: String): String {
        val out = sql.toCharArray()
        val n = out.size
        var i = 0
        fun blank(from: Int, to: Int) {
            for (j in from until to) if (out[j] != '\n' && out[j] != '\r') out[j] = ' '
        }
        while (i < n) {
            val c = out[i]
            when {
                c == '\'' || c == '"' || c == '`' -> {
                    val quote = c
                    out[i] = ' '; i++
                    while (i < n) {
                        if (out[i] == quote) {
                            out[i] = ' '; i++
                            // SQL escapes a quote by doubling it: stay in the literal.
                            if (i < n && out[i] == quote) { out[i] = ' '; i++; continue }
                            break
                        }
                        out[i] = ' '; i++
                    }
                }
                c == '-' && i + 1 < n && out[i + 1] == '-' -> {
                    var j = i + 2
                    while (j < n && out[j] != '\n' && out[j] != '\r') j++
                    blank(i, j); i = j
                }
                c == '/' && i + 1 < n && out[i + 1] == '*' -> {
                    var j = i + 2
                    while (j + 1 < n && !(out[j] == '*' && out[j + 1] == '/')) j++
                    val end = if (j + 1 < n) j + 2 else n
                    blank(i, end); i = end
                }
                else -> i++
            }
        }
        return String(out)
    }

    /**
     * Pure SQL whitelist used by both [exec] and [query]. Validates the first
     * keyword against the handle kind and rejects multi-statement input (only
     * one trailing semicolon is tolerated, and semicolons inside literals or
     * comments do not count). Leading whitespace/comments are tolerated.
     *
     * This only *checks* a statement Dart authored — it never builds one.
     */
    internal fun isAllowedSql(kind: SqlHandleKind, sql: String): Boolean {
        val masked = maskSql(sql)
        val code = masked.trim()
        if (code.isEmpty()) return false
        // At most one trailing `;`; none anywhere else in executable code.
        val body = if (code.endsWith(";")) code.substring(0, code.length - 1).trimEnd() else code
        if (body.isEmpty() || body.contains(';')) return false

        val keyword = body.takeWhile { it.isLetter() }.uppercase()
        val allowed = when (kind) {
            SqlHandleKind.ROOM -> ROOM_KEYWORDS
            SqlHandleKind.TEMP -> TEMP_KEYWORDS
        }
        if (keyword !in allowed) return false
        // writable_schema disables SQLite's schema checks and would let a
        // statement smuggle arbitrary structure past the whitelist.
        if (body.contains("writable_schema", ignoreCase = true)) return false
        // PRAGMA is only a read on the Room handle. Assignments (`= …`) are
        // rejected, and so is the function-style write form: SQLite accepts
        // `PRAGMA journal_mode(WAL)` / `PRAGMA cache_size(-2000)` as writers
        // without an equals sign. Only the schema-introspection pragmas take an
        // argument, and every other pragma must be the bare read form.
        if (kind == SqlHandleKind.ROOM && keyword == "PRAGMA") {
            if (body.contains('=')) return false
            val rest = body.substring(keyword.length).trimStart()
            val name = rest.takeWhile { it.isLetter() || it == '_' }.lowercase()
            if (name !in ROOM_READ_PRAGMAS) return false
            val argument = rest.substring(name.length).trim()
            if (argument.isNotEmpty()) {
                if (!argument.startsWith("(") || !argument.endsWith(")")) return false
                if (name !in ROOM_ARGUMENT_PRAGMAS) return false
                if (argument.contains('=')) return false
            }
        }
        if (kind == SqlHandleKind.TEMP) {
            val second = body.substring(keyword.length).trimStart().takeWhile { it.isLetter() }.uppercase()
            when (keyword) {
                "CREATE" -> if (second != "TABLE" && second != "INDEX") return false
                "DROP", "ALTER" -> if (second != "TABLE") return false
            }
        }
        return true
    }

    private fun sqlNotAllowed(kind: SqlHandleKind, sql: String) = IllegalArgumentException(
        "SQL statement is not allowed on the ${kind.name} handle: '${sql.take(80)}'. " +
            when (kind) {
                SqlHandleKind.ROOM -> "Only SELECT and PRAGMA reads are permitted on Room; " +
                    "restore commits go through data.applyRoomSnapshot."
                SqlHandleKind.TEMP -> "Only ${TEMP_KEYWORDS.sorted().joinToString(", ")} " +
                    "are permitted on the temp snapshot handle, one statement at a time."
            }
    )

    private fun kindOf(handle: Handle): SqlHandleKind = when (handle) {
        is Handle.Room -> SqlHandleKind.ROOM
        is Handle.Temp -> SqlHandleKind.TEMP
    }

    /** Executes only Dart-authored parameterized SQL; never composes SQL here. */
    fun exec(args: Map<String, Any?>): Long {
        val handle = handles[text(args["handle"])] ?: error("unknown SQL handle")
        val sql = text(args["sql"])
        val kind = kindOf(handle)
        if (!isAllowedSql(kind, sql)) throw sqlNotAllowed(kind, sql)
        // Room is read-only regardless of the statement: commits use the DAOs.
        if (handle is Handle.Room) {
            error("the Room handle is read-only; restore commits go through data.applyRoomSnapshot")
        }
        val params = (args["params"] as? List<*>) ?: emptyList<Any?>()
        return when (handle) {
            is Handle.Temp -> handle.db.compileStatement(sql).use { stmt ->
                bindStatement(stmt, params)
                stmt.executeUpdateDelete().toLong()
            }
            is Handle.Room -> error("unreachable: Room is read-only")
        }
    }

    /** Runs only Dart-authored parameterized SQL; columns come from the cursor. */
    fun query(args: Map<String, Any?>): List<Map<String, Any?>> {
        val handle = handles[text(args["handle"])] ?: error("unknown SQL handle")
        val sql = text(args["sql"])
        val kind = kindOf(handle)
        if (!isAllowedSql(kind, sql)) throw sqlNotAllowed(kind, sql)
        // rawQuery/query accept String bind args only (SupportSQLiteDatabase
        // declares Array<out String?>). The read statements bind ids, keys and
        // names; SQLite's column affinity converts the text back for numeric
        // comparisons. Blobs are only ever written through exec(), whose
        // typed binder accepts bytes.
        val params = (args["params"] as? List<*> ?: emptyList<Any?>())
            .map { it?.toString() }
            .toTypedArray()
        return when (handle) {
            is Handle.Temp -> handle.db.rawQuery(sql, params).use(::readCursor)
            is Handle.Room -> handle.db.query(sql, params).use(::readCursor)
        }
    }

    private fun readCursor(c: Cursor): List<Map<String, Any?>> {
        val names = c.columnNames
        val out = ArrayList<Map<String, Any?>>()
        while (c.moveToNext()) {
            val row = LinkedHashMap<String, Any?>()
            names.forEachIndexed { i, name -> row[name] = wire(value(i, c)) }
            out += row
        }
        return out
    }

    private val DEVICE_LOCAL_SETTINGS: Set<String> = setOf(
        "webdavServer", "webdavUsername", "webdavPassword", "webdavPath",
        "deviceId", "deviceName", "batteryPromptShown", "hwidFallback",
        "resumeAfterUpdate", "updateSkippedVersionCode", "wifiPermissionAsked",
        "serviceError", "serviceErrorDns", "serviceErrorGeo", "serviceErrorRuleSets",
        "startWithoutRuleSets", "runningProfiles", "runningRoute", "core_box_api_port",
    )
    /**
     * Mirrors SettingsRegistry.ANDROID_KEYS (the authority) and Dart's
     * backupAndroidKeys; room_snapshot_audit.py checks all three sets are equal.
     * Most of the device-local keys below are also in [DEVICE_LOCAL_SETTINGS],
     * which is checked first in applyRoomSnapshot, so their presence here is
     * inert; listing them keeps the cross-language contract single-valued.
     */
    private val ANDROID_ONLY_SETTINGS: Set<String> = setOf(
        "serviceMode", "proxyApps", "bypassMode", "individual", "appendHttpProxy",
        "httpProxyBypass", "meteredNetwork", "vpnAllowBypass", "wakeResetConnections",
        "networkChangeResetConnections", "showDirectSpeed", "showProxySpeed",
        "showGroupInNotification", "notificationActions", "notificationTitlePrefix",
        "notificationTitleTemplate", "notificationContentTemplate", "showTrafficTotal",
        "useSystemTheme", "appTheme", "nightTheme", "amoledTheme", "appLanguage",
        "groupLayoutMode", "compactProfileRows", "compactGroupCards",
        "hideFromRecentApps", "logBufSize", "logFontSize", "appTLSVersion",
        "webdavServer", "webdavUsername", "webdavPassword", "webdavPath",
        "deviceId", "deviceName", "profileCurrent", "runningProfiles", "runningRoute",
        "profileId", "previewHintDismissedVersion", "updateCheckAuto",
        "updateSkippedVersionCode", "resumeAfterUpdate", "batteryPromptShown",
        "logExportRedact", "hwidFallback", "wifiPermissionAsked", "serviceError",
        "serviceErrorDns", "serviceErrorGeo", "serviceErrorRuleSets",
        "startWithoutRuleSets",
    )
}
