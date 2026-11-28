package io.flrone.bridge

import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.SettingsMapper
import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.Outbound
import io.nekohasekai.sagernet.outbound.OutboundFactory
import io.nekohasekai.sagernet.outbound.distinctNodes
import io.nekohasekai.sagernet.outbound.import.ProfileImport
import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.ui.json.ProfileJson
import io.nekohasekai.sagernet.validation.Issue
import io.nekohasekai.sagernet.validation.Severity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The Kotlin node-editor implementation, kept only as the fallback for inputs
 * the Go profile codec still reports `supported:false` (ADR 0008 S8).
 *
 * `FlroneProfiles` asks [FlroneProfileActions] first: the blank templates, the
 * share-link/body import, the stored normalizer/validator and the stored
 * exporter are Go code now. Go explicitly refuses the cases it does not model
 * yet — WireGuard/MASQUE/OpenVPN/OpenConnect rows, custom documents whose
 * launchers the Kotlin model rewrites, the old Xray corpus, a few advanced
 * fields — and those still need the Throne outbound classes. This file is the
 * one place that names `ProfileImport`, `OutboundFactory` and `Outbound`, so a
 * source audit can prove the routing never silently re-parses a document Go
 * already accepted.
 *
 * The bodies below are the pre-S8 implementations, unchanged except for the
 * injectable [buildContext] (tests run without Android's settings store) and
 * the `commitImportedNode`/`updateImportedNode` entry points: those validate a
 * document Go already normalised, instead of re-running the importer over the
 * user's original text.
 */
internal object FlroneNodeEditorLegacy {

    /** `SettingsMapper.buildContext()` in production; `BuildContext.DEFAULT` in JVM tests. */
    @Volatile
    internal var buildContext: () -> BuildContext = { SettingsMapper.buildContext() }

    // ------------------------------------------------------------------------------------------------ create

    /** The old blank-node seed: [FlroneProfiles] calls this only when Go refused the type. */
    suspend fun createNode(type: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        val outbound = OutboundFactory.newByType(type)
        if (outbound.invalid) error("Unknown proxy type: $type")
        if (outbound.name.isBlank()) outbound.name = outbound.displayType().ifBlank { type }
        val gid = FlroneProfiles.singleNodeGroup()
        mapOf(
            "id" to 0L,
            "groupId" to gid,
            "name" to outbound.name,
            "type" to outbound.displayType(),
            "json" to ProfileJson.text(outbound),
        )
    }

    // ------------------------------------------------------------------------------------------------ parse

    /** The old `parseNodeText`: Throne's own importer, with every report the Go all-or-nothing body path omits. */
    suspend fun parseNodeText(text: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) error("There is nothing to import")
        val parsed = ProfileImport.parse(trimmed, buildContext())
        val nodes = parsed.outbounds.distinctNodes()
        if (nodes.isEmpty()) {
            error(parsed.messages.joinToString("\n").ifBlank { "No supported proxy node found" })
        }
        mapOf(
            "nodes" to nodes.map { outbound ->
                mapOf(
                    "name" to outbound.displayName().ifBlank { outbound.displayType() },
                    "type" to outbound.displayType(),
                    "json" to ProfileJson.text(outbound),
                )
            },
            "skipped" to parsed.reports.size,
            "messages" to parsed.messages,
        )
    }

    /** The old `decode`: a stored/node document, a link or a subscription body becomes the editor's seed. */
    fun decode(uri: String): Map<String, Any?> {
        val raw = uri.trim()
        val wrapped = if (raw.startsWith("sing-box://import-remote-profile", ignoreCase = true)) {
            val query = raw.substringAfter('?')
            query.split('&').firstNotNullOfOrNull { part ->
                val pieces = part.split('=', limit = 2)
                if (pieces.size == 2 && pieces[0].equals("url", ignoreCase = true)) pieces[1] else null
            }?.let { java.net.URLDecoder.decode(it, "UTF-8") }
        } else null
        val target = wrapped ?: raw
        val remote = target.startsWith("http://", ignoreCase = true) || target.startsWith("https://", ignoreCase = true)
        if (remote) {
            val name = runCatching { java.net.URI(target).host }.getOrNull().orEmpty()
            return mapOf(
                "name" to name,
                "url" to target,
                "remote" to true,
                "autoUpdate" to true,
                "interval" to 1440,
                "content" to "",
            )
        }
        val outbounds = parseOutbounds(target)
        return mapOf(
            "name" to outbounds.first().displayName(),
            "url" to "",
            "remote" to false,
            "autoUpdate" to false,
            "interval" to 0,
            "content" to target,
            "nodeCount" to outbounds.size,
        )
    }

    // ------------------------------------------------------------------------------------------------ commit / update

    /** The old `commitNode`: the full importer branch (chain included) and the model save gate. */
    suspend fun commitNode(values: Map<String, Any?>): Map<String, Any?> = withContext(Dispatchers.IO) {
        val content = values["content"] as? String ?: error("Missing node content")
        val name = (values["name"] as? String)?.trim().orEmpty()
        val document = JsonInput.parseObjectOrNull(content)
        val chainDocument = document?.takeIf { it.string("type") == "chain" }
        val outbound = if (chainDocument != null) {
            OutboundFactory.newByType("chain").also {
                if (it.invalid || !it.parseFromJson(chainDocument)) error("Invalid chain node")
            }
        } else {
            parseOutbounds(content).singleOrNull() ?: error("The content must describe exactly one node")
        }
        addOne(outbound, name)
    }

    /**
     * Validates and stores one node Go already normalised. The canonical
     * document is parsed with the model's database loader (no import-time
     * drops), which is what the old editor's factory-first branch did; if the
     * model does not own the canonical type either, the full old path runs.
     */
    suspend fun commitImportedNode(
        values: Map<String, Any?>,
        node: FlroneProfileActions.ImportedNode,
    ): Map<String, Any?> = withContext(Dispatchers.IO) {
        val name = (values["name"] as? String)?.trim().orEmpty()
        val outbound = parseStored(node.json) ?: return@withContext commitNode(values)
        addOne(outbound, name)
    }

    /** The old `updateNode`: content replaces the row, then the form's name override applies. */
    suspend fun updateNode(id: Long, name: String?, content: String?): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = ProfileManager.getProfile(id) ?: error("No proxy with id $id")
        val text = content?.trim().orEmpty()
        if (text.isNotEmpty() && text != "{}") {
            val inbound = parseOutbounds(text)
            if (inbound.size != 1) error("The content must describe exactly one node, got ${inbound.size}")
            val outbound = inbound.single()
            validate(outbound)
            profile.putOutbound(outbound)
        }
        val renamed = name?.trim().orEmpty()
        if (renamed.isNotEmpty() && renamed != profile.displayName()) {
            val outbound = profile.outbound
            outbound.name = renamed
            profile.putOutbound(outbound)
        }
        ProfileManager.updateProfile(profile)
        FlroneBridge.scheduleRefresh(immediate = true)
        nodeInfo(profile.id)
    }

    /** The same update over a canonical document Go already normalised. */
    suspend fun updateImportedNode(
        profile: ProxyEntity,
        node: FlroneProfileActions.ImportedNode,
        name: String?,
    ): Map<String, Any?> = withContext(Dispatchers.IO) {
        val outbound = parseStored(node.json)
            ?: return@withContext updateNode(profile.id, name, node.json)
        validate(outbound)
        profile.putOutbound(outbound)
        val renamed = name?.trim().orEmpty()
        if (renamed.isNotEmpty() && renamed != profile.displayName()) {
            val current = profile.outbound
            current.name = renamed
            profile.putOutbound(current)
        }
        ProfileManager.updateProfile(profile)
        FlroneBridge.scheduleRefresh(immediate = true)
        nodeInfo(profile.id)
    }

    // ------------------------------------------------------------------------------------------------ reads

    /** The old `nodeConfig`: the model's re-export, indented, plus the endpoint flag. */
    suspend fun nodeConfig(id: Long): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = ProfileManager.getProfile(id) ?: error("No proxy with id $id")
        val outbound = profile.outbound
        mapOf(
            "id" to profile.id,
            "name" to profile.displayName(),
            "json" to ProfileJson.text(outbound),
            "endpoint" to outbound.isEndpoint(),
        )
    }

    /** The old `nodeInfo`: the row's share link (or loss-less JSON link) and the model display type. */
    suspend fun nodeInfo(id: Long): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = ProfileManager.getProfile(id) ?: error("No proxy with id $id")
        mapOf(
            "id" to profile.id,
            "name" to profile.displayName(),
            "type" to profile.displayType(),
            "content" to profile.exportLink().ifBlank { profile.exportJsonLink() },
        )
    }

    // ------------------------------------------------------------------------------------------------ shared parse

    /** The old `parseOutbounds`: one stored document, else Throne's importer, deduplicated by server. */
    internal fun parseOutbounds(text: String): List<Outbound> {
        // The node editor saves the canonical sing-box JSON of ONE outbound. ProfileImport
        // intentionally wraps a bare outbound in `Custom` to stay loss-less for paste, but
        // feeding an edited VLESS/Trojan row through that path turned it into a custom
        // config. A typed document with no outbounds/endpoints is a single proxy node.
        val document = JsonInput.parseObjectOrNull(text)
        if (document != null &&
            document.contains("type") &&
            !document.contains("outbounds") &&
            !document.contains("endpoints")
        ) {
            OutboundFactory.fromJson(document)?.takeIf { !it.invalid }?.let { return listOf(it) }
        }
        val parsed = ProfileImport.parse(
            text,
            buildContext(),
        )
        if (parsed.outbounds.isEmpty()) {
            error(parsed.messages.joinToString("\n").ifBlank { "No supported proxy node found" })
        }
        // A pasted subscription/list often repeats a server under several remarks; the group should
        // receive one row per server, not one per line.
        return parsed.outbounds.distinctNodes()
    }

    private fun parseStored(json: String): Outbound? {
        val document = JsonInput.parseObjectOrNull(json) ?: return null
        return OutboundFactory.fromJson(document)?.takeIf { !it.invalid }
    }

    private suspend fun addOne(outbound: Outbound, name: String): Map<String, Any?> {
        if (name.isNotEmpty()) outbound.name = name
        validate(outbound)
        val gid = FlroneProfiles.singleNodeGroup()
        val entity = ProfileManager.addProfile(outbound, gid)
        FlroneBridge.scheduleRefresh(immediate = true)
        return nodeInfo(entity.id)
    }

    private fun validate(outbound: Outbound) {
        val issues = ArrayList<Issue>()
        outbound.validate(issues, buildContext())
        issues.filter { it.severity == Severity.Error }
            .firstOrNull()?.let { error(listOf(it.field, it.message).filter(String::isNotBlank).joinToString(": ")) }
    }
}