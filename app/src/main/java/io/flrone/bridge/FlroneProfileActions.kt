package io.flrone.bridge

import io.flrone.core.Core
import io.nekohasekai.sagernet.document.json.JsonArray
import io.nekohasekai.sagernet.document.json.JsonInput
import io.nekohasekai.sagernet.document.json.JsonObject
import io.nekohasekai.sagernet.ui.json.ProfileJson
import java.util.concurrent.atomic.AtomicLong

/**
 * The Go profile-codec actions the node editor asks first (ADR 0008 S8).
 *
 * The Go kernel already owns the share-link/body importer, the stored-form
 * normalizer/validator, the blank-template factory and the stored exporter
 * (`profile_*.go`, the `profileImport`/`profileNewOutbound`/`profileNormalize`/
 * `profileValidate`/`profileExport` actions). This object is the Kotlin side of
 * that contract: one synchronous `Core.runAction` call, the reply decoded into
 * the small shapes [FlroneProfiles] needs.
 *
 * The older Kotlin implementations did not disappear: `ProfileImport`,
 * `OutboundFactory` and the outbound model remain the *fallback* for inputs Go
 * still answers `supported:false` (wireguard/masque/openvpn/openconnect,
 * custom documents with launchers, the Xray corpus, ...). That fallback lives
 * in [FlroneNodeEditorLegacy]; when Go accepts a document the Kotlin importer is
 * never re-run — the only Kotlin read left is the model save gate over the
 * canonical JSON, for the advanced types Go's stored validator does not model.
 *
 * Transport failures are answered as `Unavailable`, not thrown: the editor
 * predates the kernel action bus and must keep working if the Go library
 * cannot be loaded (unit tests, a surprising ABI split). A semantic refusal is
 * a successful action (`supported:false`) and is reported separately, so a
 * caller can distinguish "Go cannot model this document" from "Go did not
 * answer".
 */
internal object FlroneProfileActions {

    /**
     * One synchronous action transport. Injectable for JVM tests; production is
     * the same `Core.runAction` the route-document writers use.
     */
    @Volatile
    internal var transport: (String) -> String = { Core.runAction(it) }

    private val sequence = AtomicLong()

    /** One node a Go codec accepted, in the canonical stored form. */
    internal data class ImportedNode(
        val type: String,
        val name: String,
        val json: String,
    )

    sealed class ImportOutcome {
        class Supported(val nodes: List<ImportedNode>) : ImportOutcome()
        class Refused(val reason: String) : ImportOutcome()
        class Unavailable(val message: String) : ImportOutcome()
    }

    /**
     * What the node editor should do with a pasted/shared document. `Nodes`
     * carries either the imported entries or the single canonicalised stored
     * document; the caller checks the count where one node is required.
     */
    sealed class EditorParse {
        class Nodes(val nodes: List<ImportedNode>) : EditorParse()
        class Refused(val reason: String) : EditorParse()
        class Unavailable(val message: String) : EditorParse()
    }

    internal data class Issue(val field: String, val message: String, val severity: String) {
        /** The node editor's save-gate wording: "field: message". */
        fun describe(): String = listOf(field, message).filter { it.isNotBlank() }.joinToString(": ")
    }

    sealed class StoredValidation {
        class Supported(val ok: Boolean, val issues: List<Issue>, val normalized: String) : StoredValidation()
        class Refused(val reason: String) : StoredValidation()
        class Unavailable(val message: String) : StoredValidation()
    }

    sealed class StoredNormalize {
        class Supported(val json: String) : StoredNormalize()
        class Refused(val reason: String) : StoredNormalize()
        class Unavailable(val message: String) : StoredNormalize()
    }

    internal data class ExportedNode(
        val type: String,
        val name: String,
        val displayType: String,
        val json: String,
        val link: String,
        val jsonLink: String,
    )

    sealed class StoredExport {
        class Supported(val node: ExportedNode) : StoredExport()
        class Refused(val reason: String) : StoredExport()
        class Unavailable(val message: String) : StoredExport()
    }

