package io.flrone.bridge

import io.nekohasekai.sagernet.database.DataStore

/**
 * B-box's "Outbound mode" switch. Throne has no `route.final` toggle of its own:
 * the route profile's default outbound and its rule list decide where traffic
 * goes. The stored mode is read by the Go config builder
 * (`config_build_rules.go`, `configBuildRouteProfile`), which applies the same
 * rewrite Kotlin used to perform before the cutover:
 *
 * - [Mode.Rule] uses the route profile exactly as the user saved it.
 * - [Mode.Global] drops the profile's rules and sends everything to the started profile (`proxy`).
 * - [Mode.Direct] drops the profile's rules and sends everything to `direct`.
 *
 * The DNS hijack rule survives every mode: without it the core's own DNS
 * requests would leave unhandled and the tunnel would come up without name
 * resolution.
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
}
