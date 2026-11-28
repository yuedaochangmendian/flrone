package io.flrone.bridge

import io.flrone.flutter.ServiceBridge
import io.flrone.flutter.ServiceEngineManager
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.GroupRepo
import io.nekohasekai.sagernet.database.GroupSort
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.SortInput
import io.nekohasekai.sagernet.database.isSingleNodeGroup
import io.nekohasekai.sagernet.database.SendHwid
import io.nekohasekai.sagernet.database.SettingsMapper
import io.nekohasekai.sagernet.database.SubHttpVersion
import io.nekohasekai.sagernet.database.SubTlsVersion
import io.nekohasekai.sagernet.database.SubscriptionOptions
import io.nekohasekai.sagernet.bg.autoselector.AutoSelectorProfiles
import io.nekohasekai.sagernet.bg.autoselector.AutoSelectorRuntime
import io.nekohasekai.sagernet.group.GroupRevisions
import io.nekohasekai.sagernet.group.RequestIdentity
import io.nekohasekai.sagernet.group.SubscriptionNameFilter
import io.nekohasekai.sagernet.group.SubscriptionQueue
import io.nekohasekai.sagernet.group.SubscriptionRefresh
import io.nekohasekai.sagernet.group.SubscriptionScheduler
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.outbound.Outbound
import io.nekohasekai.sagernet.outbound.OutboundFactory
import io.nekohasekai.sagernet.outbound.common.MUX_CUSTOM
import io.nekohasekai.sagernet.outbound.common.Multiplex
import io.nekohasekai.sagernet.outbound.common.Tls
import io.nekohasekai.sagernet.outbound.distinctNodes
import io.nekohasekai.sagernet.outbound.import.ProfileImport
import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.outbound.types.AutoSelector
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
 * whitelist and membership equality live there). What remains here needs the Throne model — parsing and validation
 * of a group's nodes, the subscription queue, the auto-selector runtime — plus the narrow side effects the duty table
 * names (`revision.edit` before a configuration save, `subscription.schedule` after a URL edit).
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
        // The editor no longer requires a subscription name. An existing one
        // whose name was cleared takes its URL host; a new one prefers the
        // server's Profile-Title once the body has been fetched (below).
        if (id > 0L && group.isSubscription && group.name.isBlank()) {
            group.name = subscriptionHost(group.url)
        }
        if (autoUpdate != null) group.skipAutoUpdate = !autoUpdate
        if (interval != null) group.subOptions.updateInterval = interval.coerceAtLeast(0)

        // A new subscription is downloaded and validated before its row is inserted: an unreachable server, an HTTP
        // error or a body without a single node must not leave a half-created group whose only feedback is a later
        // queue report. The fetched answer is then applied to the group, so a valid subscription is not downloaded a
        // second time. Editing an existing one saves first and refreshes only when the URL changed (below).
        if (id <= 0L && group.isSubscription) {
            val urlError = subscriptionUrlError(group.url)
            if (urlError.isNotEmpty()) error(urlError)

            // S6: the common HTTP(S) create runs in the Dart service engine,
            // which owns profiles.json: fetch → validate → create group → apply
            // nodes happens there, so no empty group is left on a refusal and
            // the Kotlin fetch/queue path is no longer needed for a plain URL.
            // content:// creates ride the same path now: the Dart create calls
            // the service-engine `subscription.fetch` host seam, whose
            // ContentResolver read is Kotlin's own SubscriptionFetch. Only a
            // URL scheme the host reader cannot fetch (or a missing document
            // owner) keeps the legacy path below.
            val trimmedUrl = group.url.trim()
            val commonUrl = trimmedUrl.startsWith("http://", ignoreCase = true) ||
                trimmedUrl.startsWith("https://", ignoreCase = true)
            val hostFetchUrl = commonUrl || trimmedUrl.startsWith("content://", ignoreCase = true)
            val created = if (hostFetchUrl && !FlroneCommands.subscriptionNeedsLegacyPath(group)) {
                val payload = mapOf(
                    "name" to group.name,
                    "url" to trimmedUrl,
                    "subOptionsJson" to group.subOptions.toJsonString(),
                    "autoUpdate" to !group.skipAutoUpdate,
                    "foreground" to true,
                )
                // Only the small editor payload crosses the channel. It never
                // carries credentials and is never logged.
                val reply = ServiceBridge.requestSubscriptionAwait("subscription.create", payload)
                val gid = (reply as? Map<*, *>)?.get("gid") as? Number
                    ?: error("subscription.create did not return a group id")
                gid.toLong()
            } else {
                try {
                    SubscriptionRefresh.createValidated(group) { candidate, prepared ->
                        // Bettbox's add names an unnamed subscription from the
                        // server's Profile-Title, then the panel's
                        // Content-Disposition filename, then the URL host.
                        if (candidate.name.isBlank()) {
                            candidate.name = prepared.info.title.trim()
                                .ifBlank { prepared.fileName }
                                .ifBlank { subscriptionHost(candidate.url) }
                        }
                        val saved = GroupRepo.add(candidate)
                        SubscriptionRefresh.applyNew(saved, prepared)
                        saved.id
                    }
                } catch (rejected: SubscriptionRefresh.Rejected) {
                    error(SubscriptionRefresh.describe(rejected))
                }
            }
            SubscriptionScheduler.schedule()
            FlroneBridge.scheduleRefresh(immediate = true)
            return@withContext created
        }

        // `{}` is the editor's own "new empty group" seed, not an import to parse.
        val import = if (id <= 0L && !group.isSubscription) {
            val text = content?.trim().orEmpty()
            if (text.isEmpty() || text == "{}") emptyList() else parseOutbounds(text)
        } else {
            emptyList()
        }
        // A single imported node joins the single-node container, not a profile of its own:
        // it shows up in the node page and the profile grid stays the subscription view.
        // The form's name renames the node itself.
        if (id <= 0L && !group.isSubscription && import.size == 1) {
            val target = singleNodeGroup()
            val outbound = import.single()
            val renamed = name?.trim().orEmpty()
            if (renamed.isNotEmpty() && renamed != outbound.displayName()) outbound.name = renamed
            val added = ProfileManager.addProfileBatch(listOf(outbound), target)
            GroupRepo.setCurrent(target)
            added.singleOrNull()?.let { FlroneCommands.select(it.id) }
            FlroneBridge.scheduleRefresh(immediate = true)
            return@withContext target
        }
        if (group.name.isNullOrBlank() && import.size == 1) group.name = import.single().displayName()

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
            val added = ProfileManager.addProfileBatch(import, saved)
            GroupRepo.setCurrent(saved)
            // A single imported node is what the user asked to use; a whole subscription stays unselected until chosen.
            added.singleOrNull()?.let { FlroneCommands.select(it.id) }
        }
        if (group.isSubscription && urlChanged) {
            // A save is not implicitly a refresh: renaming a subscription or
            // changing its auto-update switch must not download the body
            // again. A URL edit is the one save that invalidates the nodes, so
            // it still refreshes immediately (FlClash's edit page does the
            // same) — through the same Dart queue/predicate as the manual
            // update, so content:// and proxy groups take the host fetch seam.
            if (!FlroneCommands.subscriptionNeedsLegacyPath(saved) &&
                ServiceEngineManager.ensureDocumentOwner()
            ) {
                ServiceBridge.requestSubscription(
                    "subscription.refresh",
                    mapOf("gid" to saved, "showDiff" to false),
                )
            } else {
                runCatching { SubscriptionQueue.refreshGroup(saved, showDiff = false) }
            }
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
     * JSON or YAML document — goes through Throne's importer, so a single `ss://`/`vmess://`/`vless://` node opens
     * with its own name instead of failing the sing-box JSON check.
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

    /** The share link of one node, falling back to Throne's loss-less JSON link when the protocol has no standard URI. */
    suspend fun nodeLink(groupTag: String, nodeTag: String, jsonLink: Boolean = false): String =
        withContext(Dispatchers.IO) {
            val group = GroupRepo.all().firstOrNull { it.displayName() == groupTag }
                ?: error("No proxy group named $groupTag")
            val profile = ProfileManager.members(group.id).firstOrNull { it.displayName() == nodeTag }
                ?: error("No proxy named $nodeTag in ${group.displayName()}")
            val link = if (jsonLink) {
                profile.exportJsonLink()
            } else {
                profile.exportLink().ifBlank { profile.exportJsonLink() }
            }
            if (link.isBlank()) error("${profile.displayName()} cannot be shared as a link")
            link
        }

    /** The editor's seed for one node: its name, type and the share link it can be edited from. */
    suspend fun nodeInfo(id: Long): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = ProfileManager.getProfile(id) ?: error("No proxy with id $id")
        mapOf(
            "id" to profile.id,
            "name" to profile.displayName(),
            "type" to profile.displayType(),
            "content" to profile.exportLink().ifBlank { profile.exportJsonLink() },
        )
    }

    /**
     * Creates a fresh node of [type] in the single-node container and answers its editor
     * seed, so the typed form can open on it and the user fills the fields. The default
     * name is the protocol's own display type; the empty server/port keep it unselectable
     * until saved.
     */
    suspend fun createNode(type: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        val outbound = OutboundFactory.newByType(type)
        if (outbound.invalid) error("Unknown proxy type: $type")
        if (outbound.name.isBlank()) outbound.name = outbound.displayType().ifBlank { type }
        val gid = singleNodeGroup()
        mapOf(
            "id" to 0L,
            "groupId" to gid,
            "name" to outbound.name,
            "type" to outbound.displayType(),
            "json" to io.nekohasekai.sagernet.ui.json.ProfileJson.text(outbound),
        )
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
     * becomes the editor's seed rows. The importer is the same one the profile editor uses, so a
     * link the app cannot import is refused with the importer's own reason, and repeated servers
     * are collapsed the way a subscription save collapses them.
     */
    suspend fun parseNodeText(text: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) error("There is nothing to import")
        val parsed = ProfileImport.parse(
            trimmed,
            SettingsMapper.buildContext(),
        )
        val nodes = parsed.outbounds.distinctNodes()
        if (nodes.isEmpty()) {
            error(parsed.messages.joinToString("\n").ifBlank { "No supported proxy node found" })
        }
        mapOf(
            "nodes" to nodes.map { outbound ->
                mapOf(
                    "name" to outbound.displayName().ifBlank { outbound.displayType() },
                    "type" to outbound.displayType(),
                    "json" to io.nekohasekai.sagernet.ui.json.ProfileJson.text(outbound),
                )
            },
            "skipped" to parsed.reports.size,
            "messages" to parsed.messages,
        )
    }

    /** The new-node form's save: parse, validate and add exactly one row. */
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
        if (name.isNotEmpty()) outbound.name = name
        val issues = ArrayList<io.nekohasekai.sagernet.validation.Issue>()
        outbound.validate(issues, SettingsMapper.buildContext())
        issues.filter { it.severity == io.nekohasekai.sagernet.validation.Severity.Error }
            .firstOrNull()?.let { error(listOf(it.field, it.message).filter(String::isNotBlank).joinToString(": ")) }
        val gid = singleNodeGroup()
        val entity = ProfileManager.addProfile(outbound, gid)
        FlroneBridge.scheduleRefresh(immediate = true)
        nodeInfo(entity.id)
    }

    /** The typed form's seed: the node's canonical sing-box JSON (ProfileJson), which the form reads and writes. */
    suspend fun nodeConfig(id: Long): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = ProfileManager.getProfile(id) ?: error("No proxy with id $id")
        val outbound = profile.outbound
        mapOf(
            "id" to profile.id,
            "name" to profile.displayName(),
            "json" to io.nekohasekai.sagernet.ui.json.ProfileJson.text(outbound),
            "endpoint" to outbound.isEndpoint(),
        )
    }

    /**
     * Renames a node and/or replaces its outbound with one share link or JSON document. The content
     * must describe exactly one node — a whole subscription belongs to a group save, not here. The
     * parsed outbound is validated with the model's own checks (the native editor's save gate).
     */
    suspend fun updateNode(id: Long, name: String?, content: String?): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = ProfileManager.getProfile(id) ?: error("No proxy with id $id")
        val text = content?.trim().orEmpty()
        if (text.isNotEmpty() && text != "{}") {
            val inbound = parseOutbounds(text)
            if (inbound.size != 1) error("The content must describe exactly one node, got ${inbound.size}")
            val outbound = inbound.single()
            val issues = ArrayList<io.nekohasekai.sagernet.validation.Issue>()
            outbound.validate(issues, SettingsMapper.buildContext())
            issues.filter { it.severity == io.nekohasekai.sagernet.validation.Severity.Error }
                .firstOrNull()?.let { issue ->
                    error(listOf(issue.field, issue.message).filter { it.isNotBlank() }.joinToString(": "))
                }
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

    /** Creates a fresh auto-selector node in [groupId], or the first group when it is omitted. */
    suspend fun createAutoSelector(groupId: Long?, name: String? = null): Map<String, Any?> = withContext(Dispatchers.IO) {
        val gid = groupId?.takeIf { it > 0L } ?: GroupRepo.all().firstOrNull()?.id ?: defaultGroup().id
        val entity = ProfileManager.addProfile(AutoSelector(), gid)
        // A new selector starts on the group it was made from and carries a name: with an empty list it
        // tracked nothing (so it could never pick a node) and rendered as "no group" on the proxies screen.
        AutoSelectorProfiles.load(entity.id)?.let { selector ->
            selector.gids = arrayListOf(gid)
            if (selector.name.isBlank()) selector.name = name?.trim().orEmpty().ifBlank { "Auto Selector" }
            AutoSelectorProfiles.save(entity.id, selector)
        }
        FlroneBridge.scheduleRefresh(immediate = true)
        autoSelectorInfo(entity.id)
    }

    /** The auto-selector editor's seed: its fields plus the groups the picker can tick. */
    suspend fun autoSelectorInfo(id: Long): Map<String, Any?> = withContext(Dispatchers.IO) {
        val selector = AutoSelectorProfiles.load(id) ?: error("No auto selector with id $id")
        mapOf(
            "id" to id,
            "name" to selector.name,
            "nameFilter" to selector.nameFilter,
            "countryFilter" to selector.countryFilter,
            "excludeUnavailable" to selector.excludeUnavailable,
            "poolCap" to selector.poolCap,
            "buildLimit" to selector.buildLimit,
            "resultValidityMins" to selector.resultValidityMins,
            "testURL" to selector.testURL,
            "connectivityURL" to selector.connectivityURL,
            "intervalSec" to selector.intervalSec,
            "benchIntervalSec" to selector.benchIntervalSec,
            "watchIntervalSec" to selector.watchIntervalSec,
            "activeSize" to selector.activeSize,
            "sampling" to selector.sampling,
            "toleranceMs" to selector.toleranceMs,
            "maxRTTms" to selector.maxRTTms,
            "expected" to selector.expected,
            "dialRetries" to selector.dialRetries,
            "interruptOnSwitch" to selector.interruptOnSwitch,
            "balance" to selector.balance,
            "balanceMode" to selector.balanceMode,
            "balanceIntervalSec" to selector.balanceIntervalSec,
            "gids" to selector.gids.map(Long::toInt),
            "pinnedId" to selector.pinnedID,
            "groups" to GroupRepo.all().map { mapOf("id" to it.id.toInt(), "name" to it.displayName()) },
        )
    }

    /** Saves the edited fields onto the stored selector; absent keys keep their values. */
    suspend fun autoSelectorSave(id: Long, values: Map<String, Any?>): Map<String, Any?> = withContext(Dispatchers.IO) {
        // The whole load → change → save runs under the writer lock: the
        // selector is exported to `outbound_json` whole (pinnedID included), so
        // an edit that loaded before a concurrent pin would silently roll the
        // pin back. This path used to write without the lock the contract names.
        AutoSelectorProfiles.writes.withLock {
            val selector = AutoSelectorProfiles.load(id) ?: error("No auto selector with id $id")
            (values["name"] as? String)?.let { selector.name = it.trim() }
            (values["nameFilter"] as? String)?.let { selector.nameFilter = it.trim() }
            (values["countryFilter"] as? String)?.let { selector.countryFilter = it.trim() }
            (values["testURL"] as? String)?.let { selector.testURL = it.trim() }
            (values["connectivityURL"] as? String)?.let { selector.connectivityURL = it.trim() }
            (values["balanceMode"] as? String)?.let { selector.balanceMode = it.trim() }
            (values["excludeUnavailable"] as? Boolean)?.let { selector.excludeUnavailable = it }
            (values["interruptOnSwitch"] as? Boolean)?.let { selector.interruptOnSwitch = it }
            (values["balance"] as? Boolean)?.let { selector.balance = it }
            fun intOf(key: String) = (values[key] as? Number)?.toInt() ?: (values[key] as? String)?.toIntOrNull()
            intOf("poolCap")?.let { selector.poolCap = it.coerceAtLeast(0) }
            intOf("buildLimit")?.let { selector.buildLimit = it.coerceAtLeast(0) }
            intOf("resultValidityMins")?.let { selector.resultValidityMins = it.coerceAtLeast(0) }
            intOf("intervalSec")?.let { selector.intervalSec = it.coerceAtLeast(1) }
            intOf("benchIntervalSec")?.let { selector.benchIntervalSec = it.coerceAtLeast(1) }
            intOf("watchIntervalSec")?.let { selector.watchIntervalSec = it.coerceAtLeast(1) }
            intOf("activeSize")?.let { selector.activeSize = it.coerceAtLeast(1) }
            intOf("sampling")?.let { selector.sampling = it.coerceAtLeast(1) }
            intOf("toleranceMs")?.let { selector.toleranceMs = it.coerceAtLeast(0) }
            intOf("maxRTTms")?.let { selector.maxRTTms = it.coerceAtLeast(0) }
            intOf("expected")?.let { selector.expected = it.coerceAtLeast(1) }
            intOf("dialRetries")?.let { selector.dialRetries = it.coerceAtLeast(0) }
            intOf("balanceIntervalSec")?.let { selector.balanceIntervalSec = it.coerceAtLeast(1) }
            (values["gids"] as? List<*>)?.let { list ->
                selector.gids = list.filterIsInstance<Number>().mapTo(ArrayList()) { it.toLong() }
            }
            AutoSelectorProfiles.save(id, selector)
        }
        FlroneBridge.scheduleRefresh(immediate = true)
        autoSelectorInfo(id)
    }

    /** The running selector's status (AutoSelectorStatus.toJson); the phase is "idle" when nothing runs. */
    suspend fun autoSelectorStatus(): String = withContext(Dispatchers.IO) {
        val json = AutoSelectorRuntime.statusJson(withMembers = true)
        if (!FlroneKernel.ffiMode) return@withContext json
        // In ffiMode the selector runs inside the box Dart owns: this runtime never attaches to
        // it, so the status is idle even while the core is ranking. Say who holds it instead of
        // letting the page report "not running" for a selector that is working.
        runCatching {
            val root = org.json.JSONObject(json)
            if (root.optString("phase") == "idle") root.put("driver", "ffi").toString() else json
        }.getOrDefault(json)
    }

    /**
     * Pins the selector to one member profile ([memberId] < 0 returns to automatic). The choice is
     * stored first so the next build carries it, then handed to the core when one is running.
     */
    suspend fun autoSelectorPin(id: Long, memberId: Long): Map<String, Any?> = withContext(Dispatchers.IO) {
        AutoSelectorProfiles.writes.withLock {
            // Load under the lock too: a load outside it could hold a stale
            // selector and overwrite a concurrent edit on save.
            val selector = AutoSelectorProfiles.load(id) ?: error("No auto selector with id $id")
            if (selector.pinnedID != memberId) {
                selector.pinnedID = memberId
                AutoSelectorProfiles.save(id, selector)
            }
        }
        // A pin writes `outbound_json` straight to the Dart document, so the
        // repository listeners that normally refresh the catalog never fire.
        // Without this the selector card keeps showing the old pin (autoSelectorSave
        // already does the same refresh after its document write).
        FlroneBridge.scheduleRefresh(immediate = true)
        AutoSelectorRuntime.select(memberId)
        autoSelectorInfo(id)
    }

    /** Re-probes every member of the running selector now. */
    suspend fun autoSelectorRecheck(): Unit = withContext(Dispatchers.IO) {
        AutoSelectorRuntime.recheck()
    }

    // ---------------------------------------------------------------------------------- node tuning

    private fun intOf(values: Map<String, Any?>, key: String): Int? =
        (values[key] as? Number)?.toInt() ?: (values[key] as? String)?.toIntOrNull()

    /**
     * The node's own mux, fragment and TLS-tricks overrides. Mux state is the Keep Default (0) /
     * On (1) / Off (2) / Custom (3) menu; the fragment and trick states are 0 default, 1 on, 2 off.
     * A protocol without the field reports false in `hasMux`/`hasTls`.
     */
    suspend fun nodeTuningInfo(id: Long): Map<String, Any?> = withContext(Dispatchers.IO) {
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
    suspend fun nodeTuningSave(id: Long, values: Map<String, Any?>): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = ProfileManager.getProfile(id) ?: error("No proxy with id $id")
        val outbound = profile.outbound
        val muxField = outbound.javaClass.fields.firstOrNull { it.name == "multiplex" }
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
        nodeTuningInfo(id)
    }

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

    /** Throne's own clipboard/file/QR parser, with the same global settings the native importer reads. */
    private fun parseOutbounds(text: String): List<Outbound> {
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
            SettingsMapper.buildContext(),
        )
        if (parsed.outbounds.isEmpty()) {
            error(parsed.messages.joinToString("\n").ifBlank { "No supported proxy node found" })
        }
        // A pasted subscription/list often repeats a server under several remarks; the group should
        // receive one row per server, not one per line.
        return parsed.outbounds.distinctNodes()
    }

}
