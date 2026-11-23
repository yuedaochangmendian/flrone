package io.flrone.bridge

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import io.nekohasekai.sagernet.Key
import io.nekohasekai.sagernet.database.SettingsJsonStore
import io.nekohasekai.sagernet.ktx.app
import java.io.File
import java.util.Collections
import java.util.concurrent.atomic.AtomicLong

/**
 * Host side of the backup write path, after ADR 0006 stage C2c2a.
 *
 * An Android app may only dlopen libraries in public.libraries.txt: AOSP ships
 * no libsqlite3.so and libsqlite.so is not public, so the Dart-side `dart:ffi`
 * writer is null on a stock device and the backup cannot open a database from
 * Dart. This object owns the operations that must happen in the process that
 * has the platform SQLite — and, since C2c2a, none of them touches Room:
 *
 *  - [openContainer]/[exec]/[query]/[confinedContainerFile] are the backup
 *    container's SQL transport (`backup.container`, C2c1): framework SQLite on
 *    a file in the app's own storage, executing only the parameterized SQL Dart
 *    sends. This file never composes a SQL string, and the live database and
 *    the documents directory are refused by [confinedContainerFile];
 *  - [settingsSnapshot]/[markersSnapshot]/[restoreSettings]/[restoreMarkers]
 *    are the narrow settings/markers document ops (`settings.snapshot`,
 *    `markers.snapshot`, `settings.restore`, `markers.restore`): the backup
 *    export reads the live documents through them, and a restore merges/replaces
 *    them in one call each, keeping the device-local and Android-only rules
 *    here so the writer stays singular (ADR 0006 stage C2b mounted the
 *    documents; this is their only backup-facing door).
 *
 * The retired `data.roomSnapshot`/`data.applyRoomSnapshot` DAO pumps are gone:
 * profiles/groups come from Dart's `profiles.json`, routes from the kernel's
 * route documents, settings/markers from the documents above. Room's entities
 * and tables are not read or written by the backup data plane any more.
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

    private fun bool(v: Any?): Boolean = v == true || v == 1 || v == 1L || v == "true" || v == "1"
    private fun text(v: Any?): String = v?.toString() ?: ""

    @Suppress("UNCHECKED_CAST")
    private fun map(v: Any?): Map<String, Any?> =
        (v as? Map<String, Any?>) ?: emptyMap()

    @Suppress("UNCHECKED_CAST")
    private fun list(v: Any?): List<Map<String, Any?>> =
        (v as? List<*>)?.mapNotNull { it as? Map<String, Any?> } ?: emptyList()

    /**
     * One staged row set from Dart. `markers.restore` normally sends a
     * column-keyed row list; the older `{columns: [name...], rows:
     * [[v...]...]}` shape is still accepted (the Kotlin unit test pins both).
     * A malformed row fails loudly instead of being skipped: the caller has
     * already replaced the live document, so a silently short table would
     * commit a partial replacement.
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

    // ---------------------------------------------------- settings / markers documents

    /**
     * ADR 0006 stage C2b: settings and markers live in the documents
     * (`settings.json` / `markers.json`) — Room's tables were dropped in schema
     * 21 — so every read/write in this file routes through these, and the
     * document is required: the backup has no second store to fall back to.
     */
    private fun documents(): Unit = check(SettingsJsonStore.mounted) {
        "the settings document is not mounted; the backup needs it"
    }

    private fun settings(): Map<String, String> {
        documents()
        return SettingsJsonStore.all()
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

    /** `settings.snapshot`: the live document as `{key, value}` rows (export). */
    fun settingsSnapshot(): Map<String, Any?> = mapOf("rows" to settingRows().map(::wire))

    /** `markers.snapshot`: the live document as `{key, marked_at}` rows (export). */
    fun markersSnapshot(): Map<String, Any?> = mapOf("rows" to markerRows().map(::wire))

    /**
     * `settings.restore`: one call that merges the container's settings rows and
     * repairs the selection keys. Ported from the retired `applyRoomSnapshot`'s
     * settings half, with the catalog ids supplied by Dart (documents are the
     * catalog now; this process never reads Room's profile tables):
     *
     *  - `hasSettings=false` means the container carried no settings block: the
     *    live values are kept and only the selection repair runs (a profiles or
     *    routes restore still has to point `current_group`/`current_route_id`
     *    at rows that exist);
     *  - device-local keys are never overwritten or deleted;
     *  - a desktop restore (`fromAndroid=false`) keeps this phone's
     *    Android-only values when the container does not name them;
     *  - the LAN guard resets `inbound_address` to loopback and reports it.
     *
     * The write is one whole-set replace ([SettingsJsonStore.replaceAll]), so a
     * crash cannot leave the settings half merged.
     */
    @Suppress("UNCHECKED_CAST")
    fun restoreSettings(args: Map<String, Any?>): Map<String, Any?> {
        documents()
        val warnings = ArrayList<String>()
        val hasSettings = bool(args["hasSettings"])
        val fromAndroid = bool(args["fromAndroid"])
        val restoredProfiles = bool(args["restoredProfiles"])
        val incoming: Map<String, String>? = if (hasSettings) {
            map(args["settings"]).mapValues { text(it.value) }
        } else {
            null
        }

        val next = LinkedHashMap(settings())
        if (incoming != null) {
            // Keys that vanish from the container (and are not this device's
            // own) are deleted, exactly like the old table rewrite.
            for (existing in next.keys.toList()) {
                if (DEVICE_LOCAL_SETTINGS.contains(existing)) continue
                if (!fromAndroid && ANDROID_ONLY_SETTINGS.contains(existing)) continue
                if (!incoming.containsKey(existing)) next.remove(existing)
            }
            for ((key, value) in incoming) {
                if (DEVICE_LOCAL_SETTINGS.contains(key)) continue
                if (!fromAndroid && ANDROID_ONLY_SETTINGS.contains(key)) {
                    // Desktop backup on Android: Android-only keys are
                    // INSERT OR IGNORE — keep the phone's value if present.
                    if (!next.containsKey(key)) next[key] = value
                    continue
                }
                next[key] = value
            }
        }

        // Selection repair. Null id sets mean "Dart has no document to name the
        // catalog" (a pre-migration install): that selection key is left alone.
        val groupIds = restoredIds(args["restoredGroupIds"])
        if (groupIds != null) {
            val current = next["current_group"]?.trim()?.toLongOrNull()
            if (current == null || groupIds.none { it == current }) {
                putOrRemove(next, "current_group", groupIds.firstOrNull()?.toString())
            }
        }
        val profileIds = restoredIds(args["restoredProfileIds"])?.toSet()
        if (profileIds != null) {
            // Desktop backup: the desktop's `remember_id` is the selected node;
            // translate it only when it names a row the restore carried.
            if (hasSettings && restoredProfiles && !fromAndroid) {
                val remember = incoming?.get("remember_id")?.trim()?.toLongOrNull()
                if (remember != null && remember in profileIds) {
                    next["profileId"] = remember.toString()
                    next["profileCurrent"] = remember.toString()
                }
            }
            for (key in listOf("profileId", "profileCurrent")) {
                val id = next[key]?.trim()?.toLongOrNull()
                if (id != null && id > 0 && id !in profileIds) next.remove(key)
            }
        }
        val routeIds = restoredIds(args["restoredRouteIds"])
        if (routeIds != null) {
            val current = next["current_route_id"]?.trim()?.toLongOrNull()
            if (current == null || routeIds.none { it == current }) {
                putOrRemove(next, "current_route_id", routeIds.firstOrNull()?.toString())
            }
        }

        // Same guard as Dart's `_lanWasOn`: a backup that allowed other devices
        // to connect is restored with the host closed and the caller told,
        // instead of silently re-exposing the proxy.
        if (incoming != null) {
            val inbound = incoming["inbound_address"]?.trim()
            if (!inbound.isNullOrEmpty() && inbound != "127.0.0.1") {
                next["inbound_address"] = "127.0.0.1"
                warnings += "The backup lets other devices connect (inbound address $inbound); " +
                    "this was turned off. Turn it on again in the inbound settings if you need it."
            }
        }

        SettingsJsonStore.replaceAll(next)
        return mapOf("warnings" to warnings)
    }

    /** `markers.restore`: one whole-set replacement from the container's rows. */
    @Suppress("UNCHECKED_CAST")
    fun restoreMarkers(args: Map<String, Any?>): Unit {
        documents()
        replaceMarkers(tableRows(args["rows"]))
    }

    private fun putOrRemove(target: MutableMap<String, String>, key: String, value: String?) {
        if (value == null) target.remove(key) else target[key] = value
    }

    /** The ids Dart sent, or null when it sent none (no catalog to compare). */
    private fun restoredIds(v: Any?): List<Long>? {
        val list = v as? List<*> ?: return null
        return list.map { num(it) }
    }

    // ------------------------------------------------- parameterized SQL transport (container files)

    /**
     * Open container handles: framework SQLite connections to files in the app's
     * own storage. The backup's temporary snapshot (export) and staged database
     * (restore) are the only things this transport opens — the live database is
     * not reachable through it (C2c1 removed `data.roomSql`'s `openRoom`, and
     * C2c2a removed the DAO pumps that used to read/write Room).
     */
    private val handles = Collections.synchronizedMap(HashMap<String, SQLiteDatabase>())
    private val handleSeq = AtomicLong(1)

    /**
     * The one door Dart has to a file through `backup.container`, so it only
     * opens backup container files.
     *
     * The paths are Dart's (a temp snapshot the export builds, a staged restore
     * database, the embedded backup database it writes out), all under
     * `Directory.systemTemp`. The door is narrower than `data.roomSql`'s was:
     * the file must sit in the app's **own** storage — no shared/public storage —
     * and every live store that shares those roots is refused by name, by
     * directory and by canonical path: Room's database directory
     * (`<filesDir>/databases/sager_net.db`), the documents directory
     * (`<filesDir>/documents/…`: profiles.json, settings.json, the kernel route
     * documents) and the rule-set catalog (`<filesDir>/routeprofiles`).
     * `SubscriptionQueue.importFile` applies the same confinement rule to the
     * other file door.
     *
     * The live database's canonical path is computed with the framework's
     * `getDatabasePath` — never by opening it, which would create/migrate the
     * very file this guard protects.
     *
     * The roots list deliberately includes files/noBackupFiles next to cache:
     * `Directory.systemTemp` resolves to the app's temp dir on the engine's
     * terms, and refusing it on a platform that answers a sibling directory
     * would break the backup without protecting anything the deny list does not
     * already cover.
     */
    fun confinedContainerFile(path: String): File {
        require(path.isNotBlank()) { "backup.container needs a path" }
        val file = File(path).canonicalFile
        require(file.name != Key.DB_PROFILE && !file.name.startsWith("${Key.DB_PROFILE}-")) {
            "backup.container must not open the live database: $path"
        }
        // Live stores that share the private roots. `databases` holds Room's own
        // file (and its -wal/-shm); `documents` holds every JSON authority the
        // app reads; `routeprofiles` the rule-set catalog.
        val reserved = listOf("databases", "documents", "routeprofiles").mapNotNull {
            runCatching { File(app.filesDir, it).canonicalFile }.getOrNull()
        }
        require(reserved.none { file == it || file.path.startsWith(it.path + File.separator) }) {
            "backup.container must not open a live data directory: $path"
        }
        // Canonical equality catches a symlink/hardlink path into the live file
        // that the name and directory checks above would not see.
        val liveDb = runCatching { app.getDatabasePath(Key.DB_PROFILE).canonicalPath }.getOrNull()
        require(liveDb == null || file.path != liveDb) {
            "backup.container must not open the live database: $path"
        }
        val roots = listOfNotNull(
            app.cacheDir,
            app.codeCacheDir,
            app.noBackupFilesDir,
            app.filesDir,
            app.getExternalFilesDir(null),
        ).mapNotNull { runCatching { it.canonicalFile }.getOrNull() }
        require(roots.any { root -> file == root || file.path.startsWith(root.path + File.separator) }) {
            "backup.container path is outside the app's private storage: $path"
        }
        return file
    }

    /** Opens a backup container file with the framework SQLite (never Room). */
    fun openContainer(args: Map<String, Any?>): Map<String, Any?> {
        val flags = if (bool(args["write"])) {
            SQLiteDatabase.CREATE_IF_NECESSARY or SQLiteDatabase.NO_LOCALIZED_COLLATORS
        } else {
            SQLiteDatabase.NO_LOCALIZED_COLLATORS
        }
        val db = SQLiteDatabase.openDatabase(
            confinedContainerFile(text(args["path"])).path, null, flags,
        )
        val id = "container-${handleSeq.getAndIncrement()}"
        handles[id] = db
        return mapOf("handle" to id)
    }

    fun closeContainer(args: Map<String, Any?>) {
        val db = handles.remove(text(args["handle"])) ?: return
        runCatching { db.close() }
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

    // ------------------------------------------------------------------ SQL whitelist

    /**
     * Leading keywords permitted on a backup container handle: the statement
     * types the export/restore rebuild actually needs. Anything else (ATTACH,
     * VACUUM, triggers, ...) is refused before it ever reaches SQLite.
     */
    private val CONTAINER_KEYWORDS = setOf(
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
     * keyword against the container handle's statement set and rejects
     * multi-statement input (only one trailing semicolon is tolerated, and
     * semicolons inside literals or comments do not count). Leading
     * whitespace/comments are tolerated.
     *
     * This only *checks* a statement Dart authored — it never builds one.
     */
    internal fun isAllowedSql(sql: String): Boolean {
        val masked = maskSql(sql)
        val code = masked.trim()
        if (code.isEmpty()) return false
        // At most one trailing `;`; none anywhere else in executable code.
        val body = if (code.endsWith(";")) code.substring(0, code.length - 1).trimEnd() else code
        if (body.isEmpty() || body.contains(';')) return false

        val keyword = body.takeWhile { it.isLetter() }.uppercase()
        if (keyword !in CONTAINER_KEYWORDS) return false
        // writable_schema disables SQLite's schema checks and would let a
        // statement smuggle arbitrary structure past the whitelist.
        if (body.contains("writable_schema", ignoreCase = true)) return false
        val second = body.substring(keyword.length).trimStart().takeWhile { it.isLetter() }.uppercase()
        when (keyword) {
            "CREATE" -> if (second != "TABLE" && second != "INDEX") return false
            "DROP", "ALTER" -> if (second != "TABLE") return false
        }
        return true
    }

    private fun sqlNotAllowed(sql: String) = IllegalArgumentException(
        "SQL statement is not allowed on the backup container: '${sql.take(80)}'. " +
            "Only ${CONTAINER_KEYWORDS.sorted().joinToString(", ")} are permitted, " +
            "one statement at a time."
    )

    /** Executes only Dart-authored parameterized SQL; never composes SQL here. */
    fun exec(args: Map<String, Any?>): Long {
        val db = handles[text(args["handle"])] ?: error("unknown container handle")
        val sql = text(args["sql"])
        if (!isAllowedSql(sql)) throw sqlNotAllowed(sql)
        val params = (args["params"] as? List<*>) ?: emptyList<Any?>()
        return db.compileStatement(sql).use { stmt ->
            bindStatement(stmt, params)
            stmt.executeUpdateDelete().toLong()
        }
    }

    /** Runs only Dart-authored parameterized SQL; columns come from the cursor. */
    fun query(args: Map<String, Any?>): List<Map<String, Any?>> {
        val db = handles[text(args["handle"])] ?: error("unknown container handle")
        val sql = text(args["sql"])
        if (!isAllowedSql(sql)) throw sqlNotAllowed(sql)
        // rawQuery accepts String bind args only. The read statements bind ids,
        // keys and names; SQLite's column affinity converts the text back for
        // numeric comparisons. Blobs are only ever written through exec(),
        // whose typed binder accepts bytes.
        val params = (args["params"] as? List<*> ?: emptyList<Any?>())
            .map { it?.toString() }
            .toTypedArray()
        return db.rawQuery(sql, params).use(::readCursor)
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
     * which is checked first in [restoreSettings], so their presence here is
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
