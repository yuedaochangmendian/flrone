package io.nekohasekai.sagernet.database

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile

/**
 * The settings documents' inter-process write lock (ADR 0006 stage C2).
 *
 * `settings.json`/`markers.json` are whole-file read-modify-write cycles: a writer reads the
 * rows, adds or drops one and rewrites the file. Two processes doing that at the same time each
 * rewrite from their own snapshot, so one of the two keys is silently lost. The store itself is
 * mounted from [io.nekohasekai.sagernet.SagerNet.onCreate] in every process, so the lock is
 * what keeps a service write (a start's `serviceError`, the running profile) and a UI write
 * from overwriting each other.
 *
 * An OS file lock on a sibling `.settings.lock`: `fcntl` locks on Android, released by the
 * kernel when the holding process dies, so there is no stale-lock protocol to get wrong and no
 * timeout to tune. Advisory by nature — every writer must be this object, which is why the
 * store does not expose any other write path.
 *
 * The lock file is not a document: it is empty, never read, and safe to delete while nothing
 * runs.
 */
internal object DocumentWriteLock {

    /** The lock file's name inside the documents directory. */
    const val FILE = ".settings.lock"

    /**
     * Runs [block] as the only settings write in this file's directory across processes.
     *
     * The monitor the store holds around the call keeps this process's threads apart (a
     * `FileLock` is held per JVM, so a second acquisition from the same process would throw
     * `OverlappingFileLockException` instead of waiting). [block] runs outside the `IOException`
     * guard on purpose: a failed *write* must not be retried unlocked.
     */
    fun <T> withLock(dir: File, logger: (String, Throwable?) -> Unit, block: () -> T): T {
        val handle = try {
            if (!dir.isDirectory) dir.mkdirs()
            RandomAccessFile(File(dir, FILE), "rw")
        } catch (error: IOException) {
            logger("settings: cannot open the document lock, writing unlocked", error)
            return block()
        }
        try {
            val lock = try {
                handle.channel.lock()
            } catch (error: IOException) {
                // The app's own filesDir is lockable; a failure here is an environment quirk.
                // Writing unlocked is better than a settings store that stops saving.
                logger("settings: cannot take the document lock, writing unlocked", error)
                return block()
            }
            try {
                return block()
            } finally {
                runCatching { lock.release() }
            }
        } finally {
            runCatching { handle.close() }
        }
    }
}
