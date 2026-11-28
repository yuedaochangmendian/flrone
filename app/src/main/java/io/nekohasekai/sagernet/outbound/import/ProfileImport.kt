package io.nekohasekai.sagernet.outbound.import

import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.Outbound
import io.nekohasekai.sagernet.outbound.OutboundFactory
import io.nekohasekai.sagernet.document.json.JsonArray
import io.nekohasekai.sagernet.document.json.JsonInput
import io.nekohasekai.sagernet.document.json.JsonObject
import io.nekohasekai.sagernet.document.link.Base64Strict
import io.nekohasekai.sagernet.document.link.LinkCodec
import io.nekohasekai.sagernet.document.link.LinkParser
import io.nekohasekai.sagernet.document.link.ProfileImportScan
import io.nekohasekai.sagernet.outbound.types.Custom
import io.nekohasekai.sagernet.outbound.types.OpenConnect
import io.nekohasekai.sagernet.outbound.types.OpenVpn
import io.nekohasekai.sagernet.outbound.types.Shadowsocks
import io.nekohasekai.sagernet.outbound.types.WireGuard
import io.nekohasekai.sagernet.ui.json.engine.JsonTree
import io.nekohasekai.sagernet.validation.Issue
import io.nekohasekai.sagernet.validation.ParseDiag
import io.nekohasekai.sagernet.validation.Severity
import io.nekohasekai.sagernet.validation.Validation
import io.nekohasekai.sagernet.validation.vtr
import java.io.ByteArrayOutputStream
import java.util.zip.Inflater

/**
 * The desktop's subscription / clipboard / file parser (src/configs/sub/SubscriptionParser.cpp with the scanning
 * helpers of include/configs/sub/SubscriptionScan.hpp). [parse] is ParseText: the whole body is base64-decoded
 * when it looks like one blob (standard, then a wrapped standard blob, then the url-safe alphabet), then the
 * document is classified in the desktop's order: JSON (Xray outbounds / configs, sing-box outbounds / endpoints,
 * SIP008), Clash YAML, a WireGuard INI file, an OpenVPN profile, an OpenConnect profile, and finally one item per
 * line (a line opening a bracket yields its balanced JSON block), each of which may itself be base64 or a share
 * link. Every parsed profile goes through stripForeignState and validate: an Error issue refuses it, and every item
 * that was refused or carries issues leaves a [ParseReport].
 */
object ProfileImport {

    /** The profiles produced and one [ParseReport] per item that was refused or carries issues. */
    class Result(@JvmField val outbounds: List<Outbound>, @JvmField val reports: List<ParseReport>) {
        /** The reports as log lines, "source: [error] field: message". */
        val messages: List<String>
            get() = reports.flatMap { report ->
                report.issues.map { issue ->
                    val tag = if (issue.severity == Severity.Error) "[error]" else "[warning]"
                    val text = if (issue.field.isEmpty()) issue.message else issue.field + ": " + issue.message
                    if (report.source.isEmpty()) "$tag $text" else "${report.source}: $tag $text"
                }
            }

        /** The aggregate for the import box; the caller sets the stored count with [ImportReport.setImported]. */
        fun report(): ImportReport = ImportReport().also { it.addAll(reports) }
    }

    private const val MAX_DEPTH = 16

    /** The size cap of a compressed vpn:// payload (SubscriptionParser.cpp). */
    private const val MAX_VPN_PAYLOAD = 16L * 1024 * 1024

    /** [ctx] carries the global settings validate reads (SettingsMapper.buildContext()). */
    @JvmStatic
    @JvmOverloads
    fun parse(text: String, ctx: BuildContext = BuildContext.DEFAULT): Result {
        var body = ProfileImportScan.trim(text)
        if (body.isEmpty()) return Result(emptyList(), emptyList())
        if (ProfileImportScan.looksLikeBase64(body)) {
            ProfileImportScan.decodeBase64(body)?.let { body = it }
        } else if (ProfileImportScan.looksLikeWrappedBase64(body)) {
            ProfileImportScan.decodeBase64Lenient(body)?.let { body = it }
        } else if (ProfileImportScan.looksLikeUrlSafeBase64(body)) {
            ProfileImportScan.decodeBase64UrlSafe(body)?.let { body = it }
        }
        val parser = Parser(ctx)
        parser.document(body, allowBase64 = false, needParse = true, depth = 0)
        return Result(parser.produced, parser.reports)
    }

    /** "happ://routing/onadd/...": a routing profile for the group, not a proxy. */
    fun isRoutingLink(line: String): Boolean {
        val scheme = linkScheme(line)
        return scheme.isNotEmpty() && line.regionMatches(scheme.length, "://routing/", 0, 11, ignoreCase = true)
    }

    private enum class SingBoxSubType { OutboundInJson, OutboundJsonArray, OutboundObject, Invalid }

    /** An Xray document: a list of outbounds, or whole configs, which no longer have a runtime. */
    private enum class XraySubType { OutboundInJson, OutboundJsonArray, OutboundObject, ConfigJsonArray, ConfigObject, Invalid }

    private fun parserError(message: String, field: String = "") = Issue(Severity.Error, field, message)

    private fun parserWarning(message: String, field: String = "") = Issue(Severity.Warning, field, message)

    private fun elide(text: String): String {
        val trimmed = text.trim()
        return if (trimmed.length > 64) trimmed.take(64) + "…" else trimmed
    }

    /** Non-proxy entries every full config carries; skipping them is not worth a report. */
    private fun isSingBoxInfraType(type: String) =
        type == "direct" || type == "block" || type == "dns" || type == "selector" || type == "urltest"

