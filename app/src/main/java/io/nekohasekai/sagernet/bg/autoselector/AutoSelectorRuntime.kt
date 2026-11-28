package io.nekohasekai.sagernet.bg.autoselector

import androidx.annotation.StringRes
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.group.SubscriptionQueue
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock

/**
 * The host's shadow of the auto-selector the service engine's Dart kernel runs.
 *
 * Since P6 the core (and with it the selector's live core handle) is owned by the service engine; the host no longer
 * builds a ProxyInstance, so it cannot sample, pin at runtime, or recheck a live core — the parts of the old runtime
 * that hung off ProxyInstance.init/launch/close were only ever reached in the removed non-FFI path. What survives is
 * the stored selector state: the pin the editor writes (which reaches the next config build), and the subscription
 * pruning of selectors that track a refreshed group. Pin/recheck keep the call contract and report their result as a
 * status notice; the live core work happens in the service engine.
 */
object AutoSelectorRuntime {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private var notice = ""
    private var noticeAtMs = 0L

    /** Process start: subscription refreshes prune the selectors that track the refreshed group. */
    fun install() {
        SubscriptionQueue.addGroupChangedListener { gid, _ -> onGroupChanged(gid) }
    }

    /** The status the old cbAutoSelectorUpdate carried; the live status now comes from the service engine. */
    fun statusJson(withMembers: Boolean): String = synchronized(this) {
        AutoSelectorStatus(notice = notice, noticeAtMs = noticeAtMs).toJson()
    }

    /**
     * Applies a pin. Dart's `ProfileDocumentService` already persists the pin in
     * `profiles.json` (S7); the host's narrow `autoSelectorRuntimePin` op forwards
     * it here. The engine applies it on rebuild — there is no host-owned core to
     * take it now (as in FFI mode before), so report that plainly.
     */
    fun select(memberProfileId: Long) = post(R.string.autosel_notice_not_running)

    /** The editor's "Use automatic": FlroneProfiles clears the stored pin; nothing to apply to a host core. */
    fun releasePin(selectorId: Long) = Unit

    /** The live re-probe happens in the service engine's core; there is no host core to recheck. */
    fun recheck() = post(R.string.autosel_notice_not_running)

    /** BaseService ended stopped: clear the transient notice. */
    fun serviceStopped() {
        synchronized(this) {
            notice = ""
            noticeAtMs = 0L
        }
    }

    /** on_subscription_group_changed (mainwindow_autoselector.cpp:33-65). */
    private fun onGroupChanged(gid: Long) {
        if (gid < 0) return
        scope.launch(Dispatchers.IO) {
            for (id in AutoSelectorProfiles.ids()) {
                AutoSelectorProfiles.writes.withLock {
                    val selector = AutoSelectorProfiles.load(id)?.takeIf { gid in it.gids } ?: return@withLock
                    val alive = AutoSelectorProfiles.existing(selector.pool + selector.lastBuilt)
                    if (selector.pool.removeAll { it !in alive } || selector.lastBuilt.removeAll { it !in alive }) {
                        AutoSelectorProfiles.save(id, selector)
                    }
                }
            }
        }.invokeOnCompletion { error -> if (error != null) Logs.w(error) }
    }

    private fun post(@StringRes text: Int) = post(app.getString(text))

    private fun post(text: String) {
        synchronized(this) {
            notice = text
            noticeAtMs = System.currentTimeMillis()
        }
    }
}
