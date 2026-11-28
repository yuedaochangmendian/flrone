package io.nekohasekai.sagernet.group

import android.os.SystemClock
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.bg.BaseService
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.GroupRepo
import io.nekohasekai.sagernet.database.GroupSort
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.SettingsMapper
import io.nekohasekai.sagernet.database.StoredProfile
import io.nekohasekai.sagernet.database.SubUserInfo
import io.nekohasekai.sagernet.database.SubscriptionOptions
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.ktx.runOnDefaultDispatcher
import io.nekohasekai.sagernet.outbound.Outbound
import io.nekohasekai.sagernet.outbound.distinctNodes
import io.nekohasekai.sagernet.outbound.`import`.ImportReport
import io.nekohasekai.sagernet.outbound.`import`.ProfileImport
import io.nekohasekai.sagernet.validation.vplural
import io.nekohasekai.sagernet.validation.vtr
import kotlinx.coroutines.delay

/** GroupUpdater::refresh, importDocuments and afterUrlTest (GroupUpdater.cpp:465-683) over the Room data layer. */
internal object SubscriptionRefresh {

    const val AUTOSELECTOR = "autoselector"

    /** kInsertChunk (GroupUpdater.cpp:23). */
    private const val INSERT_CHUNK = 500

    /** How long a replaced running profile waits for the service to finish stopping. */
    private const val RECONNECT_WAIT_MS = 15_000L

    private val BOM = Char(0xFEFF)

    /** [reported]: the import box went out, so the caller's own count line is skipped (MwArg::Quiet). */
    class ImportResult(@JvmField val gid: Long, @JvmField val count: Int, @JvmField val reported: Boolean = false)

    /**
     * GroupUpdater::Surface: where an update's problems go: the log only (automatic), the diff popup (manual
     * refresh), or a report box (a new subscription's first update).
     */
    enum class Surface { Log, Diff, Report }

    private fun str(id: Int, vararg args: Any): String = app.getString(id, *args)

    /** notice (GroupUpdater.cpp:166-176): a list of 1000 names or more collapses to one count line. */
    fun notice(names: List<String>, prefix: String, action: String): String {
        if (names.size >= 1000) return "$prefix $action ${names.size}\n"
        val sb = StringBuilder()
        for (name in names) sb.append(prefix).append(' ').append(name).append('\n')
        return sb.toString()
    }

    /** reportTitle (GroupUpdater.cpp). */
    private fun reportTitle(surface: Surface, groupName: String): String =
        if (surface == Surface.Report) vtr(R.string.validation_import_title_new, groupName) else vtr(R.string.validation_import_title_update, groupName)

    /** logImportReport (GroupUpdater.cpp). */
    private fun logImportReport(report: ImportReport) = Logs.w(report.text())

    /**
     * refresh and applyRefresh (GroupUpdater.cpp); [notifyErrors]: fetch failures also go to the callbacks. The parse
     * report goes to the log, and with [Surface.Diff] / [Surface.Report] to a popup.
     */
    suspend fun refresh(gid: Long, surface: Surface, notifyErrors: Boolean) {
        refresh(gid, surface, notifyErrors, { group -> fetchGroup(group) }, ::parse)
    }

    /**
     * [refresh] with the fetch and the importer injectable, so a JVM test can drive the ordering and the supersede
     * rule with a delayed fake answer instead of the network and the settings document. The fetch is suspend only for
     * that seam — production's [fetchGroup] is the blocking call as before. [applyAnswer] is the last seam and
     * defaults to the real [apply]. Returns whether the answer was stored: false means the update stopped (a fetch
     * failure, a rejected body, the group's deletion or URL edit, or a newer intent overtaking the answer).
     *
     * "Newest intent wins" (FlClash's rule for a slow profile download, providers/actions/profiles.dart:168-179):
     * the ticket is taken with [GroupRevisions.begin] before the fetch; a user save/edit of the group (or a newer
     * refresh starting) moves the revision meanwhile, and the answer is then discarded with a diagnostic instead of
     * being applied over the edit. The queue entry completes as superseded; the next refresh starts on the new state,
     * so a refresh that begins after the edit applies normally.
     */
    internal suspend fun refresh(
        gid: Long,
        surface: Surface,
        notifyErrors: Boolean,
        fetch: suspend (ProxyGroup) -> SubscriptionFetch.Result,
        parseBody: (String) -> ProfileImport.Result,
        applyAnswer: suspend (ProxyGroup, Prepared, Surface) -> Unit = { group, prepared, answerSurface ->
            apply(group, prepared, answerSurface)
        },
    ): Boolean {
        val group = GroupRepo.get(gid) ?: return false
        if (group.archive) return false
        // From here this refresh is the newest intent for the group; the ticket is what lets it notice, after the
        // download, that an edit (or a newer refresh) overtook it.
        val ticket = GroupRevisions.begin(gid)
        val prepared = fetchAndParse(group, group.url.trim(), surface, notifyErrors, fetch, parseBody) ?: return false
        // The answer is only usable while the group still exists and nothing newer touched it.
        val current = GroupRepo.get(gid) ?: return false
        if (!GroupRevisions.holds(gid, ticket)) {
            noticeSuperseded(current, surface)
            return false
        }
        applyAnswer(current, prepared, surface)
        return true
    }

