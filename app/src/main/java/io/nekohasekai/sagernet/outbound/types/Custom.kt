package io.nekohasekai.sagernet.outbound.types

import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.BuildResult
import io.nekohasekai.sagernet.outbound.Outbound
import io.nekohasekai.sagernet.outbound.OutboundFactory
import io.nekohasekai.sagernet.outbound.SecurityInfo
import io.nekohasekai.sagernet.outbound.withPrivateServer
import io.nekohasekai.sagernet.document.json.JsonArray
import io.nekohasekai.sagernet.document.json.JsonInput
import io.nekohasekai.sagernet.document.json.JsonNull
import io.nekohasekai.sagernet.document.json.JsonObject
import io.nekohasekai.sagernet.document.json.JsonValues
import io.nekohasekai.sagernet.document.json.JsonWriter
import io.nekohasekai.sagernet.document.json.jsonObjectOf
import io.nekohasekai.sagernet.document.link.Hosts
import io.nekohasekai.sagernet.validation.Empty
import io.nekohasekai.sagernet.validation.Issue
import io.nekohasekai.sagernet.validation.Severity
import io.nekohasekai.sagernet.validation.Validation
import io.nekohasekai.sagernet.validation.addIssue
import io.nekohasekai.sagernet.validation.vtr

/**
 * Custom (include/configs/outbounds/custom.h, src/configs/outbounds/custom.cpp): raw JSON in one of two shapes.
 * The desktop's `type` member is [subtype] here because the base already owns `type` ("custom").
 */
class Custom : Outbound("custom") {
    @JvmField var config: String = ""
    @JvmField var subtype: String = ""

    /** A sing-box full config (`fullconfig`), which replaces the whole core config. */
    fun isFullConfig(): Boolean = subtype == CUSTOM_FULL_CONFIG

    /** QString2QJsonObject(config): an empty object when the text is not a JSON object. */
    fun configObject(): JsonObject = JsonInput.parseObject(config)

    /**
     * The desktop's strict QString2QJsonObject: the config only when [Validation.jsonObject] accepts it (comments count
     * as whitespace there), else an empty object; [configObject] would also read text the strict parser refuses.
     */
    private fun strictConfigObject(): JsonObject =
        if (Validation.jsonObject(config, Empty.Required).isEmpty()) configObject() else JsonObject()

    /** custom.h: the config carries its own server, which base validate cannot see. */
    override fun hasServerEndpoint(): Boolean = false

    /** custom.h ParseFromJson. */
    override fun parseFromJson(obj: JsonObject): Boolean {
        if (obj.isEmpty()) return false
        if (obj.contains("name")) name = obj.string("name")
        if (obj.contains("subtype")) subtype = obj.string("subtype").trim()
        if (obj.contains("config")) config = obj.string("config")
        return true
    }

    /** custom.h:31-38: all four keys always. */
    override fun exportToJson(): JsonObject {
        val obj = JsonObject()
        obj["name"] = name
        obj["type"] = "custom"
        obj["subtype"] = subtype
        obj["config"] = config
        return obj
    }

    /** Custom::GetAddress (custom.cpp): effectiveSecurity's private-server check reads this. */
    override fun getAddress(): String {
        if (subtype == CUSTOM_OUTBOUND) return configObject().string("server")
        return ""
    }

    /** Custom::DisplayAddress (custom.cpp). */
    override fun displayAddress(): String {
        if (subtype == CUSTOM_OUTBOUND) {
            val obj = configObject()
            return Hosts.displayAddress(obj.string("server"), obj.int("server_port"))
        }
        return ""
    }

    /** custom.h:70-86. */
    override fun displayType(): String = when (subtype) {
        CUSTOM_OUTBOUND -> {
            val outboundType = capitalized(configObject().string("type"))
            if (outboundType.isEmpty()) "Custom Outbound" else "Custom $outboundType Outbound"
        }
        CUSTOM_FULL_CONFIG -> "Custom Config"
        else -> subtype
    }

    /** custom.cpp:176-196: the verdict of the outbound the config actually exits through. */
    override fun security(): SecurityInfo = when (subtype) {
        CUSTOM_OUTBOUND -> analyzeSingBoxOutbound(configObject())
        CUSTOM_FULL_CONFIG -> {
            val egress = singBoxFullConfigEgress(configObject())
            if (egress.isEmpty()) SecurityInfo() else analyzeSingBoxOutbound(egress)
        }
        else -> SecurityInfo()
    }