    private val CLASH_INFRA_TYPES = setOf(
        "direct", "reject", "reject-drop", "dns", "pass", "compatible", "relay", "select", "url-test", "fallback", "load-balance",
    )

    private fun isXrayInfraProtocol(protocol: String) = protocol == "freedom" || protocol == "direct" ||
        protocol == "blackhole" || protocol == "block" || protocol == "dns" || protocol == "loopback"

    /** INI sections ("[Interface]", "[General]") also open with '['; JSON arrays hold values, not bare words. */
    private fun looksLikeJson(text: String): Boolean {
        if (text[0] == '{') return true
        val rest = ProfileImportScan.trim(text.substring(1))
        if (rest.isEmpty()) return false
        val c = rest[0]
        return c == '{' || c == '[' || c == '"' || c == ']' || c == '-' || c in '0'..'9'
    }

    /** "ssr" for "ssr://...": the RFC 3986 scheme grammar, so plain text and "#key: value" metadata never qualify. */
    private fun linkScheme(line: String): String {
        val sep = line.indexOf("://")
        if (sep <= 0 || !(line[0] in 'a'..'z' || line[0] in 'A'..'Z')) return ""
        for (i in 1 until sep) {
            val c = line[i]
            if (!(c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c == '+' || c == '.' || c == '-')) return ""
        }
        return line.substring(0, sep)
    }

    /** Never the raw link: "scheme://host:port #name", the address taken from the parsed outbound when it has one. */
    private fun linkSource(link: String, ob: Outbound?): String {
        val sep = link.indexOf("://")
        val label = StringBuilder(if (sep > 0) link.substring(0, sep).lowercase() + "://" else "")
        var host = ob?.server?.trim().orEmpty()
        var port = ob?.serverPort ?: 0
        var name = ob?.name.orEmpty()
        if (host.isEmpty() || name.isBlank()) {
            val url = LinkParser.parse(link)
            // Base64 bodies (vmess://, legacy ss://) parse as a host; only a host:port authority is an address.
            if (host.isEmpty() && url.port > 0 && url.host.isNotEmpty()) {
                host = url.host
                port = url.port
            }
            if (name.isBlank()) name = url.fragment.orEmpty()
        }
        if (host.isNotEmpty()) {
            label.append(if (host.contains(':')) "[$host]" else host)
            if (port > 0) label.append(':').append(port)
        }
        val shown = elide(name)
        if (shown.isNotEmpty()) label.append(" #").append(shown)
        return label.toString()
    }

    private fun singBoxSource(endpoint: Boolean, tag: String, index: Int): String {
        val name = elide(tag)
        return if (endpoint) {
            if (name.isEmpty()) vtr(R.string.validation_import_singbox_endpoint_index, index.toString())
            else vtr(R.string.validation_import_singbox_endpoint_named, name)
        } else {
            if (name.isEmpty()) vtr(R.string.validation_import_singbox_outbound_index, index.toString())
            else vtr(R.string.validation_import_singbox_outbound_named, name)
        }
    }

    private fun clashSource(proxyName: String, index: Int): String {
        val name = elide(proxyName)
        return if (name.isEmpty()) vtr(R.string.validation_import_clash_proxy_index, index.toString())
        else vtr(R.string.validation_import_clash_proxy_named, name)
    }

    private fun namedFileSource(kind: String, profileName: String): String {
        val name = elide(profileName)
        return if (name.isEmpty()) kind else "$kind \"$name\""
    }

    /** The importers' notes; when the import failed, the last note is the reason. */
    private fun appendImporterNotes(issues: MutableList<Issue>, notes: List<String>, ok: Boolean) {
        for ((i, note) in notes.withIndex()) {
            issues.add(if (!ok && i == notes.size - 1) parserError(note) else parserWarning(note))
        }
    }

    private class Parser(private val ctx: BuildContext) {
        val produced = ArrayList<Outbound>()
        val reports = ArrayList<ParseReport>()

        /** [source] is a function: labels are only built for items that have something to report. */
        private fun report(source: () -> String, imported: Boolean, issues: List<Issue>) {
            // A view such as ClashProxy re-reads a key for each block that uses it: one bad value, one issue.
            reports.add(ParseReport(source(), imported, issues.distinct()))
        }

        /** About the whole document rather than one profile: its errors become the import's reasons. */
        private fun reportDocument(source: String, issues: List<Issue>) {
            reports.add(ParseReport(source, false, issues.distinct(), document = true))
        }

        /**
         * Parser::accept: the import checks after a parse; an Error refuses the profile, warnings travel with it.
         * Android also refuses what the core it would run in cannot run (#63, [CoreSupport]).
         */
        private fun accept(outbound: Outbound?, parsed: Boolean, issues: MutableList<Issue>, source: () -> String) {
            var imported = false
            if (outbound == null || !parsed) {
                if (!Validation.hasError(issues)) issues.add(parserError(vtr(R.string.validation_import_unparsed)))
            } else {
                try {
                    outbound.stripForeignState(issues)
                    outbound.validate(issues, ctx)
                } catch (e: RuntimeException) {
                    issues.add(parserError(e.message ?: e.javaClass.simpleName))
                }
                CoreSupport.problem(outbound)?.let { issues.add(parserError(it)) }
                imported = !Validation.hasError(issues)
            }
            if (!imported || issues.isNotEmpty()) report(source, imported, issues)
            if (imported) produced.add(outbound!!)
        }

