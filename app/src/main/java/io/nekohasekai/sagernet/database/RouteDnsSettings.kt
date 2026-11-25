package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.route.RouteDns

/** RouteDns::Global and RouteDns::Current (RouteProfile.cpp): the DNS settings a config is generated with. */
object RouteDnsSettings {

    /** RouteDns::Global: the DNS settings of Settings › DNS. */
    fun global(): RouteDns = RouteDns(
        remoteDns = DataStore.remoteDns,
        remoteDnsDisableIpv6 = DataStore.remoteDnsDisableIpv6,
        directDns = DataStore.directDns,
        directDnsDisableIpv6 = DataStore.directDnsDisableIpv6,
        dnsFinalOut = DataStore.dnsFinalOut,
        enableDnsRouting = DataStore.enableDnsRouting,
        fakeDns = DataStore.fakedns,
        fakeIpDisableIpv6 = DataStore.fakeipDisableIpv6,
    )

    /**
     * RouteDns::Current: there is one global table and no per-profile DNS any more, so the
     * current DNS is always the global one (routeOwnsDns = false).
     */
    fun current(): Pair<RouteDns, Boolean> = global() to false
}