    /** custom.cpp:198-217. */
    override fun exportIdentity(): JsonObject {
        val ob = when (subtype) {
            CUSTOM_OUTBOUND -> singBoxOutboundIdentity(configObject())
            CUSTOM_FULL_CONFIG -> {
                val egress = singBoxFullConfigEgress(configObject())
                if (egress.isEmpty()) JsonObject() else singBoxOutboundIdentity(egress)
            }
            else -> JsonObject()
        }
        if (ob.isEmpty()) return exportToJson()
        return jsonObjectOf("subtype" to subtype, "ob" to ob)
    }

    /** Custom::Validate (custom.cpp). */
    override fun validate(issues: MutableList<Issue>, ctx: BuildContext) {
        super.validate(issues, ctx)
        if (subtype !in SUBTYPES) {
            // oneOf trims, but build() and the strip compare exactly.
            val message = Validation.oneOf(subtype, SUBTYPES, Empty.Required).ifEmpty { vtr(R.string.validation_no_spaces) }
            issues.add(Issue(Severity.Error, "subtype", message, subtype))
            return
        }
        issues.addIssue(Severity.Error, "config", CustomChecks.customConfig(subtype, config))
    }

    /**
     * Custom::StripForeignState (custom.cpp): what would expose this device, write files where the sender chose or start
     * a program. Tailscale's SSH server and Taildrop folder are not stripped: Tailscale is not on Android.
     */
    override fun stripForeignState(issues: MutableList<Issue>) {
        val root = strictConfigObject()
        val removed = when (subtype) {
            CUSTOM_FULL_CONFIG -> {
                var changed = stripSingBoxExposure(root, issues)
                for (list in listOf("outbounds", "endpoints")) {
                    changed = changed or editListNamed(root, list, "") { item, at -> stripLaunchers(item, at, issues) }
                }
                changed
            }
            // build() hands every other subtype to the core as a sing-box outbound.
            else -> stripLaunchers(root, "", issues)
        }
        if (removed) config = JsonWriter.writeIndented(root)
    }

    /** custom.h:92-98: only raw sing-box outbound JSON can describe an endpoint. */
    override fun isEndpoint(): Boolean {
        if (subtype != CUSTOM_OUTBOUND) return false
        val t = configObject().string("type")
        return t == "wireguard" || t == "tailscale" || t == "masque"
    }

    /** custom.h:127-146. */
    override fun build(ctx: BuildContext): BuildResult = BuildResult(configObject())

