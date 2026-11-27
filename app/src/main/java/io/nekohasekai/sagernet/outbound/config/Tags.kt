package io.nekohasekai.sagernet.outbound.config

/**
 * The sing-box tags shared by the outbound layer and the config's DNS defaults.
 * ConfigGenerator used to own the full set; the generator is gone, and only the
 * dns-direct server tag is still read here (DnsServers' building block).
 */
internal object Tags {
    const val DNS_DIRECT = "dns-direct"
}
