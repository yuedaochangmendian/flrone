package io.flrone.bridge

import android.content.Intent
import android.net.Uri
import io.nekohasekai.sagernet.Action
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.bg.test.TestSpec
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.GroupRepo
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.ProfileOrder
import io.nekohasekai.sagernet.group.SubscriptionQueue
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.ui.test.TestSessionClient
import io.flrone.flutter.KernelServiceActions
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The write half of the bridge: every gesture the ported UI can make, expressed in Throne's terms.
 *
 * The UI never touches `SagerNet`, the database or broadcasts itself; it calls these methods, which run the blocking
 * parts on IO and hand the resulting change back through [FlroneBridge]'s state flow.
 */
object FlroneCommands {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** The session watcher that turns a test's results into catalog refreshes; one at a time. */
    private var testWatcher: Job? = null

    /** A URL test's timeout plus its bind, stop and catalog-refresh allowance. */
    private const val TEST_NODE_TIMEOUT_MS = 45_000L

    /**
     * How long [testNodeAwait] waits for [spec] to finish.
     *
     * The 45 s floor is the old flat cap, which fitted a handful of nodes. A group run is
     * `ceil(nodes / concurrency)` rounds of `timeoutMs`, so 100 nodes at the 8 s floor over 10
     * concurrent probes need about 80 s: the flat cap cancelled the session mid-sweep, the UI
     * cleared its spinner with half the rows still untested, and nothing said why. The Dart side
     * already scaled its own wait; this is the host's copy of the same arithmetic.
     */
    private fun sessionBudgetMs(spec: TestSpec): Long {
        val nodes = spec.profileIds.size.coerceAtLeast(1)
        val perNode = maxOf(spec.timeoutMs, FLCLASH_TEST_TIMEOUT_MS)
        val concurrency = DataStore.testConcurrent.coerceAtLeast(1)
        val rounds = (nodes + concurrency - 1) / concurrency
        return maxOf(TEST_NODE_TIMEOUT_MS, rounds.toLong() * perNode + 20_000L)
    }

    /** FlClash's defaults, also used as the floor for a proxy-page test. */
    private const val FLCLASH_TEST_URL = "https://www.gstatic.com/generate_204"
    private const val LEGACY_THRONE_TEST_URL = "https://cp.cloudflare.com"
    private const val FLCLASH_TEST_TIMEOUT_MS = 8_000

    /**
     * The proxy page tests the actual running exit whenever it targets that profile. A probe box remains only
     * for offline/other-node tests, because a probe-only verdict is not allowed to replace a live usable node.
     */
    private fun urlTestSpec(ids: List<Long>, scopeLabel: String): TestSpec {
        val live = DataStore.serviceState.connected && ids.size == 1 && ids[0] == ProfileManager.runningProfileId()
        val configuredUrl = DataStore.testUrl.trim()
        val usesLegacyDefault = configuredUrl.trimEnd('/') == LEGACY_THRONE_TEST_URL
        val url = if (configuredUrl.isEmpty() || usesLegacyDefault) {
            FLCLASH_TEST_URL
        } else {
            configuredUrl
        }
        return TestSpec(
            kind = TestSpec.KIND_URL,
            profileIds = ids.toLongArray(),
            testCurrent = live,
            persistCurrentResult = live,
            scopeLabel = scopeLabel,
            url = url,
            timeoutMs = maxOf(DataStore.urlTestTimeoutMs, FLCLASH_TEST_TIMEOUT_MS),
        )
    }

    /**
     * A test writes its results from the service process ([TestSessionClient]), whose profile updates the catalog's
     * in-process listeners never hear — the cards would keep their old latency until the next cold start. The session
     * reports back here, because this is the process that started it, so each landed result re-reads the catalog.
     */
    private fun watchTestSession() {
        if (testWatcher?.isActive == true) return
        testWatcher = scope.launch {
            var seen = -1
            TestSessionClient.state.collect { state ->
                if (state.done != seen) {
                    seen = state.done
                    if (seen > 0) FlroneBridge.scheduleRefresh()
                }
                // Cancel when the session is no longer running and we have seen at least
                // one state emission (seen >= 0 covers sessions that end with 0 results).
                if (!state.running && seen >= 0) {
                    FlroneBridge.scheduleRefresh(immediate = true)
                    testWatcher?.cancel()
                    testWatcher = null
                }
            }
        }
    }

    fun toggleService() {
        val state = DataStore.serviceState
        when {
            state.canStop -> SagerNet.stopService()
            DataStore.selectedProxy <= 0L -> Logs.w("bbox: start asked with no profile selected")
            else -> SagerNet.startService()
        }
    }

