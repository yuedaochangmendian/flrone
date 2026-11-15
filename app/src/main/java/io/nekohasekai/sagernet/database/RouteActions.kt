package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.ktx.runOnDefaultDispatcher
import io.nekohasekai.sagernet.outbound.json.JsonArray
import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.outbound.json.JsonObject
import io.nekohasekai.sagernet.route.OutboundIds
import io.nekohasekai.sagernet.route.RouteProfile
import io.nekohasekai.sagernet.route.RouteRule
import io.nekohasekai.sagernet.route.RuleType
import io.throneproj.mobile.Mobile
import java.io.File

/**
 * The Kotlin face of the kernel's route action bus (ADR 0002, phase 3c).
 *
 * The route documents are kernel-owned: `RouteJsonStore` is read-only on this side and
 * `RouteManager.save` throws once those documents exist, which is the state of every install
 * that has ever opened the routing screen. Two writers here do not go through the UI —
 * [io.nekohasekai.sagernet.group.RemoteRouteUpdater] (a remote profile's periodic refresh) and
 * [io.nekohasekai.sagernet.group.SubscriptionRoute] (a subscription's `routing` header) — and
 * both must still be able to save.
 *
 * `Mobile.runAction` is the synchronous twin of `throne_invoke_action`: same registry, same
 * `ActionResult` JSON, but the answer comes back on the calling thread instead of a Dart
 * message port. That is what makes it callable from a coroutine worker that has no port to
 * reply to.
 *
 * Errors are thrown, never swallowed: a failed save must not leave the caller believing the
 * profile was written.
 *
 * The route documents are not the only state a selection moves. `settings.current_route_id`
 * lives in Room's `settings` table, whose only writer is this process (see [setCurrent] and
 * `settings_codec.go`); the kernel never opens its own connection against it.
 */
object RouteActions {

    /** Set once so the startup repair runs at most once per process, however many callers ask for it. */
    private val repairStarted = java.util.concurrent.atomic.AtomicBoolean(false)

    /** The kernel's document directory, `<filesDir>/documents` (route_store.go documentsDirName). */
    private const val DOCUMENTS_DIR = "documents"

    /**
     * One profile as `saveRouteProfile` takes it, so the caller's model survives the trip.
     *
     * The row goes in two writes because the save handler's `rules` field is the simple-address
     * TEXT (a `*string` on the Go side, folded by prefix+outbound), not the editor's rule
     * object list: sending the array there fails to unmarshal before anything is written, which
     * is why an auto-update or subscription refresh silently changed nothing. So the profile
     * row is saved first, then its rules are replaced through `saveRouteRules` — the same pair
     * the routing screen performs, and the only path that writes the `*_json` columns a rule's
     * conditions live in.
     */
    fun save(p: RouteProfile): Long {
        val payload = JsonObject().apply {
            this["id"] = p.id
            this["name"] = p.name
            // Absent (`null`) means "leave untouched" to the Go handler; every field here is
            // the model's own current value, so a remote update writes the whole row it built.
            this["defaultOutbound"] = OutboundIds.toName(p.default_outbound_id)
            this["isRemote"] = p.is_remote
            this["remoteUrl"] = p.remote_url
            this["autoUpdate"] = p.auto_update
            this["endpointIds"] = JsonArray().also { array ->
                for (id in RouteProfileEntity.parseIdJson(p.endpoint_profile_ids)) array.add(id)
            }
            // The subscription binding and the refresh stamp. Both are columns of the row, not
            // editor fields: a create through this path has no earlier row to inherit them from,
            // and a lost `source_gid` would detach the subscription from its profile.
            this["sourceGid"] = p.source_gid
            this["remoteLastUpdate"] = p.remote_last_update
        }
        val answer = invoke("saveRouteProfile", payload)
        val id = (answer["data"] as? Number)?.toLong()
            ?: error("saveRouteProfile answered no profile id")
        p.id = id
        // The rules are a separate write; a failure here throws, because a profile saved without
        // them is exactly the lost update this path exists to prevent.
        invoke("saveRouteRules", JsonObject().apply {
            this["id"] = id
            this["rules"] = rulesToWire(p.rules)
        })
        return id
    }

    /**
     * Marks [id] as the profile the core builds.
     *
     * A selection moves two stores, and the host writes them in this order:
     *
     *  1. `DataStore.currentRouteId` — the `settings.current_route_id` row the config build,
     *     `RouteManager.current()` and the profile screen's rule count read. Room is that
     *     table's only writer, so the row is written here, on the host's own connection.
     *  2. the route document's `__current` marker, through the kernel's `setCurrentRoute`.
     *
     * The direction is the fix for SQLite error 522. This row used to be written by the kernel
     * over the vendored SQLite amalgamation, one open/close per call; closing that connection
     * can checkpoint and truncate the shared `-wal` file while the framework connection is
     * mid-read, which is how VpnService's start died with `SQLITE_IOERR_SHORT_READ` (522) in
     * `SettingsStore.getBoolean` right after a route card was tapped. Go must never open a
     * connection against a table the host owns (see `route_actions.go`), so this is the only
     * writer of the settings row and the kernel only maintains the marker.
     *
     * A kernel failure still throws, so the caller reports it; the host row remains the
     * authority either way, and `RouteManager.current()` repairs a marker that disagrees.
     */
    fun setCurrent(id: Long) {
        DataStore.currentRouteId = id
        invoke("setCurrentRoute", JsonObject().apply { this["id"] = id })
    }

