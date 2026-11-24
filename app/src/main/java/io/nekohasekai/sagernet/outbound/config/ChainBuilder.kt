package io.nekohasekai.sagernet.outbound.config

import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.Outbound
import io.nekohasekai.sagernet.outbound.json.jsonObjectOf

/** ChainBuildRequest (generate.cpp:1413-1428). */
internal class ChainRequest(
    /** Exit first: index 0 is the hop whose address the traffic leaves from (unwrapChain, :1296-1308). */
    val hopIds: List<Long>,
    val prefix: String,
    val includeProxy: Boolean = false,
    val link: Boolean = true,
    val startSuffix: Int = 0,
    /** Hop 0 is the WARP hop: it becomes `proxy` dialing through hop 1, which becomes `warp-bypass`. */
    val warpWrap: Boolean = false,
    val origin: HopOrigin = HopOrigin.NONE,
)

/** A group whose landing / front proxy a chain carries, by name. */
internal class ChainGroup(val name: String, val landingProxyId: Long, val frontProxyId: Long)

/**
 * Where the hop ids of a chain come from, for missingHopError (generate.cpp): the profile being built (the desktop's
 * BuildContext::ent) and the groups whose landing / front proxy the chain carries.
 */
internal class HopOrigin(val profile: Outbound? = null, val groups: List<ChainGroup> = emptyList()) {
    companion object {
        val NONE = HopOrigin()
    }
}

/** hopChainOptions (generate.cpp:1310-1319) without the auxiliary-endpoint members. */
internal class HopChainOptions(
    val prefix: String,
    val includeProxy: Boolean = false,
    val link: Boolean = true,
    val startSuffix: Int = 0,
    val warpWrap: Boolean = false,
)

/** chainScan (generate.cpp:1204-1213) as far as a sing-box-only chain needs it. */
private class ChainScan {
    var hopCount = 0
    var extraCoreCount = 0
    var extraCoreIdx = -1
    var hasCustomFullConfig = false
}

/**
 * The hop-list machinery of generate.cpp:1204-1600: the scan, the chain builder and the built-in WARP hop
 * ([warp], resolved for [WarpHop.PROFILE_ID]). A chain is a plain ordered list of sing-box outbounds linked with
 * `detour`. Auxiliary VPN endpoints are not generated on Android.
 */
