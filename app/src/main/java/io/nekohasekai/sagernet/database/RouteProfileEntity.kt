package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.route.RouteDns
import io.nekohasekai.sagernet.route.RouteProfile
import io.nekohasekai.sagernet.route.RouteRule

/**
 * The desktop's `route_profiles` row (RoutesRepo.cpp:14-49). The raw and endpoint columns only carry desktop data
 * through restores and backups; Android never builds from them.
 */
data class RouteProfileEntity(
    var id: Long = 0L,
    var name: String = "",
    var defaultOutboundId: Long = -1L,
    var isRemote: Boolean = false,
    var remoteUrl: String = "",
    var autoUpdate: Boolean = false,
    var remoteLastUpdate: Long = 0L,
    var isRaw: Boolean = false,
    var rawRoute: String = "",
    var preventModifications: Boolean = false,
    /** Compact JSON int array. */
    var endpointProfileIds: String = "[]",
    var innerHopEndpointIds: String = "[]",
    /** The profile's RouteDns as Qt-compact JSON, '' when it has none. */
    var dnsJson: String = "",
    var customDns: Boolean = false,
    /** The subscription group whose refreshes overwrite this profile's rules, -1 = none (RoutesRepo.cpp). */
    var sourceGid: Long = -1L,
    /** Compact JSON int array: the global-pool rule ids this profile keeps off (FlClash's per-profile disables). */
    var disabledGlobalRuleJson: String = "[]",
) {

    /** custom_dns only counts when dns_json holds an object (RoutesRepo.cpp routeProfileFromJson). */
    fun toModel(rules: List<RouteRuleEntity>): RouteProfile = RouteProfile().also {
        it.id = id
        it.name = name
        it.default_outbound_id = defaultOutboundId
        it.is_remote = isRemote
        it.remote_url = remoteUrl
        it.auto_update = autoUpdate
        it.remote_last_update = remoteLastUpdate
        it.is_raw = isRaw
        it.raw_route = rawRoute
        it.prevent_modifications = preventModifications
        it.endpoint_profile_ids = endpointProfileIds
        it.inner_hop_endpoint_ids = innerHopEndpointIds
        it.dns = dnsFromJson(dnsJson)
        it.custom_dns = customDns && it.dns != null
        it.source_gid = sourceGid
        it.disabled_global_rules = ArrayList(parseIdJson(disabledGlobalRuleJson))
        it.rules = rules.sortedBy { r -> r.ruleOrder }.mapTo(ArrayList<RouteRule>()) { r -> r.toModel() }
    }

    companion object {
        const val TABLE = "route_profiles"

        fun of(p: RouteProfile) = RouteProfileEntity(
            id = p.id,
            name = p.name,
            defaultOutboundId = p.default_outbound_id,
            isRemote = p.is_remote,
            remoteUrl = p.remote_url,
            autoUpdate = p.auto_update,
            remoteLastUpdate = p.remote_last_update,
            isRaw = p.is_raw,
            rawRoute = p.raw_route,
            preventModifications = p.prevent_modifications,
            endpointProfileIds = p.endpoint_profile_ids,
            innerHopEndpointIds = p.inner_hop_endpoint_ids,
            dnsJson = p.dns?.toJson()?.toCompact() ?: "",
            customDns = p.custom_dns,
            sourceGid = p.source_gid,
            disabledGlobalRuleJson = p.disabled_global_rules.joinToString(",", "[", "]") { it.toString() },
        )

        /** A stored compact JSON int array ([RouteManager.ID_RE] shape); anything else reads as empty. */
        fun parseIdJson(text: String?): List<Long> {
            val ids = ID_RE.findAll(text ?: "").mapNotNull { it.value.toLongOrNull() }
            return ids.toList()
        }

        private val ID_RE = Regex("-?\\d+")

        /** A stored dns_json; anything but a JSON object reads as no DNS. */
        fun dnsFromJson(text: String?): RouteDns? {
            if (text.isNullOrBlank()) return null
            return JsonInput.parseObjectOrNull(text)?.let(RouteDns::fromJson)
        }
    }
}
