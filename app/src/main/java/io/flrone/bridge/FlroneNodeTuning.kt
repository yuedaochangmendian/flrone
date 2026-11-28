package io.flrone.bridge

import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.outbound.common.MUX_CUSTOM
import io.nekohasekai.sagernet.outbound.common.Multiplex
import io.nekohasekai.sagernet.outbound.common.Tls
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The node page's per-row mux/fragment/TLS-tricks overrides (ADR 0008 S8).
 *
 * The Go profile codec does not model these three editor-only override blocks:
 * they live on the Kotlin outbound model and are written back by mutating its
 * `Multiplex`/`Tls` fields. Keeping them in their own file (instead of
 * `FlroneProfiles`) keeps the node-editor routing audit honest: the model
 * reflection that remains is isolated here, named, and reported as the one
 * node-editor dependency the final S8 batch must still replace.
 */
internal object FlroneNodeTuning {

    private fun intOf(values: Map<String, Any?>, key: String): Int? =
        (values[key] as? Number)?.toInt() ?: (values[key] as? String)?.toIntOrNull()

    /**
     * The node's own mux, fragment and TLS-tricks overrides. Mux state is the
     * Keep Default (0) / On (1) / Off (2) / Custom (3) menu; the fragment and
     * trick states are 0 default, 1 on, 2 off. A protocol without the field
     * reports false in `hasMux`/`hasTls`.
     */
    suspend fun info(id: Long): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = ProfileManager.getProfile(id) ?: error("No proxy with id $id")
        val outbound = profile.outbound
        val muxField = outbound.javaClass.fields.firstOrNull { it.name == "multiplex" }
        val tlsField = outbound.javaClass.fields.firstOrNull { it.name == "tls" }
        val hasMux = muxField?.type == Multiplex::class.java
        val hasTls = tlsField?.type == Tls::class.java
        val mux = outbound.getMux()
        val tls = outbound.getTls()
        mapOf(
            "id" to id,
            "hasMux" to hasMux,
            "hasTls" to hasTls,
            "muxState" to mux.getMuxState(),
            "muxProtocol" to mux.protocol,
            "muxMaxStreams" to mux.max_streams,
            "muxMaxConnections" to mux.max_connections,
            "muxMinStreams" to mux.min_streams,
            "muxPadding" to mux.padding,
            "muxBrutal" to mux.brutal.enabled,
            "muxBrutalUp" to mux.brutal.up_mbps,
            "muxBrutalDown" to mux.brutal.down_mbps,
            "fragmentState" to when {
                tls.fragment_unspecified -> 0
                tls.fragment -> 1
                else -> 2
            },
            "fragmentFallbackDelay" to tls.fragment_fallback_delay,
            "recordFragment" to tls.record_fragment,
            "tlsTricksState" to when {
                tls.tls_tricks_unspecified -> 0
                tls.tls_tricks -> 1
                else -> 2
            },
        )
    }

    /** Writes the edited overrides back onto the outbound; absent keys keep their values. */
    suspend fun save(id: Long, values: Map<String, Any?>): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = ProfileManager.getProfile(id) ?: error("No proxy with id $id")
        val outbound = profile.outbound
        val mux = outbound.getMux()
        val tls = outbound.getTls()
        intOf(values, "muxState")?.let { state ->
            mux.saveMuxState(state)
            if (state == MUX_CUSTOM) {
                (values["muxProtocol"] as? String)?.let { mux.protocol = it.trim() }
                intOf(values, "muxMaxStreams")?.let { mux.max_streams = it.coerceAtLeast(0) }
                intOf(values, "muxMaxConnections")?.let { mux.max_connections = it.coerceAtLeast(0) }
                intOf(values, "muxMinStreams")?.let { mux.min_streams = it.coerceAtLeast(0) }
                (values["muxPadding"] as? Boolean)?.let { mux.padding = it }
                (values["muxBrutal"] as? Boolean)?.let { mux.brutal.enabled = it }
                intOf(values, "muxBrutalUp")?.let { mux.brutal.up_mbps = it.coerceAtLeast(0) }
                intOf(values, "muxBrutalDown")?.let { mux.brutal.down_mbps = it.coerceAtLeast(0) }
            }
        }
        intOf(values, "fragmentState")?.let { state ->
            tls.saveFragmentState(state)
            (values["fragmentFallbackDelay"] as? String)?.let { tls.fragment_fallback_delay = it.trim() }
            (values["recordFragment"] as? Boolean)?.let { tls.record_fragment = it }
        }
        intOf(values, "tlsTricksState")?.let { state ->
            tls.tls_tricks = state == 1
            tls.tls_tricks_unspecified = state == 0
        }
        profile.putOutbound(outbound)
        ProfileManager.updateProfile(profile)
        FlroneBridge.scheduleRefresh(immediate = true)
        info(id)
    }
}