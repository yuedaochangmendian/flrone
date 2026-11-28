package io.nekohasekai.sagernet.group

import android.os.Handler
import android.os.Looper
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.bg.CoreForeground
import io.nekohasekai.sagernet.bg.test.TestEngine
import io.nekohasekai.sagernet.database.GroupRepo
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.ktx.readableMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The in-process subscription job queue (GroupUpdater, GroupUpdater.cpp:321-446): jobs run one at a time in FIFO
 * order; a group is queued at most once; a batch refuses to start while the previous one runs. Since P6 the service
 * and UI share one process, so callers (SubscriptionClient) invoke these entry points directly instead of binding
 * CoreService. Jobs keep CoreService in the foreground and report their failures through [listeners].
 */
object SubscriptionQueue {

    const val STATE_IDLE = 0
    const val STATE_QUEUED = 1
    const val STATE_RUNNING = 2

    private const val FOREGROUND_REASON = "subscriptions"

    /** Posts subscription events to the main thread; matches the old oneway AIDL callback's async delivery. */
    private val mainHandler = Handler(Looper.getMainLooper())

    /** In-process listeners, replacing the old cross-process callback registry. */
    private val listeners = CopyOnWriteArrayList<SubscriptionListener>()

    /**
     * The in-process subscription event sink. Methods are dispatched on the main thread, mirroring the old oneway
     * binder callback so the StateFlow/SharedFlow collectors observe the same delivery semantics.
     */
    interface SubscriptionListener {
        /** state: [STATE_IDLE] / [STATE_QUEUED] / [STATE_RUNNING]. */
        fun onState(gid: Long, state: Int) {}
        fun onReport(gid: Long, title: String, text: String, popup: Boolean) {}
        fun onError(gid: Long, message: String) {}
        /** A refresh re-pointed a route reference the running config was built from. */
        fun onReloadNeeded(gid: Long) {}
    }

    /** SubscriptionGroupChanged: [disturbed] profiles were deleted or changed in place (auto selectors re-plan). */
    fun interface GroupChangedListener {
        fun onGroupChanged(gid: Long, disturbed: List<Long>)
    }

    private val groupChangedListeners = CopyOnWriteArrayList<GroupChangedListener>()

    fun addGroupChangedListener(listener: GroupChangedListener) {
        groupChangedListeners.addIfAbsent(listener)
    }

    private class Job(val gid: Long, val batch: Boolean, val foreground: Boolean, val run: suspend () -> Unit)

    // Guards the queue and the state events: a callback registered meanwhile never sees them out of order.
    private val lock = Any()
    private val queue = ArrayDeque<Job>()
    private val pending = HashSet<Long>()
    private var pendingBatch = 0
    private var draining = false
    private var runningGid = -1L

    /** Queued or running jobs plus URL-test follow-ups not yet queued. */
    private val outstanding = MutableStateFlow(0)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // ------------------------------------------------------------------------------------------------ callbacks

    fun register(listener: SubscriptionListener) {
        synchronized(lock) {
            if (listeners.addIfAbsent(listener)) {
                // Replay the current states on the main thread, like the old oneway binder callback did.
                for (gid in pending) {
                    val state = if (gid == runningGid) STATE_RUNNING else STATE_QUEUED
                    mainHandler.post { runCatching { listener.onState(gid, state) }.onFailure { Logs.w(it) } }
                }
            }
        }
    }

    fun unregister(listener: SubscriptionListener) {
        listeners.remove(listener)
    }

    /** Dispatch to all listeners on the main thread; a single bad listener must not silence the others. */
    private fun broadcast(action: (SubscriptionListener) -> Unit) {
        mainHandler.post {
            for (listener in listeners) {
                runCatching { action(listener) }.onFailure { Logs.w(it) }
            }
        }
    }

    private fun stateLocked(gid: Long, state: Int) = broadcast { it.onState(gid, state) }

    internal fun report(gid: Long, title: String, text: String, popup: Boolean) =
        broadcast { it.onReport(gid, title, text, popup) }

    internal fun error(gid: Long, message: String) = broadcast { it.onError(gid, message) }

    internal fun reloadNeeded(gid: Long) = broadcast { it.onReloadNeeded(gid) }

    internal fun groupChanged(gid: Long, disturbed: List<Long>) {
        for (listener in groupChangedListeners) {
            runCatching { listener.onGroupChanged(gid, disturbed) }.onFailure { Logs.w(it) }
        }
    }

    // ------------------------------------------------------------------------------------------------ entry points

