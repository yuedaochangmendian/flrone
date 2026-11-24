package io.nekohasekai.sagernet.bg.proto

import io.nekohasekai.sagernet.outbound.config.GeneratedConfig

/**
 * What a core instance or a probe box is started with: the sing-box config.
 *
 * The Xray half is gone from the generator (batch B). The four Xray members stay, as constants, so the FFI/probe call
 * sites and the Dart side keep their shape until batch C drops them (CoreHost setters, `needXray` sends).
 */
data class CoreConfig(
    val coreConfig: String,
    val xrayConfig: String? = null,
    val needXray: Boolean = false,
    val xrayDnsStrategy: String = "",
    val xrayFullConfigs: List<String> = emptyList(),
    val outboundTags: List<String> = emptyList(),
) {
    companion object {
        /** The exit of the main config (the started profile) and the direct outbound after it. */
        const val TAG_PROXY = "proxy"
        const val TAG_DIRECT = "direct"

        @JvmStatic
        @JvmOverloads
        fun from(result: GeneratedConfig, outboundTags: List<String> = result.outboundTags): CoreConfig = CoreConfig(
            coreConfig = result.coreConfig,
            // Always the no-Xray values: the generator emits nothing for them any more.
            xrayConfig = null,
            needXray = false,
            xrayDnsStrategy = "",
            xrayFullConfigs = emptyList(),
            outboundTags = outboundTags,
        )
    }
}
