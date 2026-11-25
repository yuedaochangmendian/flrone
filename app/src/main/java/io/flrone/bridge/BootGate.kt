package io.flrone.bridge

import io.flrone.flutter.ServiceEngineManager
import org.json.JSONObject
import java.io.File

/**
 * The service engine's automatic-start gate (wave 4 of the FlClash alignment).
 *
 * `flutter/lib/service_entry.dart` auto-starts the tunnel 300 ms after a non-prewarm engine is
 * created. That is the app's only launch-time automatic start, so a tile, boot, widget or
 * always-on start that merely repeats the previous, dies-before-the-UI launch repeats the failure
 * too. Dart's boot guard already records the launch (`flutter/lib/services/boot_guard.dart`):
 * `evaluate()` writes `{stage: starting, startedAt, …}` before any automatic work and
 * `markRunning()` rewrites it as `running` once the first frame has painted. A marker still at
 * `starting` and fresh is the evidence that the previous launch died on its way up.
 *
 * The service side cannot read that record where it lives — the guard's store is the UI's
 * preferences document, and a tile/boot start holds no Flutter engine. So the UI mirrors the one
 * preference to `<filesDir>/documents/boot_guard.json` on every preferences write
 * (`FlronePlatformBridge.writePreferences`), and [shouldSkipAutoStart] reads that file — the same
 * `documents` directory the other cross-process documents live in.
 *
 * A gated start is deferred, not refused: the engine comes up idle ([ServiceEngineManager.ARG_PREWARM],
 * so its 300 ms auto-start never runs), the service and its notification stay stopped, and the
 * user starts the tunnel deliberately — a UI start carries no silent flag and is never gated.
 *
 * The automatic starts are the ones nobody tapped: the app's own quiet start (`quick`/`boot`, which
 * carries those args) and the platform's always-on VPN start, which carries no engine args at all
 * and is recognised by its intent action instead ([isPlatformAlwaysOnStart]).
 *
 * One deliberate imprecision: while a live UI is between `evaluate()` and `markRunning()`, its own
 * marker also reads as `starting`, so a tile tap in those first frames is deferred as well. That
 * is the conservative direction (nothing starts that the user did not just ask the UI for), and
 * the freshness window keeps it to the launch itself.
 *
 * Pure JVM (only `org.json` and `java.io`): `BootGateTest` drives it with a temp file.
 */
object BootGate {

    /** The mirrored marker inside the documents directory (not a kernel-owned document). */
    const val MARKER_NAME = "boot_guard.json"

    /**
     * The preference that carries the record: Dart's `BootGuard.preferenceKey`
     * (`flutter/lib/services/boot_guard.dart`). Keep the two literals identical.
     */
    const val PREFERENCE_KEY = "bootGuardRecord"

    /**
     * The freshness window: Dart's `BootGuard.freshness` (`Duration(minutes: 10)`), the one place
     * in each language. A marker older than this is not evidence — the OS may have killed the
     * process long after it started.
     */
    const val FRESHNESS_MS = 10 * 60_000L

    /** The marker's [BootStage.starting] name, as encoded by the Dart side. */
    private const val STAGE_STARTING = "starting"

    /**
     * The marker a deliberate restart writes (`BootStage.restarting`): the launch did not die,
     * it was replaced on purpose. The automatic start is gated exactly like an interrupted
     * launch (the tunnel may still be running, so the sticky service can come back), but the
     * Dart boot guard does not treat it as a failed launch.
     */
    private const val STAGE_RESTARTING = "restarting"

    /**
     * `android.net.VpnService.SERVICE_INTERFACE`, spelled out so this object stays pure JVM (the
     * constant is a compile-time literal in `android.jar`; referencing the class would drag the
     * platform stub into a unit test).
     */
    const val PLATFORM_START_ACTION = "android.net.VpnService"