    /**
     * Runs the kernel's one-time route-document repair, once per process, off the main thread.
     *
     * The repair lives in the kernel's read path (`readRouteState(true)` in `route_actions.go`): the old seed
     * wrote `default_outbound_id = direct`, which makes `route.final` "direct" and sends every unmatched
     * connection out unproxied. Only a read that goes *through* the kernel runs it, and the kernel's writers are
     * the routing-screen actions — but `ConfigGenerator` builds from `RouteManager.current()` /
     * `RouteJsonStore.allProfiles()`, reading the documents directly and never entering Go. So an upgraded
     * install would keep the direct default until the user opened the routing screen, which is after the first
     * config build and possibly never.
     *
     * `getRouteProfiles` is the read with `seed = true`, so calling it here runs the migration before any build.
     * It is idempotent (the handler only rewrites the untouched seed row, and only when it still says direct), so
     * a launch that finds nothing to do costs two small file reads.
     *
     * Calling it is gated on `route_profiles.json` already being there, which is the same marker
     * `RoomToJsonMigration.seed` uses. Without that gate a fresh install would have the kernel create the documents
     * from its own seed first, and the Room → JSON export — the one thing that copies an existing install's route
     * tables — would then see its marker and never run. A fresh install has nothing to repair anyway: its documents
     * are created by whichever side writes first, and the kernel's seed is the fixed one.
     *
     * Called from `SagerNet.onCreate` on the default dispatcher: `Mobile.runAction` is synchronous JNI and holds
     * `routeStoreMu` in the kernel, which must not happen on the main thread. Failures are swallowed — a repair
     * that cannot run must never block startup, and the next routing-screen read retries it.
     */
    fun repairDefaultProfile() {
        if (!repairStarted.compareAndSet(false, true)) return
        runOnDefaultDispatcher {
            val dir = File(app.filesDir, DOCUMENTS_DIR)
            if (!File(dir, "route_profiles.json").isFile) return@runOnDefaultDispatcher
            runCatching { invoke("getRouteProfiles", JsonObject()) }
                .onFailure { Logs.w("routes: default-profile repair failed: ${it.message}") }
        }
    }

    // Deletion is the one route write with no host twin: Dart sends `deleteRouteProfile`
    // straight to the kernel, so the handler moves the document marker and nothing here runs.
    // The `settings.current_route_id` row is then corrected by the host's own read path,
    // exactly as RouteManager.current documents — a row naming a profile that no longer exists
    // falls back to the first usable one and writes the row back through Room. That is the
    // same rule the Go handler applies to the marker, so the two agree again on the next read.
    // No Kotlin delete hook is invented here, and Go still never writes the row.

    /**
     * Runs one action and unwraps its `ActionResult`.
     *
     * The Go side encodes `{id, method, data, code}`; a non-zero `code` carries the handler's
     * error message in `data`. Both are surfaced as an [IllegalStateException] so a caller's
     * existing `catch (e: Exception)` (the update paths already have one) reports a readable
     * message instead of a silent no-op.
     */
    private fun invoke(method: String, payload: JsonObject): JsonObject {
        val request = JsonObject().apply {
            this["id"] = "kotlin:$method"
            this["method"] = method
            this["data"] = payload
        }
        val answer = JsonInput.parseObjectOrNull(Mobile.runAction(request.toCompact()))
            ?: error("$method answered no result")
        val code = answer.integer("code")
        if (code != 0L) {
            error(answer.string("data").ifEmpty { "$method failed with code $code" })
        }
        return answer
    }

    /**
     * The editor's rule maps, mirroring `BboxRoutes.ruleToMap` (the shape the Go
     * `ruleRowFromWire` reads): the type as its token, the outbound as a number and the column
     * groups by name, so every condition the editor can hold round-trips.
     *
     * Lists go out under their column name (`rule_set_json`), which is the spelling every
     * reader of the store uses — `RouteJsonStore` and the config generator read only those.
     * The kernel also normalises a short name now, but writing the column directly keeps this
     * path correct against an older AAR too.
     */
    private fun rulesToWire(rules: List<RouteRule>): JsonArray = JsonArray().also { out ->
        for (rule in rules) {
            val map = JsonObject()
            map["name"] = rule.name
            map["type"] = RuleType.values().firstOrNull { it.id == rule.type }?.token
                ?: RuleType.CUSTOM.token
            map["disabled"] = rule.disabled
            map["action"] = rule.action
            map["outbound_id"] = rule.outbound_id
            for (field in RouteRule.STRING_FIELDS) map[field.name] = field.get(rule)
            for (field in RouteRule.LIST_FIELDS) {
                map["${field.name}_json"] = JsonArray().also { list -> for (value in field.get(rule)) list.add(value) }
            }
            for (field in RouteRule.BOOL_FIELDS) map[field.name] = field.get(rule)
            out.add(map)
        }
    }
}