internal class ChainBuilder(
    private val profiles: ProfileProvider,
    private val ctx: BuildContext,
    private val state: BuildState,
    private val warp: Outbound? = null,
) {

    /** unwrapChain (:1296-1308): the hop ids exit first, i.e. the stored in -> out list reversed. */
    fun unwrapChain(id: Long): List<Long> {
        val outbound = profiles.get(id) ?: return emptyList()
        if (outbound.type == "chain") return TypeAccess.chainHops(outbound).asReversed()
        return listOf(id)
    }

    // chainScanError (:1215-1235)
    private fun chainScanError(scan: ChainScan): String {
        if (scan.hasCustomFullConfig)
            return "Custom full config profiles cannot be used in a chain; only custom outbound profiles are chainable"
        if (scan.extraCoreCount > 1)
            return "Only one extra-core profile is allowed in a chain"
        // The last hop is the entry side: an extra core's socks server must be dialed directly, nothing runs after it.
        if (scan.extraCoreCount == 1 && scan.hopCount > 1 && scan.extraCoreIdx != scan.hopCount - 1)
            return "Extra-core profiles can only be the final hop in a chain (top of the chain editor)"
        return ""
    }

    // missingHopError: names the setting that still points at a deleted profile, so the user knows what to amend.
    private fun missingHopError(id: Long, origin: HopOrigin): String {
        val profile = origin.profile
        if (profile != null && profile.type == "chain" && id in TypeAccess.chainHops(profile)) {
            return "Chain \"${profile.name}\" has a hop (profile id $id) that no longer exists, edit the chain to remove it"
        }
        for (group in origin.groups) {
            if (group.frontProxyId == id) return "Group \"${group.name}\" has a front proxy that has been deleted."
            if (group.landingProxyId == id) return "Group \"${group.name}\" has a landing proxy that has been deleted."
        }
        return "A proxy in the chain can no longer be found."
    }

    /** entIDListtoEntList (:1237-1294): resolves the hops exit first, then checks what a chain cannot carry. */
    private fun resolveHops(hopIds: List<Long>, hops: MutableList<Hop>, origin: HopOrigin): String {
        val scan = ChainScan()
        for (id in hopIds) {
            if (id == WarpHop.PROFILE_ID) {
                val warpHop = warp ?: return missingHopError(id, origin)
                hops.add(Hop(id, warpHop))
                continue
            }
            val outbound = profiles.get(id) ?: return missingHopError(id, origin)
            if (outbound.invalid) return "Profile $id has a type this build cannot use: ${outbound.type}"
            if (outbound.type == "chain") return "Chain in Chain is not allowed"
            // A selector resolves to a different member over time; a chain hop has to stay put.
            if (outbound.type == "autoselector") return "An auto selector cannot be used as a hop; it is not a fixed server"
            if (outbound.isExtraCore()) {
                scan.extraCoreCount++
                scan.extraCoreIdx = hops.size
            }
            if (TypeAccess.isCustomFullConfig(outbound)) scan.hasCustomFullConfig = true
            hops.add(Hop(id, outbound))
        }
        scan.hopCount = hops.size
        return chainScanError(scan)
    }

    /**
     * Stands in for the desktop's IsValid (generate.cpp:2408-2525) before a test candidate is built: the hop walk
     * and every hop's Build() run once, and the first error is the reason to skip the candidate.
     */
    fun candidateError(hopIds: List<Long>, origin: HopOrigin = HopOrigin.NONE): String {
        val hops = ArrayList<Hop>()
        val scanError = resolveHops(hopIds, hops, origin)
        if (scanError.isNotEmpty()) return scanError
        if (hops.isEmpty()) return "The profile has no hops"
        for (hop in hops) {
            val result = hop.outbound.buildChecked(ctx)
            if (!result.ok) return result.error
        }
        return ""
    }

    /**
     * buildOutboundChain (:1430-1560). Returns the ingress tag (the hop the rules name) and reports failures through
     * [BuildState.error]. The hops link with `detour`: the exit (hop 0) is dialed through the next hop, and so on
     * until the entry hop, which is dialed directly.
     */
    fun buildOutboundChain(req: ChainRequest): String {
        val ingressTag = if (req.includeProxy) Tags.PROXY else hopTag(req.prefix, req.startSuffix)
        val hops = ArrayList<Hop>()
        val scanError = resolveHops(req.hopIds, hops, req.origin)
        if (scanError.isNotEmpty()) {
            state.error = scanError
            return ingressTag
        }
        buildSingboxChain(
            hops,
            HopChainOptions(req.prefix, req.includeProxy, req.link, req.startSuffix, warpWrap = req.warpWrap),
        )
        return ingressTag
    }

    /** resolvesHostnamesViaDnsRules (generate.cpp): endpoints and plain SOCKS4, whose server cannot resolve names (SOCKS4a can). */
    private fun resolvesHostnamesViaDnsRules(hop: Hop): Boolean =
        hop.outbound.isEndpoint() || TypeAccess.asSocks(hop.outbound)?.let { it.version == 4 && !it.socks4a } == true

    /**
     * buildSingboxChain (:1321-1369). Hop idx gets `<prefix>-<startSuffix+idx>` (idx 0 is `proxy` for the main
     * chain) and, when linked, `detour` to the next tag: the exit is dialed through the next hop, and so on until the
     * entry hop, which is dialed directly. Under [HopChainOptions.warpWrap] idx 0 is WARP as `proxy` and idx 1 takes
     * `warp-bypass`, the tag rules name to skip WARP.
     */
    private fun buildSingboxChain(hops: List<Hop>, opts: HopChainOptions) {
        for (idx in hops.indices) {
            var tag = hopTag(opts.prefix, opts.startSuffix + idx)
            val nextTag = if (idx < hops.size - 1) hopTag(opts.prefix, opts.startSuffix + idx + 1) else ""
            if (opts.includeProxy && idx == 0) tag = Tags.PROXY
            if (opts.warpWrap && idx == 1) tag = Tags.WARP_BYPASS
            val hop = hops[idx]
            val result = hop.outbound.buildChecked(ctx)
            if (!result.ok) {
                state.error += result.error
                return
            }
            val obj = result.json
            obj["tag"] = tag
            state.collectEchQueryName(hop.outbound)
            // Realm reads its STUN resolver off this key only; without it the hosts go through DNS rules (:1356-1358).
            if (TypeAccess.realmActive(hop.outbound)) obj["domain_resolver"] = jsonObjectOf("server" to Tags.DNS_DIRECT)
            if (nextTag.isNotEmpty() && opts.link) obj["detour"] = nextTag
            if (opts.warpWrap && idx == 0) obj["detour"] = Tags.WARP_BYPASS
            // A detour gets the server hostname unresolved; endpoints look it up via DNS rules, which end at dns-remote over the proxy.
            if (nextTag.isNotEmpty() && opts.link && !hop.outbound.isEndpoint() && !obj.contains("domain_resolver") &&
                resolvesHostnamesViaDnsRules(hops[idx + 1])
            ) obj["domain_resolver"] = directDomainResolver(ctx)
            if (hop.outbound.isEndpoint()) state.endpoints.add(obj) else state.outbounds.add(obj)
        }
    }
}
