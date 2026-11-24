package moe.matsuri.nb4a.utils

import androidx.preference.PreferenceDataStore
import io.nekohasekai.sagernet.Key
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.SettingsDocumentWatch
import io.nekohasekai.sagernet.database.SettingsJsonStore
import io.nekohasekai.sagernet.database.SettingsRegistry
import io.nekohasekai.sagernet.database.preference.OnPreferenceDataStoreChangeListener
import io.nekohasekai.sagernet.ktx.app
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong

// Shared by both processes: every line is an O_APPEND write on one inode. At the size cap the newest half is kept in
// place under a file lock (both processes may hit the cap; the loser re-checks the size), so a process that opened
// the file earlier keeps appending to it. A new :bg process keeps the previous session in core.log.prev.
object CoreLog {

    private const val FILE_NAME = "core.log"
    private const val PREVIOUS_FILE_NAME = "core.log.prev"
    const val DEFAULT_SIZE_KB = 512
    const val MIN_SIZE_KB = 50
    const val MAX_SIZE_KB = 10 * 1024

    private val lock = Any()
    private var stream: FileOutputStream? = null
    // Local time like the desktop's log.
    private val timestamp = SimpleDateFormat("yyyy/MM/dd HH:mm:ss", Locale.US)

    val file: File get() = File(app.filesDir, FILE_NAME)
    val previousFile: File get() = File(app.filesDir, PREVIOUS_FILE_NAME)

    @Volatile
    private var cachedLevel: String? = null

    @Volatile
    private var cachedSizeKb = 0

    private var watching = false

    private val refreshTicket = AtomicLong()
    private var appliedTicket = 0L

    /**
     * Catches the settings writes no in-process listener reports: a backup restore replaces the
     * whole document ([SettingsJsonStore.replaceAll]) instead of putting one key at a time, and a
     * second process would fire nothing here at all. Rate-limited by the watch (one stat pair per
     * 2 s) and read-driven — an idle process never stats. The refresh it triggers must not
     * register the listener again, or every watched change would add another one.
     */
    private val documentWatch = SettingsDocumentWatch(
        stampSource = SettingsJsonStore::settingsStamp,
        onChanged = { refreshSettings(registerListener = false) },
    )

    /** The stored log_level, cached for every line written; null while the settings cannot be read (JVM tests). */
    val logLevel: String?
        get() {
            documentWatch.check()
            return cachedLevel ?: run {
                refreshSettings()
                cachedLevel
            }
        }

    /**
     * Re-reads log_level and logBufSize. The first read starts watching the settings document, so a change made
     * in this process reaches the cache; a whole-document replace (a backup restore) or a write from another
     * process is caught by [documentWatch] on the next read of the level or the size.
     *
     * ADR 0006 stage C2c2b2: this used to also watch Room's settings table, which no longer exists.
     */
    fun refreshSettings() {
        refreshSettings(registerListener = true)
    }

    /**
     * [refreshSettings] for the document watch: applies the fresh values but leaves the existing
     * listener in place. Registering from here would add a listener per detected write — and the
     * listener itself would then call back into this object on every put.
     */
    private fun refreshSettings(registerListener: Boolean) {
        // Sample the document before the read: the values cached below and this baseline then
        // describe the same moment, so a restore landing during or after the read is still seen
        // by the next check instead of being folded into the baseline.
        documentWatch.prime()
        // Overlapping refreshes (listener callbacks run concurrently) may finish out of order: the one that started
        // last read the freshest value, so an older read never overwrites it. The document read stays outside the monitor.
        val ticket = refreshTicket.incrementAndGet()
        val (level, sizeKb) = runCatching { DataStore.logLevel to DataStore.logBufSize }.getOrNull() ?: return
        synchronized(this) {
            if (ticket > appliedTicket) {
                appliedTicket = ticket
                cachedSizeKb = sizeKb
                cachedLevel = level
            }
        }
        if (!registerListener) return
        val register = synchronized(this) {
            if (watching) {
                false
            } else {
                watching = true
                true
            }
        }
        if (!register) return
        DataStore.configurationStore.registerChangeListener(object : OnPreferenceDataStoreChangeListener {
            override fun onPreferenceDataStoreChanged(store: PreferenceDataStore, key: String) {
                if (key == SettingsRegistry.LOG_LEVEL.key || key == Key.LOG_BUF_SIZE) refreshSettings()
            }
        })
    }

