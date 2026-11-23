package io.nekohasekai.sagernet.database

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile

/**
 * The settings documents — `settings.json` and `markers.json` — the pure-file
 * store behind [io.nekohasekai.sagernet.database.preference.SettingsStore]
 * (ADR 0006 stage C1). One file, one writer: this process owns the settings,
 * Dart reads them over the channel, and a backup restore funnels through the
 * host op, so the writer stays singular.
 *
 * The documents are the only store once the host has named the directory (ADR 0006
 * stages C2b/C2c2b2 retired the settings/markers tables and every Room type). [ensure]
 * seeds a missing or corrupt document from the legacy rows on first access — read
 * straight out of the old file by [io.flrone.bridge.LegacyRoomReader], the only reader
 * of it — so correctness does not depend on call order at start-up, and a corrupt or
 * missing document re-seeds instead of losing rows.
 *
 * ADR 0006 stage C2: the directory is mounted by
 * [io.nekohasekai.sagernet.SagerNet.onCreate], i.e. in every process that runs
 * before it can read [io.nekohasekai.sagernet.database.DataStore] — not by the
 * UI bridge once Dart attaches. A service launched from a tile or at boot (no
 * Flutter engine, no `data.path` call) therefore reads and writes the same
 * document the UI does, instead of Room's frozen copy.
 *
 * File discipline mirrors Go's `writeDocument`: temp file, flush, rename.
 * Parsed rows are cached by file mtime+length (like `RouteJsonStore`), so the
 * host's own writes and a restore from Dart both invalidate by construction.
 * Read-modify-write is a whole-file cycle, so every mutation runs under a
 * process monitor **and** an OS file lock ([DocumentWriteLock]) — two processes
 * writing the settings would otherwise each rewrite the file from its own
 * snapshot and one of them would lose its key.
 */
object SettingsJsonStore {

    private const val SETTINGS = "settings"
    private const val MARKERS = "markers"

    /**
     * Set on every document this object writes. An empty `rows` array without it
     * is not authoritative — it is what a truncated seed, a foreign file or a
     * pre-C2 document written from empty legacy rows looks like — so [ensure]
     * seeds it from the legacy rows instead of letting the next write start from
     * nothing. A deliberate [reset]/[resetMarkers] keeps the marker, so an
     * intentional empty document stays empty.
     */
    private const val WRITTEN = "written"

    private class Parsed(val modified: Long, val length: Long, val rows: Map<String, String>?)

    private val lock = Any()
    private var settingsCache: Parsed? = null
    private var markersCache: Parsed? = null

    /** Where the documents live; `SagerNet.onCreate` sets it for every process. */
    @Volatile
    var directory: File? = null
        set(value) {
            field = value
            synchronized(lock) {
                settingsCache = null
                markersCache = null
            }
        }

    /** True once the host has named a directory: the documents are then the store. */
    val mounted: Boolean get() = directory != null

    /**
     * The pre-migration rows the seed dumps: the retired `settings` table, read
     * read-only through [io.flrone.bridge.LegacyRoomReader] — the only reader of
     * the old file (ADR 0006 stage C2c2b2). The rows only exist in an install
     * that has not migrated yet; injected by tests.
     */
    @Volatile
    var legacySettings: () -> Map<String, String> = {
        io.flrone.bridge.LegacyRoomReader.settings()
    }

    /** The pre-migration marker rows (the retired `markers` table), same reader. */
    @Volatile
    var legacyMarkers: () -> Map<String, Long> = {
        io.flrone.bridge.LegacyRoomReader.markers()
    }

    /** Diagnostics seam for JVM tests (RouteJsonStore's pattern). */
    @Volatile
    var logger: (String, Throwable?) -> Unit = { message, error ->
        if (error != null) {
            io.nekohasekai.sagernet.ktx.Logs.w(message, error)
        } else {
            io.nekohasekai.sagernet.ktx.Logs.w(message)
        }
    }

    // ------------------------------------------------------------------------------------------------ documents

    /**
     * Runs [block] as the process's only settings read-modify-write: the object monitor keeps
     * the threads of this process apart, [DocumentWriteLock] keeps the processes apart.
     */
    private fun <T> withWriteLock(block: () -> T): T = synchronized(lock) {
        val dir = directory ?: return block()
        DocumentWriteLock.withLock(dir, logger) { block() }
    }

    private fun fileOf(name: String): File? = directory?.let { File(it, "$name.json") }

    private fun readRows(name: String): Map<String, String>? {
        val file = fileOf(name) ?: return null
        if (!file.isFile) return null
        val meta = Parsed(file.lastModified(), file.length(), null)
        val cached = if (name == SETTINGS) settingsCache else markersCache
        if (cached != null && cached.modified == meta.modified && cached.length == meta.length) {
            return cached.rows
        }
        val rows = try {
            val document = JSONObject(file.readText())
            val array = document.optJSONArray("rows") ?: JSONArray()
            val parsed = LinkedHashMap<String, String>()
            for (i in 0 until array.length()) {
                val row = array.optJSONObject(i) ?: continue
                val key = row.optString("key")
                if (key.isNotEmpty()) parsed[key] = row.opt("value")?.toString() ?: ""
            }
            if (parsed.isEmpty() && !document.optBoolean(WRITTEN)) {
                // Empty and not written by this object: a half seed, a foreign file or a
                // pre-C2 document. Treat it as missing (the seed path) rather than as "the
                // user has no settings", which would make the next write drop the legacy rows.
                logger("settings: ${file.name} is empty and unmarked, re-seeding from the legacy rows", null)
                null
            } else {
                parsed
            }
        } catch (error: Throwable) {
            logger("settings: ${file.name} is unreadable, re-seeding from the legacy rows", error)
            null
        }
        val entry = Parsed(meta.modified, meta.length, rows)
        synchronized(lock) {
            if (name == SETTINGS) settingsCache = entry else markersCache = entry
        }
        return rows
    }

