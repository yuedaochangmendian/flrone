package io.flrone.bridge

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import io.nekohasekai.sagernet.Key
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import java.io.File

/**
 * The ONE reader of the retired Room file (`sager_net.db`): raw, read-only, and
 * used only for the one-time seed of the documents that replaced it
 * (ADR 0006 stages C2c2a / C2c2b2).
 *
 * Every live data plane has a document of its own: profiles/groups in
 * `profiles.json` (Dart), the single global rule table in the kernel's
 * `global_route_rules.json`, settings and markers in
 * `settings.json`/`markers.json`. Those documents are read and written
 * directly; this object exists so an upgrading install can carry the
 * profiles/settings/markers rows the old file still holds into them, once.
 * Route rows are never migrated: there is no legacy route format any more,
 * and a missing global table is simply an empty rule table. Nothing in the
 * running app reads the database after the seed, and no Room code is involved.
 *
 * The columns are read with the framework's [SQLiteDatabase] — an app may not
 * dlopen the platform SQLite from Dart (`libsqlite3.so` is not on AOSP and
 * `libsqlite.so` is not public) and the retired database must not be opened
 * just to answer a question about documents the app already owns.
 *
 * The reader is deliberately incapable of hurting the file:
 *  - it never creates or migrates a database ([SQLiteDatabase.OPEN_READONLY],
 *    and a missing file answers empty before anything is opened);
 *  - it never writes: no INSERT/UPDATE/DELETE and no DDL, only `SELECT *` on
 *    the compile-time table list below;
 *  - a corrupt/incompatible file (or a table that is gone) answers empty lists,
 *    which is exactly the first-install seed.
 *
 * Three consumers, all "documents first":
 *  - [snapshot] (`data.legacyRows`) hands the profiles/groups rows to Dart's
 *    one-time `profiles.json` seed, and the settings/marker rows only while
 *    their documents are absent;
 *  - [settings] / [markers] feed `SettingsJsonStore.ensure` on the first launch
 *    after the upgrade, before the documents exist.
 *
 * The row decisions ([eligible], [read] over a [Source]) are plain Kotlin so
 * the JVM tests can exercise them; only [FrameworkSource] touches
 * `android.database`, so the DB-open path itself is a device/CI check.
 */
object LegacyRoomReader {

    /** The tables the one-time hand-over reads, in the retired schema's names. */
    const val PROFILES = "profiles"
    const val GROUPS = "groups"
    const val SETTINGS = "settings"
    const val MARKERS = "markers"

    /** Every table [snapshot] can answer. Route tables are deliberately absent. */
    val TABLES = listOf(PROFILES, GROUPS, SETTINGS, MARKERS)

    /** What the retired database held; every list is empty when nothing was read. */
    class Legacy(val rows: Map<String, List<Map<String, Any?>>> = emptyMap())

    /** Which tables are still allowed to answer: their documents are absent. */
    class Eligible(
        val profiles: Boolean,
        val settings: Boolean,
        val markers: Boolean,
    )

    /** The two reads the mapping needs; a fake implements this in the JVM tests. */
    internal interface Source {
        /** Table names from `sqlite_master`. */
        fun tables(): Set<String>

        /** `SELECT *` rows of [table], column-keyed. Table names are constants. */
        fun rows(table: String): List<Map<String, Any?>>
    }

    /** Diagnostics seam, like `SettingsJsonStore.logger`. */
    @Volatile
    var logger: (String, Throwable?) -> Unit = { message, error ->
        if (error != null) Logs.w(message, error) else Logs.w(message)
    }

    /** Room's file (`Key.DB_PROFILE`); the reader never opens anything else. */
    fun databaseFile(): File = app.getDatabasePath(Key.DB_PROFILE)

    /** The documents directory the eligibility check looks at. */
    fun documentsDir(): File = File(app.filesDir, "documents")

