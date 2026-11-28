package io.flrone.bridge

import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.StoredProfile
import io.nekohasekai.sagernet.document.json.JsonInput
import io.nekohasekai.sagernet.document.json.JsonObject
import io.nekohasekai.sagernet.document.json.jsonObjectOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The node page's per-row mux/fragment/TLS-tricks overrides (ADR 0008 S8, final batch).
 *
 * The Go profile codec does not model these three editor-only override blocks, and the Kotlin
 * outbound model is on its way out, so this helper reads and writes them in the stored
 * `outbound_json` document itself. The document *is* the compact `ExportToJson` of the row
 * (ProxyEntity's contract), which makes the block shapes below the model's own export:
 *
 *  - `multiplex`: absent for Keep Default, `{"enabled":false}` for Off, and
 *    `{"enabled":true, ...}` with only the non-default settings for On/Custom (multiplex.h,
 *    `Multiplex::ExportToJson`); the Custom settings are the profile's own when it has any;
 *  - `tls.fragment` / `tls.fragment_fallback_delay` / `tls.record_fragment` / `tls.tls_tricks`
 *    (TLS.h tri-states, `Tls::ExportToJson`): `fragment`/`tls_tricks` are written only when the
 *    state is not Keep Default, and the whole block exists only while TLS is on;
 *  - `tls.tls_tricks` is the `{"mixedcase_sni": bool}` object, never a bare boolean.
 *
 * Nothing else in the document is touched: the block is mutated in place and the row is patched
 * with the re-serialised JSON, so every other field keeps its value (and the writer's sorted
 * canonical order). No `outbound` model class is imported any more — the capability table below
 * is the static equivalent of the old field probe on the parsed outbound.
 */
internal object FlroneNodeTuning {

    /** kMuxCustom (multiplex.h:9-10): "Custom" in the profile's Keep Default / On / Off / Custom menu. */
    private const val MUX_STATE_CUSTOM = 3

    /**
     * The canonical types whose outbound carries its own `Multiplex` (the old probe found the
     * `multiplex` field): Shadowsocks, Trojan, VLESS, VMess.
     */
    private val MUX_TYPES = setOf("shadowsocks", "trojan", "vless", "vmess")

    /**
     * The canonical types whose outbound carries its own editable `Tls` member.
     * OpenVPN/OpenConnect also have a `tls` member, but their TLS accessor answers a scratch
     * instance, so the old editor's writes there were dropped on export; they are not tunable and
     * are left out.
     */
    private val TLS_TYPES = setOf(
        "http", "trojan", "vless", "vmess", "hysteria", "tuic",
        "juicity", "trusttunnel", "anytls", "naive", "shadowtls", "masque",
    )

    private fun intOf(values: Map<String, Any?>, key: String): Int? =
        (values[key] as? Number)?.toInt() ?: (values[key] as? String)?.toIntOrNull()

    /** The stored document: an empty object for a blank column (the type's defaults), null when unreadable. */
    private fun documentOf(json: String): JsonObject? =
        if (json.isBlank()) JsonObject() else JsonInput.parseObjectOrNull(json)

    /**
     * The node's own mux, fragment and TLS-tricks overrides. Mux state is the
     * Keep Default (0) / On (1) / Off (2) / Custom (3) menu; the fragment and
     * trick states are 0 default, 1 on, 2 off. A protocol without the block
     * reports false in `hasMux`/`hasTls`.
     */
    suspend fun info(id: Long): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = ProfileManager.getProfile(id) ?: error("No proxy with id $id")
        infoPayload(id, profile.type, profile.outboundJson)
    }

    /**
     * Writes the edited overrides into the row's `outbound_json`; absent keys keep their values.
     *
     * Only the `multiplex`/`tls` blocks change, and the row is patched through the document writer
     * (a per-column patch, like the old `putOutbound` + `updateProfile` pair) before the kernel
     * refresh.
     */
    suspend fun save(id: Long, values: Map<String, Any?>): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = ProfileManager.getProfile(id) ?: error("No proxy with id $id")
        val json = savePayload(profile.type, profile.outboundJson, values)
        if (json != profile.outboundJson) {
            DartProfileWriter.patchProfiles(mapOf(id to mapOf("outbound_json" to json)))
            profile.outboundJson = json
            ProfileManager.iterator { onUpdated(profile, false) }
            FlroneBridge.scheduleRefresh(immediate = true)
        }
        infoPayload(id, profile.type, json)
    }

    /**
     * The row's document after the edit, or the stored text itself when there is nothing to tune.
     * Pure, so the state mapping is testable without the store. A row whose type is unknown or whose
     * document is unreadable is left alone — there is no block to tune, and rewriting it from
     * nothing would destroy the stored row.
     */
    internal fun savePayload(type: String, json: String, values: Map<String, Any?>): String {
        val document = documentOf(json) ?: return json
        if (!StoredProfile.isKnownType(type)) return json
        val canonical = StoredProfile.canonicalType(type)
        if (canonical in MUX_TYPES) applyMultiplex(document, values)
        if (canonical in TLS_TYPES) applyTls(document, values)
        return document.toCompact()
    }

    // ------------------------------------------------------------------------------------- reading

    /** The wire payload of [info]; pure, so the state mapping is testable without the store. */
    internal fun infoPayload(id: Long, type: String, json: String): Map<String, Any?> {
        val document = documentOf(json)
        val canonical = StoredProfile.canonicalType(type)
        val hasMux = document != null && canonical in MUX_TYPES
        val hasTls = document != null && canonical in TLS_TYPES
        val mux = if (hasMux) document?.obj("multiplex") ?: JsonObject() else JsonObject()
        val tls = if (hasTls) document?.obj("tls") ?: JsonObject() else JsonObject()
        val brutal = mux.obj("brutal")
        return mapOf(
            "id" to id,
            "hasMux" to hasMux,
            "hasTls" to hasTls,
            "muxState" to muxState(mux),
            "muxProtocol" to mux.string("protocol"),
            "muxMaxStreams" to mux.int("max_streams"),
            "muxMaxConnections" to mux.int("max_connections"),
            "muxMinStreams" to mux.int("min_streams"),
            "muxPadding" to mux.bool("padding"),
            "muxBrutal" to brutal.bool("enabled"),
            "muxBrutalUp" to brutal.int("up_mbps"),
            "muxBrutalDown" to brutal.int("down_mbps"),
            "fragmentState" to fragmentState(tls),
            "fragmentFallbackDelay" to tls.string("fragment_fallback_delay"),
            "recordFragment" to tls.bool("record_fragment"),
            "tlsTricksState" to tlsTricksState(tls),
        )
    }

    /** `Multiplex::getMuxState`: no block (or no `enabled`) is Keep Default, else On/Off/Custom. */
    private fun muxState(mux: JsonObject): Int = when {
        !mux.contains("enabled") -> 0
        !mux.bool("enabled") -> 2
        hasOwnMuxSettings(mux) -> MUX_STATE_CUSTOM
        else -> 1
    }

    /** `Multiplex::HasOwnSettings`: any non-default setting makes an enabled multiplex Custom. */
    private fun hasOwnMuxSettings(mux: JsonObject): Boolean =
        mux.string("protocol").isNotEmpty() || mux.int("max_connections") > 0 || mux.int("min_streams") > 0 ||
            mux.int("max_streams") > 0 || mux.bool("padding") || mux.obj("brutal").bool("enabled")

    /** TLS.h tri-state: a missing `fragment` key is Keep Default, else On/Off. */
    private fun fragmentState(tls: JsonObject): Int = when {
        !tls.contains("fragment") -> 0
        tls.bool("fragment") -> 1
        else -> 2
    }

    /** TLS.h tri-state: a missing `tls_tricks` key is Keep Default, else the mixedcase SNI flag. */
    private fun tlsTricksState(tls: JsonObject): Int = when {
        !tls.contains("tls_tricks") -> 0
        tls.obj("tls_tricks").bool("mixedcase_sni") -> 1
        else -> 2
    }

    // ------------------------------------------------------------------------------------- writing

    /**
     * `Multiplex::saveMuxState` plus the Custom settings, written as `Multiplex::ExportToJson`:
     * Keep Default drops the block, Off is `{"enabled":false}`, On keeps no settings, and Custom
     * keeps the profile's own settings (only the supplied ones change) with the non-default ones
     * exported alone.
     */
    private fun applyMultiplex(document: JsonObject, values: Map<String, Any?>) {
        val state = intOf(values, "muxState") ?: return
        when (state) {
            0 -> document.remove("multiplex")
            1 -> document["multiplex"] = jsonObjectOf("enabled" to true)
            MUX_STATE_CUSTOM -> {
                val current = document.obj("multiplex")
                val protocol = (values["muxProtocol"] as? String)?.trim() ?: current.string("protocol")
                val maxStreams = intOf(values, "muxMaxStreams")?.coerceAtLeast(0) ?: current.int("max_streams")
                val maxConnections = intOf(values, "muxMaxConnections")?.coerceAtLeast(0)
                    ?: current.int("max_connections")
                val minStreams = intOf(values, "muxMinStreams")?.coerceAtLeast(0) ?: current.int("min_streams")
                val padding = (values["muxPadding"] as? Boolean) ?: current.bool("padding")
                val brutalNow = current.obj("brutal")
                val brutal = (values["muxBrutal"] as? Boolean) ?: brutalNow.bool("enabled")
                val brutalUp = intOf(values, "muxBrutalUp")?.coerceAtLeast(0) ?: brutalNow.int("up_mbps")
                val brutalDown = intOf(values, "muxBrutalDown")?.coerceAtLeast(0) ?: brutalNow.int("down_mbps")
                document["multiplex"] = muxExport(
                    protocol, maxStreams, maxConnections, minStreams, padding, brutal, brutalUp, brutalDown,
                )
            }

            // Off, and any state the menu cannot produce, is `saveMuxState`'s disabled multiplex.
            else -> document["multiplex"] = jsonObjectOf("enabled" to false)
        }
    }

    /** `Multiplex::ExportToJson` for an enabled multiplex; `saveMuxState` cleared the settings unless Custom. */
    private fun muxExport(
        protocol: String,
        maxStreams: Int,
        maxConnections: Int,
        minStreams: Int,
        padding: Boolean,
        brutal: Boolean,
        brutalUp: Int,
        brutalDown: Int,
    ): JsonObject {
        val mux = JsonObject()
        mux["enabled"] = true
        if (protocol.isNotEmpty()) mux["protocol"] = protocol
        if (maxConnections > 0) mux["max_connections"] = maxConnections
        if (minStreams > 0) mux["min_streams"] = minStreams
        if (maxStreams > 0) mux["max_streams"] = maxStreams
        if (padding) mux["padding"] = true
        if (brutal) {
            // TcpBrutal::ExportToJson: sing-box wants both rates, so a missing one is written as 1.
            mux["brutal"] = jsonObjectOf(
                "enabled" to true,
                "up_mbps" to if (brutalUp <= 0) 1 else brutalUp,
                "down_mbps" to if (brutalDown <= 0) 1 else brutalDown,
            )
        }
        return mux
    }

    /**
     * `Tls::saveFragmentState` and the trick flag, written as `Tls::ExportToJson`: the tri-states
     * are omitted for Keep Default, a blank fallback delay and a false record fragment are omitted,
     * and the whole block only exists while TLS is on (the old model mutated a scratch instance and
     * dropped the write for a row without one).
     */
    private fun applyTls(document: JsonObject, values: Map<String, Any?>) {
        if (!document.isObject("tls")) return
        val tls = document.obj("tls")
        if (!tls.bool("enabled")) return
        intOf(values, "fragmentState")?.let { state ->
            when (state) {
                0 -> tls.remove("fragment")
                1 -> tls["fragment"] = true
                else -> tls["fragment"] = false
            }
            (values["fragmentFallbackDelay"] as? String)?.let { delay ->
                val trimmed = delay.trim()
                if (trimmed.isNotEmpty()) tls["fragment_fallback_delay"] = trimmed else tls.remove("fragment_fallback_delay")
            }
            (values["recordFragment"] as? Boolean)?.let { record ->
                if (record) tls["record_fragment"] = true else tls.remove("record_fragment")
            }
        }
        intOf(values, "tlsTricksState")?.let { state ->
            when (state) {
                0 -> tls.remove("tls_tricks")
                1 -> tls["tls_tricks"] = jsonObjectOf("mixedcase_sni" to true)
                else -> tls["tls_tricks"] = jsonObjectOf("mixedcase_sni" to false)
            }
        }
    }
}