    /**
     * Where a superseded update's diagnostic goes. The default writes the log line and (for a refresh the user asked
     * for) a non-popup report; a JVM test replaces the hook, because the queue's report needs the main looper.
     */
    @Volatile
    internal var supersededNotice: (ProxyGroup, Surface) -> Unit = { group, surface ->
        if (surface != Surface.Log) {
            SubscriptionQueue.report(
                group.id,
                str(R.string.subs_change_of, group.name),
                str(R.string.subs_superseded_by_edit, group.name),
                false,
            )
        }
    }

    /** A newer intent owns the group now: the downloaded answer is stale and is not applied. */
    private fun noticeSuperseded(group: ProxyGroup, surface: Surface) {
        Logs.w(
            "${group.name}: discarded a stale update: the group was edited while its answer downloaded " +
                "(intent moved to revision ${GroupRevisions.current(group.id)})"
        )
        supersededNotice(group, surface)
    }

    /**
     * The first update of a subscription that was just created: `FlroneProfiles.save` fetched and validated the body
     * before the group existed, so the answer is stored here instead of being downloaded a second time. Its problems
     * report the way a first update's do ([Surface.Report]).
     */
    internal suspend fun applyNew(group: ProxyGroup, prepared: Prepared) = apply(group, prepared, Surface.Report)

