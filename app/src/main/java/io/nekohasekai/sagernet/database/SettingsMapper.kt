package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.Key
import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.Outbound
import io.nekohasekai.sagernet.outbound.config.SelectorGroup
import io.nekohasekai.sagernet.outbound.config.SelectorMember
import io.nekohasekai.sagernet.outbound.config.SelectorStore
import io.nekohasekai.sagernet.outbound.types.AutoSelector
import io.nekohasekai.sagernet.route.RouteDns

/**
 * DataStore -> BuildContext for the outbound layer's own checks, and the profile tables -> the auto-selector plan's
 * SelectorStore. Config generation itself is Go's `configBuild` action; this object no longer maps
 * GeneratorSettings.
 */
object SettingsMapper {

    /** GroupsRepo / ProfilesRepo for the auto-selector plan; each group is read once per store. */
    fun selectorStore(): SelectorStore = DatabaseSelectorStore()

    /** The outbound layer's lookups into the database (autoselector.cpp:9-15 DisplayAddress); once per process. */
    fun installOutboundHooks() {
        AutoSelector.groupNames = AutoSelector.GroupNames { gid -> GroupRepo.get(gid)?.displayName() }
    }

    /**
     * DataStore -> BuildContext: the preset globals and the domain strategies, with direct_dns_disable_ipv6 from [dns],
     * the routing profile's own DNS, when given. TLS spoof is never mapped (decision D8).
     */
    fun buildContext(dns: RouteDns? = null): BuildContext = BuildContext(
        skipCert = DataStore.skipCert,
        utlsFingerprint = DataStore.utlsFingerprint,
        muxDefaultOn = DataStore.muxDefaultOn,
        muxProtocol = DataStore.muxProtocol,
        muxMode = DataStore.muxMode,
        muxConcurrency = DataStore.muxConcurrency,
        muxMaxConnections = DataStore.muxMaxConnections,
        muxMinStreams = DataStore.muxMinStreams,
        muxPadding = DataStore.muxPadding,
        muxBrutal = DataStore.muxBrutal,
        muxBrutalUpMbps = DataStore.muxBrutalUpMbps,
        muxBrutalDownMbps = DataStore.muxBrutalDownMbps,
        fragmentImplementation = DataStore.fragmentImplementation,
        fragmentDefaultOn = DataStore.fragmentDefaultOn,
        fragmentSize = DataStore.fragmentSize.ifBlank { SettingsRegistry.FRAGMENT_SIZE.default },
        fragmentSleep = DataStore.fragmentSleep.ifBlank { SettingsRegistry.FRAGMENT_SLEEP.default },
        tlsTricksDefaultOn = DataStore.tlsTricksDefaultOn,
        h2IdleTimeout = DataStore.h2IdleTimeout,
        h2KeepAlivePeriod = DataStore.h2KeepAlivePeriod,
        h2StreamReceiveWindow = DataStore.h2StreamReceiveWindow,
        h2ConnectionReceiveWindow = DataStore.h2ConnectionReceiveWindow,
        h2MaxConcurrentStreams = DataStore.h2MaxConcurrentStreams,
        quicInitialPacketSize = DataStore.quicInitialPacketSize,
        quicDisablePathMtuDiscovery = DataStore.quicDisablePathMtuDiscovery,
        defaultDomainStrategy = DataStore.outboundDomainStrategy,
        directDnsDisableIpv6 = dns?.directDnsDisableIpv6 ?: DataStore.directDnsDisableIpv6,
        useDnsObject = DataStore.useDnsObject,
        routeOwnsDns = dns != null,
    )

    private class DatabaseSelectorStore : SelectorStore {
        private val groups = HashMap<Long, SelectorGroup?>()

        override fun group(gid: Long): SelectorGroup? {
            if (groups.containsKey(gid)) return groups[gid]
            return load(gid).also { groups[gid] = it }
        }

        private fun load(gid: Long): SelectorGroup? {
            // ADR 0006 stage C2c2b2: the document is the ONLY source for the
            // selector's group and members; there is no Room row to fall back to.
            val group = if (gid <= 0) null else io.flrone.bridge.DartProfileStore.group(gid)
            if (group == null) return null
            val members = ProfileManager.members(gid).map {
                SelectorMember(it.id, it.outbound, it.latency, it.latencyAt, it.testCountry.orEmpty())
            }
            val landing = group.landingProxyId.takeIf { it > 0 } ?: -1L
            val front = group.frontProxyId.takeIf { it > 0 } ?: -1L
            fun outbound(id: Long): Outbound? = if (id <= 0) null
            else ProfileManager.getProfile(id)?.outbound
            return SelectorGroup(group.id, group.name, landing, front, outbound(landing), outbound(front), members)
        }
    }

}