        /** [ParseDiag.scoped], with an unexpected exception of [parse] reported as this item's error instead of aborting the import. */
        private inline fun guarded(issues: MutableList<Issue>, parse: () -> Boolean): Boolean = try {
            ParseDiag.scoped(issues, parse)
        } catch (e: Exception) {
            issues.add(parserError(unreadable(e)))
            false
        }

        private fun unreadable(e: Exception): String =
            e.message?.takeIf { it.isNotBlank() }?.let { vtr(R.string.validation_import_clash_unreadable_reason, it) }
                ?: vtr(R.string.validation_import_clash_unreadable)

        /** Parser::document (SubscriptionParser.cpp); [overrideName] names a WireGuard profile that has none. */
        fun document(raw: String, allowBase64: Boolean, needParse: Boolean, depth: Int, overrideName: String = "") {
            if (depth > MAX_DEPTH) return
            val text = ProfileImportScan.trim(raw)
            if (text.isEmpty()) return

            if (allowBase64) {
                val decoded = when {
                    ProfileImportScan.looksLikeBase64(text) -> ProfileImportScan.decodeBase64(text)
                    ProfileImportScan.looksLikeUrlSafeBase64(text) -> ProfileImportScan.decodeBase64UrlSafe(text)
                    else -> null
                }
                if (decoded != null) {
                    document(decoded, allowBase64 = false, needParse = true, depth = depth + 1, overrideName = overrideName)
                    return
                }
            }

            if (text[0] == '{' || text[0] == '[') {
                // QJsonDocument::fromJson rejects trailing content, which org.json would silently ignore
                if (ProfileImportScan.matchingClose(text, 0) == text.length - 1) {
                    val value = JsonInput.parseValue(text)
                    if (value is JsonObject || value is JsonArray) {
                        json(value, text)
                        return
                    }
                }
                // Whole documents only: the per-line split of a broken one would repeat the error for every brace line.
                if (needParse && looksLikeJson(text)) {
                    val before = produced.size
                    val reportedBefore = reports.size
                    documentBody(text, needParse, depth, overrideName)
                    if (produced.size == before && reports.size == reportedBefore) reportJsonSyntax(text)
                    return
                }
            }

            documentBody(text, needParse, depth, overrideName)
        }

        private fun documentBody(text: String, needParse: Boolean, depth: Int, overrideName: String) {
            if (text.contains("proxies:")) {
                clash(text)
                return
            }

            if (hasWireGuardSections(text)) {
                wireguardFile(text, overrideName)
                return
            }

            if (looksLikeOvpnConfig(text)) {
                openVpnFile(text)
                return
            }

            if (looksLikeOpenConnectProfile(text)) {
                openConnectProfile(text)
                return
            }

            if (needParse && text.contains('\n')) {
                ProfileImportScan.forEachItem(text) { item ->
                    document(item, allowBase64 = true, needParse = false, depth = depth + 1, overrideName = overrideName)
                }
                return
            }

            link(text, depth, overrideName)
        }

        private fun reportJsonSyntax(text: String) {
            val result = JsonTree.parse(text)
            if (result.ok) return
            val lineColumn = JsonTree.lineColumn(text, result.errorSpan.offset)
            val message = vtr(R.string.validation_import_json_syntax, result.error, lineColumn[0].toString(), lineColumn[1].toString())
            reportDocument("", listOf(parserError(message)))
        }

        /** Parser::json (SubscriptionParser.cpp): Xray first, its configs share the `outbounds` wrapper with sing-box. */
        private fun json(doc: Any, text: String) {
            val xrayType = xraySubType(doc)
            if (xrayType != XraySubType.Invalid) {
                xray(doc, xrayType)
                return
            }

            val subType = singBoxSubType(doc)
            if (subType == SingBoxSubType.OutboundObject) {
                val tag = (doc as JsonObject).string("tag")
                val custom = Custom.fromSingBoxOutboundText(text)
                accept(custom, custom != null, ArrayList()) { singBoxSource(false, tag, 1) }
                return
            }
            if (subType != SingBoxSubType.Invalid) {
                singBox(doc, subType)
                return
            }

            if (text.contains("version") && text.contains("servers")) sip008(doc)
        }

        /** getSingBoxSubType (SubscriptionParser.cpp). */
        private fun singBoxSubType(doc: Any): SingBoxSubType {
            if (doc is JsonObject) {
                if (doc.contains("outbounds") || doc.contains("endpoints")) return SingBoxSubType.OutboundInJson
                if (doc.contains("type")) return SingBoxSubType.OutboundObject
                return SingBoxSubType.Invalid
            }
            if (doc is JsonArray && doc.isNotEmpty()) {
                val first = doc[0]
                if (first is JsonObject && first.contains("type")) return SingBoxSubType.OutboundJsonArray
            }
            return SingBoxSubType.Invalid
        }

        /** getXraySubType (SubscriptionParser.cpp): Xray tags outbounds with `protocol` where sing-box uses `type`. */
        private fun xraySubType(doc: Any): XraySubType {
            if (doc is JsonObject) {
                // A whole config is no longer runnable; one carrying a `protocol` outbound still has the Xray shape.
                if (doc.contains("outbounds")) {
                    return if (hasXrayOutbound(doc.array("outbounds"))) XraySubType.OutboundInJson else XraySubType.Invalid
                }
                if (doc.contains("protocol")) {
                    val whole = doc.contains("inbounds") || doc.contains("routing") || doc.contains("log") || doc.contains("remarks")
                    return if (whole) XraySubType.ConfigObject else XraySubType.OutboundObject
                }
                return XraySubType.Invalid
            }
            if (doc is JsonArray && doc.isNotEmpty()) {
                val first = doc[0]
                if (first is JsonObject) {
                    if (first.contains("protocol") && !first.contains("outbounds")) return XraySubType.OutboundJsonArray
                    if (first.contains("outbounds") && hasXrayOutbound(first.array("outbounds"))) return XraySubType.ConfigJsonArray
                }
            }
            return XraySubType.Invalid
        }

