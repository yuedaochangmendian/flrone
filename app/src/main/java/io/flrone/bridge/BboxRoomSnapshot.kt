package io.flrone.bridge

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import androidx.sqlite.db.SupportSQLiteDatabase
import io.nekohasekai.sagernet.database.MarkerEntity
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.RouteProfileEntity
import io.nekohasekai.sagernet.database.RouteRuleEntity
import io.nekohasekai.sagernet.database.SagerDatabase
import io.nekohasekai.sagernet.database.SubUserInfo
import io.nekohasekai.sagernet.database.SubscriptionOptions
import io.nekohasekai.sagernet.database.preference.SettingEntry
import io.nekohasekai.sagernet.ktx.Logs
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
 *  - [applyRoomSnapshot] commits staged rows back to Room through the DAOs in
 *    one transaction, then returns the committed profiles/groups for Dart to
 *    rebuild its owned document (Dart stays the only writer of profiles.json).
 */
object BboxRoomSnapshot {

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
    private fun nullableText(v: Any?): String? = v?.toString()

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
        val settings = SagerDatabase.settingsDao.all().map { mapOf("key" to it.key, "value" to it.value) }
        val markers = SagerDatabase.markerDao.all().map { mapOf("key" to it.key, "marked_at" to it.markedAt) }
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

    // ------------------------------------------------------------------ DAO writes (restore)

    /**
     * Commits the Dart-staged rows to Room in one transaction. Rows are keyed by
     * Room column names; entity construction is a straight field copy (no SQL).
     * Device-local settings are never overwritten, matching the Dart writer's
     * `backupDeviceLocalKeys` merge (Dart already filtered them out).
     */
    @Suppress("UNCHECKED_CAST")
    fun applyRoomSnapshot(args: Map<String, Any?>): Map<String, Any?> {
        val db = SagerDatabase.instance
        val doProfiles = bool(args["doProfiles"])
        val doRoutes = bool(args["doRoutes"])
        val doSettings = bool(args["doSettings"])
        val fromAndroid = bool(args["fromAndroid"])
        val androidOnlyKeys = ANDROID_ONLY_SETTINGS

        db.runInTransaction {
            if (doProfiles) {
                val groups = table(args["groups"]).map(::toGroup)
                val profiles = table(args["profiles"]).map(::toProfile)
                SagerDatabase.groupDao.reset()
                SagerDatabase.proxyDao.reset()
                if (groups.isNotEmpty()) SagerDatabase.groupDao.insert(groups)
                if (profiles.isNotEmpty()) SagerDatabase.proxyDao.insert(profiles)
                if (groups.isEmpty()) {
                    SagerDatabase.groupDao.insertDefaultIfEmpty(text(args["defaultGroupName"]))
                }
            }
            if (doRoutes) {
                val profiles = table(args["routeProfiles"]).map(::toRouteProfile)
                val rules = table(args["routeRules"]).map(::toRouteRule)
                SagerDatabase.routeDao.reset()
                profiles.forEach { SagerDatabase.routeDao.insertProfile(it) }
                if (rules.isNotEmpty()) SagerDatabase.routeDao.insertRules(rules)
                if (profiles.none { !it.isRaw }) {
                    SagerDatabase.routeDao.insertProfile(RouteProfileEntity(name = "Default", defaultOutboundId = -1L))
                }
            }
            if (doSettings) {
                val incoming = map(args["settings"]).mapValues { text(it.value) }
                val settingsDao = SagerDatabase.settingsDao
                settingsDao.all().forEach { existing ->
                    if (DEVICE_LOCAL_SETTINGS.contains(existing.key)) return@forEach
                    if (!fromAndroid && androidOnlyKeys.contains(existing.key)) return@forEach
                    if (!incoming.containsKey(existing.key)) settingsDao.delete(existing.key)
                }
                incoming.forEach { (key, v) ->
                    if (DEVICE_LOCAL_SETTINGS.contains(key)) return@forEach
                    if (!fromAndroid && androidOnlyKeys.contains(key)) {
                        // Desktop backup on Android: Android-only keys are
                        // INSERT OR IGNORE - keep the phone's value if present.
                        if (settingsDao[key] == null) settingsDao.put(SettingEntry(key, v))
                        return@forEach
                    }
                    settingsDao.put(SettingEntry(key, v))
                }
                SagerDatabase.markerDao.reset()
                table(args["markers"]).forEach { SagerDatabase.markerDao.put(toMarker(it)) }
            }
            // Selection repair (Dart's `_fixSelection`): point the selection
            // settings at rows that actually exist after the replacement. All
            // reads/writes go through DAOs, never hand-written SQL.
            if (doProfiles || doSettings) {
                val groups = SagerDatabase.groupDao.allGroups().map { it.id }
                val currentGroup = SagerDatabase.settingsDao["current_group"]
                if (currentGroup == null || groups.none { it.toString() == currentGroup.trim() }) {
                    putOrDeleteSetting("current_group", groups.firstOrNull()?.toString())
                }
                val profileIds = SagerDatabase.proxyDao.getAll().map { it.id }.toSet()
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
                    val id = SagerDatabase.settingsDao[key]?.trim()?.toLongOrNull()
                    if (id != null && id > 0 && id !in profileIds) {
                        SagerDatabase.settingsDao.delete(key)
                    }
                }
            }
            if (doRoutes || doSettings) {
                val usable = SagerDatabase.routeDao.allProfiles().filter { !it.isRaw }.map { it.id }
                val currentRoute = SagerDatabase.settingsDao["current_route_id"]
                if (currentRoute == null || usable.none { it.toString() == currentRoute.trim() }) {
                    putOrDeleteSetting("current_route_id", usable.firstOrNull()?.toString())
                }
            }
            // Counters: @Insert with explicit ids advances sqlite_sequence to
            // the highest id automatically; no separate counter write needed.
        }

