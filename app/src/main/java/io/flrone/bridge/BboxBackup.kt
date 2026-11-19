package io.flrone.bridge

import android.database.DatabaseUtils
import android.database.sqlite.SQLiteDatabase
import android.util.Base64
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.GroupRepo
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.backup.BackupExport
import io.nekohasekai.sagernet.database.backup.BackupRestore
import io.nekohasekai.sagernet.database.backup.DesktopSchema
import io.nekohasekai.sagernet.database.backup.ThrBackup
import io.nekohasekai.sagernet.ktx.Logs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import io.nekohasekai.sagernet.outbound.json.JsonArray
import io.nekohasekai.sagernet.outbound.json.JsonNull
import io.nekohasekai.sagernet.outbound.json.JsonObject
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Backup and restore in three dialects: the ported UI's JSON envelope, Throne's own container, and WebDAV.
 *
 * The screens deal in JSON — `backup.create` hands back a map the Dart side encodes and writes wherever it likes — but
 * Throne's own backup is a binary container whose import rules (id counters, table repair, setting merges) are real
 * and easy to get wrong. So the map is an envelope: its `thr` member is the genuine Throne backup, and restoring
 * decodes it straight into Throne's restore rather than reimplementing any of that.
 *
 * The `profiles` member is the part the UI reads, so it carries the group names and their node counts — enough for the
 * confirmation dialog to say what is about to replace what.
 */
object BboxBackup {

    private const val KEY = "thr"

    /** A backup whose real content is Throne's own, held until it is restored. */
    private class Holder(val payload: Map<String, Any?>, val loaded: BackupRestore.Loaded? = null)

    @Volatile
    private var holder: Holder? = null

    @Volatile
    private var lastPayload: Map<String, Any?>? = null

    private fun selection(scope: String): BackupExport.Selection {
        val everything = scope != "profiles"
        return BackupExport.Selection(profiles = true, routes = everything, settings = everything)
    }

    /** Builds a Throne backup and wraps it in the envelope the UI expects. */
    suspend fun create(scope: String = "all", ui: Map<String, Any?> = emptyMap()): Map<String, Any?> = withContext(Dispatchers.IO) {
        val bytes = ByteArrayOutputStream().use { out ->
            // Embed the UI payload in the container meta too, so a raw .thrbackup
            // (or a shared file) restores preferences just like the JSON envelope.
            BackupExport.write(selection(scope), out, extraMeta = ui)
            out.toByteArray()
        }
        val groups = GroupRepo.rawGroups().map { group ->
            mapOf(
                "name" to group.displayName(),
                "type" to if (group.isSubscription) "subscription" else "local",
                "url" to group.url,
                "nodes" to ProfileManager.memberIds(group.id).size,
            )
        }
        val payload = mapOf(
            "format" to ThrBackup.FORMAT_VERSION,
            "createdAt" to System.currentTimeMillis(),
            "scope" to scope,
            "profiles" to groups,
            KEY to Base64.encodeToString(bytes, Base64.DEFAULT),
            "ui" to ui,
        )
        lastPayload = payload
        holder = Holder(payload)
        payload
    }

    /** A preview: whatever was created or read most recently, since there is no on-device backup registry to list. */
    fun read(): Map<String, Any?>? = holder?.payload ?: lastPayload

    /**
     * A .thrbackup the platform handed us (a VIEW or SEND of a "THRN" container). It becomes the same envelope
     * [create] hands out, so the confirmation and [restore] need no path of their own.
     *
     * Returns null when [bytes] are not a Throne backup at all — a shared document is the importer's business —
     * and refuses a container it cannot read, which only the magic can tell apart.
     */
    suspend fun open(bytes: ByteArray): Map<String, Any?>? = withContext(Dispatchers.IO) {
        // "THRN" first and silently: a plain document is not a broken backup.
        if (!ThrBackup.hasMagic(ByteArrayInputStream(bytes))) return@withContext null
        stage(bytes)
    }

    /**
     * The JSON envelope `backup.create` produced — what the local "Backup" entry writes, and what a
     * user re-selects in "Restore". The envelope's `thr` member is the real container; the rest is a
     * preview. Returns null when the text is not an envelope at all, so the caller can say so.
     */
    suspend fun openJson(text: String): Map<String, Any?>? = withContext(Dispatchers.IO) {
        val root = runCatching { JSONObject(text) }.getOrNull() ?: return@withContext null
        val encoded = root.optString(KEY).takeIf { it.isNotBlank() } ?: return@withContext null
        val bytes = runCatching { Base64.decode(encoded, Base64.DEFAULT) }.getOrNull()
            ?: return@withContext null
        val ui = runCatching { jsonToWire(root.optJSONObject("ui") ?: JSONObject()) }.getOrNull() as? Map<*, *>
        stage(bytes, ui?.entries?.associate { it.key.toString() to it.value } ?: emptyMap())
    }

    private fun jsonToWire(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { jsonToWire(value.get(it)) }
        is org.json.JSONArray -> (0 until value.length()).map { jsonToWire(value.get(it)) }
        else -> value
    }

    private fun metaToWire(value: Any?): Any? = when (value) {
        null, JsonNull -> null
        is JsonObject -> value.associate { (key, item) -> key to metaToWire(item) }
        is JsonArray -> value.map(::metaToWire)
        else -> value
    }

    private fun uiFromMeta(meta: JsonObject): Map<String, Any?> {
        var ui = meta.obj("flrone_ui")
        // Backups written by the first version of this branch nested the UI object twice.
        if (ui.contains("flrone_ui") && !ui.contains("preferences") && !ui.contains("settings") && !ui.contains("quality")) {
            ui = ui.obj("flrone_ui")
        }
        return ui.associate { (key, value) -> key to metaToWire(value) }
    }