    /**
     * Stores a prepared answer into [group]: the metadata, then the server diff, the reports and the follow-ups. An
     * update and a new subscription share this step, so a new group's nodes take the insert path subscriptions always
     * take — nothing validates a body here, that already happened in [prepare].
     */
    private suspend fun apply(group: ProxyGroup, prepared: Prepared, surface: Surface) {
        val gid = group.id
        val url = group.url.trim()
        val options = group.subOptions
        val info = prepared.info
        val named = prepared.named
        val servers = prepared.servers
        val metadata = saveMetadata(group, info)

        // Deleted for good, for the route rules that named them.
        val removed = ArrayList<Long>()
        // Ids a running auto selector can no longer trust: deleted, or same id with new settings.
        val disturbed = ArrayList<Long>()
        val snapshot = loadSnapshot(gid, options, disturbed, removed) ?: return
        val sticky = snapshot.sticky
        val stickyIds = snapshot.stickyIds
        val old = snapshot.old
        val working = snapshot.working
        val cleared = snapshot.cleared
        var stoppedRunning = snapshot.stopped
        val index = ContentIndex(old)
        val sink = ImportSink(gid, if (cleared) null else index)

        Logs.i(">>>>>>>> " + str(R.string.subs_processing))
        for (outbound in servers) sink.add(outbound)
        sink.finish(old)
        Logs.i(">>>>>>>> " + str(R.string.subs_process_complete))
        val report = prepared.result.report()
        report.setImported(sink.stored())

        var changeText: String
        if (cleared) {
            changeText = if (sink.entries.size >= 1000) {
                "[+] ${sink.entries.size} profiles\n"
            } else {
                sink.entries.joinToString("") { "[+] ${it.display}\n" }
            }
        } else {
            val plan = SubscriptionReconcile.reconcile(old, sink.entries, index)
            disturbed.addAll(plan.updates)

            val stale = ArrayList<Long>()
            val keptWorking = ArrayList<Long>()
            for (id in plan.stale) (if (id in working) keptWorking else stale).add(id)

            val previousOrder = ProfileManager.memberIds(gid)
            val order = ArrayList(plan.order)
            for ((position, id) in sticky) order.add(minOf(position, order.size), id)

            val outcome = ProfileManager.batchDeleteProfiles(stale)
            if (!outcome.ok) {
                dbError(gid)
            }
            disturbed.addAll(outcome.deleted)
            removed.addAll(outcome.deleted)
            outcome.stopped?.let { stoppedRunning = it }

            // Survivors of the deletion (the running profile, working ones) return to their previous position.
            val ordered = order.toHashSet()
            val previousPosition = HashMap<Long, Int>(previousOrder.size * 2)
            previousOrder.forEachIndexed { position, id -> previousPosition.putIfAbsent(id, position) }
            fun restore(id: Long): Boolean {
                if (!ordered.add(id)) return false
                order.add(minOf(previousPosition[id] ?: order.size, order.size), id)
                return true
            }
            val keptIds = outcome.kept.filter(::restore)
            val workingIds = keptWorking.filter(::restore)
            val survivors = ProfileManager.getProfiles(keptIds + workingIds).associateBy { it.id }
            val noticeKept = StringBuilder()
            for (id in keptIds) {
                survivors[id]?.let {
                    noticeKept.append("[=] ")
                        .append(StoredProfile.displayTypeAndName(it.name, it.type, it.outboundJson)).append('\n')
                }
            }
            val workingNames = workingIds.mapNotNull { survivors[it]?.let { profile ->
                StoredProfile.displayTypeAndName(profile.name, profile.type, profile.outboundJson)
            } }
            ProfileManager.setOrder(gid, order)

            var deletedNames: List<String> = plan.deleted
            if (keptWorking.isNotEmpty()) {
                val doomed = stale.toHashSet()
                deletedNames = old.filter { it.id in doomed }.map { it.display }
            }

            changeText = "\n" + str(
                R.string.subs_change_summary,
                plan.added.size, notice(plan.added, "[+]", "added"),
                plan.updates.size, notice(plan.updated, "[~]", "updated"),
                deletedNames.size, notice(deletedNames, "[-]", "deleted"),
            )
            if (noticeKept.isNotEmpty()) changeText += "\n" + str(R.string.subs_still_in_use, noticeKept.toString())
            if (workingNames.isNotEmpty()) {
                changeText += "\n" + str(R.string.subs_working_kept, notice(workingNames, "[=]", "kept"))
            }
            if (plan.added.isEmpty() && plan.updates.isEmpty() && deletedNames.isEmpty() && keptWorking.isEmpty()) {
                changeText = str(R.string.subs_nothing)
            }
        }

        val filteredOut = prepared.result.outbounds.size - named.size
        if (filteredOut > 0) changeText += "\n" + str(R.string.subs_filtered_out, filteredOut) + "\n"
        val filtered = SubscriptionFilters.removeFlagged(gid, options) {
            ProfileManager.members(gid).filter { it.id !in stickyIds }
        }
        changeText += filtered.report
        disturbed.addAll(filtered.deleted)
        removed.addAll(filtered.deleted)
        filtered.stopped?.let { stoppedRunning = it }

        SubscriptionRouteRebind.rebind(gid, removed, snapshot.routeNames)
        // The subscription's own order replaced the group's above.
        if (disturbed.isNotEmpty() || ProfileManager.memberIds(gid) != snapshot.membersBefore) GroupSort.resortLater(gid)
        // Stamped only once the update went through, so an interrupted one is retried instead of counting as fresh.
        if (!urlChanged(gid, url)) {
            io.flrone.bridge.DartProfileWriter.patchGroups(mapOf(gid to mapOf(
                "sub_last_update" to System.currentTimeMillis() / 1000,
                "info" to "",
                "sub_metadata_json" to metadata,
            )))
            GroupRepo.postUpdate(gid)
        }

        Logs.i("<<<<<<<< " + str(R.string.subs_change_of_log, group.name) + "\n" + changeText)
        if (report.hasProblems()) logImportReport(report)
        val diffPopup = surface == Surface.Diff && DataStore.subShowChangePopup
        var diffBody = changeText.trim().ifEmpty { str(R.string.subs_nothing) }
        if (diffPopup && report.hasProblems()) diffBody += "\n\n" + vtr(R.string.validation_import_problems) + "\n" + report.text()
        SubscriptionQueue.report(gid, str(R.string.subs_change_of, group.name), diffBody, diffPopup)
        if (!diffPopup && surface != Surface.Log && report.hasProblems()) {
            SubscriptionQueue.report(gid, reportTitle(surface, group.name), report.text(), true)
        }
        stoppedRunning?.let { reconnectSuccessor(gid, it) }
        SubscriptionQueue.groupChanged(gid, disturbed)

        if (options.urlTest) SubscriptionQueue.requestUrlTest(gid, ProfileManager.memberIds(gid).filter { it !in stickyIds })
    }

