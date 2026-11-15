package io.flrone.bridge

import io.nekohasekai.sagernet.database.RouteManager
import io.nekohasekai.sagernet.database.RouteRepo
import io.nekohasekai.sagernet.route.OutboundIds
import io.nekohasekai.sagernet.route.RuleType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The method-channel action table (ADR 0002, phase 3b-2).
 *
 * `ThroneBoxBridge.onMethodCall` used to hold every data-plane handler inline as a 136-arm
 * `when`. This object keeps handlers in a registry keyed by the same dotted names, so the
 * bridge only forwards and the wire contract is one table instead of one giant expression.
 *
 * Returning [Unhandled] rather than throwing is deliberate: the bridge falls back to its own
 * arms for anything not registered, so a domain can move without touching the rest.
 *
 * ADR 0002 phase 3c moved the route DATA to the Go kernel (which is now its only writer), so
 * the profile and rule handlers are gone from here. What stays is what is not route data:
 *
 *  * `routes.presets` lists the bundled `Profile_<Country>` files — the snapshot CI ships in
 *    the assets plus whatever `RouteRepo.refresh` cached, which the kernel has no way to read;
 *  * `routes.ruleSets` searches the local rule-set catalog that `RouteManager` builds from the
 *    installed rule-set files.
 *
 * `routes.addPreset` is deliberately absent. Adding a preset writes route profiles, and the
 * kernel owns those documents; a Kotlin writer would be the second writer that
 * `RouteJsonStore` exists to prevent. The screen adds the entries it picked through
 * `saveRouteProfile` on the action bus instead.
 */
object BboxActions {

    /** Marker type: "this registry has no handler for that name". */
    object Unhandled

    private typealias Handler = suspend (Map<String, Any?>) -> Any?

    private val handlers = LinkedHashMap<String, Handler>()

    /** Registers [handler] under [method]; a duplicate replaces the earlier one. */
    fun register(method: String, handler: Handler) {
        handlers[method] = handler
    }

    /** The names this registry answers; used by the contract audit. */
    val methods: Set<String> get() = handlers.keys

    /** Runs [method] with [args], or [Unhandled] when nothing is registered for it. */
    suspend fun invoke(method: String, args: Map<String, Any?>): Any? =
        handlers[method]?.invoke(args) ?: Unhandled

    init {
        // The bundled profile snapshot, as `{bundles:[{country, entries:[{name,url}]}]}`.
        // Read-only: `RouteRepo.bundles()` parses the `Profile_<Country>` files out of the
        // assets (and the runtime cache a refresh wrote). Nothing is saved — the screen turns
        // a picked entry into a profile through `saveRouteProfile`, so the kernel stays the
        // only writer of the route documents.
        register("routes.presets") {
            withContext(Dispatchers.IO) {
                val bundles = try {
                    RouteRepo.bundles()
                } catch (e: Exception) {
                    error("Cannot read the bundled route profiles: ${e.message}")
                }
                mapOf(
                    "bundles" to bundles.map { bundle ->
                        mapOf(
                            "country" to bundle.country,
                            "entries" to bundle.entries.map { entry ->
                                mapOf("name" to entry.name, "url" to entry.url)
                            },
                        )
                    },
                )
            }
        }
        register("routes.ruleSets") { args ->
            val query = args.string("query").trim()
            val limit = requireLong(args["limit"]).toInt().let { if (it > 0) it else 100 }
            val catalog = withContext(Dispatchers.IO) { RouteManager.catalog() }
            mapOf(
                "total" to catalog.size,
                "entries" to catalog.search(query, limit).map { (name, url) ->
                    mapOf("name" to name, "url" to url)
                },
            )
        }
        // The route-profile list, for the Dart data plane's fallback path. The
        // kernel owns the route documents and answers `getRouteProfiles` over
        // the action bus; when the FFI driver is absent (or its Room read
        // fails) that path throws, and `RouteProfilesSource` needs this arm to
        // keep the screen alive. `RouteManager.all()` reads the same documents
        // through RouteJsonStore and seeds the default profile, so both
        // producers answer the identical wire shape.
        register("routes.list") {
            withContext(Dispatchers.IO) {
                val profiles = RouteManager.all()
                // `current()` applies the same fallback the native screen uses
                // (a missing or raw profile moves to the first usable one), so
                // the badge agrees with what the kernel will build.
                val currentId = runCatching { RouteManager.current().id }.getOrDefault(-1L)
                mapOf(
                    "currentId" to currentId,
                    "profiles" to profiles.map { profile ->
                        val rules = profile.rules
                        mapOf(
                            "id" to profile.id,
                            "name" to profile.name,
                            "defaultOutbound" to OutboundIds.toName(profile.default_outbound_id),
                            "current" to (profile.id == currentId),
                            "isRemote" to profile.is_remote,
                            "isRaw" to profile.is_raw,
                            "ruleCount" to rules.size,
                            // The three simple address types plus WARP, matching
                            // `isSimpleAddressType` on the kernel side.
                            "simpleRuleCount" to rules.count {
                                it.type == RuleType.SIMPLE_ADDRESS_PROXY.id ||
                                    it.type == RuleType.SIMPLE_ADDRESS_BYPASS.id ||
                                    it.type == RuleType.SIMPLE_ADDRESS_BLOCK.id ||
                                    it.type == RuleType.SIMPLE_ADDRESS_WARP_BYPASS.id
                            },
                        )
                    },
                )
            }
        }
    }
}

// --- argument coercion --------------------------------------------------------
//
// The channel hands numbers over as Int/Double/Long depending on the platform codec, so a
// plain `as Long` cast is the kind of bug that only shows on one device. Normalised once.

private fun requireLong(value: Any?): Long = when (value) {
    is Long -> value
    is Int -> value.toLong()
    is Number -> value.toLong()
    is String -> value.toLongOrNull() ?: -1L
    else -> -1L
}

private fun requireString(value: Any?): String = value?.toString().orEmpty()

private fun Map<String, Any?>.long(key: String): Long = requireLong(this[key])

private fun Map<String, Any?>.string(key: String): String = requireString(this[key])