    fun setMode(mode: String) {
        FlroneMode.set(FlroneMode.Mode.of(mode))
        if (DataStore.serviceState.canStop) SagerNet.reloadService()
        FlroneBridge.scheduleRefresh(immediate = true)
    }

    /**
     * Resolves the member profile a selection names: the id when the caller has one, else the
     * display name, inside the group of the same display name. Null means the names no longer
     * address a row (a deleted group or node); both selection paths treat that as a no-op,
     * which is the answer the old single method gave. Blocking reads: callers hop to IO.
     */
    private fun selectionProfileId(group: String, tag: String, nodeId: Long?): Long? {
        val target = GroupRepo.all().firstOrNull { it.displayName() == group } ?: return null
        val members = ProfileManager.members(target.id)
        return nodeId?.takeIf { it > 0L }?.let { id -> members.firstOrNull { it.id == id }?.id }
            ?: members.firstOrNull { it.displayName() == tag }?.id
    }

    /**
     * The persistence half of a live selector switch. The running core already points at the
     * member (the `groupsSelect` action proved it), so only the settings the next start reads
     * move here: [DataStore.selectedProxy] / [DataStore.currentProfile].
     *
     * Deliberately NO [Action.SWITCH_PROFILE] broadcast and no reload: the broadcast is what
     * rebuilds the config, which is exactly the work a live switch exists to skip. An unresolved
     * row is a silent no-op — the action answered on outbound tags, and a row this process cannot
     * find is a deleted one, not a reason to fail the tap the user already saw applied.
     */
    suspend fun persistSelection(group: String, tag: String, nodeId: Long?) {
        val profileId = withContext(Dispatchers.IO) { selectionProfileId(group, tag, nodeId) } ?: return
        withContext(Dispatchers.IO) {
            val previous = applySelection(profileId, announce = false) ?: return@withContext
            runCatching {
                ProfileManager.getProfile(previous)?.let { ProfileManager.postUpdate(it.id, true) }
                ProfileManager.postUpdate(profileId, true)
            }
        }
        // The core already logged the switch itself (groups_actions.go); this records the
        // other half, so a report can tell "switched but not remembered" from "not switched".
        KernelServiceActions.note("select: persisted $group -> $tag")
        FlroneBridge.scheduleRefresh(immediate = true)
    }

    /**
     * The reload path: persist the member, then let the core rebuild with it. The broadcast is
     * the legacy service's hot-switch signal; in ffiMode Dart refreshes the core itself
     * (`onSelectionChanged`), which is the caller's step. A no-op when the names resolve to
     * nothing, like the old method.
     */
    suspend fun selectMemberAwait(group: String, tag: String, nodeId: Long?) {
        val profileId = withContext(Dispatchers.IO) { selectionProfileId(group, tag, nodeId) } ?: return
        selectSuspend(profileId)
    }

    /** Makes [profileId] the selection; a running service switches to it instead of restarting from scratch. */
    fun select(profileId: Long) {
        val previous = applySelection(profileId) ?: return
        scope.launch { postSelectionUpdate(profileId, previous) }
    }

    /**
     * Writes the selection and asks a running service to switch to it. Returns the profile that
     * was selected before, or null when [profileId] is not a usable selection, so the caller can
     * post the row updates for both sides of the change.
     */
    private fun applySelection(profileId: Long, announce: Boolean = true): Long? {
        if (profileId <= 0L) return null
        val previous = DataStore.selectedProxy
        DataStore.selectedProxy = profileId
        DataStore.currentProfile = profileId
        if (announce && DataStore.serviceState.canStop && previous != profileId) {
            app.sendBroadcast(
                Intent(Action.SWITCH_PROFILE)
                    .setPackage(app.packageName)
                    .putExtra(Action.EXTRA_PROFILE_ID, profileId)
            )
        }
        return previous
    }

    /** Refreshes both affected profile rows and the catalog; IO-bound, so it hops off the caller. */
    private suspend fun postSelectionUpdate(profileId: Long, previous: Long) {
        withContext(Dispatchers.IO) {
            runCatching {
                ProfileManager.getProfile(previous)?.let { ProfileManager.postUpdate(it.id, true) }
                ProfileManager.postUpdate(profileId, true)
            }
        }
        FlroneBridge.scheduleRefresh(immediate = true)
    }