    // ------------------------------------------------------------------------------------------------ actions

    /** The blank stored document for [type], or null when Go refused/did not answer (legacy fallback). */
    fun newOutbound(type: String): String? = try {
        // The Go action trims its type; the Kotlin factory never did. Keep the
        // old rejection for a padded type instead of creating a node Go would
        // have silently accepted.
        if (type != type.trim()) return null
        val data = invoke("profileNewOutbound", JsonObject().apply { this["type"] = type })
        val template = data.string("json")
        if (template.isBlank() || JsonInput.parseObjectOrNull(template) == null) null else template
    } catch (failure: Throwable) {
        rethrowCancellation(failure)
        null
    }

    /** `profileImport` over one share link, subscription body, Clash YAML or JSON document. */
    fun importText(text: String): ImportOutcome = try {
        val data = invoke("profileImport", JsonObject().apply { this["text"] = text })
        if (!data.bool("supported")) {
            ImportOutcome.Refused(data.string("reason").ifBlank { "No supported proxy node found" })
        } else {
            val nodes = importedNodes(data["nodes"] as? JsonArray)
            if (nodes.isEmpty()) {
                ImportOutcome.Refused(data.string("reason").ifBlank { "No supported proxy node found" })
            } else {
                ImportOutcome.Supported(nodes)
            }
        }
    } catch (failure: Throwable) {
        rethrowCancellation(failure)
        ImportOutcome.Unavailable(failure.message ?: failure.javaClass.simpleName)
    }

    /**
     * The node editor's document path for commit/update/decode.
     *
     * A document that *is one stored outbound* (a bare object with `type`, no
     * `outbounds`/`endpoints`) is normalised through `profileNormalize
     * format=stored`: the editor's old `parseOutbounds` read it through
     * `OutboundFactory.fromJson`, i.e. the database loader, not the importer's
     * drop-on-import rules. Everything else is a share link/body and goes
     * through `profileImport`, exactly like the old importer branch. `custom` and
     * `autoselector` documents deliberately take the import branch: their model
     * reads the config/group names, which a JSON canonicaliser does not.
     */
    fun parseEditorNode(text: String): EditorParse = try {
        val stored = bareStoredDocument(text)
        val storedType = stored?.string("type").orEmpty()
        // custom's launcher rewrite and autoselector's group-name display address
        // live on the Kotlin model; neither document can be trusted to a pure
        // JSON canonicaliser.
        if (stored != null && storedType != "custom" && storedType != "autoselector") {
            when (val normalized = normalizeStored(text)) {
                is StoredNormalize.Supported -> {
                    val json = normalized.json
                    val objectValue = JsonInput.parseObjectOrNull(json)
                        ?: return EditorParse.Refused("the Go normalizer answered a non-object document")
                    EditorParse.Nodes(listOf(ImportedNode(
                        type = objectValue.string("type").ifBlank { stored.string("type") },
                        name = objectValue.string("tag"),
                        json = json,
                    )))
                }
                is StoredNormalize.Refused -> EditorParse.Refused(normalized.reason)
                is StoredNormalize.Unavailable -> EditorParse.Unavailable(normalized.message)
            }
        } else {
            when (val imported = importText(text)) {
                is ImportOutcome.Supported -> EditorParse.Nodes(imported.nodes)
                is ImportOutcome.Refused -> EditorParse.Refused(imported.reason)
                is ImportOutcome.Unavailable -> EditorParse.Unavailable(imported.message)
            }
        }
    } catch (failure: Throwable) {
        rethrowCancellation(failure)
        EditorParse.Unavailable(failure.message ?: failure.javaClass.simpleName)
    }