        private fun hasXrayOutbound(outbounds: JsonArray): Boolean =
            outbounds.any { it is JsonObject && it.contains("protocol") }

        /** A whole Xray config, in the shapes the removed implementation accepted: it has no runtime any more. */
        private fun xrayConfig(doc: JsonObject) {
            val remarks = elide(doc.string("remarks"))
            val source = if (remarks.isEmpty()) "Xray" else "Xray \"$remarks\""
            report({ source }, false, listOf(parserError(LegacyXray.FULL_CONFIG_ERROR)))
        }

        /** Parser::singBox (SubscriptionParser.cpp). */
        private fun singBox(doc: Any, type: SingBoxSubType) {
            val outbounds: JsonArray
            val endpoints: JsonArray
            when (type) {
                SingBoxSubType.OutboundInJson -> {
                    val json = doc as JsonObject
                    outbounds = json.array("outbounds")
                    endpoints = json.array("endpoints")
                }

                SingBoxSubType.OutboundJsonArray -> {
                    outbounds = doc as JsonArray
                    endpoints = JsonArray()
                }

                else -> return
            }
            fun handle(value: Any, endpoint: Boolean, index: Int) {
                val out = value as? JsonObject ?: return
                val source = { singBoxSource(endpoint, out.string("tag"), index) }
                if (out.isEmpty()) {
                    report(source, false, listOf(parserWarning(vtr(R.string.validation_import_empty_object))))
                    return
                }
                val type = out.string("type")
                val profileType = OutboundFactory.typeForSingBox(type)
                if (profileType == null) {
                    if (isSingBoxInfraType(type)) return
                    val message = if (type.isEmpty()) vtr(R.string.validation_import_missing_type)
                    else vtr(R.string.validation_import_singbox_unsupported, type)
                    report(source, false, listOf(parserWarning(message)))
                    return
                }
                val outbound = OutboundFactory.newByType(profileType)
                val issues = ArrayList<Issue>()
                val parsed = !outbound.invalid && guarded(issues) { outbound.parseFromJson(out) }
                accept(outbound, parsed, issues, source)
            }
            for ((i, outbound) in outbounds.withIndex()) handle(outbound, false, i + 1)
            for ((i, endpoint) in endpoints.withIndex()) handle(endpoint, true, i + 1)
        }

        /**
         * Parser::xray (SubscriptionParser.cpp) without the Xray runtime: every outbound is converted to the sing-box
         * outbound that means the same thing ([LegacyXray]); a whole config has no counterpart any more and is refused.
         */
        private fun xray(doc: Any, type: XraySubType) {
            when (type) {
                XraySubType.ConfigObject -> xrayConfig(doc as JsonObject)
                XraySubType.ConfigJsonArray -> for (c in doc as JsonArray) {
                    val cfg = c as? JsonObject ?: continue
                    xrayConfig(cfg)
                }
                else -> {
                    val outbounds: JsonArray = when (type) {
                        XraySubType.OutboundInJson -> (doc as JsonObject).array("outbounds")
                        XraySubType.OutboundJsonArray -> doc as JsonArray
                        else -> return
                    }
                    // A config whose single egress dials through a sibling only runs as the config it was.
                    if (type == XraySubType.OutboundInJson && keepsWhole(outbounds)) {
                        xrayConfig(doc as JsonObject)
                        return
                    }
                    for ((i, o) in outbounds.withIndex()) {
                        val out = o as? JsonObject ?: continue
                        xrayOutbound(out, i + 1)
                    }
                }
            }
        }

        /**
         * One Xray outbound element. Infrastructure protocols are dropped as before; the rest is converted by
         * [LegacyXray] or refused with the reason its conversion gives.
         */
        private fun xrayOutbound(out: JsonObject, index: Int) {
            if (out.isEmpty() || isXrayInfraProtocol(out.string("protocol"))) return
            val source = {
                val name = elide(out.string("tag"))
                if (name.isEmpty()) vtr(R.string.validation_import_xray_outbound_index, index.toString())
                else vtr(R.string.validation_import_xray_outbound_named, name)
            }
            val conversion = LegacyXray.convertOutbound(out)
            if (conversion == null) return
            if (conversion.outbound == null) {
                report(source, false, listOf(parserError(conversion.error)))
                return
            }
            accept(conversion.outbound, true, ArrayList(), source)
        }

        /**
         * #88 (Android only): an outbound that dials through a sibling (`sockopt.dialerProxy`, `proxySettings.tag`)
         * only runs next to it, so the config stays one profile when it has exactly one egress: a proxy outbound no
         * sibling dials through. Several egresses sharing a dialer (a fragmenting freedom, say) are separate servers
         * and split as on the desktop.
         */
        private fun keepsWhole(outbounds: JsonArray): Boolean {
            val objects = outbounds.mapNotNull { it as? JsonObject }
            val tags = objects.mapNotNullTo(HashSet()) { o -> o.string("tag").takeIf { it.isNotEmpty() } }
            val targeted = HashSet<String>()
            for (out in objects) {
                val dialer = out.obj("streamSettings").obj("sockopt").string("dialerProxy")
                val proxy = out.obj("proxySettings").string("tag")
                for (target in arrayOf(dialer, proxy)) if (target.isNotEmpty() && target in tags) targeted.add(target)
            }
            if (targeted.isEmpty()) return false
            val egresses = objects.count { out ->
                val tag = out.string("tag")
                !isXrayInfraProtocol(out.string("protocol")) && (tag.isEmpty() || tag !in targeted)
            }
            return egresses == 1
        }

