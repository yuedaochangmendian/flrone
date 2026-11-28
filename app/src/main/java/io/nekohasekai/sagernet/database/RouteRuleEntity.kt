package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.document.json.JsonArray
import io.nekohasekai.sagernet.document.json.JsonInput
import io.nekohasekai.sagernet.document.json.JsonValues
import io.nekohasekai.sagernet.route.RouteRule

/**
 * The columns of one global route rule (`global_route_rules.json`), plus Android-only extras.
 * List members are compact JSON string arrays in the `<member>_json` columns. Value equality is
 * field-wise so reorders read as changes.
 */
open class RouteRuleColumns() {
    var ruleOrder: Int = 0
    var name: String = ""
    var type: Int = 0
    var ipVersion: String = ""
    var network: String = ""
    var protocol: String = ""
    var inboundJson: String = "[]"
    var domainJson: String = "[]"
    var domainSuffixJson: String = "[]"
    var domainKeywordJson: String = "[]"
    var domainRegexJson: String = "[]"
    var sourceIpCidrJson: String = "[]"
    var sourceIpIsPrivate: Boolean = false
    var ipCidrJson: String = "[]"
    var ipIsPrivate: Boolean = false
    var sourcePortJson: String = "[]"
    var sourcePortRangeJson: String = "[]"
    var portJson: String = "[]"
    var portRangeJson: String = "[]"
    var processNameJson: String = "[]"
    var processPathJson: String = "[]"
    var processPathRegexJson: String = "[]"
    var packageNameJson: String = "[]"
    var ruleSetJson: String = "[]"
    var invert: Boolean = false
    var outboundId: Long = -2L
    var action: String = "route"
    var rejectMethod: String = ""
    var noDrop: Boolean = false
    var overrideAddress: String = ""
    var overridePort: String = ""
    var sniffersJson: String = "[]"
    var sniffOverrideDest: Boolean = false
    var strategy: String = ""
    var wifiSsidJson: String = "[]"
    var wifiBssidJson: String = "[]"
    var tlsSpoof: String = ""
    var tlsSpoofMethod: String = ""
    var networkTypeJson: String = "[]"
    var networkIsExpensive: Boolean = false
    var packageNameRegexJson: String = "[]"
    var tlsFragment: Boolean = false
    var tlsFragmentFallbackDelay: String = ""
    var tlsRecordFragment: Boolean = false
    var disabled: Boolean = false

    fun toModel(): RouteRule = RouteRule().also {
        it.name = name
        it.type = type
        it.ip_version = ipVersion
        it.network = network
        it.protocol = protocol
        it.inbound = listFromJson(inboundJson)
        it.domain = listFromJson(domainJson)
        it.domain_suffix = listFromJson(domainSuffixJson)
        it.domain_keyword = listFromJson(domainKeywordJson)
        it.domain_regex = listFromJson(domainRegexJson)
        it.source_ip_cidr = listFromJson(sourceIpCidrJson)
        it.source_ip_is_private = sourceIpIsPrivate
        it.ip_cidr = listFromJson(ipCidrJson)
        it.ip_is_private = ipIsPrivate
        it.source_port = listFromJson(sourcePortJson)
        it.source_port_range = listFromJson(sourcePortRangeJson)
        it.port = listFromJson(portJson)
        it.port_range = listFromJson(portRangeJson)
        it.process_name = listFromJson(processNameJson)
        it.process_path = listFromJson(processPathJson)
        it.process_path_regex = listFromJson(processPathRegexJson)
        it.package_name = listFromJson(packageNameJson)
        it.rule_set = listFromJson(ruleSetJson)
        it.invert = invert
        it.outbound_id = outboundId
        it.action = action
        it.reject_method = rejectMethod
        it.no_drop = noDrop
        it.override_address = overrideAddress
        it.override_port = overridePort
        it.sniffers = listFromJson(sniffersJson)
        it.sniff_override_dest = sniffOverrideDest
        it.strategy = strategy
        it.wifi_ssid = listFromJson(wifiSsidJson)
        it.wifi_bssid = listFromJson(wifiBssidJson)
        it.tls_spoof = tlsSpoof
        it.tls_spoof_method = tlsSpoofMethod
        it.network_type = listFromJson(networkTypeJson)
        it.network_is_expensive = networkIsExpensive
        it.package_name_regex = listFromJson(packageNameRegexJson)
        it.tls_fragment = tlsFragment
        it.tls_fragment_fallback_delay = tlsFragmentFallbackDelay
        it.tls_record_fragment = tlsRecordFragment
        it.disabled = disabled
    }