        // Return the committed rows for Dart's document rebuild.
        val profiles = SagerDatabase.proxyDao.getAll().map(::profileRow)
        val groups = SagerDatabase.groupDao.allGroups().map(::groupRow)
        return mapOf("profiles" to profiles.map(::wire), "groups" to groups.map(::wire))
    }

    private fun putOrDeleteSetting(key: String, value: String?) {
        if (value == null) SagerDatabase.settingsDao.delete(key)
        else SagerDatabase.settingsDao.put(SettingEntry(key, value))
    }

    private fun table(v: Any?): List<Map<String, Any?>> = list(v)

    private fun toProfile(m: Map<String, Any?>) = ProxyEntity(
        id = num(m["id"]), type = text(m["type"]),
        name = nullableText(m["name"]), groupId = num(m["gid"]),
        userOrder = num(m["user_order"]), latency = int(m["latency"]),
        latencyAt = num(m["latency_at"]), dlSpeed = nullableText(m["dl_speed"]),
        ulSpeed = nullableText(m["ul_speed"]), testCountry = nullableText(m["test_country"]),
        ipOut = nullableText(m["ip_out"]), outboundJson = text(m["outbound_json"]),
        rx = num(m["traffic_dl"]), tx = num(m["traffic_up"]),
        testError = nullableText(m["test_error"]),
    )

    private fun toGroup(m: Map<String, Any?>) = ProxyGroup(
        id = num(m["id"]), archive = bool(m["archive"]),
        skipAutoUpdate = bool(m["skip_auto_update"]), name = text(m["name"]),
        url = text(m["url"]), info = text(m["info"]),
        subLastUpdate = num(m["sub_last_update"]),
        frontProxyId = num(m["front_proxy_id"], -1L),
        landingProxyId = num(m["landing_proxy_id"], -1L),
        columnWidthJson = text(m["column_width_json"]),
        scrollLastProfile = int(m["scroll_last_profile"], -1),
        autoClearUnavailable = bool(m["auto_clear_unavailable"]),
        testSortBy = int(m["test_sort_by"]), trafficSortBy = int(m["traffic_sort_by"]),
        testItemsToShow = int(m["test_items_to_show"]), typeSortBy = int(m["type_sort_by"]),
        subOptions = SubscriptionOptions.parse(text(m["sub_options_json"])),
        subMetadata = SubUserInfo.parse(text(m["sub_metadata_json"])),
        sortMethod = int(m["sort_method"]), sortDescending = bool(m["sort_descending"]),
        displayOrder = num(m["display_order"]), routeId = num(m["route_id"], -1L),
        importSubRoute = bool(m["import_sub_route"]),
    )

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

    private fun toMarker(m: Map<String, Any?>) =
        MarkerEntity(key = text(m["key"]), markedAt = num(m["marked_at"]))

    // ------------------------------------------------------------------ parameterized SQL transport (temp DB + Room)

    private sealed class Handle {
        class Temp(val db: SQLiteDatabase) : Handle()
        class Room(val db: SupportSQLiteDatabase) : Handle()
    }

    private val handles = Collections.synchronizedMap(HashMap<String, Handle>())
    private val handleSeq = AtomicLong(1)

    /** Opens a temp snapshot DB (framework SQLite) or Room's own connection. */
    fun openSql(args: Map<String, Any?>): Map<String, Any?> {
        val write = bool(args["write"])
        val path = text(args["path"])
        val handle = if (args["op"] == "openRoom") {
            val db = if (write) SagerDatabase.instance.openHelper.writableDatabase
                     else SagerDatabase.instance.openHelper.readableDatabase
            Handle.Room(db)
        } else {
            val flags = if (write) {
                SQLiteDatabase.CREATE_IF_NECESSARY or SQLiteDatabase.NO_LOCALIZED_COLLATORS
            } else {
                SQLiteDatabase.NO_LOCALIZED_COLLATORS
            }
            Handle.Temp(SQLiteDatabase.openDatabase(path, null, flags))
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

    /** Executes only Dart-authored parameterized SQL; never composes SQL here. */
    fun exec(args: Map<String, Any?>): Long {
        val handle = handles[text(args["handle"])] ?: error("unknown SQL handle")
        val sql = text(args["sql"])
        val params = (args["params"] as? List<*>) ?: emptyList<Any?>()
        return when (handle) {
            is Handle.Temp -> handle.db.compileStatement(sql).use { stmt ->
                bindStatement(stmt, params)
                stmt.executeUpdateDelete().toLong()
            }
            is Handle.Room -> handle.db.compileStatement(sql).use { stmt ->
                bindStatement(stmt, params)
                stmt.executeUpdateDelete().toLong()
            }
        }
    }

    /** Runs only Dart-authored parameterized SQL; columns come from the cursor. */
    fun query(args: Map<String, Any?>): List<Map<String, Any?>> {
        val handle = handles[text(args["handle"])] ?: error("unknown SQL handle")
        val sql = text(args["sql"])
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
    private val ANDROID_ONLY_SETTINGS: Set<String> = setOf(
        "serviceMode", "proxyApps", "bypassMode", "individual", "appendHttpProxy",
        "httpProxyBypass", "meteredNetwork", "vpnAllowBypass", "wakeResetConnections",
        "networkChangeResetConnections", "showDirectSpeed", "showProxySpeed",
        "showGroupInNotification", "notificationActions", "notificationTitlePrefix",
        "notificationTitleTemplate", "notificationContentTemplate", "showTrafficTotal",
        "useSystemTheme", "appTheme", "nightTheme", "amoledTheme", "appLanguage",
        "groupLayoutMode", "compactProfileRows", "compactGroupCards",
        "hideFromRecentApps", "logBufSize", "logFontSize", "appTLSVersion",
        "profileCurrent", "previewHintDismissedVersion", "updateCheckAuto",
        "logExportRedact",
    )
}