        /** Parser::sip008 (SubscriptionParser.cpp). */
        private fun sip008(doc: Any) {
            val servers = (doc as? JsonObject)?.array("servers") ?: return
            for ((i, o) in servers.withIndex()) {
                val index = i + 1
                val source = { vtr(R.string.validation_import_sip008_server, index.toString()) }
                val out = o as? JsonObject ?: JsonObject()
                if (out.isEmpty()) {
                    report(source, false, listOf(parserWarning(vtr(R.string.validation_import_empty_server))))
                    continue
                }
                val shadowsocks = Shadowsocks()
                val issues = ArrayList<Issue>()
                val parsed = guarded(issues) { shadowsocks.parseFromSip008(out) }
                accept(shadowsocks, parsed, issues, source)
            }
        }

        /** Parser::clash (SubscriptionParser.cpp): one entry at a time; an unreadable entry is reported, the rest still import. */
        private fun clash(text: String) {
            try {
                val doc = ClashYaml.document(text)
                val proxies = doc.proxies
                if (proxies.isNullOrEmpty()) {
                    val message = if (doc.mapping && doc.proxyProviders) vtr(R.string.validation_import_clash_providers)
                    else vtr(R.string.validation_import_clash_no_proxies)
                    reportDocument("", listOf(parserError(message)))
                    return
                }
                for ((i, node) in proxies.withIndex()) {
                    val index = i + 1
                    try {
                        clashProxy(node, index)
                    } catch (e: Exception) {
                        val reason = e.message?.takeIf { it.isNotBlank() }?.let { vtr(R.string.validation_import_clash_unreadable_reason, it) }
                            ?: vtr(R.string.validation_import_clash_unreadable)
                        report({ clashSource(ClashProxy(node).string("name"), index) }, false, listOf(parserError(reason)))
                    }
                }
            } catch (e: Exception) {
                val reason = e.message?.takeIf { it.isNotBlank() }?.let { vtr(R.string.validation_import_clash_doc_reason, it) }
                    ?: vtr(R.string.validation_import_clash_doc)
                reportDocument("", listOf(parserError(reason)))
            }
        }

        /** Parser::clashProxy: the scope covers the whole read of the entry, as the desktop's struct decode does. */
        private fun clashProxy(node: JsonObject, index: Int) {
            var outbound: Outbound? = null
            var name = ""
            var unsupported = ""
            var infra = false
            var parsed = false
            val issues = ArrayList<Issue>()
            val scope = ParseDiag.Scope()
            try {
                val proxy = ClashProxy(node)
                name = proxy.string("name")
                val profileType = OutboundFactory.typeForClash(proxy.type)
                if (profileType == null) {
                    infra = proxy.type in CLASH_INFRA_TYPES
                    unsupported = proxy.string("type")
                } else {
                    val created = OutboundFactory.newByType(profileType)
                    parsed = created.parseFromClash(node)
                    // #63 (Android only): what the entry asked for that its parse dropped without a trace.
                    if (parsed) CoreSupport.clashProblem(proxy, created)?.let { issues.add(parserError(it)) }
                    outbound = created
                }
            } finally {
                issues.addAll(0, scope.take())
                scope.close()
            }
            val source = { clashSource(name, index) }
            if (outbound == null) {
                if (infra) return
                issues.add(
                    parserWarning(
                        if (unsupported.isEmpty()) vtr(R.string.validation_import_missing_type)
                        else vtr(R.string.validation_import_clash_unsupported, unsupported)
                    )
                )
                report(source, false, issues)
                return
            }
            accept(outbound, parsed, issues, source)
        }

        /** Parser::wireguardFile (SubscriptionParser.cpp). */
        private fun wireguardFile(text: String, overrideName: String) {
            val wireguard = WireGuard()
            val issues = ArrayList<Issue>()
            val parsed = guarded(issues) { wireguard.parseFromLink(text) }
            if (parsed) {
                val names = extractWireGuardNames(text)
                setNameIfEmpty(wireguard, overrideName, names.explicitName, names.peerComment)
            } else if (!Validation.hasError(issues)) {
                if (wireguard.private_key.isBlank()) {
                    issues.add(parserError(vtr(R.string.validation_import_wg_no_private_key), "PrivateKey"))
                }
                if (wireguard.peer.public_key.isBlank()) {
                    issues.add(parserError(vtr(R.string.validation_import_wg_no_public_key), "PublicKey"))
                }
            }
            accept(wireguard, parsed, issues) {
                namedFileSource(vtr(R.string.validation_import_kind_wireguard), if (parsed) wireguard.name else overrideName)
            }
        }

        /** Parser::openVpnFile (SubscriptionParser.cpp). */
        private fun openVpnFile(text: String) {
            val problems = ArrayList<String>()
            val openVpn = OpenVpn()
            val issues = ArrayList<Issue>()
            val ok = guarded(issues) { openVpn.parseOvpnConfig(text, problems) }
            appendImporterNotes(issues, problems, ok)
            accept(openVpn, ok, issues) { namedFileSource(vtr(R.string.validation_import_kind_openvpn), openVpn.name) }
        }