    /**
     * A subscription answer that can be used: the metadata the headers carried, the parse result (for the report)
     * and the servers after the group's name filter and deduplication. What an update sinks into its group and what a
     * new subscription is created from — both go through [prepare].
     */
    internal class Prepared(
        @JvmField val info: SubUserInfo,
        @JvmField val result: ProfileImport.Result,
        @JvmField val named: List<Outbound>,
        @JvmField val servers: List<Outbound>,
        @JvmField val routing: String,
        /** `Content-Disposition`'s filename, the fallback after the server's title and before the URL host. */
        @JvmField val fileName: String = "",
    )

    /**
     * A subscription body that cannot be used. [reason] is the machine-readable kind, [error] the transport's own
     * sentence (empty for a body that downloaded but held no node), [result] the parse report of an unusable body.
     * Never names the URL: an error text may embed the request, token included.
     */
    internal class Rejected(
        @JvmField val reason: Reason,
        @JvmField val error: String = "",
        @JvmField val result: ProfileImport.Result? = null,
        @JvmField val info: SubUserInfo = SubUserInfo(),
    ) : Exception(error) {
        enum class Reason { FETCH, EMPTY, WEB_PAGE, FILTERED }
    }

    /**
     * Parses and validates a fetched body — the code an update and a new subscription share (FlClash's add does
     * fetch → parse → insert, models/profile.dart:201-214). The rules are the update path's own: at least one node
     * after the group's name filter and deduplication, and an HTML block page is named as one instead of being read
     * as an empty subscription. Pure — no write, no queue, no strings — so the create path can run it before a group
     * exists and a JVM test can drive it with a fake fetch. [parseBody] is the importer; only the global outbound
     * settings it reads come from the settings document, which a JVM test cannot mount.
     */
    internal fun prepare(
        group: ProxyGroup,
        fetched: SubscriptionFetch.Result,
        parseBody: (String) -> ProfileImport.Result = ::parse,
    ): Prepared {
        if (fetched.error != null) {
            throw Rejected(Rejected.Reason.FETCH, fetched.error.orEmpty(), null, fetched.subInfo)
        }
        val info = fetched.subInfo
        val result = parseBody(fetched.body)
        // Android-only (#53): filtered servers never enter the sink.
        val named = SubscriptionNameFilter.apply(result.outbounds, group.subOptions, group.name)
        // A body that lists one server twice must become one row.
        val servers = named.distinctNodes()
        if (named.size != servers.size) {
            Logs.i("${group.name}: dropped ${named.size - servers.size} repeated nodes from the subscription")
        }
        if (servers.isEmpty()) {
            val reason = when {
                result.outbounds.isNotEmpty() -> Rejected.Reason.FILTERED
                looksLikeWebPage(fetched.body) -> Rejected.Reason.WEB_PAGE
                else -> Rejected.Reason.EMPTY
            }
            throw Rejected(reason, "", result, info)
        }
        return Prepared(
            info,
            result,
            named,
            servers,
            "",
            SubscriptionFileName.fromDisposition(fetched.contentDisposition),
        )
    }

    /**
     * The create ordering (FlClash's Profile.add): download and validate first, insert second. [create] — which
     * inserts the group and applies the already-fetched answer — is only reached with a usable body, so a bad URL, an
     * HTTP error, an empty body or an all-filtered one throws [Rejected] and leaves no group row behind. [parseBody]
     * is the same seam [prepare] takes.
     */
    internal suspend fun createValidated(
        group: ProxyGroup,
        fetch: (ProxyGroup) -> SubscriptionFetch.Result = ::fetchGroup,
        parseBody: (String) -> ProfileImport.Result = ::parse,
        create: suspend (ProxyGroup, Prepared) -> Long,
    ): Long {
        val prepared = prepare(group, fetch(group), parseBody)
        return create(group, prepared)
    }