    /** Reads [file] (Room's database); empty when it is missing or unreadable. */
    fun read(file: File = databaseFile()): Legacy {
        if (!file.isFile) return Legacy()
        val database = try {
            SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY)
        } catch (error: Throwable) {
            logger("legacy: ${file.name} cannot be opened read-only, seeding nothing", error)
            return Legacy()
        }
        return try {
            read(FrameworkSource(database))
        } finally {
            runCatching { database.close() }
        }
    }

    /**
     * The row decisions: which tables exist and which rows come back. A failing
     * read of one table leaves that table empty instead of failing the hand-over.
     */
    internal fun read(source: Source): Legacy {
        val tables = try {
            source.tables()
        } catch (error: Throwable) {
            logger("legacy: the table list is unreadable, seeding nothing", error)
            return Legacy()
        }
        val rows = LinkedHashMap<String, List<Map<String, Any?>>>()
        for (table in TABLES) {
            if (table !in tables) continue
            rows[table] = try {
                source.rows(table)
            } catch (error: Throwable) {
                logger("legacy: the $table rows are unreadable, skipping them", error)
                emptyList()
            }
        }
        return Legacy(rows)
    }

    /**
     * The document-presence gate: a table may only answer while its document is
     * missing. `profiles.json` is Dart's document; settings and markers are
     * named by their owners (`settings.json`, `markers.json`). Route documents
     * have no migration path — there is no legacy route format. Plain
     * [File.isFile] checks — nothing is created here.
     */
    internal fun eligible(documents: File): Eligible = Eligible(
        profiles = !File(documents, "profiles.json").isFile,
        settings = !File(documents, "settings.json").isFile,
        markers = !File(documents, "markers.json").isFile,
    )

    /**
     * The `data.legacyRows` reply: the rows of every table whose document is
     * still absent, empty lists otherwise. A fresh install (no database file)
     * answers all-empty lists and creates nothing.
     */
    fun snapshot(
        documents: File = documentsDir(),
        file: File = databaseFile(),
    ): Map<String, Any?> = snapshot(read(file), eligible(documents))

    /** [snapshot] over already-read rows; the JVM tests drive the gate without Android. */
    internal fun snapshot(legacy: Legacy, can: Eligible): Map<String, Any?> {
        fun part(table: String, enabled: Boolean): List<Map<String, Any?>> =
            if (enabled) legacy.rows[table].orEmpty() else emptyList()

        return mapOf(
            "profiles" to part(PROFILES, can.profiles),
            "groups" to part(GROUPS, can.profiles),
            SETTINGS to part(SETTINGS, can.settings),
            MARKERS to part(MARKERS, can.markers),
        )
    }

    /**
     * The retired `settings` rows as `settings.json` takes them: key -> value, a
     * row without a key skipped and a null value read as "". Read only while
     * that document is absent ([SettingsJsonStore] gates it), so a healthy
     * install never opens the database for this.
     */
    fun settings(file: File = databaseFile()): Map<String, String> =
        settingsFrom(read(file).rows[SETTINGS].orEmpty())

    /**
     * The retired `markers` rows as `markers.json` takes them: key -> marked_at.
     * A row without a usable timestamp is not a marker this app can carry.
     */
    fun markers(file: File = databaseFile()): Map<String, Long> =
        markersFrom(read(file).rows[MARKERS].orEmpty())

    internal fun settingsFrom(rows: List<Map<String, Any?>>): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for (row in rows) {
            val key = row["key"] as? String ?: continue
            out[key] = row["value"]?.toString() ?: ""
        }
        return out
    }

    internal fun markersFrom(rows: List<Map<String, Any?>>): Map<String, Long> {
        val out = LinkedHashMap<String, Long>()
        for (row in rows) {
            val key = row["key"] as? String ?: continue
            val markedAt = row["marked_at"] as? Number ?: continue
            out[key] = markedAt.toLong()
        }
        return out
    }

    /** The framework connection, adapted to [Source]. Nothing here writes. */
    private class FrameworkSource(private val database: SQLiteDatabase) : Source {

        override fun tables(): Set<String> {
            val names = HashSet<String>(16)
            database.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'", null).use { cursor ->
                while (cursor.moveToNext()) cursor.getString(0)?.let { names += it }
            }
            return names
        }

        override fun rows(table: String): List<Map<String, Any?>> {
            // [table] is one of this object's compile-time constants, never input.
            database.rawQuery("SELECT * FROM `$table`", null).use { cursor ->
                val columns = cursor.columnNames
                val out = ArrayList<Map<String, Any?>>(cursor.count.coerceAtLeast(0))
                while (cursor.moveToNext()) {
                    val row = LinkedHashMap<String, Any?>(columns.size * 2)
                    columns.forEachIndexed { index, name -> row[name] = value(cursor, index) }
                    out += row
                }
                return out
            }
        }

        private fun value(cursor: Cursor, index: Int): Any? = when (cursor.getType(index)) {
            Cursor.FIELD_TYPE_NULL -> null
            Cursor.FIELD_TYPE_INTEGER -> cursor.getLong(index)
            Cursor.FIELD_TYPE_FLOAT -> cursor.getDouble(index)
            Cursor.FIELD_TYPE_BLOB -> cursor.getBlob(index)
            else -> cursor.getString(index)
        }
    }
}