    /** Overwrites the shared columns from [r]; the keys (profile id, order, own id) stay the caller's. */
    fun fillFrom(r: RouteRule) {
        name = r.name
        type = r.type
        ipVersion = r.ip_version
        network = r.network
        protocol = r.protocol
        inboundJson = listToJson(r.inbound)
        domainJson = listToJson(r.domain)
        domainSuffixJson = listToJson(r.domain_suffix)
        domainKeywordJson = listToJson(r.domain_keyword)
        domainRegexJson = listToJson(r.domain_regex)
        sourceIpCidrJson = listToJson(r.source_ip_cidr)
        sourceIpIsPrivate = r.source_ip_is_private
        ipCidrJson = listToJson(r.ip_cidr)
        ipIsPrivate = r.ip_is_private
        sourcePortJson = listToJson(r.source_port)
        sourcePortRangeJson = listToJson(r.source_port_range)
        portJson = listToJson(r.port)
        portRangeJson = listToJson(r.port_range)
        processNameJson = listToJson(r.process_name)
        processPathJson = listToJson(r.process_path)
        processPathRegexJson = listToJson(r.process_path_regex)
        packageNameJson = listToJson(r.package_name)
        ruleSetJson = listToJson(r.rule_set)
        invert = r.invert
        outboundId = r.outbound_id
        action = r.action
        rejectMethod = r.reject_method
        noDrop = r.no_drop
        overrideAddress = r.override_address
        overridePort = r.override_port
        sniffersJson = listToJson(r.sniffers)
        sniffOverrideDest = r.sniff_override_dest
        strategy = r.strategy
        wifiSsidJson = listToJson(r.wifi_ssid)
        wifiBssidJson = listToJson(r.wifi_bssid)
        tlsSpoof = r.tls_spoof
        tlsSpoofMethod = r.tls_spoof_method
        networkTypeJson = listToJson(r.network_type)
        networkIsExpensive = r.network_is_expensive
        packageNameRegexJson = listToJson(r.package_name_regex)
        tlsFragment = r.tls_fragment
        tlsFragmentFallbackDelay = r.tls_fragment_fallback_delay
        tlsRecordFragment = r.tls_record_fragment
        disabled = r.disabled
    }

    /** Every stored value in field order, for the field-wise [equals]. */
    private fun fingerprint(): List<Any?> = listOf(
        ruleOrder, name, type, ipVersion, network, protocol,
        inboundJson, domainJson, domainSuffixJson, domainKeywordJson, domainRegexJson,
        sourceIpCidrJson, sourceIpIsPrivate, ipCidrJson, ipIsPrivate,
        sourcePortJson, sourcePortRangeJson, portJson, portRangeJson,
        processNameJson, processPathJson, processPathRegexJson, packageNameJson, ruleSetJson,
        invert, outboundId, action, rejectMethod, noDrop, overrideAddress, overridePort,
        sniffersJson, sniffOverrideDest, strategy, wifiSsidJson, wifiBssidJson,
        tlsSpoof, tlsSpoofMethod, networkTypeJson, networkIsExpensive, packageNameRegexJson,
        tlsFragment, tlsFragmentFallbackDelay, tlsRecordFragment, disabled,
    )

    override fun equals(other: Any?) = other is RouteRuleColumns && other.fingerprint() == fingerprint()

    override fun hashCode() = fingerprint().hashCode()

    companion object {
        /** QListStr2QJsonArray (Utils.cpp:110-118) written compact. */
        fun listToJson(list: List<String>): String = JsonValues.stringArray(list).toCompact()

        /** A stored list column; anything that is not a JSON array reads as empty (RoutesRepo.cpp:426-429). */
        fun listFromJson(text: String?): MutableList<String> {
            if (text.isNullOrBlank()) return ArrayList()
            val arr = JsonInput.parseValue(text) as? JsonArray ?: return ArrayList()
            return arr.strings().filterTo(ArrayList()) { it.isNotBlank() }
        }
    }
}

/**
 * One rule of the single global rule table. [ruleId] is the id the kernel writes as `id`.
 */
class GlobalRouteRuleEntity() : RouteRuleColumns() {
    var ruleId: Long = 0L

    companion object {
        const val TABLE = "global_route_rules"

        fun of(order: Int, r: RouteRule) = GlobalRouteRuleEntity().also {
            it.ruleOrder = order
            it.fillFrom(r)
        }
    }
}
