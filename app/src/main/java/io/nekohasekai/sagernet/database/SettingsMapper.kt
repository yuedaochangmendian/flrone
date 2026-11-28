package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.types.AutoSelector

/**
 * DataStore -> BuildContext for the outbound layer's own checks. Config generation itself is Go's `configBuild`
 * action; this object no longer maps GeneratorSettings.
 */
object SettingsMapper {

    /** The outbound layer's lookups into the database (autoselector.cpp:9-15 DisplayAddress); once per process. */
    fun installOutboundHooks() {
        AutoSelector.groupNames = AutoSelector.GroupNames { gid -> GroupRepo.get(gid)?.displayName() }
    }

    /**
     * DataStore -> BuildContext: the preset globals and the domain strategies. TLS spoof is
     * never mapped (decision D8).
     */
    fun buildContext(): BuildContext = BuildContext(
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
        directDnsDisableIpv6 = DataStore.directDnsDisableIpv6,
    )

}
