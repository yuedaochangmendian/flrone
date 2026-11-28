package io.flrone.bridge

import io.flrone.flutter.ServiceBridge
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.GroupRepo
import io.nekohasekai.sagernet.database.GroupSort
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.SortInput
import io.nekohasekai.sagernet.database.StoredProfile
import io.nekohasekai.sagernet.database.isSingleNodeGroup
import io.nekohasekai.sagernet.document.json.JsonInput
import io.nekohasekai.sagernet.database.SendHwid
import io.nekohasekai.sagernet.database.SubHttpVersion
import io.nekohasekai.sagernet.database.SubTlsVersion
import io.nekohasekai.sagernet.database.SubscriptionOptions
import io.nekohasekai.sagernet.bg.autoselector.AutoSelectorRuntime
import io.nekohasekai.sagernet.group.GroupRevisions
import io.nekohasekai.sagernet.group.SubscriptionScheduler
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ui.settings.SettingChecks
import io.nekohasekai.sagernet.validation.Empty
import io.nekohasekai.sagernet.validation.Validation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * The catalog writes the ported UI can make, in Throne's own terms.
 *
 * B-box's "profile" is what Throne calls a group — a tab that is either a subscription or a hand-filled list — so a
 * create here is a group create and a reorder here is Throne's display order, not a list the UI keeps.
 *
 * The configuration editor's group manifest (`config`/`read`/`write`) is no longer here: it only reads and edits the
 * same `profiles.json` document Dart owns, so it moved to Dart's `ProfileDocumentService` (its revision guard, key
 * whitelist and membership equality live there). What remains here needs the auto-selector runtime and the narrow side
 * effects the duty table names (`revision.edit` before a configuration save, `subscription.schedule` after a URL edit).
 * Every subscription fetch/refresh is dispatched to the service engine's Dart owner queue; the only platform fetch left
 * is the `subscription.fetch` host seam (`SubscriptionHostFetch`).
 *
 * S8: the node editor's document codec is the Go kernel
 * ([FlroneProfileActions]: profileNewOutbound/profileImport/profileNormalize/
 * profileValidate/profileExport), including the group-content import. A
 * `supported:false` refusal is the editor's error text; there is no Kotlin
 * importer/model fallback any more. The mux/fragment/TLS-tricks override
 * editor lives in [FlroneNodeTuning], which reads the stored columns directly.
 */
object FlroneProfiles {

    /** A file opened from outside is read whole, so a document the size of a video is refused up front. */
    private const val MAX_IMPORT_BYTES = 16 * 1024 * 1024

