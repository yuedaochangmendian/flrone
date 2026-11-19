package io.nekohasekai.sagernet.bg.autoselector

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * The UI's copy of the auto-selector status without its member table.
 *
 * It used to be fed by every SagerConnection binder callback. Service + UI now share one process and
 * the binder is gone, so the status is read straight from [AutoSelectorRuntime] (the same in-process
 * source BboxProfiles reads) and mirrored into a StateFlow for any legacy consumer.
 */
object AutoSelectorClient {

    private val mutableStatus = MutableStateFlow(AutoSelectorStatus.IDLE)

    val status: StateFlow<AutoSelectorStatus> = mutableStatus

    /** Re-reads the status from the in-process runtime. */
    fun refresh() {
        mutableStatus.value = AutoSelectorStatus.parse(AutoSelectorRuntime.statusJson(withMembers = false))
    }

    /** The service stopped: the runtime cleared its notice, so re-read the (now idle) status. */
    fun reset() = refresh()
}