    /** The subscription request for [group]: its own options carry the User Agent, TLS and HWID settings. */
    private fun fetchGroup(group: ProxyGroup): SubscriptionFetch.Result =
        SubscriptionFetch.fetch(group.url.trim(), group.name, RequestIdentity.resolve(group))

    /** The sentence a create failure shows: the transport's own for a fetch, the reason otherwise. */
    internal fun describe(rejected: Rejected): String = when (rejected.reason) {
        Rejected.Reason.FETCH -> str(R.string.validation_import_fetch_failed, rejected.error)
        Rejected.Reason.WEB_PAGE -> str(R.string.subs_web_page)
        Rejected.Reason.EMPTY -> str(R.string.subs_empty_aborted)
        Rejected.Reason.FILTERED -> str(R.string.subs_filtered_all_aborted, rejected.result?.outbounds?.size ?: 0)
    }

    /**
     * fetch + [prepare] for an update, with its rejection reported on [surface]; null when the update stops here.
     * The answer is validated against the group row re-read after the download, so an edit that reached the document
     * meanwhile (while leaving the URL alone) is what the body is checked against; the caller's revision check then
     * decides whether the answer may still be applied at all.
     */
    private suspend fun fetchAndParse(
        group: ProxyGroup,
        url: String,
        surface: Surface,
        notifyErrors: Boolean,
        fetch: suspend (ProxyGroup) -> SubscriptionFetch.Result,
        parseBody: (String) -> ProfileImport.Result,
    ): Prepared? {
        val gid = group.id
        val fetched = fetch(group)
        // The group must still be there, and still be the one this answer was fetched for, before anything is said
        // about the body: an edit of the URL meanwhile (or the group's deletion) makes the answer stale.
        val current = GroupRepo.get(gid) ?: run {
            GroupRevisions.forget(gid)
            return null
        }
        if (current.url.trim() != url) {
            Logs.w(str(R.string.subs_url_changed, group.name))
            return null
        }
        return try {
            prepare(current, fetched, parseBody)
        } catch (rejected: Rejected) {
            reportRejection(current, rejected, surface, notifyErrors)
            null
        }
    }

    /**
     * Reports a rejected answer on the surface the caller asked for. A first update's report box names the failure
     * and the group's own TLS / HTTP / User Agent settings as where to fix it; a manual refresh's report carries the
     * parse problems; a silent update only reaches the callbacks.
     */
    private suspend fun reportRejection(
        group: ProxyGroup,
        rejected: Rejected,
        surface: Surface,
        notifyErrors: Boolean,
    ) {
        val gid = group.id
        when (rejected.reason) {
            Rejected.Reason.FETCH -> if (surface == Surface.Report) {
                val report = ImportReport()
                report.addFatal(vtr(R.string.validation_import_fetch_failed, rejected.error))
                report.addFatal(vtr(R.string.validation_import_first_download_failed, group.name))
                SubscriptionQueue.report(gid, reportTitle(surface, group.name), report.summary(), true)
            } else if (notifyErrors) {
                SubscriptionQueue.error(gid, rejected.error)
            }

            Rejected.Reason.EMPTY, Rejected.Reason.WEB_PAGE -> {
                val probe = rejected.result?.report() ?: ImportReport()
                if (rejected.reason == Rejected.Reason.WEB_PAGE) probe.addFatal(str(R.string.subs_web_page))
                val info = rejected.info
                // Panels answer a device or quota limit with an empty list and an announcement saying why.
                if (info.valid) {
                    if (info.announce.isNotEmpty()) probe.addFatal(str(R.string.subs_announcement_from, group.name, info.announce))
                    saveMetadata(group, info)
                }
                val message = str(R.string.subs_empty_aborted)
                probe.addFatal(message)
                Logs.w("${group.name}: " + probe.text())
                if (surface != Surface.Log) SubscriptionQueue.report(gid, reportTitle(surface, group.name), probe.text(), true)
                else if (notifyErrors) SubscriptionQueue.error(gid, message)
            }

            Rejected.Reason.FILTERED -> {
                if (rejected.info.valid) saveMetadata(group, rejected.info)
                val message = str(R.string.subs_filtered_all_aborted, rejected.result?.outbounds?.size ?: 0)
                Logs.w("${group.name}: $message")
                if (notifyErrors) SubscriptionQueue.error(gid, message)
            }
        }
    }