        /** Parser::openConnectProfile (SubscriptionParser.cpp). */
        private fun openConnectProfile(text: String) {
            val problems = ArrayList<String>()
            val kind = vtr(R.string.validation_import_kind_openconnect)
            if (text.contains("<AnyConnectProfile") || text.contains("<ServerList")) {
                val hosts = ArrayList<OpenConnect>()
                val issues = ArrayList<Issue>()
                val ok = guarded(issues) { OpenConnect.parseAnyConnectXml(text, hosts, problems) }
                appendImporterNotes(issues, problems, ok)
                if (!ok) {
                    if (!Validation.hasError(issues)) issues.add(parserError(vtr(R.string.validation_import_unparsed)))
                    reportDocument(kind, issues)
                    return
                }
                if (issues.isNotEmpty()) reportDocument(kind, issues)
                for (host in hosts) accept(host, true, ArrayList()) { namedFileSource(kind, host.name) }
                return
            }
            val openConnect = OpenConnect()
            val issues = ArrayList<Issue>()
            val ok = guarded(issues) { openConnect.parseOpenConnectProfile(text, problems) }
            appendImporterNotes(issues, problems, ok)
            accept(openConnect, ok, issues) { namedFileSource(kind, openConnect.name) }
        }

        /**
         * Parser::link (SubscriptionParser.cpp): comments and short lines are skipped, json:// and throne://add/ carry
         * JSON, everything else follows the scheme table. [overrideName] only reaches a link of a wireguard scheme.
         */
        private fun link(line: String, depth: Int, overrideName: String) {
            try {
                linkBody(line, depth, overrideName)
            } catch (e: Exception) {
                report({ linkSource(line, null) }, false, listOf(parserError(unreadable(e))))
            }
        }

        private fun linkBody(line: String, depth: Int, overrideName: String) {
            if (line.startsWith("//") || line.startsWith("#") || line.length < 2) return
            if (line.startsWith("json://")) {
                jsonLink(line, false)
                return
            }
            if (line.startsWith("throne://add/", ignoreCase = true)) {
                jsonLink(line, true)
                return
            }
            if (line.startsWith("vpn://", ignoreCase = true)) {
                vpnLink(line, depth)
                return
            }
            val profileType = OutboundFactory.typeForScheme(line)
            if (profileType == null) {
                if (isRoutingLink(line)) return
                val written = linkScheme(line)
                if (written.isNotEmpty()) {
                    val lower = written.lowercase()
                    val known = lower == "json" || OutboundFactory.typeForScheme("$lower://") != null
                    val message = if (known) vtr(R.string.validation_import_link_lowercase, lower, written)
                    else vtr(R.string.validation_import_link_unsupported, written)
                    report({ linkSource(line, null) }, false, listOf(parserWarning(message)))
                }
                return
            }
            val outbound = OutboundFactory.newByType(profileType)
            val issues = ArrayList<Issue>()
            val parsed = ParseDiag.scoped(issues) { outbound.parseFromLink(line) }
            if (parsed && profileType == "wireguard") setNameIfEmpty(outbound, overrideName)
            accept(outbound, parsed, issues) { linkSource(line, outbound) }
        }

        /** Parser::jsonLink (SubscriptionParser.cpp): `throne://add/<base64 of ExportToJson>` or `json://#<base64url>`. */
        private fun jsonLink(str: String, throneAdd: Boolean) {
            var type = ""
            var name = ""
            val source = {
                val label = StringBuilder(if (throneAdd) "throne://add/" else "json://").append(type)
                val shown = elide(name)
                if (shown.isNotEmpty()) label.append(" #").append(shown)
                label.toString()
            }
            fun damaged(message: String) = report(source, false, listOf(parserError(message)))

            val url = LinkParser.parse(str)
            if (!url.isValid) {
                damaged(vtr(R.string.validation_import_link_damaged_url))
                return
            }
            var dataBytes = if (throneAdd) Base64Strict.decode(url.path.drop(1)) else Base64Strict.decode(url.fragment ?: "", urlSafe = true)
            // ExportJsonLink emits the url-safe alphabet, which the standard decoder rejects whenever '-' or '_' occurs
            if ((dataBytes == null || dataBytes.isEmpty()) && throneAdd) dataBytes = Base64Strict.decode(url.path.drop(1), urlSafe = true)
            if (dataBytes == null || dataBytes.isEmpty()) {
                damaged(vtr(R.string.validation_import_link_damaged_base64))
                return
            }
            val data = JsonInput.parseObject(String(dataBytes, Charsets.UTF_8))
            if (data.isEmpty()) {
                damaged(vtr(R.string.validation_import_link_damaged_object))
                return
            }
            name = data.string("tag")
            if (data.contains("protocol")) {
                val conversion = LegacyXray.convertOutbound(data)
                if (conversion == null) {
                    damaged(vtr(R.string.validation_import_missing_type))
                    return
                }
                val legacy = conversion.outbound
                if (legacy == null) {
                    damaged(conversion.error)
                    return
                }
                accept(legacy, true, ArrayList(), source)
                return
            }
            type = data.string("type")
            val refusal = OutboundFactory.refusedForeignType(type)
            if (refusal.isNotEmpty()) {
                damaged(refusal)
                return
            }
            val outbound = OutboundFactory.newByType(type)
            if (outbound.invalid) {
                damaged(if (type.isEmpty()) vtr(R.string.validation_import_missing_type) else vtr(R.string.validation_import_unsupported_type, type))
                return
            }
            val issues = ArrayList<Issue>()
            val parsed = ParseDiag.scoped(issues) { outbound.parseFromJson(data) }
            accept(outbound, parsed, issues, source)
        }