    /** Loads a container into the holder [restore] reads, and returns the envelope the UI previews. */
    private fun stage(bytes: ByteArray, ui: Map<String, Any?> = emptyMap()): Map<String, Any?> {
        val loaded = runCatching { BackupRestore.load(ByteArrayInputStream(bytes)) }
            .onFailure { Logs.w(it) }.getOrNull() ?: error("This backup cannot be read")
        val restoredUi = ui.ifEmpty { uiFromMeta(loaded.contents.meta) }
        val payload = mapOf(
            "format" to loaded.contents.formatVersion,
            "createdAt" to loaded.contents.createdAt,
            "profiles" to profileNames(loaded.database),
            KEY to Base64.encodeToString(bytes, Base64.DEFAULT),
            "ui" to restoredUi,
        )
        // The envelope is what travels to the UI and what [restore] decodes, so the staged database goes back.
        loaded.discard()
        holder = Holder(payload)
        return payload
    }

    /**
     * Restores an envelope. [strategy] is B-box's merge-vs-replace choice, which Throne's restore does not have — it
     * replaces a part's rows keeping ids. A full-scope restore always brings back the application settings (per-app
     * selection, proxy apps, HTTP proxy options and the rest of the settings table), because those were exported but
     * silently dropped under the old "Compatible" default; `Override` additionally replaces the route tables.
     */
    suspend fun restore(payload: Map<String, Any?>?, scope: String, strategy: String): List<String> =
        withContext(Dispatchers.IO) {
            val current = holder
            val loaded = when {
                // The newest remote read is only reachable through the handle that download gave us.
                payload != null && current?.payload === payload && current.loaded != null -> current.loaded
                else -> decode(payload)?.let { BackupRestore.load(it) } ?: current?.loaded
                    ?: error("Nothing has been read yet: choose a backup to restore from")
            }
            val available = BackupRestore.available(loaded.contents)
            val allParts = scope != "profiles"
            val override = strategy == "Override"
            val choice = BackupRestore.Choice(
                profiles = available.profiles,
                routes = available.routes && allParts && override,
                settings = available.settings && allParts,
            )
            if (!choice.any()) error("This backup holds nothing Throne can restore")
            val warnings = try {
                BackupRestore.restore(loaded, choice)
            } finally {
                holder = null
            }
            BboxBridge.scheduleRefresh(immediate = true)
            warnings
        }

    private fun decode(payload: Map<String, Any?>?): ByteArrayInputStream? {
        val encoded = payload?.get(KEY) as? String ?: return null
        return ByteArrayInputStream(Base64.decode(encoded, Base64.DEFAULT))
    }

    // -------------------------------------------------------------------------------------------------- WebDAV

    /**
     * The legacy WebDAV account, read from the four Room `settings` rows.
     *
     * ADR 0005 phase 1 moved the account's authority to Dart's `WebDavAccountStore`
     * (one `webdavAccount` value in the preferences document). This read-only bridge
     * remains for exactly one upgrade job: the host folds a legacy account into the
     * preferences document on `ready` when no Dart-owned account exists yet. The
     * writer (`setWebdav`) is gone; the host still mirrors Dart's writes back into
     * these rows for legacy compatibility, but phase 4's transport no longer reads
     * them (WebDAV backup is fully Dart-owned). The shape
     * `{uri, user, password, fileName}` is unchanged.
     */
    fun webdav(): Map<String, Any?>? {
        val server = DataStore.webdavServer.orEmpty()
        if (server.isBlank()) return null
        return mapOf(
            "uri" to server,
            "user" to DataStore.webdavUsername.orEmpty(),
            "password" to DataStore.webdavPassword.orEmpty(),
            "fileName" to DataStore.webdavPath.orEmpty(),
        )
    }

    // ADR 0005 phase 1: setWebdav() was deleted. Dart owns the account now; the
    // host mirrors preferences.webdavAccount into the four DataStore rows in
    // preferences.set (see ThroneBoxBridge.mirrorWebDavAccountToRoom).

    // ADR 0005 phase 4: WebDavBackup transport (upload/list/download) moved to
    // Dart (`services/backup_webdav.dart`). `webdav.check`, `webdav.get/set` and
    // `webdav.upload/read` are all Dart-owned now; this object keeps only the
    // THRN envelope and the Room-backed create/stage/restore, which own data
    // authority and cannot move without a second, lossy Room implementation.

    /** Group names and node counts straight out of a staged backup database, for the restore confirmation. */
    private fun profileNames(database: File): List<Map<String, Any?>> = runCatching {
        SQLiteDatabase.openDatabase(database.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
            if (!db.hasTable(DesktopSchema.PROFILES)) return emptyList()
            val nodeCounts = if (db.hasTable(DesktopSchema.ENTITY_IDS)) emptyMap<Long, Long>() else emptyMap()
            db.rawQuery("SELECT id, name FROM ${DesktopSchema.PROFILES}", null).use { cursor ->
                val rows = ArrayList<Map<String, Any?>>()
                while (cursor.moveToNext()) {
                    rows += mapOf(
                        "name" to cursor.getString(1),
                        "nodes" to (nodeCounts[cursor.getLong(0)] ?: 0L),
                    )
                }
                rows
            }
        }
    }.onFailure { Logs.w(it) }.getOrDefault(emptyList())

    private fun SQLiteDatabase.hasTable(name: String): Boolean = runCatching {
        DatabaseUtils.longForQuery(this, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", arrayOf(name)) > 0
    }.getOrDefault(false)
}
