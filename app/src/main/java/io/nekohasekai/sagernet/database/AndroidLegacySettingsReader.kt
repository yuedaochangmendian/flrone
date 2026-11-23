package io.nekohasekai.sagernet.database

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import io.nekohasekai.sagernet.Key
import io.nekohasekai.sagernet.SagerNet
import java.io.File

/**
 * One shot read of Room's retired `settings` / `markers` tables, for the seed of
 * `settings.json` / `markers.json` (ADR 0006 stage C2b).
 *
 * Room schema 21 drops both tables. An install that upgrades from 20 still has
 * its rows in `sager_net.db` and only there, so [io.nekohasekai.sagernet.database.SettingsJsonStore]
 * seeds the documents from this reader *before* Room opens the file — and Room's
 * own open runs the 20 -> 21 migration, which drops the tables afterwards.
 * `SagerNet.onCreate` mounts the document directory and calls
 * `SettingsJsonStore.ensure()`, so the order holds in every process; a process
 * that somehow opened Room first would just find no tables here and seed
 * nothing (the migration's DROP keeps it from losing rows the document already
 * has).
 *
 * The file is opened with the framework's own [SQLiteDatabase] in read-only
 * mode: this code never creates a database, never migrates one and never writes
 * — a missing file (first install), a missing table (already on schema 21) or
 * any error at all answers empty maps, which is exactly the first-install seed.
 * That includes a WAL-mode file whose `-shm` cannot be attached to; the rows
 * are then already lost to the migration, not to this reader.
 *
 * The row decisions ([read] over a [Source]) are plain Kotlin so the JVM tests
 * can exercise them; only [FrameworkSource] touches `android.database`, so the
 * DB-open path itself is a device/CI check.
 */
object AndroidLegacySettingsReader {

    /** The retired tables' names, as schema 20 exported them. */
    const val SETTINGS = "settings"
    const val MARKERS = "markers"

    /** What the retired tables held; both maps are empty when there was nothing to read. */
    class Legacy(
        val settings: Map<String, String> = emptyMap(),
        val markers: Map<String, Long> = emptyMap(),
    )

    /**
     * The three reads the seed needs. Implemented by [FrameworkSource] over the
     * real database and by the JVM tests over a fake.
     */
    internal interface Source {
        /** Table names from `sqlite_master`. */
        fun tables(): Set<String>

        /** `(key, value)` rows of [`settings`], key null when the column is null. */
        fun settingsRows(): List<Pair<String?, String?>>

        /** `(key, marked_at)` rows of [`markers`]. */
        fun markerRows(): List<Pair<String?, Long?>>
    }

    /** Diagnostics seam, like `SettingsJsonStore.logger`. */
    @Volatile
    var logger: (String, Throwable?) -> Unit = { message, error ->
        if (error != null) {
            io.nekohasekai.sagernet.ktx.Logs.w(message, error)
        } else {
            io.nekohasekai.sagernet.ktx.Logs.w(message)
        }
    }

    /** Room's file (`Key.DB_PROFILE`); the reader never opens anything else. */
    fun databaseFile(): File = SagerNet.application.getDatabasePath(Key.DB_PROFILE)

    /** Seeds from [file] (Room's database); empty when it or a table is missing. */
    fun read(file: File = databaseFile()): Legacy {
        if (!file.isFile) return Legacy()
        val database = try {
            SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY)
        } catch (error: Throwable) {
            logger("settings: ${file.name} cannot be opened read-only, seeding nothing", error)
            return Legacy()
        }
        return try {
            read(FrameworkSource(database))
        } finally {
            runCatching { database.close() }
        }
    }

    /**
     * The row decisions: which tables exist, which rows survive, and what a key
     * without a usable value means. A failing read of one table leaves that
     * table empty instead of failing the whole seed.
     */
    internal fun read(source: Source): Legacy {
        val tables = try {
            source.tables()
        } catch (error: Throwable) {
            logger("settings: the legacy table list is unreadable, seeding nothing", error)
            return Legacy()
        }
        val settings = if (SETTINGS in tables) {
            try {
                val rows = LinkedHashMap<String, String>()
                for ((key, value) in source.settingsRows()) {
                    if (key != null) rows[key] = value ?: ""
                }
                rows
            } catch (error: Throwable) {
                logger("settings: the legacy settings rows are unreadable, skipping them", error)
                emptyMap()
            }
        } else {
            emptyMap()
        }
        val markers = if (MARKERS in tables) {
            try {
                val rows = LinkedHashMap<String, Long>()
                for ((key, markedAt) in source.markerRows()) {
                    // The desktop stores the timestamp opaquely; a row without a
                    // usable one is not a marker this app can carry forward.
                    if (key != null && markedAt != null) rows[key] = markedAt
                }
                rows
            } catch (error: Throwable) {
                logger("settings: the legacy marker rows are unreadable, skipping them", error)
                emptyMap()
            }
        } else {
            emptyMap()
        }
        return Legacy(settings, markers)
    }

    /** The framework connection, adapted to [Source]. Nothing here writes. */
    private class FrameworkSource(private val database: SQLiteDatabase) : Source {

        override fun tables(): Set<String> {
            val names = HashSet<String>(16)
            database.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'", null).use { cursor ->
                while (cursor.moveToNext()) names += cursor.getString(0)
            }
            return names
        }

        override fun settingsRows(): List<Pair<String?, String?>> =
            database.rawQuery("SELECT `key`, `value` FROM `settings` ORDER BY `key`", null).use { cursor ->
                rows(cursor) { it.getString(0) to it.getString(1) }
            }

        override fun markerRows(): List<Pair<String?, Long?>> =
            database.rawQuery("SELECT `key`, `marked_at` FROM `markers` ORDER BY `key`", null).use { cursor ->
                rows(cursor) { it.getString(0) to if (it.isNull(1)) null else it.getLong(1) }
            }

        private fun <T> rows(cursor: Cursor, read: (Cursor) -> T): List<T> {
            val out = ArrayList<T>(cursor.count.coerceAtLeast(0))
            while (cursor.moveToNext()) out += read(cursor)
            return out
        }
    }
}