    /** logBufSize KB (the long-press setting) within [MIN_SIZE_KB]..[MAX_SIZE_KB], [DEFAULT_SIZE_KB] while unset. */
    private fun maxSizeBytes(): Long {
        documentWatch.check()
        val kb = cachedSizeKb
        return (if (kb <= 0) DEFAULT_SIZE_KB else kb.coerceIn(MIN_SIZE_KB, MAX_SIZE_KB)) * 1024L
    }

    // "panic" keeps the file empty, the way the old "none" level did.
    private fun enabled(): Boolean = logLevel != "panic"

    private fun stream(): FileOutputStream {
        stream?.let { return it }
        return FileOutputStream(file, true).also { stream = it }
    }

    // The core colours its lines for terminals; the Log screen and exports are plain text.
    private val ansiColor = Regex("\u001B\\[[0-9;]*m")

    fun write(line: String) {
        if (!enabled()) return
        val stamp = synchronized(timestamp) { timestamp.format(Date()) }
        val text = if (line.indexOf('\u001B') >= 0) ansiColor.replace(line, "") else line
        val bytes = "$stamp $text\n".toByteArray()
        synchronized(lock) {
            runCatching {
                val out = stream()
                val max = maxSizeBytes()
                if (out.channel.size() + bytes.size > max) rotate(out.channel, max, bytes.size)
                out.write(bytes)
            }.onFailure { stream = null }
        }
    }

    private fun rotate(channel: FileChannel, max: Long, incoming: Int) {
        val fileLock = channel.lock()
        try {
            val size = channel.size()
            if (size + incoming <= max) return
            val keep = minOf(size, max / 2).toInt()
            val tail = ByteArray(keep)
            RandomAccessFile(file, "r").use {
                it.seek(size - keep)
                it.readFully(tail)
            }
            val start = if (keep.toLong() == size) 0 else tail.indexOf('\n'.code.toByte()) + 1
            channel.truncate(0)
            channel.write(ByteBuffer.wrap(tail, start, keep - start))
        } finally {
            fileLock.release()
        }
    }

    /** A new :bg process: the previous session moves to core.log.prev, so a crashed service's log survives. */
    fun newSession() {
        refreshSettings()
        synchronized(lock) {
            runCatching {
                val channel = stream().channel
                val fileLock = channel.lock()
                try {
                    if (channel.size() > 0) {
                        file.copyTo(previousFile, overwrite = true)
                        channel.truncate(0)
                    }
                } finally {
                    fileLock.release()
                }
            }.onFailure { stream = null }
        }
    }

    /** Clears both the current and the previous session. */
    fun clear() {
        synchronized(lock) {
            runCatching { stream().channel.truncate(0) }.onFailure { stream = null }
            runCatching { previousFile.delete() }
        }
    }

    fun read(maxBytes: Long): ByteArray = read(file, maxBytes)

    fun readPrevious(): ByteArray = read(previousFile, 0)

    private fun read(target: File, maxBytes: Long): ByteArray {
        return try {
            val length = target.length()
            FileInputStream(target).use { input ->
                if (maxBytes !in 1 until length) return input.readBytes()
                input.skip(length - maxBytes)
                val tail = input.readBytes()
                // The cut lands mid-line: start at the next full line.
                val start = tail.indexOf('\n'.code.toByte()) + 1
                tail.copyOfRange(start, tail.size)
            }
        } catch (e: Exception) {
            e.stackTraceToString().toByteArray()
        }
    }
}
