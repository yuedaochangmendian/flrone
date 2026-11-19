package io.flrone.bridge

import io.nekohasekai.sagernet.database.RouteRepo
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
 * the profile and rule handlers are gone from here. ADR 0005 phase 3 removed the last two
 * channel reads:
 *
 *  * `routes.list` was the Dart data plane's fallback for the kernel's `getRouteProfiles`. It
 *    read a stale Room snapshot once the kernel owned the documents; the kernel is now the
 *    single authority and the fallback is gone.
 *  * `routes.ruleSets` searched the local rule-set catalog. That is a file fact —
 *    `<filesDir>/routeprofiles/srslist.h` — which Dart now parses directly through the
 *    `data.path` directory fact. No channel round-trip and no second reader needed.
 *
 * What stays is what is not route data: `routes.presets` lists the bundled `Profile_<Country>`
 * files — the snapshot CI ships in the assets plus whatever `RouteRepo.refresh` cached, which
 * the kernel has no way to read.
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
    }
}