    /**
     * Creates or renames a group. [url] empty means a local list; otherwise it is a subscription, which is fetched
     * and validated *before* the group exists: a bad URL, an HTTP error or a body without a single node throws and
     * leaves nothing behind, and a usable body's nodes are stored right away (FlClash's add does the same,
     * models/profile.dart:201-214).
     *
     * A new local group may also carry `content`: one share link, a base64 subscription, or a whole JSON/YAML
     * document. It is parsed with Throne's own importer *before* the group is created, so an invalid import leaves
     * nothing behind, and its outbounds become the group's nodes.
     */
    suspend fun save(values: Map<String, Any?>): Long = withContext(Dispatchers.IO) {
        val id = (values["id"] as? Number)?.toLong() ?: 0L
        val name = values["name"] as? String
        val url = values["url"] as? String
        val autoUpdate = values["autoUpdate"] as? Boolean
        val interval = (values["interval"] as? Number)?.toInt()
        val content = values["content"] as? String

        val group = (if (id > 0L) GroupRepo.get(id) else null) ?: ProxyGroup()
        val previousUrl = group.url
        if (name != null) group.name = name.trim()
        if (url != null) group.url = url.trim()
        val urlChanged = previousUrl.trim() != group.url.trim()
        // The Dart owner queue is the only subscription refresh path (S6). A
        // scheme the Dart transport and the `subscription.fetch` host seam cannot
        // read (anything outside http(s)/content://, or an empty URL) has no
        // Kotlin fallback any more, so a create or a URL edit is refused here —
        // before anything is written — with the reason as the error text.
        if (group.isSubscription && (id <= 0L || urlChanged)) {
            FlroneCommands.subscriptionFetchError(group)?.let { error(it) }
        }
        // The editor no longer requires a subscription name. An existing one
        // whose name was cleared takes its URL host; a new one prefers the
        // server's Profile-Title once the body has been fetched (below).
        if (id > 0L && group.isSubscription && group.name.isBlank()) {
            group.name = subscriptionHost(group.url)
        }
        if (autoUpdate != null) group.skipAutoUpdate = !autoUpdate
        if (interval != null) {
            // The scheduler's floor is 30 minutes; clamp here so the card does
            // not show 15 while refreshes actually run every 30.
            group.subOptions.updateInterval = if (interval <= 0) {
                0
            } else {
                maxOf(interval, SubscriptionScheduler.MIN_INTERVAL_MINUTES)
            }
        }

        // A new subscription is downloaded and validated before its row is inserted: an unreachable server, an HTTP
        // error or a body without a single node must not leave a half-created group whose only feedback is a later
        // queue report. The fetched answer is then applied to the group, so a valid subscription is not downloaded a
        // second time. Editing an existing one saves first and refreshes only when the URL changed (below).
        if (id <= 0L && group.isSubscription) {
            val urlError = subscriptionUrlError(group.url)
            if (urlError.isNotEmpty()) error(urlError)

            // S6: the create runs in the Dart service engine, which owns
            // profiles.json: fetch → validate → create group → apply nodes
            // happens there, so no empty group is left on a refusal and the
            // Kotlin fetch/queue path is gone. Plain http(s) URLs use the Dart
            // transport; content:// rides the same create through the service
            // engine's `subscription.fetch` host seam, whose ContentResolver
            // read is Kotlin's own SubscriptionFetch.
            val payload = mapOf(
                "name" to group.name,
                "url" to group.url.trim(),
                "subOptionsJson" to group.subOptions.toJsonString(),
                "autoUpdate" to !group.skipAutoUpdate,
                "foreground" to true,
            )
            // Only the small editor payload crosses the channel. It never
            // carries credentials and is never logged.
            val reply = ServiceBridge.requestSubscriptionAwait("subscription.create", payload)
            val gid = (reply as? Map<*, *>)?.get("gid") as? Number
                ?: error("subscription.create did not return a group id")
            SubscriptionScheduler.schedule()
            FlroneBridge.scheduleRefresh(immediate = true)
            return@withContext gid.toLong()
        }

        // `{}` is the editor's own "new empty group" seed, not an import to parse.
        // S8: the group's pasted content goes through the same Go codec as the
        // node editor: one stored document is normalised, a link/subscription
        // body is imported (deduplicated by the Go importer). A Go refusal is
        // the user-visible error; there is no second Kotlin importer.
        val import = if (id <= 0L && !group.isSubscription) {
            val text = content?.trim().orEmpty()
            if (text.isEmpty() || text == "{}") emptyList() else parseGroupContent(text)
        } else {
            emptyList()
        }
        // A single imported node joins the single-node container, not a profile of its own:
        // it shows up in the node page and the profile grid stays the subscription view.
        // The form's name renames the node itself.
        if (id <= 0L && !group.isSubscription && import.size == 1) {
            val target = singleNodeGroup()
            var node = import.single()
            val renamed = name?.trim().orEmpty()
            if (renamed.isNotEmpty() && renamed != rowDisplayName(node)) {
                node = renameNode(node, renamed)
            }
            val added = ProfileManager.addStoredProfileBatch(storedRows(listOf(node)), target)
            GroupRepo.setCurrent(target)
            added.singleOrNull()?.let { FlroneCommands.select(it.id) }
            FlroneBridge.scheduleRefresh(immediate = true)
            return@withContext target
        }
        if (group.name.isNullOrBlank() && import.size == 1) group.name = rowDisplayName(import.single())

        val saved = if (group.id > 0L) {
            // The form is a user edit: an update already downloading this group's answer is stale from here on
            // (newest intent wins, GroupRevisions). Bumped before the document write, so an answer that passed its
            // own check just before cannot land on top of this row.
            GroupRevisions.edit(group.id)
            GroupRepo.save(group)
            group.id
        } else {
            GroupRepo.add(group).id
        }
        if (import.isNotEmpty()) {
            val added = ProfileManager.addStoredProfileBatch(storedRows(import), saved)
            GroupRepo.setCurrent(saved)
            // A single imported node is what the user asked to use; a whole subscription stays unselected until chosen.
            added.singleOrNull()?.let { FlroneCommands.select(it.id) }
        }
        if (group.isSubscription && urlChanged) {
            // A save is not implicitly a refresh: renaming a subscription or
            // changing its auto-update switch must not download the body
            // again. A URL edit is the one save that invalidates the nodes, so
            // it still refreshes immediately (FlClash's edit page does the
            // same) — through the Dart owner queue, the only refresh path left.
            ServiceBridge.requestSubscription(
                "subscription.refresh",
                mapOf("gid" to saved, "showDiff" to false),
            )
        }
        // Re-plan even when the URL became empty or the group became local: a
        // stale timer must not keep refreshing a group that no longer is one.
        SubscriptionScheduler.schedule()
        FlroneBridge.scheduleRefresh(immediate = true)
        saved
    }