    companion object {
        /** custom.h:10-13 */
        const val CUSTOM_OUTBOUND = "outbound"
        const val CUSTOM_FULL_CONFIG = "fullconfig"

        private val SUBTYPES = listOf(CUSTOM_OUTBOUND, CUSTOM_FULL_CONFIG)

        /**
         * SubscriptionParser.cpp:344-350: a JSON document that is one sing-box outbound object (it has `type`, and
         * is neither a config with `outbounds`/`endpoints` nor an Xray outbound with `protocol`, which the legacy
         * conversion in profile-import handles) is stored as JSON text. Null when the text is not such an object.
         * Android stores the Indented re-serialization rather than the source: the lenient reader takes text (raw
         * control characters in strings) that the strict check refuses.
         */
        @JvmStatic
        fun fromSingBoxOutboundText(text: String): Custom? {
            val obj = JsonInput.parseObjectOrNull(text) ?: return null
            if (obj.contains("protocol") || obj.contains("outbounds") || obj.contains("endpoints") || !obj.contains("type")) return null
            val custom = Custom()
            custom.subtype = CUSTOM_OUTBOUND
            custom.config = JsonWriter.writeIndented(obj)
            return custom
        }

        private fun firstObject(arr: JsonArray): JsonObject =
            if (arr.isEmpty()) JsonObject() else arr[0] as? JsonObject ?: JsonObject()

        /** QChar::toUpper on the first character. */
        private fun capitalized(s: String): String =
            if (s.isEmpty()) s else s[0].uppercaseChar() + s.substring(1)

        /** custom.cpp:15-18. */
        private fun isSingBoxInfra(t: String): Boolean = t == "direct" || t == "block" || t == "dns"

        /** custom.cpp:20-30 (the outbound of an unknown or not yet ported type has no verdict). */
        private fun analyzeSingBoxOutbound(o: JsonObject): SecurityInfo {
            val type = o.string("type")
            if (type.isEmpty() || type == "custom" || type == "selector" || type == "urltest" || isSingBoxInfra(type)) return SecurityInfo()
            val ob = OutboundFactory.newByType(type)
            if (ob.invalid) return SecurityInfo()
            ob.parseFromJson(o)
            return withPrivateServer(ob.security(), ob.getAddress())
        }

        /** custom.cpp:32-42. */
        private fun singBoxOutboundIdentity(o: JsonObject): JsonObject {
            val type = o.string("type")
            if (type.isEmpty() || type == "custom" || type == "selector" || type == "urltest" || isSingBoxInfra(type)) return JsonObject()
            val ob = OutboundFactory.newByType(type)
            if (ob.invalid) return JsonObject()
            ob.parseFromJson(o)
            return ob.exportIdentity()
        }

        private fun singBoxFullConfigEgress(cfg: JsonObject): JsonObject =
            resolveSingBoxEgress(cfg.array("outbounds"), cfg.obj("route").string("final"), 5)

        // custom.cpp:44-69: the named tag, or the first outbound (sing-box's default egress), through selector/urltest groups.
        private fun resolveSingBoxEgress(outbounds: JsonArray, tag: String, depth: Int): JsonObject {
            if (depth <= 0 || outbounds.isEmpty()) return JsonObject()
            var target = JsonObject()
            if (tag.isEmpty()) {
                target = firstObject(outbounds)
            } else {
                for (v in outbounds) {
                    val obj = v as? JsonObject ?: JsonObject()
                    if (obj.string("tag") == tag) {
                        target = obj
                        break
                    }
                }
            }
            if (target.isEmpty()) return JsonObject()
            val type = target.string("type")
            if (type == "selector" || type == "urltest") {
                val subs = target.array("outbounds")
                var next = target.string("default")
                if (next.isEmpty() && subs.isNotEmpty()) next = JsonValues.toStringValue(subs[0])
                return resolveSingBoxEgress(outbounds, next, depth - 1)
            }
            if (type.isEmpty() || isSingBoxInfra(type)) return JsonObject()
            return target
        }
    }
}

/** The Checks of custom.h. */
object CustomChecks {
    /** Checks::CustomConfig (custom.cpp): valid JSON (line and column on a syntax error) with what the subtype needs: a type or an outbounds list. */
    @JvmStatic
    fun customConfig(subtype: String, text: String): String {
        Validation.jsonObject(text, Empty.Required).let {
            if (it.isNotEmpty()) return if (!hasJsonComment(text)) it else it + " " + vtr(R.string.validation_custom_json_comments)
        }
        val root = JsonInput.parseObject(text)
        if (subtype == Custom.CUSTOM_OUTBOUND && JsonValues.toStringValue(customValueNamed(root, "type")).trim().isEmpty()) {
            return vtr(R.string.validation_custom_type_missing)
        }
        // A missing list fails too: the desktop's customValueNamed gives a null QJsonValue then.
        if (subtype == Custom.CUSTOM_FULL_CONFIG && customValueNamed(root, "outbounds") !is JsonArray) {
            return vtr(R.string.validation_custom_outbounds_list)
        }
        return ""
    }
}

/** custom.cpp keysNamed: the core matches object keys case-insensitively, so every spelling of a key sets the same option. */
private fun keysNamed(o: JsonObject, name: String): List<String> = o.sortedKeys().filter { it.equals(name, ignoreCase = true) }

/** custom.cpp customValueNamed: null when no spelling is present. */
private fun customValueNamed(o: JsonObject, name: String): Any? = keysNamed(o, name).firstOrNull()?.let { o[it] }

private fun isBlank(value: Any?): Boolean = value == null || value === JsonNull || (value is String && value.isEmpty()) ||
    (value is JsonArray && value.isEmpty()) || (value is JsonObject && value.isEmpty())

/** torrc keys reach Tor's SETCONF unescaped. */
private fun isTorOptionName(key: String): Boolean =
    key.isNotEmpty() && key.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '_' }

