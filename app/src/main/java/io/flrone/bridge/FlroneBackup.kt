package io.flrone.bridge

import android.database.DatabaseUtils
import android.database.sqlite.SQLiteDatabase
import android.util.Base64
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
object FlroneBackup {

    private const val KEY = "thr"

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

    /** org.json → plain wire values; shared with FlronePlatformBridge's document reads. */
    internal fun jsonToWire(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { jsonToWire(value.get(it)) }
        is org.json.JSONArray -> (0 until value.length()).map { jsonToWire(value.get(it)) }
        else -> value
    }

    private fun metaToWire(value: Any?): Any? = when (value) {
        null, io.nekohasekai.sagernet.document.json.JsonNull -> null
        is io.nekohasekai.sagernet.document.json.JsonObject -> value.associate { (key, item) -> key to metaToWire(item) }
        is io.nekohasekai.sagernet.document.json.JsonArray -> value.map(::metaToWire)
        else -> value
    }

    private fun uiFromMeta(meta: io.nekohasekai.sagernet.document.json.JsonObject): Map<String, Any?> {
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
            return payload
        } finally {
            runCatching { temp.delete() }
        }
    }

    // WebDAV is Dart-owned (one `webdavAccount` value in the preferences document).
    // The legacy Room fold, its tombstone and the four-row read bridge were removed
    // with the Room chain; no account data passes through this object.

    // ADR 0005 phase 4: the create/restore write path moved to Dart
    // (`services/backup_write.dart`); this object keeps only the read-only
    // envelope decode the SAF picker (`decodeFile` / `openBackupDocument`) needs.

    /**
     * Group names and node counts straight out of a staged backup database, for the restore
     * confirmation. The shape mirrors Dart's `_profileNames`: one entry per group with
     * `name`, `type`, `url` and `nodes` (counted from `profiles.gid`), sorted by the
     * `groups_order.display_order` tab order when that table is present. The previous
     * implementation counted from an empty map, so every group previewed zero nodes.
     *
     * The pure counting/shaping is extracted to [groupPreview] so a JVM test can pin
     * it with staged rows without needing a staged SQLite database.
     */
    internal data class GroupRow(val id: Long, val name: String, val url: String, val order: Long)

    internal data class StagedRows(
        val groups: List<GroupRow>,
        /** One `gid` per staged profile row. */
        val gids: List<Long>,
    )

    internal fun groupPreview(staged: StagedRows): List<Map<String, Any?>> {
        if (staged.groups.isEmpty()) return emptyList()
        val counts = HashMap<Long, Long>()
        for (gid in staged.gids) counts[gid] = (counts[gid] ?: 0L) + 1L
        val orderById = staged.groups.associate { it.id to it.order }
        val sorted = staged.groups.sortedWith(
            compareBy<GroupRow> { orderById[it.id] ?: 0L }.thenBy { it.id },
        )
        return sorted.map { group ->
            val url = group.url
            mapOf(
                "name" to group.name,
                "type" to if (url.isEmpty()) "local" else "subscription",
                "url" to url,
                "nodes" to (counts[group.id] ?: 0L),
            )
        }
    }

    private fun profileNames(database: File): List<Map<String, Any?>> = runCatching {
        SQLiteDatabase.openDatabase(database.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
            if (!db.hasTable(DesktopSchema.GROUPS)) return emptyList()
            val ids = LinkedHashMap<Long, Int>()
            val groups = ArrayList<GroupRow>()
            db.rawQuery("SELECT id, name, url FROM ${DesktopSchema.GROUPS}", null).use { cursor ->
                while (cursor.moveToNext()) {
                    ids[cursor.getLong(0)] = cursor.position
                    groups += GroupRow(cursor.getLong(0), cursor.getString(1), cursor.getString(2) ?: "", 0L)
                }
            }
            if (db.hasTable(DesktopSchema.GROUPS_ORDER)) {
                db.rawQuery(
                    "SELECT group_id, display_order FROM ${DesktopSchema.GROUPS_ORDER}", null,
                ).use { cursor ->
                    val byId = groups.associateBy { it.id }.toMutableMap()
                    while (cursor.moveToNext()) {
                        val id = cursor.getLong(0)
                        byId[id]?.let { byId[id] = it.copy(order = cursor.getLong(1)) }
                    }
                    groups.clear()
                    groups.addAll(byId.values)
                }
            } else {
                // Without the tab-order table keep the physical order the query returned.
                groups.sortBy { ids[it.id] ?: Int.MAX_VALUE }
            }
            val gids = ArrayList<Long>()
            if (db.hasTable(DesktopSchema.PROFILES)) {
                db.rawQuery("SELECT gid FROM ${DesktopSchema.PROFILES}", null).use { cursor ->
                    while (cursor.moveToNext()) gids += cursor.getLong(0)
                }
            }
            groupPreview(StagedRows(groups, gids))
        }
    }.onFailure { Logs.w(it) }.getOrDefault(emptyList())

    private fun SQLiteDatabase.hasTable(name: String): Boolean = runCatching {
        DatabaseUtils.longForQuery(this, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", arrayOf(name)) > 0
    }.getOrDefault(false)
}