    /**
     * reconnectSuccessor (GroupUpdater.cpp, #2051): the refresh deleted the running profile, so only an unambiguous
     * successor (same type and name) takes over; with none or several, the profile stays stopped.
     */
    private fun reconnectSuccessor(gid: Long, stopped: ProxyEntity) {
        val name = stopped.name.orEmpty()
        val matches = if (name.isEmpty()) emptyList() else {
            // ADR 0005: Room is no longer written, so its name index is stale;
            // resolve the successor from the Dart-owned document.
            io.flrone.bridge.DartProfileStore.members(gid)
                .filter { it.type == stopped.type && it.name == name }
        }
        val display = StoredProfile.displayTypeAndName(stopped.name, stopped.type, stopped.outboundJson)
        if (matches.size != 1) {
            Logs.w(str(R.string.subs_running_removed, display))
            return
        }
        Logs.i(str(R.string.subs_running_replaced, display))
        val successor = matches.first().id
        runOnDefaultDispatcher { startWhenStopped(stopped.id, successor) }
    }

    /**
     * EngineHost's subscriptionReplacedRunning: the delete only asked the service to stop, and a start while it is
     * stopping is ignored, so this waits for Stopped. Whatever the user started meanwhile wins.
     * A user-initiated stop during the wait is also respected: the auto-restart is abandoned.
     */
    private suspend fun startWhenStopped(stoppedId: Long, successor: Long) {
        val deadline = SystemClock.elapsedRealtime() + RECONNECT_WAIT_MS
        var observedStopping = false
        while (SystemClock.elapsedRealtime() < deadline) {
            val state = DataStore.serviceState
            if (state == BaseService.State.Stopping) observedStopping = true
            if (state == BaseService.State.Stopped) {
                // Only auto-restart if we observed the service stopping (i.e. the stop was
                // caused by the profile deletion). A user stop goes straight to Stopped
                // without passing through Stopping from our perspective.
                if (!observedStopping) return
                DataStore.selectedProxy = successor
                try {
                    SagerNet.startServiceQuick()
                } catch (e: Exception) {
                    Logs.w(e)
                }
                return
            }
            if (state.started && DataStore.currentProfile != stoppedId) return
            delay(200)
        }
    }

    /** The group as the diff starts from it; [routeNames] is [SubscriptionRouteRebind.referencedNames]' result. */
    private class Snapshot(
        @JvmField val sticky: List<Pair<Int, Long>>,
        @JvmField val stickyIds: HashSet<Long>,
        @JvmField val membersBefore: List<Long>,
        @JvmField val routeNames: Map<Long, String>,
        @JvmField val old: ArrayList<OldEntry>,
        @JvmField val working: HashSet<Long>,
        @JvmField val cleared: Boolean,
        @JvmField val stopped: ProxyEntity?,
    )

    /**
     * Loads the group once and runs "clear servers before updating"; null after a database error (already reported).
     * The loaded rows, with their parsed outbounds, die with this frame instead of living through the whole refresh.
     */
    private suspend fun loadSnapshot(
        gid: Long,
        options: SubscriptionOptions,
        disturbed: MutableList<Long>,
        removed: MutableList<Long>,
    ): Snapshot? {
        // Auto selectors are local state, not servers the remote sent: keep them out of the diff.
        var members = ProfileManager.members(gid)
        val sticky = members.withIndex()
            .filter { it.value.type == AUTOSELECTOR }
            .map { it.index to it.value.id }
        val stickyIds = sticky.mapTo(HashSet()) { it.second }
        val membersBefore = members.map { it.id }
        members = members.filter { it.id !in stickyIds }

        val routeNames = SubscriptionRouteRebind.referencedNames(members)
        var cleared = false
        var stopped: ProxyEntity? = null
        if (DataStore.subClear) {
            Logs.i(str(R.string.subs_clearing))
            val doomed = if (options.keepWorking) members.filter { !it.isWorking() } else members
            val outcome = ProfileManager.batchDeleteProfiles(doomed.map { it.id })
            if (!outcome.ok) {
                val message = str(R.string.subs_db_error_retry)
                Logs.e(message)
                SubscriptionQueue.error(gid, message)
                return null
            }
            disturbed.addAll(outcome.deleted)
            removed.addAll(outcome.deleted)
            stopped = outcome.stopped
            // A survivor still belongs to the subscription: fall through to the diff. A row gone meanwhile is none.
            val alive = ProfileManager.memberIds(gid).toHashSet()
            members = members.filter { it.id in alive }
            cleared = members.isEmpty()
        }

        val old = ArrayList<OldEntry>()
        val working = HashSet<Long>()
        if (!cleared) {
            for (profile in members) {
                old.add(
                    OldEntry(
                        profile.id, contentKey(profile), identityKey(profile),
                        StoredProfile.displayTypeAndName(profile.name, profile.type, profile.outboundJson),
                    ),
                )
                if (options.keepWorking && profile.isWorking()) working.add(profile.id)
            }
        }
        return Snapshot(sticky, stickyIds, membersBefore, routeNames, old, working, cleared, stopped)
    }