    /** `profileValidate format=stored`: the editor's save gate over one canonical stored row. */
    fun validateStored(json: String): StoredValidation = try {
        val data = invoke("profileValidate", JsonObject().apply {
            this["json"] = json
            this["format"] = "stored"
        })
        val issues = (data["issues"] as? JsonArray)?.map { raw ->
            val issue = raw as? JsonObject ?: return@map Issue("", "", "error")
            Issue(issue.string("field"), issue.string("message"), issue.string("severity").ifBlank { "error" })
        }.orEmpty()
        val supported = if (data.contains("supported")) data.bool("supported") else true
        if (!supported) {
            StoredValidation.Refused(
                issues.firstOrNull()?.message?.ifBlank { "the stored document is not supported by Go validation" }
                    ?: "the stored document is not supported by Go validation",
            )
        } else {
            StoredValidation.Supported(
                ok = data.bool("ok"),
                issues = issues,
                normalized = data.string("normalized"),
            )
        }
    } catch (failure: Throwable) {
        rethrowCancellation(failure)
        StoredValidation.Unavailable(failure.message ?: failure.javaClass.simpleName)
    }

    /** `profileNormalize format=stored`: the database-loader canonical stored bytes. */
    fun normalizeStored(json: String): StoredNormalize = try {
        val data = invoke("profileNormalize", JsonObject().apply {
            this["json"] = json
            this["format"] = "stored"
        })
        val supported = if (data.contains("supported")) data.bool("supported") else true
        if (!supported) {
            StoredNormalize.Refused(data.string("reason").ifBlank { "the stored document is not supported by Go" })
        } else {
            val canonical = data.string("json")
            if (canonical.isBlank()) {
                StoredNormalize.Refused("the Go normalizer answered no document")
            } else {
                StoredNormalize.Supported(canonical)
            }
        }
    } catch (failure: Throwable) {
        rethrowCancellation(failure)
        StoredNormalize.Unavailable(failure.message ?: failure.javaClass.simpleName)
    }

    /**
     * Applies the editor form's name override to one canonical stored document:
     * the tag is replaced (not appended) and the result re-normalised, so the
     * row's column name, stored `tag` and the next export agree — what
     * `putOutbound(outbound.name = …)` used to answer.
     */
    fun renameStored(json: String, name: String): StoredNormalize = try {
        val objectValue = JsonInput.parseObjectOrNull(json)
            ?: return StoredNormalize.Refused("the stored document is not a JSON object")
        if (name.isEmpty()) objectValue.remove("tag") else objectValue["tag"] = name
        normalizeStored(objectValue.toCompact())
    } catch (failure: Throwable) {
        rethrowCancellation(failure)
        StoredNormalize.Unavailable(failure.message ?: failure.javaClass.simpleName)
    }

    /** Re-reads one canonical document's stored type/tag after a normalizer answer. */
    fun importedFromJson(json: String, fallbackType: String = ""): ImportedNode {
        val objectValue = JsonInput.parseObjectOrNull(json)
        return ImportedNode(
            type = objectValue?.string("type").orEmpty().ifBlank { fallbackType },
            name = objectValue?.string("tag").orEmpty(),
            json = json,
        )
    }

    /** `profileExport`: the stored row's canonical JSON, share link and JSON link. */
    fun exportStored(json: String): StoredExport = try {
        val data = invoke("profileExport", JsonObject().apply {
            this["json"] = json
        })
        if (!data.bool("supported")) {
            StoredExport.Refused(data.string("reason").ifBlank { "the stored document is not supported by Go" })
        } else {
            StoredExport.Supported(ExportedNode(
                type = data.string("type"),
                name = data.string("name"),
                displayType = data.string("displayType"),
                json = data.string("json"),
                link = data.string("link"),
                jsonLink = data.string("jsonLink"),
            ))
        }
    } catch (failure: Throwable) {
        rethrowCancellation(failure)
        StoredExport.Unavailable(failure.message ?: failure.javaClass.simpleName)
    }

    // ------------------------------------------------------------------------------------------------ shapes

