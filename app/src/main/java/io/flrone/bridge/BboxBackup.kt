package io.flrone.bridge

import android.database.DatabaseUtils
import android.database.sqlite.SQLiteDatabase
import android.util.Base64
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.backup.DesktopSchema
import io.nekohasekai.sagernet.database.backup.ThrBackup
import io.nekohasekai.sagernet.ktx.Logs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.File

/**
 * The read-only edge of backup import (ADR 0005 phase 4).
 *
 * Creating a backup and writing one back into Room are Dart-owned now
 * (`flutter/lib/services/backup_write.dart` + `backup_store.dart`). What stays
 * native is exactly the SAF/decode path the platform needs: a `.thrbackup` or a
 * JSON envelope the user selected is turned into the same preview envelope the
 * confirmation dialog reads. The actual restore decodes that envelope's `thr`
 * member on the Dart side; decoding here is read-only and writes no Room tables.
 *
 * The `profiles` member is the preview: group names and their node counts —
 * enough for "Restore N profiles?" to say what is about to replace what.
 */
object BboxBackup {

    private const val KEY = "thr"

    @Volatile
    private var lastPayload: Map<String, Any?>? = null

    /** The last container decoded here, since there is no on-device backup registry to list. */
    fun read(): Map<String, Any?>? = lastPayload

    /**
     * A .thrbackup the platform handed us (a VIEW or SEND of a "THRN" container). It becomes the same envelope
     * a backup produces, so the confirmation needs no path of its own.
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
     * The JSON envelope a backup produced — what the local "Backup" entry writes, and what a
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
        null, io.nekohasekai.sagernet.outbound.json.JsonNull -> null
        is io.nekohasekai.sagernet.outbound.json.JsonObject -> value.associate { (key, item) -> key to metaToWire(item) }
        is io.nekohasekai.sagernet.outbound.json.JsonArray -> value.map(::metaToWire)
        else -> value
    }

    private fun uiFromMeta(meta: io.nekohasekai.sagernet.outbound.json.JsonObject): Map<String, Any?> {
        var ui = meta.obj("flrone_ui")
        // Backups written by the first version of this branch nested the UI object twice.
        if (ui.contains("flrone_ui") && !ui.contains("preferences") && !ui.contains("settings") && !ui.contains("quality")) {
            ui = ui.obj("flrone_ui")
        }
        return ui.associate { (key, value) -> key to metaToWire(value) }
    }

    /** Decodes a container and returns the envelope the UI previews. */
    private fun stage(bytes: ByteArray, ui: Map<String, Any?> = emptyMap()): Map<String, Any?> {
        // Read-only decode: stream the container's database entry to a temp file so
        // `profileNames` can preview the groups. No Room table is written here.
        val temp = File.createTempFile("bbox-backup-preview-", ".db")
        try {
            val contents = runCatching {
                ThrBackup.read(ByteArrayInputStream(bytes), temp)
            }.onFailure { Logs.w(it) }.getOrNull() ?: error("This backup cannot be read")
            val restoredUi = ui.ifEmpty { uiFromMeta(contents.meta) }
            val payload = mapOf(
                "format" to contents.formatVersion,
                "createdAt" to contents.createdAt,
                "profiles" to profileNames(temp),
                // NO_WRAP: dart's base64Decode rejects the 76-column newlines
                // DEFAULT inserts, and this payload is decoded straight on the
                // Dart restore path.
                KEY to Base64.encodeToString(bytes, Base64.NO_WRAP),
                "ui" to restoredUi,
            )
            lastPayload = payload
            return payload
        } finally {
            runCatching { temp.delete() }
        }
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

    // ADR 0005 phase 4: the create/restore write path moved to Dart
    // (`services/backup_write.dart`); this object keeps only the read-only
    // envelope decode the SAF picker (`decodeFile` / `openBackupDocument`) needs.

    /** Group names and node counts straight out of a staged backup database, for the restore confirmation. */
    private fun profileNames(database: File): List<Map<String, Any?>> = runCatching {
        SQLiteDatabase.openDatabase(database.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
            if (!db.hasTable(DesktopSchema.PROFILES)) return emptyList()
            val nodeCounts = emptyMap<Long, Long>()
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
