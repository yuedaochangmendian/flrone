package io.nekohasekai.sagernet.outbound.config

/**
 * BuildConfigResult / BuildTestConfigResult (include/configs/generate.h:35-63) as the service layer consumes them:
 * every JSON document is compact, key-sorted text.
 *
 * - [coreConfig]: the sing-box config.
 * - [outboundTags] / [tagToProfileId]: the ingress tag of every built test candidate (`proxy-<id>-0`) and its
 *   profile id (test builds only).
 * - [fullConfigs]: custom `fullconfig` test candidates passed through with their `inbounds` emptied, by profile id.
 * - [skipped]: test candidates that were not built, with the reason.
 * - [tunIPv4Cidr]: the tun address of the started config (generated tun inbound or the custom full config's).
 * - [error]: null on success.
 */
class GeneratedConfig(
    @JvmField val coreConfig: String,
    @JvmField val outboundTags: List<String>,
    @JvmField val tagToProfileId: Map<String, Long>,
    @JvmField val fullConfigs: Map<Long, String>,
    @JvmField val skipped: Map<Long, String>,
    @JvmField val tunIPv4Cidr: String?,
    @JvmField val error: String?,
) {
    val ok: Boolean get() = error == null

    companion object {
        @JvmStatic
        fun failure(error: String): GeneratedConfig = GeneratedConfig(
            coreConfig = "",
            outboundTags = emptyList(),
            tagToProfileId = emptyMap(),
            fullConfigs = emptyMap(),
            skipped = emptyMap(),
            tunIPv4Cidr = null,
            error = error,
        )
    }
}