        /**
         * Parser::vpnLink (SubscriptionParser.cpp), the AmneziaVPN share link: base64 (standard, then url-safe),
         * optionally Qt-compressed, holding either the `containers` JSON (each protocol's `last_config` carries a
         * config document) or a config document itself. The #fragment, else the export's `description` or `name`,
         * becomes the name of the WireGuard profiles inside.
         */
        private fun vpnLink(line: String, depth: Int) {
            var raw = line.substring(6)
            var fragmentName = ""
            val fragment = raw.indexOf('#')
            if (fragment != -1) {
                fragmentName = LinkCodec.decodeFully(raw.substring(fragment + 1)).trim()
                raw = raw.substring(0, fragment)
            }
            val source = { namedFileSource("vpn://", fragmentName) }
            raw = LinkCodec.decodeFully(raw)
            val decoded = Base64Strict.decode(raw)?.takeIf { it.isNotEmpty() }
                ?: Base64Strict.decode(raw, urlSafe = true)?.takeIf { it.isNotEmpty() }
            if (decoded == null) {
                report(source, false, listOf(parserError(vtr(R.string.validation_import_vpn_undecodable))))
                return
            }
            val data = uncompressVpnPayload(decoded) ?: decoded

            val before = produced.size
            val reportedBefore = reports.size
            val text = String(data, Charsets.UTF_8)
            val trimmed = ProfileImportScan.trim(text)
            val doc = if (trimmed.startsWith("{") && ProfileImportScan.matchingClose(trimmed, 0) == trimmed.length - 1) {
                JsonInput.parseObjectOrNull(trimmed)
            } else {
                null
            }
            if (doc != null && doc.contains("containers")) {
                var jsonName = doc.string("description").trim()
                if (jsonName.isEmpty()) jsonName = doc.string("name").trim()
                val targetName = fragmentName.ifEmpty { jsonName }

                val entries = ArrayList<VpnConfigEntry>()
                var wgCount = 0

                for (container in doc.array("containers")) {
                    val containerObj = container as? JsonObject ?: continue
                    val containerType = containerObj.string("container").trim()

                    for (key in containerObj.keys()) {
                        val protoObj = containerObj[key] as? JsonObject ?: continue
                        val conf = when (val lastConfig = protoObj["last_config"]) {
                            is String -> {
                                val inner = JsonInput.parseObjectOrNull(lastConfig)
                                if (inner != null && inner.contains("config")) inner.string("config") else lastConfig
                            }

                            is JsonObject -> lastConfig.string("config")
                            else -> ""
                        }
                        if (conf.isEmpty()) continue

                        val isWireGuard = hasWireGuardSections(conf)
                        if (isWireGuard) wgCount++
                        entries.add(VpnConfigEntry(conf, containerType, isWireGuard))
                    }
                }

                for (e in entries) {
                    // Several WireGuard confs in one export would share a single name, so each is tagged with its container type.
                    var name = targetName
                    if (e.isWireGuard && wgCount > 1 && name.isNotEmpty() && e.containerType.isNotEmpty()) {
                        name += " (" + e.containerType + ")"
                    }
                    document(e.conf, allowBase64 = false, needParse = true, depth = depth + 1, overrideName = name)
                }
            } else {
                document(text, allowBase64 = false, needParse = true, depth = depth + 1, overrideName = fragmentName)
            }
            // Inner items that failed already said why.
            if (produced.size == before && reports.size == reportedBefore) {
                report(source, false, listOf(parserError(vtr(R.string.validation_import_vpn_empty))))
            }
        }

        /**
         * uncompressVpnPayload (SubscriptionParser.cpp): qUncompress data (4-byte big-endian size, then a zlib
         * stream) after validating the header; null when it is not such data.
         */
        private fun uncompressVpnPayload(data: ByteArray): ByteArray? {
            if (data.size < 6) return null
            val expected = ((data[0].toLong() and 0xFF) shl 24) or ((data[1].toLong() and 0xFF) shl 16) or
                ((data[2].toLong() and 0xFF) shl 8) or (data[3].toLong() and 0xFF)
            val cmf = data[4].toInt() and 0xFF
            val flg = data[5].toInt() and 0xFF
            if (expected == 0L || expected > MAX_VPN_PAYLOAD || (cmf and 0x0F) != 8 || ((cmf shl 8) or flg) % 31 != 0) {
                return null
            }
            val inflater = Inflater()
            return try {
                inflater.setInput(data, 4, data.size - 4)
                val out = ByteArrayOutputStream(minOf(expected, 1L shl 20).toInt())
                val buffer = ByteArray(64 * 1024)
                while (!inflater.finished()) {
                    val n = inflater.inflate(buffer)
                    if (n == 0 && !inflater.finished()) return null
                    out.write(buffer, 0, n)
                    if (out.size() > MAX_VPN_PAYLOAD) return null
                }
                out.toByteArray()
            } catch (e: Exception) {
                null
            } finally {
                inflater.end()
            }
        }

        /** looksLikeOvpnConfig (SubscriptionParser.cpp:181-198). */
        private fun looksLikeOvpnConfig(text: String): Boolean {
            var hasRemote = false
            var hasClientMarker = false
            var result = false
            ProfileImportScan.forEachLine(text) { raw ->
                val line = ProfileImportScan.trim(raw)
                if (line.isEmpty() || line[0] == '#' || line[0] == ';') return@forEachLine true
                if (line.startsWith("remote ") || line == "<ca>" || line == "<tls-auth>" || line == "<tls-crypt>" ||
                    line == "<tls-crypt-v2>" || line == "<secret>"
                ) {
                    hasRemote = true
                }
                if (line == "client" || line == "tls-client" || line.startsWith("dev ") || line.startsWith("dev-type ") ||
                    line.startsWith("proto ")
                ) {
                    hasClientMarker = true
                }
                result = hasRemote && hasClientMarker
                !result
            }
            return result
        }