    // ------------------------------------------------------------------------------------------------ group settings

    /** The fetcher reads content:// URLs (a picked file) too, and those carry no host — the native form's rule. */
    private fun subscriptionUrlError(text: String): String {
        if (text.startsWith("content://", ignoreCase = true)) return ""
        return Validation.url(text, SettingChecks.HTTP, Empty.Required)
    }

    /** The name an unnamed subscription falls back to: its URL host, or a neutral label. */
    private fun subscriptionHost(url: String): String {
        val host = runCatching { java.net.URI(url.trim()).host }.getOrNull()
            ?.trim()
            ?.removePrefix("www.")
        return host?.takeIf { it.isNotEmpty() } ?: "Subscription"
    }

    /**
     * Turns imported text into something the editor can open, on an IO dispatcher. See [decode].
     */
    suspend fun decodeIntent(uri: String): Map<String, Any?> = withContext(Dispatchers.IO) { decode(uri) }

    /**
     * Turns a file the platform handed us into what the UI should do with it, keyed by `backup` or by the editor's
     * own shape. A "THRN" container opens the restore, because the importer cannot read one and a parse error is
     * not an answer the user can act on; anything else is read as text and decoded the way [decodeIntent] decodes
     * imported text, so a shared document holding a link, a base64 subscription or a JSON config opens the editor.
     */
    suspend fun decodeFile(uriString: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        val uri = android.net.Uri.parse(uriString)
        val bytes = app.contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: error("The file could not be read")
        if (bytes.size > MAX_IMPORT_BYTES) error("The file is too large to import")
        val backup = FlroneBackup.open(bytes)
        // The envelope carries the container; its absence is the importer's turn.
        if (backup != null) return@withContext mapOf("backup" to backup)
        decode(String(bytes, Charsets.UTF_8))
    }