    /**
     * importDocuments (GroupUpdater.cpp): a plain import into [gid] (<= 0: the current group). With problems the
     * import box goes out as a popup report; [emptyReason] replaces the generic "nothing found" when nothing is stored.
     */
    suspend fun importDocuments(gid: Long, documents: List<String>, emptyReason: String = ""): ImportResult {
        val target = if (gid > 0) gid else GroupRepo.currentId()
        val sink = ImportSink(target, null)
        val report = ImportReport()
        Logs.i(">>>>>>>> " + str(R.string.subs_processing))
        for (document in documents) {
            val result = parse(document)
            report.addAll(result.reports)
            for (outbound in result.outbounds) sink.add(outbound)
        }
        sink.flush()
        Logs.i(">>>>>>>> " + str(R.string.subs_process_complete))
        val count = sink.stored()
        report.setImported(count)
        val lost = sink.entries.size - count
        if (lost > 0) report.addFatal(vplural(R.plurals.validation_import_not_saved, lost))
        if (count == 0) {
            if (emptyReason.isNotEmpty()) report.addFatal(emptyReason)
            else if (!report.hasProblems()) report.addFatal(vtr(R.string.validation_import_none))
        }
        if (!report.hasProblems()) {
            Logs.i(str(R.string.subs_imported, count))
            return ImportResult(target, count)
        }
        // The logged summary already carries the count.
        logImportReport(report)
        SubscriptionQueue.report(target, vtr(R.string.validation_import_title), report.text(), true)
        return ImportResult(target, count, reported = true)
    }

    /** afterUrlTest (GroupUpdater.cpp:669-683). */
    suspend fun afterUrlTest(gid: Long) {
        val group = GroupRepo.get(gid) ?: return
        if (group.archive) return
        val options = group.subOptions
        if (!options.urlTest || (!options.removeUnavailable && !options.sortByLatency)) return

        val result = SubscriptionFilters.removeUnavailableAndSort(group, options)
        if (result.report.isNotEmpty()) {
            val heading = str(R.string.subs_after_url_test, group.name)
            Logs.i("<<<<<<<< $heading${result.report}")
            SubscriptionQueue.report(gid, heading.removeSuffix(":"), result.report.trim(), false)
        }
        SubscriptionQueue.groupChanged(gid, result.deleted)
    }

    /** GroupUpdater.cpp:850-853: an edit of the group's URL meanwhile (or its deletion) makes the answer stale. */
    private fun urlChanged(gid: Long, url: String): Boolean = GroupRepo.get(gid)?.url?.trim() != url

    /** looksLikeWebPage (GroupUpdater.cpp:84-87): a CAPTCHA, bot check or block page instead of a subscription. */
    internal fun looksLikeWebPage(body: String): Boolean {
        val start = body.indexOfFirst { !it.isWhitespace() && it != BOM }
        if (start < 0) return false
        return body.startsWith("<!doctype html", start, ignoreCase = true) || body.startsWith("<html", start, ignoreCase = true)
    }

    /**
     * Stores what the answer said about the subscription (no update time) and returns the column text; a changed
     * profile-update-interval moves a group that follows it to another schedule.
     */
    private suspend fun saveMetadata(group: ProxyGroup, info: SubUserInfo): String {
        val metadata = info.toJsonString()
        io.flrone.bridge.DartProfileWriter.patchGroups(mapOf(group.id to mapOf(
            "info" to "",
            "sub_metadata_json" to metadata,
        )))
        GroupRepo.postUpdate(group.id)
        if (info.serverInterval != group.subInfo.serverInterval && SubscriptionScheduler.followsServerInterval(group)) {
            SubscriptionScheduler.schedule()
        }
        return metadata
    }