    /** RefreshGroup (GroupUpdater.cpp:331-345); [showDiff] asks for the change window (manual refreshes). */
    fun refreshGroup(gid: Long, showDiff: Boolean) = refreshGroup(gid, showDiff, foreground = true)

    fun refreshGroup(gid: Long, showDiff: Boolean, foreground: Boolean) =
        refreshGroup(gid, if (showDiff) SubscriptionRefresh.Surface.Diff else SubscriptionRefresh.Surface.Log, foreground)

    /** RefreshGroup with the Surface its problems go to (GroupUpdater.cpp). */
    internal fun refreshGroup(gid: Long, surface: SubscriptionRefresh.Surface, foreground: Boolean) {
        val queued = synchronized(lock) {
            if (gid in pending) return@synchronized false
            pending.add(gid)
            enqueueLocked(Job(gid, batch = false, foreground) { SubscriptionRefresh.refresh(gid, surface, foreground) })
            true
        }
        if (!queued) Logs.i(app.getString(R.string.subs_already_queued, groupLabel(gid)))
    }

    /**
     * RefreshAll (GroupUpdater.cpp:347-365): every subscription group in tab order except archived ones and, with
     * [onlyAllowed] (the automatic update), those that skip automatic updates.
     */
    fun refreshAll(onlyAllowed: Boolean) = refreshAll(onlyAllowed, foreground = true)

    fun refreshAll(onlyAllowed: Boolean, foreground: Boolean) {
        val groups = GroupRepo.all()
        val refused = synchronized(lock) {
            if (pendingBatch > 0) return@synchronized true
            for (group in groups) {
                if (group.url.isEmpty() || group.archive || (onlyAllowed && group.skipAutoUpdate)) continue
                val gid = group.id
                if (gid in pending) continue
                pending.add(gid)
                pendingBatch++
                enqueueLocked(Job(gid, batch = true, foreground) { SubscriptionRefresh.refresh(gid, SubscriptionRefresh.Surface.Log, foreground) })
            }
            false
        }
        if (refused) {
            val message = app.getString(R.string.subs_batch_running)
            Logs.i(message)
            if (foreground) error(-1L, message)
        }
    }

    /** Suspends until no job is queued or running and no URL-test follow-up is pending. */
    suspend fun awaitIdle() {
        outstanding.first { it == 0 }
    }

    /**
     * requestUrlTest (GroupUpdater.cpp:658-667): the URL test waits for any running test session; the follow-up
     * goes back through the queue, so it never races another job over the group.
     */
    internal fun requestUrlTest(gid: Long, profileIds: List<Long>) {
        outstanding.update { it + 1 }
        scope.launch {
            try {
                try {
                    TestEngine.queueUrlTests(profileIds)
                } catch (e: Exception) {
                    if (e is CancellationException) ensureActive() else Logs.w(e)
                }
                synchronized(lock) {
                    enqueueLocked(Job(-1L, batch = false, foreground = false) { SubscriptionRefresh.afterUrlTest(gid) })
                }
            } finally {
                outstanding.update { it - 1 }
            }
        }
    }

    // ------------------------------------------------------------------------------------------------ worker

    private fun enqueueLocked(job: Job) {
        queue.addLast(job)
        outstanding.update { it + 1 }
        if (job.foreground) CoreForeground.acquire(FOREGROUND_REASON)
        if (job.gid >= 0) stateLocked(job.gid, STATE_QUEUED)
        if (draining) return
        draining = true
        scope.launch { drain() }
    }

    private suspend fun drain() {
        while (true) {
            val job = synchronized(lock) {
                val next = queue.removeFirstOrNull()
                if (next == null) {
                    draining = false
                } else if (next.gid >= 0) {
                    runningGid = next.gid
                    stateLocked(next.gid, STATE_RUNNING)
                }
                next
            } ?: return
            try {
                job.run()
            } catch (e: Throwable) {
                // Anything thrown here would otherwise take the whole :bg process (and the VPN) down.
                val message = app.getString(R.string.subs_task_failed, e.readableMessage)
                Logs.w(message, e)
                if (job.foreground) error(job.gid, message)
            } finally {
                synchronized(lock) {
                    runningGid = -1L
                    if (job.gid >= 0) {
                        pending.remove(job.gid)
                        stateLocked(job.gid, STATE_IDLE)
                    }
                    if (job.batch) pendingBatch--
                }
                if (job.foreground) CoreForeground.release(FOREGROUND_REASON)
                outstanding.update { it - 1 }
            }
        }
    }

    private fun groupLabel(gid: Long): String = GroupRepo.get(gid)?.name ?: gid.toString()
}
