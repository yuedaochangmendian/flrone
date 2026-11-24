package io.nekohasekai.sagernet.bg.proto

import io.nekohasekai.sagernet.outbound.config.GeneratedConfig

/**
 * What a core instance or a probe box is started with: the sing-box config.
 */
data class CoreConfig(
    val coreConfig: String,
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
            outboundTags = outboundTags,
        )
    }
}