    private fun writeRows(name: String, rows: Map<String, String>) {
        val file = fileOf(name) ?: error("settings document directory is not set")
        val document = JSONObject()
        document.put("version", 1)
        document.put("name", name)
        document.put(WRITTEN, true)
        val array = JSONArray()
        for ((key, value) in rows) {
            array.put(JSONObject().put("key", key).put("value", value))
        }
        document.put("rows", array)
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, "${file.name}.${System.nanoTime()}.tmp")
        temp.writeText(document.toString())
        if (!temp.renameTo(file)) {
            file.writeText(document.toString())
            temp.delete()
        }
        synchronized(lock) {
            if (name == SETTINGS) {
                settingsCache = Parsed(file.lastModified(), file.length(), LinkedHashMap(rows))
            } else {
                markersCache = Parsed(file.lastModified(), file.length(), LinkedHashMap(rows))
            }
        }
    }

    /**
     * Seeds a missing or corrupt document from the legacy rows; no-op when healthy.
     *
     * The healthy path stays lock-free: reads are safe because every write lands by rename,
     * and taking the write lock on every preference read would put a file lock in front of
     * each of them. Only the seeding write takes it.
     */
    fun ensure() {
        if (!mounted) return
        if (readRows(SETTINGS) != null && readRows(MARKERS) != null) return
        withWriteLock { ensureLocked() }
    }

    /** [ensure] with the monitor and the file lock already held. */
    private fun ensureLocked() {
        if (readRows(SETTINGS) == null) {
            val seeded = LinkedHashMap(legacySettings())
            writeRows(SETTINGS, seeded)
        }
        if (readRows(MARKERS) == null) {
            writeRows(MARKERS, markersToStrings(legacyMarkers()))
        }
    }

    // ------------------------------------------------------------------------------------------------ settings

    fun get(key: String): String? {
        ensure()
        return readRows(SETTINGS)?.get(key)
    }

    fun all(): Map<String, String> {
        ensure()
        return LinkedHashMap(readRows(SETTINGS) ?: emptyMap())
    }

    fun put(key: String, value: String) = withWriteLock {
        ensureLocked()
        val rows = LinkedHashMap(readRows(SETTINGS) ?: emptyMap())
        rows[key] = value
        writeRows(SETTINGS, rows)
    }

    fun putAll(values: Map<String, String>) {
        if (values.isEmpty()) return
        withWriteLock {
            ensureLocked()
            val rows = LinkedHashMap(readRows(SETTINGS) ?: emptyMap())
            rows.putAll(values)
            writeRows(SETTINGS, rows)
        }
    }

    fun remove(key: String) {
        withWriteLock {
            ensureLocked()
            val rows = LinkedHashMap(readRows(SETTINGS) ?: emptyMap())
            if (rows.remove(key) == null) return@withWriteLock
            writeRows(SETTINGS, rows)
        }
    }

    fun reset() {
        if (!mounted) return
        withWriteLock { writeRows(SETTINGS, LinkedHashMap()) }
    }

    /**
     * Replaces the whole settings set in one write. A backup restore is a full
     * replacement (the merge rules run before it, in `BboxRoomSnapshot`), and
     * [reset] + [putAll] would leave the settings empty if the process died
     * between the two cycles — the same reason [replaceMarkers] exists.
     */
    fun replaceAll(values: Map<String, String>) {
        if (!mounted) return
        withWriteLock { writeRows(SETTINGS, LinkedHashMap(values)) }
    }

    // ------------------------------------------------------------------------------------------------ markers

    fun markers(): Map<String, Long> {
        ensure()
        return stringToMarkers(readRows(MARKERS))
    }

    fun resetMarkers() {
        if (!mounted) return
        withWriteLock { writeRows(MARKERS, LinkedHashMap()) }
    }

    fun putMarkers(values: Map<String, Long>) {
        if (values.isEmpty()) return
        withWriteLock {
            ensureLocked()
            val rows = LinkedHashMap(readRows(MARKERS) ?: emptyMap())
            rows.putAll(markersToStrings(values))
            writeRows(MARKERS, rows)
        }
    }

    /**
     * Replaces the whole marker set in one write: a restore is a full
     * replacement, and [resetMarkers] + [putMarkers] would leave the markers
     * empty if the process died between the two cycles.
     */
    fun replaceMarkers(values: Map<String, Long>) {
        if (!mounted) return
        withWriteLock { writeRows(MARKERS, markersToStrings(values)) }
    }

    private fun markersToStrings(values: Map<String, Long>): Map<String, String> =
        values.mapValues { it.value.toString() }

    private fun stringToMarkers(rows: Map<String, String>?): Map<String, Long> =
        (rows ?: emptyMap()).mapNotNull { (key, value) ->
            value.toLongOrNull()?.let { key to it }
        }.toMap(LinkedHashMap())
}