/** A pluggable-transport line ("obfs4 exec /path/to/program") makes Tor spawn that program; Tor also takes abbreviated option names. */
private fun isTorPluginOption(key: String): Boolean = key.length >= 4 &&
    ("ClientTransportPlugin".startsWith(key, ignoreCase = true) || "ServerTransportPlugin".startsWith(key, ignoreCase = true))

/** custom.cpp stripLaunchers: removes what would make the core start a program; true when anything went. */
private fun stripLaunchers(o: JsonObject, at: String, issues: MutableList<Issue>): Boolean {
    var removed = false
    fun report(key: String, message: String, value: String = "") {
        issues.add(Issue(Severity.Warning, at + key, message, value))
        removed = true
    }

    fun strip(name: String, message: String, showValue: Boolean) {
        for (key in keysNamed(o, name)) {
            if (isBlank(o[key])) continue
            report(key, message, if (showValue) JsonValues.toStringValue(o[key]) else "")
            o.remove(key)
        }
    }
    when (o.string("type")) {
        "tor" -> {
            strip("executable_path", vtr(R.string.validation_custom_tor_executable), true)
            strip("extra_args", vtr(R.string.validation_custom_tor_args), false)
            strip("data_directory", vtr(R.string.validation_custom_tor_data_directory), true)
            for (torrcKey in keysNamed(o, "torrc")) {
                val torrc = o[torrcKey] as? JsonObject ?: continue
                for (key in torrc.sortedKeys()) {
                    if (!isTorOptionName(key)) {
                        report(torrcKey, vtr(R.string.validation_custom_tor_option_name), key)
                    } else if (isTorPluginOption(key)) {
                        report("$torrcKey.$key", vtr(R.string.validation_custom_tor_plugin, key), JsonValues.toStringValue(torrc[key]))
                    } else {
                        continue
                    }
                    torrc.remove(key)
                }
            }
        }

        "openconnect" -> for (section in listOf("csd", "hip", "tncc")) {
            for (sectionKey in keysNamed(o, section)) {
                val wrapper = o[sectionKey] as? JsonObject ?: continue
                for (key in keysNamed(wrapper, "wrapper_path")) {
                    if (isBlank(wrapper[key])) continue
                    report("$sectionKey.$key", vtr(R.string.validation_custom_wrapper_path, section.uppercase()), JsonValues.toStringValue(wrapper[key]))
                    wrapper.remove(key)
                }
            }
        }
    }
    return removed
}

private fun stripNamed(o: JsonObject, name: String, at: String, message: String, showValue: Boolean, issues: MutableList<Issue>): Boolean {
    var removed = false
    for (key in keysNamed(o, name)) {
        val value = o[key]
        if (isBlank(value)) continue
        issues.add(Issue(Severity.Warning, at + key, message, if (showValue) JsonValues.toStringValue(value) else ""))
        o.remove(key)
        removed = true
    }
    return removed
}

/** Runs [edit] on every spelling of [name] that holds an object, in place, with the field prefix of that object. */
private fun editObjectNamed(o: JsonObject, name: String, at: String, edit: (JsonObject, String) -> Boolean): Boolean {
    var changed = false
    for (key in keysNamed(o, name)) {
        val inner = o[key] as? JsonObject ?: continue
        if (edit(inner, "$at$key.")) changed = true
    }
    return changed
}

private fun editListNamed(o: JsonObject, name: String, at: String, edit: (JsonObject, String) -> Boolean): Boolean {
    var changed = false
    for (key in keysNamed(o, name)) {
        val items = o[key] as? JsonArray ?: continue
        for ((i, item) in items.withIndex()) {
            if (item is JsonObject && edit(item, "$at$key[$i].")) changed = true
        }
    }
    return changed
}

private fun opensPortMessage() = vtr(R.string.validation_custom_opens_port)

private fun writesFileMessage() = vtr(R.string.validation_custom_writes_file)

private val LOCAL_INBOUND_TYPES = listOf("mixed", "socks", "http", "direct", "redirect", "tproxy")

/** QHostAddress(text).isLoopback(): 127.0.0.0/8, ::1 and the v4-mapped 127.0.0.0/8, a scope id allowed. */
private fun isLoopbackLiteral(text: String): Boolean {
    val a = text.trim()
    if (a.contains(':')) {
        val pct = a.lastIndexOf('%')
        val v6 = Hosts.parseIpv6(if (pct >= 0) a.substring(0, pct) else a)
        if (v6 != null) {
            if ((0 until 15).all { v6[it].toInt() == 0 } && v6[15].toInt() == 1) return true
            val mapped = (0 until 10).all { v6[it].toInt() == 0 } && v6[10] == 0xFF.toByte() && v6[11] == 0xFF.toByte()
            return mapped && v6[12].toInt() == 127
        }
    }
    val v4 = Hosts.parseIpv4(a) ?: return false
    return (v4 shr 24) == 127L
}