    /**
     * The blank-node editor draft in the exact shape `FlroneProfiles.createNode`
     * answered before the Go move: id 0, the container id, the default name,
     * the display type and the *indented* stored JSON the typed form edits.
     */
    fun createNodeDraft(type: String, compactJson: String, groupId: Long): Map<String, Any?> {
        val canonicalJson = JsonInput.parseObjectOrNull(compactJson)
        val displayType = displayType(type)
        val tag = canonicalJson?.string("tag").orEmpty()
        return mapOf(
            "id" to 0L,
            "groupId" to groupId,
            "name" to tag.ifBlank { displayType.ifBlank { type } },
            "type" to displayType,
            "json" to prettyStored(compactJson),
        )
    }

    /** The canonical stored JSON as the editor's indented text (Kotlin `ProfileJson.text`). */
    fun prettyStored(compact: String): String {
        val objectValue = JsonInput.parseObjectOrNull(compact) ?: return compact
        return ProfileJson.text(objectValue)
    }

    /**
     * The editor's display name: the stored tag, else the type's display
     * address (the old `Outbound.displayName()`), else the display type.
     */
    fun displayName(type: String, name: String, json: String): String =
        name.ifEmpty { displayAddress(type, json) }.ifBlank { displayType(type) }.ifBlank { type }

    /**
     * `Outbound.displayName()` alone: the stored tag, else the address. `decode`
     * asks this (the old editor's draft name did not fall back to the type
     * label for a nameless Chain/AutoSelector document).
     */
    fun storedDisplayName(type: String, name: String, json: String): String =
        name.ifEmpty { displayAddress(type, json) }

    /** `ProxyEntity.displayName()`: the outbound's name, else its display type. */
    fun rowDisplayName(type: String, name: String, json: String): String =
        storedDisplayName(type, name, json).ifEmpty { displayTypeOrStored(type) }

    /**
     * `Outbound.displayAddress()` without the model: `server:port` (IPv6
     * bracketed), Hysteria's realm address when a realm block is active, and
     * Direct's binding label. Empty when the document cannot answer.
     */
    fun displayAddress(type: String, json: String): String {
        val objectValue = JsonInput.parseObjectOrNull(json) ?: return ""
        val canonicalType = canonicalType(type.ifBlank { objectValue.string("type") })
        if (canonicalType == "direct") {
            val bindInterface = objectValue.string("bind_interface")
            if (bindInterface.isNotEmpty()) return "Bind NIC: $bindInterface"
            val inet4 = objectValue.string("inet4_bind_address")
            if (inet4.isNotEmpty()) return "Bind Addr4: $inet4"
            val inet6 = objectValue.string("inet6_bind_address")
            if (inet6.isNotEmpty()) return "Bind Addr6$inet6"
            return "Empty"
        }
        if (canonicalType == "hysteria" && objectValue.string("type") == "hysteria2") {
            val realm = objectValue["realm"] as? JsonObject
            if (realm != null) {
                val url = realm.string("server_url").trim()
                val host = runCatching { java.net.URI(url).host }.getOrNull()
                    ?.takeIf { it.isNotBlank() } ?: url
                val realmId = realm.string("realm_id")
                return if (realmId.isEmpty()) host else "$realmId@$host"
            }
        }
        val server = objectValue.string("server")
        val port = objectValue.int("server_port")
        if (server.isEmpty() && port == 0) return ""
        val host = if (isIpv6Literal(server)) {
            "[" + server.removePrefix("[").removeSuffix("]") + "]"
        } else {
            server
        }
        return "$host:$port"
    }

    /** `Outbound.displayType()` for the node editor's covered types; "" for a blank custom. */
    fun displayType(type: String): String = when (canonicalType(type)) {
        "direct" -> "Direct"
        "http" -> "HTTP"
        "socks" -> "Socks"
        "shadowsocks" -> "Shadowsocks"
        "vmess" -> "VMess"
        "vless" -> "VLESS"
        "trojan" -> "Trojan"
        "hysteria" -> "Hysteria"
        "tuic" -> "TUIC"
        "juicity" -> "Juicity"
        "trusttunnel" -> "TrustTunnel"
        "anytls" -> "AnyTLS"
        "mieru" -> "Mieru"
        "snell" -> "Snell"
        "shadowtls" -> "ShadowTLS"
        "wireguard" -> "WireGuard"
        "masque" -> "MASQUE"
        "openvpn" -> "OpenVPN"
        "openconnect" -> "OpenConnect"
        "ssh" -> "SSH"
        "naive" -> "Naive"
        "chain" -> "Chain Proxy"
        "autoselector" -> "Auto Selector"
        else -> ""
    }