    internal fun dbError(gid: Long) {
        val message = str(R.string.subs_db_error_corrupted)
        Logs.e(message)
        SubscriptionQueue.error(gid, message)
    }

    private fun parse(body: String): ProfileImport.Result =
        ProfileImport.parse(body, SettingsMapper.buildContext())

    /** The stored JSON of a type this build cannot parse is kept as is (re-exporting would drop its fields). */
    private fun contentKey(profile: ProxyEntity): String = SubscriptionReconcile.contentKey(
        if (profile.outbound.invalid) profile.outboundJson else profile.outbound.exportToJson().toCompact()
    )

    private fun identityKey(profile: ProxyEntity): String =
        SubscriptionReconcile.identityKey(profile.type, profile.outbound.exportIdentity().toCompact())

    /**
     * ImportSink (GroupUpdater.cpp:112-154): inserts in chunks, claiming old ids by identical content first. Against a
     * [ContentIndex] the rest waits for [finish], where the identity pairs update their old rows in place.
     */
    private class ImportSink(private val gid: Long, private val index: ContentIndex?) {
        val entries = ArrayList<NewEntry>()
        private val chunk = ArrayList<Outbound>()

        /** stored (GroupUpdater.cpp): rows that really reached the database, added or reused from the group. */
        fun stored(): Int = entries.count { it.id > 0 }
        private val entryIndex = ArrayList<Int>()

        /** The entries (by position) waiting for [finish], with their profiles. */
        private val pendingIndex = ArrayList<Int>()
        private val pending = ArrayList<Outbound>()

        suspend fun add(outbound: Outbound) {
            val entry = NewEntry(outbound.displayTypeAndName())
            if (index != null) {
                entry.content = SubscriptionReconcile.contentKey(outbound.exportToJson().toCompact())
                index.noteArrival(entry.content)
                entry.contentKnown = index.knows(entry.content)
                val oldId = index.claim(entry.content)
                if (oldId != null) {
                    entry.id = oldId
                    entry.reused = true
                    entries.add(entry)
                    return
                }
                if (!entry.contentKnown) {
                    entry.identity = SubscriptionReconcile.identityKey(outbound.type, outbound.exportIdentity().toCompact())
                }
                pendingIndex.add(entries.size)
                entries.add(entry)
                pending.add(outbound)
                return
            }
            entryIndex.add(entries.size)
            entries.add(entry)
            chunk.add(outbound)
            if (chunk.size >= INSERT_CHUNK) flush()
        }

        /** After the last [add]: the identity pairs of [old] take their arrival's data, the other arrivals are inserted. */
        suspend fun finish(old: List<OldEntry>) {
            if (index != null) {
                SubscriptionReconcile.pairByIdentity(old, entries, index)
                val updates = ArrayList<Int>()
                for (k in pending.indices) {
                    val position = pendingIndex[k]
                    if (entries[position].supersedes > 0L) {
                        updates.add(k)
                        continue
                    }
                    entryIndex.add(position)
                    chunk.add(pending[k])
                    if (chunk.size >= INSERT_CHUNK) flush()
                }
                flush()
                for (part in updates.chunked(INSERT_CHUNK)) {
                    val json = part.map { pending[it].exportToJson().toCompact() }
                    // The old row keeps its id, test results and traffic: a
                    // per-column patch on the Dart document, never a whole row.
                    val patches = HashMap<Long, Map<String, Any?>>()
                    part.forEachIndexed { i, k ->
                        val entry = entries[pendingIndex[k]]
                        val outbound = pending[k]
                        patches[entry.supersedes] = mapOf(
                            "type" to outbound.type,
                            "name" to outbound.name,
                            "outbound_json" to json[i],
                        )
                        entry.id = entry.supersedes
                    }
                    io.flrone.bridge.DartProfileWriter.patchProfiles(patches)
                }
                pendingIndex.clear()
                pending.clear()
            }
            flush()
        }

        suspend fun flush() {
            if (chunk.isEmpty()) return
            try {
                val rows = ProfileManager.addProfileBatch(chunk, gid)
                rows.forEachIndexed { i, row -> entries[entryIndex[i]].id = row.id }
            } catch (e: Exception) {
                Logs.w(e)
            }
            chunk.clear()
            entryIndex.clear()
        }
    }
}
