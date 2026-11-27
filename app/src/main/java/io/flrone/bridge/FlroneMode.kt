package io.flrone.bridge

import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.outbound.config.RoutingInput
import io.nekohasekai.sagernet.route.OutboundIds

/**
 * B-box's "Outbound mode" switch, backed by Throne's routing profile instead of sing-box's per-box mode.
 *
 * Throne has no `route.final` toggle of its own: the route profile's default outbound and its rule list decide where
 * traffic goes. The three modes B-box shows map onto that model without touching stored user data:
 *
 * - [Mode.Rule] uses the route profile exactly as the user saved it.
 * - [Mode.Global] drops the profile's rules and sends everything to the started profile (`proxy`).
 * - [Mode.Direct] drops the profile's rules and sends everything to `direct`.
 *
 * The DNS hijack rule survives every mode: without it the core's own DNS requests would leave unhandled and the
 * tunnel would come up without name resolution.
 */
object FlroneMode {

    enum class Mode(val id: String) {
        Rule("rule"),
        Global("global"),
        Direct("direct");

        companion object {
            fun of(id: String?): Mode = entries.firstOrNull { it.id.equals(id, ignoreCase = true) } ?: Rule
        }
    }

    private const val KEY = "bbox_outbound_mode"

    /** Every mode the switch offers, in the order B-box draws them. */
    val modes: List<String> get() = Mode.entries.map { it.id }

    fun get(): Mode = Mode.of(DataStore.configurationStore.getString(KEY))

    /** Stores the mode; the caller reloads the core so the new routing takes effect. */
    fun set(mode: Mode) {
        DataStore.configurationStore.putString(KEY, mode.id)
    }

    /**
     * Rewrites [input]'s route profile for the stored mode. Rule mode returns the input untouched, so the common path
     * allocates nothing.
     */
    fun applyTo(input: RoutingInput): RoutingInput = rewrite(input, get())

    /**
     * The mode rewrite without the settings read, so the config golden oracle can pin Global/Direct against the Go
     * builder. Rule mode returns [input] untouched.
     */
    internal fun rewrite(input: RoutingInput, mode: Mode): RoutingInput {
        if (mode == Mode.Rule) return input
        val profile = input.profile ?: return input
        val routed = profile.copy().apply {
            default_outbound_id = if (mode == Mode.Global) OutboundIds.PROXY else OutboundIds.DIRECT
            rules = profile.rules.filter { it.action == "hijack-dns" }.mapTo(ArrayList()) { it.copy() }
        }
        // The global table's rules are already attached to `profile`, so dropping everything but
        // the DNS hijack here is enough: the build copies this profile as-is and applies no pool
        // of its own. Global/Direct therefore send all traffic to one outbound, as the switch says.
        return RoutingInput(routed, input.catalog, input.selectors, input.memberCheck)
    }
}