    /**
     * True when the platform started the service as an always-on VPN rather than the app starting
     * it for the user.
     *
     * Android starts an always-on VpnService with `Intent(VpnConfig.SERVICE_INTERFACE)` — the action
     * [PLATFORM_START_ACTION] and no extras (`Vpn.startAlwaysOnVpn()` in the platform's
     * connectivity service). Every start the app issues is an explicit intent pinned to the service
     * class with **no** action (`SagerNet.startChosenService`), so the action discriminates cleanly:
     * a null intent (a START_STICKY restart), a tile/boot/widget start and the user's own start all
     * answer false. The same action is how the platform *binds* the service (`VpnService.onBind`),
     * which is the existing confirmation that this is the platform's channel.
     */
    fun isPlatformAlwaysOnStart(action: String?): Boolean = action == PLATFORM_START_ACTION

    /** The marker file for an application's `filesDir`. */
    fun mirrorFile(filesDir: File): File = File(File(filesDir, "documents"), MARKER_NAME)

    /**
     * True when an automatic start must be held back: the marker says the previous launch was
     * still `starting` and is fresh enough to blame on it.
     *
     * `false` is the answer for every other shape of the world — no file, an unreadable or
     * malformed one, a stage that is not a string (or not `starting`), a `startedAt` that is not a
     * positive number, and an age outside `[0, freshnessMs]` (a marker dated in the future is a
     * clock change, not a launch). A wrong guess in that direction costs one repeated start; a
     * wrong guess the other way costs an app that cannot start by itself at all.
     */
    fun shouldSkipAutoStart(marker: File, now: Long, freshnessMs: Long = FRESHNESS_MS): Boolean {
        if (!marker.isFile) return false
        val raw = runCatching { marker.readText() }.getOrNull() ?: return false
        val record = runCatching { JSONObject(raw) }.getOrNull() ?: return false
        val stage = record.opt("stage") as? String ?: return false
        // `restarting` is a deliberate relaunch: the sticky service must not race the new UI
        // either, so it is gated exactly like an unfinished launch.
        if (stage != STAGE_STARTING && stage != STAGE_RESTARTING) return false
        val startedAt = (record.opt("startedAt") as? Number)?.toLong() ?: return false
        if (startedAt <= 0L) return false
        val age = now - startedAt
        return age in 0..freshnessMs
    }

    /**
     * Mirrors the preference value into [marker]. A [String] is written verbatim (Dart encodes the
     * record once); anything else — including the key being absent, which arrives as null — deletes
     * the file, because a mirror that disagrees with the record must never outlive the write.
     *
     * Atomic and best-effort, the discipline the other documents use (temp + rename, with a direct
     * write when the rename fails): the service may read the file at any moment, and a half-written
     * record must not look like evidence. Answers whether the file is now in the intended state.
     */
    fun mirror(marker: File, value: Any?): Boolean {
        if (value !is String) {
            return runCatching { !marker.exists() || marker.delete() }.getOrDefault(false)
        }
        val directory = marker.parentFile ?: return false
        if (!directory.isDirectory && !directory.mkdirs()) return false
        val temp = File(directory, "${marker.name}.${System.nanoTime()}.tmp")
        return try {
            temp.writeText(value)
            if (!temp.renameTo(marker)) marker.writeText(value)
            true
        } catch (_: Exception) {
            false
        } finally {
            temp.delete()
        }
    }

    /**
     * The engine args for a start: a [blocked] start the user did not ask for gains
     * [ServiceEngineManager.ARG_PREWARM], so the fresh engine's 300 ms auto-start does not run.
     *
     * [silent] names the automatic starts that carry no flag of their own — the platform's
     * always-on VPN start ([isPlatformAlwaysOnStart]); the app's quick/boot starts are recognised
     * by their args. Everything else is returned unchanged: a deliberate start carries neither a
     * flag nor [silent], and args that are already a prewarm are left alone.
     */
    fun gateEngineArgs(args: List<String>, blocked: Boolean, silent: Boolean): List<String> {
        if (!blocked) return args
        if (ServiceEngineManager.ARG_PREWARM in args) return args
        val automatic = silent ||
            ServiceEngineManager.ARG_QUICK in args ||
            ServiceEngineManager.ARG_BOOT in args
        return if (automatic) args + ServiceEngineManager.ARG_PREWARM else args
    }
}
