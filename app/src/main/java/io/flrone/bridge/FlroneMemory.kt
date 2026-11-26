package io.flrone.bridge

import android.content.ComponentCallbacks2
import android.os.Build
import java.util.concurrent.CopyOnWriteArrayList

/**
 * System-level memory trimming on Android — the platform half of Bettbox's background-GC strategy.
 *
 * The core is sing-box compiled into this process. What Android can do is hint the ART runtime
 * ([gc]) and ask it to trim the heap back to the OS ([purgeMemory]); the Go runtime's heap is
 * outside ART, so the service engine is asked to force a GC there as well ([forceCoreGc]).
 *
 * Bettbox trims malloc arenas with `mallopt`; bionic exports `mallopt` as a plain libc symbol with no
 * `Java_` binding, so it cannot be reached through JNI static registration without a native shim. The
 * ART [dalvik.system.VMRuntime.trimHeap] this invokes serves the same purpose — it releases the heap
 * the runtime holds onto after a burst of traffic — and is stable since API 21, hidden only from the
 * SDK surface.
 *
 * Neither call reaches the Dart heap: the Flutter engine owns that one, so the decoded-image cache
 * and the UI's own objects survive a trim unless the UI is told. [observeTrim] is that channel.
 */
object FlroneMemory {

    private val trims = CopyOnWriteArrayList<(Int) -> Unit>()

    /** Registers a listener told about every trim level; call the returned function to unregister. */
    fun observeTrim(listener: (Int) -> Unit): () -> Unit {
        trims += listener
        return { trims -= listener }
    }

    /**
     * ART + decoded-image trim only — NOT a whole-process release. This is the host half of the
     * user-facing "release memory" action: the same complete-level ART/image trim the system would
     * ask for under pressure. The Go collection is deliberately not triggered here — the memory
     * page pairs this with the core's `forceGC(full=true)` so it can measure and report the freed
     * Go bytes; firing both here would run two full collections and hide that measurement. A future
     * caller invoking [release] alone must not claim the Go heap was collected. It cannot reach the
     * Dart VM's heap (native, outside ART).
     */
    fun release() {
        for (listener in trims) runCatching { listener(ComponentCallbacks2.TRIM_MEMORY_COMPLETE) }
        gc()
        purgeMemory()
    }

    /**
     * The whole reaction to `Application.onTrimMemory`: tell the UI first (it can drop decoded
     * images immediately), then hand the hint to ART and the Go runtime. The order matters — a
     * trim that reaches the UI after the process has already been killed is not a trim.
     */
    fun onTrim(level: Int) {
        for (listener in trims) runCatching { listener(level) }
        when {
            level >= ComponentCallbacks2.TRIM_MEMORY_COMPLETE -> {
                gc()
                purgeMemory()
                forceCoreGc(full = true)
            }
            level >= ComponentCallbacks2.TRIM_MEMORY_MODERATE -> {
                gc()
                // Ordinary pressure: collect without the stop-the-world
                // FreeOSMemory pass. Complete/low-memory asks for the full trim.
                forceCoreGc(full = false)
            }
        }
    }

    /**
     * The Go runtime's heap is outside ART, so an ART trim cannot reach it. The
     * service engine owns the core's action bus; this is a no-op when no engine
     * is attached, and failures are swallowed because a memory-pressure hint
     * must never crash the process.
     */
    private fun forceCoreGc(full: Boolean) {
        runCatching { io.flrone.flutter.ServiceBridge.forceGc(full) }
    }

    /** Application.onLowMemory: the same complete trim, including the Go core. */
    fun onLowMemory() {
        gc()
        purgeMemory()
        forceCoreGc(full = true)
    }

    /** A soft hint: ART decides when it actually collects. */
    fun gc() {
        runCatching { Runtime.getRuntime().gc() }
    }

    /**
     * Releases the heap back to the OS. A no-op below SDK 28, mirroring the floor Bettbox sets before
     * it trims arenas; above it the trim runs through reflection so a future removal degrades to a
     * no-op instead of a crash.
     */
    fun purgeMemory() {
        if (Build.VERSION.SDK_INT < 28) return
        runCatching {
            val vmRuntime = Class.forName("dalvik.system.VMRuntime")
            val runtime = vmRuntime.getMethod("getRuntime").invoke(null)
            vmRuntime.getMethod("trimHeap").invoke(runtime)
        }
    }
}