        /** looksLikeOpenConnectProfile (SubscriptionParser.cpp:200-224). */
        private fun looksLikeOpenConnectProfile(text: String): Boolean {
            if (text.contains("<AnyConnectProfile") || text.contains("<ServerList")) return true
            var matched = false
            if (text.contains("protocol")) {
                ProfileImportScan.forEachLine(text) { raw ->
                    if (!raw.contains("protocol")) return@forEachLine true
                    matched = OPENCONNECT_CLI.containsMatchIn(raw) || OPENCONNECT_FILE.matches(raw)
                    !matched
                }
            }
            if (matched) return true
            var result = false
            ProfileImportScan.forEachLine(text) { raw ->
                val line = ProfileImportScan.trim(raw)
                if (line.isEmpty() || line[0] == '#') return@forEachLine true
                result = line.startsWith("openconnect ")
                false
            }
            return result
        }
    }

    private val OPENCONNECT_CLI = Regex("""(?:^|\s)--protocol[= ](?:anyconnect|nc|gp|pulse|f5|fortinet)\b""")
    private val OPENCONNECT_FILE = Regex("""[ \t]*protocol[ \t]*=[ \t]*(?:anyconnect|nc|gp|pulse|f5|fortinet)[ \t]*""")

    /** hasWireGuardSections (SubscriptionParser.cpp:103-106): shared by document and vpnLink so both agree on what a WireGuard conf is. */
    private fun hasWireGuardSections(text: String): Boolean = text.contains("[Interface]") && text.contains("[Peer]")

    // PCRE2's \s and \w spelled out: Unicode-wide where the desktop sets UseUnicodePropertiesOption, ASCII elsewhere.
    // java.util.regex (ASCII by default) and Android's ICU engine (Unicode) would each get one of them wrong.
    private val WG_NAME_SEPARATOR = Regex("""[\p{Z}\t\n\u000B\f\r\u0085_\-.:]+""")
    private val WG_COMMENT_MARKERS = Regex("""^[#;\p{Z}\t\n\u000B\f\r\u0085]+""")
    private val WG_DIRECTIVE = Regex("""^[A-Za-z0-9_]+[ \t\n\u000B\f\r]*=""")
    private val WG_EXPLICIT_NAME = Regex("""^(?:name|remarks?)[ \t\n\u000B\f\r]*[:=][ \t\n\u000B\f\r]*(.+)$""", RegexOption.IGNORE_CASE)
    private val WG_GENERIC_WORDS = setOf("peer", "server", "wireguard", "configuration", "config", "interface", "client", "wg")

    /**
     * looksLikeName (SubscriptionParser.cpp:108-121): filters dividers and boilerplate headers ("# WireGuard
     * configuration", "# Peer 1") so only a real node name can become a profile name.
     */
    private fun looksLikeName(comment: String): Boolean {
        // QChar::isLetterOrNumber covers every L* and N* category; Char.isLetterOrDigit stops at Nd
        if (comment.none { it.category.code[0] in "LN" }) return false
        for (word in comment.lowercase().split(WG_NAME_SEPARATOR)) {
            val w = word.trimEnd { it.isDigit() }
            if (w.isEmpty()) continue
            if (w !in WG_GENERIC_WORDS) return true
        }
        return false
    }

    /** WireGuardNames (SubscriptionParser.cpp:123-126). */
    private class WireGuardNames {
        var explicitName = ""
        var peerComment = ""
    }

    /**
     * extractWireGuardNames (SubscriptionParser.cpp:128-163): an explicit `name`/`remark(s)` comment, and the comment
     * directly above the last `[Peer]`. Any blank or config line in between drops that comment, so `[Interface]`
     * comments cannot leak in.
     */
    private fun extractWireGuardNames(text: String): WireGuardNames {
        val out = WireGuardNames()
        var lastComment = ""

        ProfileImportScan.forEachLine(text) { raw ->
            val line = ProfileImportScan.trim(raw)
            val isComment = line.isNotEmpty() && (line[0] == '#' || line[0] == ';')
            if (!isComment) {
                // Assigned on every [Peer]: the name comes from the last peer, the one WireGuard.parseFromLink keeps.
                if (line.startsWith("[peer]", ignoreCase = true)) out.peerComment = lastComment
                lastComment = ""
                return@forEachLine true
            }

            val comment = WG_COMMENT_MARKERS.replace(line, "").trim()

            if (out.explicitName.isEmpty()) {
                WG_EXPLICIT_NAME.find(comment)?.let { out.explicitName = it.groupValues[1].trim() }
            }

            // Commented-out options such as "# DNS = 1.1.1.1" are not names.
            lastComment = if (!WG_DIRECTIVE.containsMatchIn(comment) && looksLikeName(comment)) comment else ""
            true
        }

        return out
    }

    /**
     * setNameIfEmpty (SubscriptionParser.cpp:165-175): candidates in priority order; a name the link parse already
     * read from a #fragment is never overwritten.
     */
    private fun setNameIfEmpty(outbound: Outbound, vararg candidates: String) {
        if (outbound.name.trim().isNotEmpty()) return
        for (c in candidates) {
            val t = c.trim()
            if (t.isNotEmpty()) {
                outbound.name = t
                return
            }
        }
    }

    /** ConfigEntry of Parser::vpnLink (SubscriptionParser.cpp:669-673): one config document of a `containers` export. */
    private class VpnConfigEntry(val conf: String, val containerType: String, val isWireGuard: Boolean)


}