    /** A row's display type with the stored type as the fallback (`ProxyEntity.displayType()`). */
    fun displayTypeOrStored(type: String): String = displayType(type).ifBlank { type }

    /** The four endpoint types; custom documents never reach this helper (legacy path). */
    fun isEndpointType(type: String): Boolean = when (canonicalType(type)) {
        "wireguard", "masque", "openvpn", "openconnect" -> true
        else -> false
    }

    /** `OutboundFactory.canonicalType`: the two stored aliases. */
    fun canonicalType(type: String): String = when (type) {
        "hysteria2" -> "hysteria"
        "openvpn-client" -> "openvpn"
        else -> type
    }

    /** A stored JSON object with `type` and no config envelope, the editor's `parseOutbounds` first branch. */
    fun bareStoredDocument(text: String): JsonObject? {
        val objectValue = JsonInput.parseObjectOrNull(text) ?: return null
        if (!objectValue.contains("type")) return null
        if (objectValue.contains("outbounds") || objectValue.contains("endpoints")) return null
        return objectValue
    }

    /**
     * Whether a row's column type and stored `type` name the same model class.
     *
     * The old row readers built the object from the **column** type and then
     * parsed the JSON into it; a corrupt row whose two names disagree, or a
     * blank/missing type, therefore read as the column's (often Invalid)
     * outbound, not the JSON's. Those rows stay on the Kotlin model path.
     * `custom` is the fourth case: its model rewrites launcher blocks, and
     * `autoselector`'s display address reads the tracked group names through
     * the model, so neither can be read from JSON alone.
     */
    fun rowTypeMatches(json: String, columnType: String): Boolean {
        if (columnType.isBlank()) return false
        when (canonicalType(columnType)) {
            "custom", "autoselector" -> return false
        }
        val jsonType = bareStoredDocument(json)?.string("type").orEmpty()
        if (jsonType.isBlank()) return false
        return canonicalType(jsonType) == canonicalType(columnType)
    }

    // ------------------------------------------------------------------------------------------------ plumbing

    private fun importedNodes(array: JsonArray?): List<ImportedNode> {
        if (array == null) return emptyList()
        val nodes = ArrayList<ImportedNode>(array.size)
        for (raw in array) {
            val node = raw as? JsonObject ?: continue
            nodes.add(ImportedNode(
                type = node.string("type"),
                name = node.string("name"),
                json = node.string("json"),
            ))
        }
        return nodes
    }

    private fun invoke(method: String, data: JsonObject): JsonObject {
        val request = JsonObject()
        request["id"] = "kotlin:profile:" + sequence.incrementAndGet()
        request["method"] = method
        request["data"] = data
        val encoded = transport(request.toCompact())
        val answer = JsonInput.parseObjectOrNull(encoded)
            ?: error("$method answered no action result")
        val code = answer.integer("code")
        if (code != 0L) {
            error(answer.string("data").ifBlank { "$method failed with code $code" })
        }
        return answer["data"] as? JsonObject ?: error("$method answered no data")
    }

    /** IPv6 literals are bracketed by `Hosts.displayAddress`; a bare host with two colons is one. */
    private fun isIpv6Literal(text: String): Boolean {
        val bare = text.removePrefix("[").removeSuffix("]").substringBefore('%')
        return bare.count { it == ':' } >= 2
    }

    private fun rethrowCancellation(failure: Throwable) {
        if (failure is kotlinx.coroutines.CancellationException) throw failure
    }
}