    /**
     * Turns imported text into something the editor can open. Subscriptions arrive either as a plain link or wrapped
     * by the core's own `sing-box://import-remote-profile`; anything else — a share link, a base64 subscription, a
     * JSON or YAML document — goes through the Go codec (S8), so a single `ss://`/`vmess://`/`vless://` node
     * opens with its own name instead of failing the sing-box JSON check. A `supported:false` refusal is the
     * user-visible error text.
     */
    private fun decode(uri: String): Map<String, Any?> {
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
                // Imported subscriptions start on a daily refresh; the editor
                // lets the user lower it (30 min floor) before saving.
                "interval" to 1440,
                "content" to "",
            )
        }
        when (val parsed = FlroneProfileActions.parseEditorNode(target)) {
            is FlroneProfileActions.EditorParse.Nodes -> {
                val nodes = parsed.nodes
                if (nodes.isNotEmpty()) {
                    val first = nodes.first()
                    return mapOf(
                        "name" to rowDisplayName(first),
                        "url" to "",
                        "remote" to false,
                        "autoUpdate" to false,
                        "interval" to 0,
                        "content" to target,
                        "nodeCount" to nodes.size,
                    )
                }
                error("No supported proxy node found")
            }
            is FlroneProfileActions.EditorParse.Refused -> error(parsed.reason)
            is FlroneProfileActions.EditorParse.Unavailable ->
                error("The profile codec is unavailable: ${parsed.message}")
        }
    }

    /** The share link of one node, falling back to the stored document's JSON link when the protocol has no standard URI. */
    suspend fun nodeLink(groupTag: String, nodeTag: String, jsonLink: Boolean = false): String =
        withContext(Dispatchers.IO) {
            val group = GroupRepo.all().firstOrNull { it.displayName() == groupTag }
                ?: error("No proxy group named $groupTag")
            val profile = ProfileManager.members(group.id).firstOrNull { it.displayName() == nodeTag }
                ?: error("No proxy named $nodeTag in ${group.displayName()}")
            val link = if (jsonLink) {
                jsonLinkOf(profile)
            } else {
                when (val exported = FlroneProfileActions.exportStored(profile.outboundJson)) {
                    is FlroneProfileActions.StoredExport.Supported ->
                        exported.node.link.takeIf { it.contains("://") }.orEmpty()
                            .ifBlank { exported.node.jsonLink }
                    // Types the stored exporter has no share URI for (custom,
                    // chain, autoselector) keep the loss-less JSON link.
                    is FlroneProfileActions.StoredExport.Refused,
                    is FlroneProfileActions.StoredExport.Unavailable,
                    -> jsonLinkOf(profile)
                }
            }
            if (link.isBlank()) error("${profile.displayName()} cannot be shared as a link")
            link
        }

    /**
     * The editor's seed for one node: its name, type and the share link it can be
     * edited from. S8: the Go `profileExport` exporter answers every link-bearing
     * type; a type it has no URI for (custom, chain, autoselector) keeps the
     * loss-less JSON link of its stored document.
     */
    private suspend fun nodeInfo(id: Long): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = ProfileManager.getProfile(id) ?: error("No proxy with id $id")
        if (!FlroneProfileActions.rowTypeMatches(profile.outboundJson, profile.type)) {
            return@withContext rawNodeInfo(profile)
        }
        when (val exported = FlroneProfileActions.exportStored(profile.outboundJson)) {
            is FlroneProfileActions.StoredExport.Supported -> {
                val node = exported.node
                val storedType = node.type.ifBlank { profile.type }
                mapOf(
                    "id" to profile.id,
                    "name" to FlroneProfileActions.rowDisplayName(storedType, node.name, node.json),
                    "type" to node.displayType.ifBlank { FlroneProfileActions.displayTypeOrStored(storedType) },
                    // The old nodeInfo used exportLink() only when it looked like
                    // a URI and otherwise answered exportJsonLink() (Direct's
                    // query-only link is the case that matters).
                    "content" to node.link.takeIf { it.contains("://") }.orEmpty()
                        .ifBlank { node.jsonLink },
                )
            }
            is FlroneProfileActions.StoredExport.Refused,
            is FlroneProfileActions.StoredExport.Unavailable,
            -> rawNodeInfo(profile)
        }
    }

    /** [nodeInfo] for a row the exporter has no URI for: the stored document's own JSON link. */
    private fun rawNodeInfo(profile: ProxyEntity): Map<String, Any?> = mapOf(
        "id" to profile.id,
        "name" to profile.displayName(),
        "type" to profile.displayType(),
        "content" to jsonLinkOf(profile).ifBlank { profile.outboundJson },
    )

    /**
     * Creates a fresh node of [type] in the single-node container and answers its editor
     * seed, so the typed form can open on it and the user fills the fields. The default
     * name is the protocol's own display type; the empty server/port keep it unselectable
     * until saved.
     *
     * S8: `profileNewOutbound` owns the blank stored template for all 25
     * creatable types, byte-for-byte the deleted Kotlin factory's
     * `newByType(type).exportToJson()`; an unknown type is the action's refusal.
     */
    suspend fun createNode(type: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        val template = FlroneProfileActions.newOutbound(type)
            ?: error(
                if (StoredProfile.isKnownType(type)) {
                    "The profile codec cannot create $type"
                } else {
                    "Unknown proxy type: $type"
                },
            )
        val gid = singleNodeGroup()
        FlroneProfileActions.createNodeDraft(type, template, gid)
    }

    /**
     * The group manually imported single nodes live in — Throne's Default group,
     * created on first use.
     *
     * Single nodes are their own mode, not extra rows inside a subscription, so the
     * clipboard import and the typed node form target this container, creating it on
     * that first write. Reads never create it (the node page's list reads the document
     * directly in Dart now). The profile grid hides it: that list is the
     * subscription/local-config view.
     */
    private suspend fun singleNodeGroup(): Long = defaultGroup().id

    /**
     * The narrow Kotlin remainder of `clearTestResults` (the clear itself is Dart's
     * now): a group kept sorted BY_TEST_RESULT/BY_LATENCY must reposition the rows
     * whose test columns just changed. The sort keys read the parsed outbound model,
     * so this one duty stays here rather than becoming a second implementation in
     * Dart. [GroupSort.repositionLater] queues the work and returns; the queue
     * reloads the group if the order actually moved.
     */
    suspend fun repositionTestResults(groupId: Long): Unit = withContext(Dispatchers.IO) {
        GroupSort.repositionLater(ProfileManager.memberIds(groupId), SortInput.TEST_RESULT)
    }

    /**
     * Deletes empty single-node containers — the hidden "Default" configurations the
     * profile grid never shows.
     *
     * A document can hold more than one: an older build seeded a group with no name
     * (rendered with the localized default label) and a later import created the
     * flagged container beside it, so the node-page pickers listed "Default" twice.
     * The container that holds nodes is kept; every other empty one is a leftover.
     * When none holds nodes, the first stays as the container.
     *
     * The document is the only writer (ADR 0005), so the delete goes through
     * [GroupRepo.delete], which also drops the group's routing profile and points the
     * current group elsewhere; a selection that named the group or a member of it is
     * cleared there too. Both [GroupRepo.delete] and the Dart document refuse to
     * delete the last group of a catalog, so a lone container is kept until another
     * group exists.
     */
    private suspend fun pruneEmptyNodeContainer() {
        val containers = GroupRepo.rawGroups().filter { it.isSingleNodeGroup() }
        if (containers.isEmpty()) return
        val keep = containers.firstOrNull { ProfileManager.memberIds(it.id).isNotEmpty() }
            ?: containers.first()
        var removed = false
        for (group in containers) {
            if (group.id == keep.id || ProfileManager.memberIds(group.id).isNotEmpty()) continue
            if (GroupRepo.delete(group.id)) {
                Logs.i("[Profiles] removed the empty single-node container ${group.id}")
                removed = true
            }
        }
        if (removed) FlroneBridge.scheduleRefresh(immediate = true)
    }

    /**
     * Single-node import's parse step: one share link, a list of them or a base64 subscription
     * becomes the editor's seed rows. The Go importer runs in its tolerant mode: supported
     * entries are imported and every refused line is counted/reported, so one bad entry no
     * longer discards a whole paste. A single-link refusal is still the user-visible error.
     */
    suspend fun parseNodeText(text: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        when (val imported = FlroneProfileActions.importText(text)) {
            is FlroneProfileActions.ImportOutcome.Supported -> {
                val nodes = imported.nodes
                if (nodes.isEmpty()) error("No supported proxy node found")
                mapOf(
                    "nodes" to nodes.map { node ->
                        mapOf(
                            "name" to FlroneProfileActions.displayName(node.type, node.name, node.json),
                            "type" to StoredProfile.displayType(node.type, node.json),
                            "json" to FlroneProfileActions.prettyStored(node.json),
                        )
                    },
                    // The partial importer keeps the old per-entry contract: a
                    // refused line is counted and its reason reported while the
                    // supported entries still reach the form.
                    "skipped" to imported.skipped,
                    "messages" to imported.messages,
                )
            }
            is FlroneProfileActions.ImportOutcome.Refused -> error(imported.reason)
            is FlroneProfileActions.ImportOutcome.Unavailable ->
                error("The profile codec is unavailable: ${imported.message}")
        }
    }

    /** The new-node form's save: parse, validate and add exactly one row. */
    suspend fun commitNode(values: Map<String, Any?>): Map<String, Any?> = withContext(Dispatchers.IO) {
        val content = values["content"] as? String ?: error("Missing node content")
        val name = (values["name"] as? String)?.trim().orEmpty()
        val node = parseOne(content, "The content must describe exactly one node")
        val canonical = validateAndCanonicalize(node)
        // The new-node form's name (unlike the edit form's) is applied
        // unconditionally when the field is non-empty.
        val named = if (name.isEmpty()) canonical else renameNode(canonical, name)
        val gid = singleNodeGroup()
        val entity = ProfileManager.addStoredProfile(named.type, named.name, named.json, gid)
        FlroneBridge.scheduleRefresh(immediate = true)
        nodeInfo(entity.id)
    }

    /** The typed form's seed: the node's canonical stored JSON, which the form reads and writes. */
    suspend fun nodeConfig(id: Long): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = ProfileManager.getProfile(id) ?: error("No proxy with id $id")
        when (val normalized = FlroneProfileActions.normalizeStored(storedDocument(profile))) {
            is FlroneProfileActions.StoredNormalize.Supported -> {
                val json = normalized.json
                val stored = FlroneProfileActions.importedFromJson(json, profile.type)
                mapOf(
                    "id" to profile.id,
                    "name" to FlroneProfileActions.rowDisplayName(stored.type, stored.name, json),
                    "json" to FlroneProfileActions.prettyStored(json),
                    "endpoint" to StoredProfile.isEndpoint(profile.type, profile.outboundJson),
                )
            }
            // A row the normalizer cannot canonicalise (a corrupt/unknown
            // document, or an action bus that is not there) still opens: the
            // form shows the stored bytes instead of re-serialising them
            // through a type it does not know.
            is FlroneProfileActions.StoredNormalize.Refused,
            is FlroneProfileActions.StoredNormalize.Unavailable,
            -> mapOf(
                "id" to profile.id,
                "name" to profile.displayName(),
                "json" to FlroneProfileActions.prettyStored(storedDocument(profile)),
                "endpoint" to StoredProfile.isEndpoint(profile.type, profile.outboundJson),
            )
        }
    }

    /**
     * Renames a node and/or replaces its outbound with one share link or JSON document. The content
     * must describe exactly one node — a whole subscription belongs to a group save, not here. The
     * parsed row goes through Go's stored validator; a refusal is the user-visible error.
     */
    suspend fun updateNode(id: Long, name: String?, content: String?): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = ProfileManager.getProfile(id) ?: error("No proxy with id $id")
        val text = content?.trim().orEmpty()
        val renamed = name?.trim().orEmpty()
        if (text.isNotEmpty() && text != "{}") {
            val node = parseOne(text, "The content must describe exactly one node")
            val canonical = validateAndCanonicalize(node)
            val named = applyNameOverride(canonical, renamed)
            profile.type = named.type
            profile.name = named.name
            profile.outboundJson = named.json
            ProfileManager.updateProfile(profile)
            FlroneBridge.scheduleRefresh(immediate = true)
            nodeInfo(profile.id)
        } else {
            // A name-only edit is not a content replacement: the old path parsed
            // the row, renamed it and wrote it back. Keep the canonical document
            // and the name key in step, and leave the JSON untouched when the
            // name already reads the same.
            if (renamed.isEmpty()) {
                ProfileManager.updateProfile(profile)
                FlroneBridge.scheduleRefresh(immediate = true)
                return@withContext nodeInfo(profile.id)
            }
            val normalized = when (val result = FlroneProfileActions.normalizeStored(storedDocument(profile))) {
                is FlroneProfileActions.StoredNormalize.Supported -> result.json
                is FlroneProfileActions.StoredNormalize.Refused -> error(result.reason)
                is FlroneProfileActions.StoredNormalize.Unavailable ->
                    error("The profile codec is unavailable: ${result.message}")
            }
            val stored = FlroneProfileActions.importedFromJson(normalized, profile.type)
            val display = FlroneProfileActions.rowDisplayName(stored.type, stored.name, normalized)
            if (renamed == display) {
                ProfileManager.updateProfile(profile)
                FlroneBridge.scheduleRefresh(immediate = true)
                return@withContext nodeInfo(profile.id)
            }
            val finalNode = renameNode(stored, renamed)
            profile.type = finalNode.type
            profile.name = finalNode.name
            profile.outboundJson = finalNode.json
            ProfileManager.updateProfile(profile)
            FlroneBridge.scheduleRefresh(immediate = true)
            nodeInfo(profile.id)
        }
    }

    /** The form's name rule (`putOutbound`): the name key changes only when the requested name differs from the display name. */
    private fun applyNameOverride(
        node: FlroneProfileActions.ImportedNode,
        requested: String,
    ): FlroneProfileActions.ImportedNode {
        val currentDisplay = FlroneProfileActions.rowDisplayName(node.type, node.name, node.json)
        if (requested.isEmpty() || requested == currentDisplay) return node
        return renameNode(node, requested)
    }

    private fun renameNode(
        node: FlroneProfileActions.ImportedNode,
        name: String,
    ): FlroneProfileActions.ImportedNode =
        when (val renamed = FlroneProfileActions.renameStored(node.json, name)) {
            is FlroneProfileActions.StoredNormalize.Supported ->
                FlroneProfileActions.importedFromJson(renamed.json, node.type)
            is FlroneProfileActions.StoredNormalize.Refused -> error(renamed.reason)
            is FlroneProfileActions.StoredNormalize.Unavailable ->
                error("The profile codec is unavailable: ${renamed.message}")
        }

    /** One parsed/normalised node, validated with the Go stored validator and canonicalised. */
    private fun validateAndCanonicalize(node: FlroneProfileActions.ImportedNode): FlroneProfileActions.ImportedNode =
        when (val validation = FlroneProfileActions.validateStored(node.json)) {
            is FlroneProfileActions.StoredValidation.Supported -> {
                validation.issues.firstOrNull { it.severity == "error" }?.let { error(it.describe()) }
                if (!validation.ok) error("The stored document is invalid")
                if (validation.normalized.isBlank()) {
                    node
                } else {
                    FlroneProfileActions.importedFromJson(validation.normalized, node.type)
                }
            }
            is FlroneProfileActions.StoredValidation.Refused -> error(validation.reason)
            is FlroneProfileActions.StoredValidation.Unavailable ->
                error("The profile codec is unavailable: ${validation.message}")
        }

    /** The editor's parse step for a document that must hold exactly one node. */
    private fun parseOne(text: String, tooMany: String): FlroneProfileActions.ImportedNode =
        when (val parsed = FlroneProfileActions.parseEditorNode(text)) {
            is FlroneProfileActions.EditorParse.Nodes -> {
                if (parsed.nodes.isEmpty()) error("No supported proxy node found")
                if (parsed.nodes.size != 1) error(tooMany)
                parsed.nodes.single()
            }
            is FlroneProfileActions.EditorParse.Refused -> error(parsed.reason)
            is FlroneProfileActions.EditorParse.Unavailable ->
                error("The profile codec is unavailable: ${parsed.message}")
        }

    /** A group create's pasted content: one stored document, a link or a whole body, all through Go. */
    private fun parseGroupContent(text: String): List<FlroneProfileActions.ImportedNode> =
        when (val parsed = FlroneProfileActions.parseEditorNode(text)) {
            is FlroneProfileActions.EditorParse.Nodes ->
                if (parsed.nodes.isEmpty()) error("No supported proxy node found") else parsed.nodes
            is FlroneProfileActions.EditorParse.Refused -> error(parsed.reason)
            is FlroneProfileActions.EditorParse.Unavailable ->
                error("The profile codec is unavailable: ${parsed.message}")
        }

    private fun storedRows(nodes: List<FlroneProfileActions.ImportedNode>): List<ProfileManager.StoredRow> =
        nodes.map { ProfileManager.StoredRow(it.type, it.name, it.json) }

    private fun rowDisplayName(node: FlroneProfileActions.ImportedNode): String =
        FlroneProfileActions.rowDisplayName(node.type, node.name, node.json)

    private fun jsonLinkOf(profile: ProxyEntity): String =
        StoredProfile.jsonLink(profile.type, profile.outboundJson)

    /** The row's stored document; a blank column answers the type's Go template (the old model's defaults). */
    private fun storedDocument(profile: ProxyEntity): String =
        profile.outboundJson.ifBlank { FlroneProfileActions.newOutbound(profile.type).orEmpty() }

    /** Deletes one node from its group; the group itself stays, except an emptied single-node container. */
    suspend fun deleteNode(id: Long): Unit = withContext(Dispatchers.IO) {
        val profile = ProfileManager.getProfile(id) ?: error("No proxy with id $id")
        ProfileManager.deleteProfile(profile.groupId, id)
        // The last node of the container takes the container with it: an empty one is a
        // hidden configuration the profile grid never shows.
        pruneEmptyNodeContainer()
        FlroneBridge.scheduleRefresh(immediate = true)
    }

    // ------------------------------------------------------------------------------------- auto selector

    /**
     * The running selector's status (AutoSelectorStatus.toJson); the phase is "idle" when nothing runs.
     *
     * S7: the editor's document state (`info`/`save`/`pin`/`create`) moved to Dart's
     * `ProfileDocumentService` — the selector row is the same `profiles.json` document Dart owns.
     * What remains here is only the runtime shadow: this status read, [autoSelectorRuntimePin] and
     * [autoSelectorRecheck] all belong to the kernel-backed service engine.
     */
    suspend fun autoSelectorStatus(): Any? = withContext(Dispatchers.IO) {
        val json = AutoSelectorRuntime.statusJson(withMembers = true)
        val text = if (!FlroneKernel.ffiMode) {
            json
        } else {
            // In ffiMode the selector runs inside the box Dart owns: this runtime never attaches to
            // it, so the status is idle even while the core is ranking. Say who holds it instead of
            // letting the page report "not running" for a selector that is working.
            runCatching {
                val root = org.json.JSONObject(json)
                if (root.optString("phase") == "idle") root.put("driver", "ffi").toString() else json
            }.getOrDefault(json)
        }
        // The platform channel encodes maps, not JSON text: the status page
        // reads the reply as a document (`json(raw)`).
        JsonInput.parseObjectOrNull(text) ?: text
    }

    /**
     * Tells the runtime shadow that a pin was chosen. The pin itself is stored first by Dart in
     * `profiles.json`; there is no host-owned core to take it now (as in FFI mode before), so the
     * shadow only reports the result as a status notice. A negative [memberId] returns to automatic.
     */
    suspend fun autoSelectorRuntimePin(memberId: Long): Unit = withContext(Dispatchers.IO) {
        AutoSelectorRuntime.select(memberId)
    }

    /** Re-probes every member of the running selector now. */
    suspend fun autoSelectorRecheck(): Unit = withContext(Dispatchers.IO) {
        AutoSelectorRuntime.recheck()
    }

    // The node page's mux/fragment/TLS-tricks overrides live in FlroneNodeTuning:
    // they read and write the Kotlin model's Multiplex/Tls fields, which the Go
    // profile codec does not model. Keeping them out of this file makes the
    // node-editor routing audit honest about the one remaining model dependency.

    /**
     * The single-node container, created (and flagged) when it does not exist yet.
     *
     * The document flag is the marker; a container created before it existed is
     * recognised by the default name and backfilled on first use, so the name
     * match never has to survive a rename or a translation change.
     */
    private suspend fun defaultGroup(): ProxyGroup {
        val existing = GroupRepo.rawGroups().firstOrNull { it.isSingleNodeGroup() }
        if (existing != null) {
            if (!existing.single) {
                existing.single = true
                GroupRepo.save(existing)
            }
            return existing
        }
        return GroupRepo.add(ProxyGroup().apply {
            name = GroupRepo.defaultGroupName()
            single = true
        })
    }

}
