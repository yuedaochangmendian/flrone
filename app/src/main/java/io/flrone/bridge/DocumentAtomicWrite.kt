package io.flrone.bridge

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * The one temp-file + rename discipline for the JSON documents Kotlin owns
 * (`ui_settings.json`, `preferences.json`, `settings.json`, `markers.json`).
 *
 * A failed rename must never fall back to writing the target in place: the
 * target may be the only authoritative copy, and a partial write truncates it.
 * Instead the temp file is moved with NIO `REPLACE_EXISTING` (MoveFileEx on
 * Windows, which replaces an existing target atomically; `File.renameTo` does
 * not and was the reason the old code had an in-place fallback at all). A
 * transient failure is retried once with a fresh temp name; if that still
 * fails the error is surfaced and the old target is left byte-for-byte intact.
 *
 * [move] is injectable so a JVM test can force a failing rename without
 * depending on OS-specific file locking semantics.
 */
internal object DocumentAtomicWrite {

    /** Same contract as the atomic move below, injectable for tests. */
    fun interface Move {
        fun invoke(from: File, to: File)
    }

    @Volatile
    var move: Move = Move { from, to ->
        Files.move(
            from.toPath(), to.toPath(),
            StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING,
        )
    }

    /** Number of attempts: the first plus one retry with a fresh temp name. */
    private const val ATTEMPTS = 2

    /**
     * Atomically replaces [target] with [payload] (UTF-8). Throws [IOException] when no
     * move succeeds; the previous [target] is left byte-for-byte intact in that case.
     */
    fun write(target: File, payload: String) {
        val directory = target.parentFile ?: throw IOException("no parent directory for ${target.name}")
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw IOException("cannot create document directory ${directory.path}")
        }
        val base = target.name
        var lastError: IOException? = null
        repeat(ATTEMPTS) { attempt ->
            val temp = File(directory, "$base.${System.nanoTime()}-$attempt.tmp")
            try {
                temp.writeText(payload, Charsets.UTF_8)
                move.invoke(temp, target)
                return
            } catch (error: IOException) {
                lastError = error
            } finally {
                runCatching { if (temp.isFile) temp.delete() }
            }
        }
        throw lastError ?: IOException("cannot write $base")
    }
}