/** custom.cpp isLocalSingBoxInbound: every spelling must agree, the core may read any of them. */
private fun isLocalSingBoxInbound(inbound: JsonObject): Boolean {
    val typeKeys = keysNamed(inbound, "type")
    if (typeKeys.isEmpty()) return false
    var tun = true
    var local = true
    for (key in typeKeys) {
        val t = inbound.string(key)
        tun = tun && t == "tun"
        local = local && t in LOCAL_INBOUND_TYPES
    }
    if (tun) return true
    if (!local) return false
    // TLS can carry ACME, which answers challenges on public ports.
    if (keysNamed(inbound, "tls").any { !isBlank(inbound[it]) }) return false
    // The core listens on 127.0.0.1 when no address is given.
    for (key in keysNamed(inbound, "listen")) {
        val listen = inbound[key]
        if (!isBlank(listen) && !isLoopbackLiteral(JsonValues.toStringValue(listen))) return false
    }
    return true
}

/** custom.cpp stripSingBoxExposure: removes what would open a port on this device or write a file; Throne runs a full config as it is. */
private fun stripSingBoxExposure(root: JsonObject, issues: MutableList<Issue>): Boolean {
    var removed = false
    for (key in keysNamed(root, "inbounds")) {
        val items = root[key] as? JsonArray ?: continue
        val kept = JsonArray()
        for ((i, item) in items.withIndex()) {
            val inbound = item as? JsonObject ?: JsonObject()
            if (isLocalSingBoxInbound(inbound)) {
                kept.add(item)
                continue
            }
            issues.add(
                Issue(
                    Severity.Warning, "$key[$i]", vtr(R.string.validation_custom_inbound_removed),
                    JsonValues.toStringValue(customValueNamed(inbound, "type")),
                ),
            )
        }
        if (kept.size == items.size) continue
        root[key] = kept
        removed = true
    }
    removed = stripNamed(root, "services", "", opensPortMessage(), false, issues) or removed
    removed = stripNamed(root, "certificate_providers", "", opensPortMessage(), false, issues) or removed
    removed = editObjectNamed(root, "log", "") { log, at -> stripNamed(log, "output", at, writesFileMessage(), true, issues) } or removed
    removed = editObjectNamed(root, "experimental", "") { experimental, at ->
        var changed = stripNamed(experimental, "clash_api", at, vtr(R.string.validation_custom_clash_api), false, issues)
        // The core builds the V2Ray API only when it listens.
        for (key in keysNamed(experimental, "v2ray_api")) {
            val api = experimental.obj(key)
            if (keysNamed(api, "listen").all { isBlank(api[it]) }) continue
            issues.add(Issue(Severity.Warning, at + key, vtr(R.string.validation_custom_v2ray_api)))
            experimental.remove(key)
            changed = true
        }
        changed = editObjectNamed(experimental, "debug", at) { debug, debugAt ->
            stripNamed(debug, "listen", debugAt, opensPortMessage(), true, issues)
        } or changed
        changed = editObjectNamed(experimental, "cache_file", at) { cache, cacheAt ->
            stripNamed(cache, "path", cacheAt, writesFileMessage(), true, issues)
        } or changed
        changed
    } or removed
    removed = editListNamed(root, "network_namespaces", "") { ns, at -> stripNamed(ns, "pid_file", at, writesFileMessage(), true, issues) } or removed
    return removed
}

/** custom.cpp hasJsonComment: a line or block comment opener outside a string; one inside (an https:// URL) is no comment. */
private fun hasJsonComment(text: String): Boolean {
    var inString = false
    var i = 0
    while (i < text.length) {
        val c = text[i]
        if (inString) {
            if (c == '\\') i++ else if (c == '"') inString = false
        } else if (c == '"') {
            inString = true
        } else if (c == '/' && i + 1 < text.length && (text[i + 1] == '/' || text[i + 1] == '*')) {
            return true
        }
        i++
    }
    return false
}
