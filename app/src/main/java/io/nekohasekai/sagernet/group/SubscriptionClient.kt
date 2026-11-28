package io.nekohasekai.sagernet.group

import io.nekohasekai.sagernet.database.GroupRepo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * The UI's entry to the in-process subscription queue (the desktop's GroupUpdater: RefreshGroup, RefreshAll,
 * SubscribeUrl, ImportUrl, ImportText). Since P6 the UI and service share one process, so these call [SubscriptionQueue]
 * directly. [states] and [reports] are fed by one listener registration that lives while either of them is collected.
 */
object SubscriptionClient {

    /** One subscription event: a change report (popup = show the change window), an error or a reload hint. */
    data class Report(
        val gid: Long,
        val title: String,
        val text: String,
        val popup: Boolean,
        val error: Boolean,
        val reload: Boolean = false,
    )

    /** One queue state transition, forwarded to the UI so a refresh spinner can span the whole download. */
    data class StateEvent(val gid: Long, val state: Int)

    /** The registration outlives the last collector by this much (configuration changes). */
    private const val STOP_DELAY_MS = 5_000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val mutableStates = MutableStateFlow<Map<Long, Int>>(emptyMap())

    /** gid → 1 queued / 2 running ([SubscriptionQueue.STATE_QUEUED], [SubscriptionQueue.STATE_RUNNING]); absent = idle. */
    val states: StateFlow<Map<Long, Int>> get() = mutableStates

    private val mutableReports = MutableSharedFlow<Report>(
        extraBufferCapacity = 64,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /**
     * Refresh reports (popup only for a manual refresh with sub_show_change_popup), after-URL-test reports and
     * importUrl results (popup false), and errors of the requests made here (gid -1 = no single group).
     */
    val reports: SharedFlow<Report> get() = mutableReports

    /**
     * Queue state transitions, replayed to a fresh collector by [SubscriptionQueue.register]. Separate from
     * [reports] so a spinner does not depend on a report being produced (a successful refresh has no popup).
     */
    private val mutableStateEvents = MutableSharedFlow<StateEvent>(
        extraBufferCapacity = 64,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val stateEvents: SharedFlow<StateEvent> get() = mutableStateEvents

    private val listenerLock = Any()
    private var listener: Job? = null
    private var stopper: Job? = null

    init {
        scope.launch {
            combine(
                mutableStates.subscriptionCount,
                mutableReports.subscriptionCount,
                mutableStateEvents.subscriptionCount,
            ) { a, b, c -> a + b + c }
                .collect { subscribersChanged(it) }
        }
    }

    // ------------------------------------------------------------------------------------------------ callbacks

    private fun subscriberCount(): Int = mutableStates.subscriptionCount.value +
        mutableReports.subscriptionCount.value + mutableStateEvents.subscriptionCount.value

    private fun subscribersChanged(count: Int) {
        synchronized(listenerLock) {
            if (count > 0) {
                stopper?.cancel()
                stopper = null
                if (listener == null) listener = scope.launch { listen() }
                return
            }
            if (listener == null || stopper != null) return
            val job = scope.launch(start = CoroutineStart.LAZY) {
                delay(STOP_DELAY_MS)
                synchronized(listenerLock) {
                    if (stopper !== coroutineContext[Job]) return@synchronized
                    stopper = null
                    if (subscriberCount() == 0) {
                        listener?.cancel()
                        listener = null
                    }
                }
            }
            stopper = job
            job.start()
        }
    }

    private suspend fun listen() {
        // Same process as the queue: register an in-process listener, no AIDL bind or service-death path.
        val listener = object : SubscriptionQueue.SubscriptionListener {
            override fun onState(gid: Long, state: Int) {
                mutableStates.update { if (state == SubscriptionQueue.STATE_IDLE) it - gid else it + (gid to state) }
                // Forward every transition (including the register-time replay) to the UI so a
                // spinner can span the whole download, not just the enqueue round-trip.
                mutableStateEvents.tryEmit(StateEvent(gid, state))
                // In-process listeners (group rows, profile lists) learn about the writes here.
                if (state == SubscriptionQueue.STATE_IDLE) scope.launch {
                    GroupRepo.postUpdate(gid)
                    GroupRepo.postReload(gid)
                }
            }

            override fun onReport(gid: Long, title: String, text: String, popup: Boolean) {
                mutableReports.tryEmit(Report(gid, title, text, popup, error = false))
            }

            override fun onError(gid: Long, message: String) {
                mutableReports.tryEmit(Report(gid, "", message, popup = false, error = true))
            }

            override fun onReloadNeeded(gid: Long) {
                mutableReports.tryEmit(Report(gid, "", "", popup = false, error = false, reload = true))
            }
        }
        SubscriptionQueue.register(listener)
        try {
            awaitCancellation()
        } finally {
            SubscriptionQueue.unregister(listener)
            mutableStates.value = emptyMap()
        }
    }
}