    /**
     * The proxy page's card and group actions need the call to live for as long
     * as the spinner should. Resolve the target, start one session, and answer
     * once that session has finished.
     */
    suspend fun testNodeAwait(tag: String, profileIds: List<Long> = emptyList()): Boolean {
        val target = withContext(Dispatchers.IO) {
            if (profileIds.isNotEmpty()) {
                val ids = profileIds.distinct()
                return@withContext urlTestSpec(ids, tag) to 0L
            }
            val groups = GroupRepo.all()
            val group = groups.firstOrNull { it.displayName() == tag }
            if (group != null) {
                val ids = ProfileManager.memberIds(group.id)
                return@withContext if (ids.isEmpty()) null else {
                    urlTestSpec(ids, group.displayName()) to group.id
                }
            }
            val owner = groups.firstOrNull { candidate ->
                ProfileManager.members(candidate.id).any { it.displayName() == tag }
            } ?: return@withContext null
            val profile = ProfileManager.members(owner.id).firstOrNull { it.displayName() == tag }
                ?: return@withContext null
            urlTestSpec(listOf(profile.id), profile.displayName()) to profile.groupId
        } ?: return false
        val before = TestSessionClient.state.value
        if (!TestSessionClient.start(target.first, target.second)) return false
        watchTestSession()
        // Scaled by the node count: the flat 45 s cap cut big group runs off mid-sweep.
        val finished = withTimeoutOrNull(sessionBudgetMs(target.first)) {
            TestSessionClient.state.first { state ->
                !state.running && (state.startedAt > before.startedAt || state.session != before.session)
            }
        }
        if (finished != null) return true
        TestSessionClient.stop()
        delay(500)
        FlroneBridge.scheduleRefresh(immediate = true)
        return false
    }

    fun selectProfile(id: Long) {
        scope.launch { selectProfileAwait(id) }
    }

    /** Awaitable variant: completes after the selection is persisted, so the caller can
     *  safely rebuild the core config without racing the DB write. */
    suspend fun selectProfileAwait(id: Long) {
        val member = withContext(Dispatchers.IO) {
            val group = GroupRepo.get(id) ?: return@withContext null
            GroupRepo.setCurrent(group.id)
            // The selection moves even while the service runs (switchProfile hot-switches it):
            // the profile card, the proxies screen and the running config all follow the same
            // selected member. A group that already holds it keeps it; another gets its first.
            val ids = ProfileManager.memberIds(group.id)
            ids.firstOrNull { it == DataStore.selectedProxy } ?: ids.firstOrNull()
        }
        member?.let { selectSuspend(it) }
        FlroneBridge.scheduleRefresh(immediate = true)
    }

    /** Awaitable variant of [select]: returns after the selection is written and the
     *  profile-update notifications are dispatched. */
    suspend fun selectSuspend(profileId: Long) {
        val previous = applySelection(profileId) ?: return
        postSelectionUpdate(profileId, previous)
    }

    fun updateSubscription(id: Long) {
        if (id <= 0L) return
        runCatching { SubscriptionQueue.refreshGroup(id, showDiff = true) }
            .onFailure { Logs.w(it) }
    }

    /**
     * Previous / next server, the television's way of changing profiles (TvControls.switchServer):
     * a running service hot-switches through the same broadcast its notification buttons send, a
     * stopped one just moves the selection inside the current group.
     */
    fun switchServer(step: Int) {
        if (step == 0) return
        if (DataStore.serviceState.canStop) {
            app.sendBroadcast(
                Intent(if (step > 0) Action.SWITCH_NEXT else Action.SWITCH_PREVIOUS)
                    .setPackage(app.packageName)
            )
            return
        }
        scope.launch {
            val moved = withContext(Dispatchers.IO) {
                val old = DataStore.selectedProxy
                val target = ProfileOrder.neighbour(old, step) ?: return@withContext null
                DataStore.selectedProxy = target.id
                old to target.id
            } ?: return@launch
            withContext(Dispatchers.IO) {
                runCatching {
                    ProfileManager.postUpdate(moved.first, true)
                    ProfileManager.postUpdate(moved.second, true)
                }
            }
            FlroneBridge.scheduleRefresh(immediate = true)
        }
    }

    fun deleteProfile(id: Long) {
        if (id <= 0L) return
        scope.launch {
            withContext(Dispatchers.IO) { runCatching { GroupRepo.delete(id) } }
            FlroneBridge.scheduleRefresh(immediate = true)
        }
    }

    fun openUrl(url: String) {
        if (url.isBlank()) return
        runCatching {
            app.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }.onFailure { Logs.w(it) }
    }
}
