package io.nekohasekai.sagernet.bg

import android.content.ComponentName
import android.graphics.drawable.Icon
import android.service.quicksettings.Tile
import androidx.annotation.RequiresApi
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.SagerDatabase
import android.service.quicksettings.TileService as BaseTileService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Quick settings tile. Service + tile now share one process (P6), so the tile reads the live
 * DataStore.serviceState directly instead of binding the service over AIDL. State changes push a
 * listening-state request so onStartListening re-reads it while the tile is visible.
 */
@RequiresApi(24)
class TileService : BaseTileService() {
    private val tileIcon by lazy { Icon.createWithResource(this, R.drawable.ic_throne_tile) }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    override fun onStartListening() {
        super.onStartListening()
        refresh()
    }

    override fun onClick() {
        if (isLocked) unlockAndRun(this::toggle) else toggle()
    }

    private fun refresh() {
        val state = DataStore.serviceState
        val runningId = DataStore.baseService?.data?.runningProfileId ?: 0L
        val id = runningId.takeIf { it > 0L } ?: DataStore.selectedProxy
        // The tile is drawn on the main thread and the profile name comes from Room: read it
        // off-thread and post the label back. (`.allowMainThreadQueries()` made the old inline
        // read "work" by blocking the UI thread for the length of the query.)
        scope.launch {
            val name = runCatching { ProfileManager.getProfile(id)?.displayName() }.getOrNull()
            withContext(Dispatchers.Main) { updateTile(state, name) }
        }
    }

    private fun updateTile(serviceState: BaseService.State, profileName: String?) {
        qsTile?.apply {
            label = null
            icon = tileIcon
            // Only a live tunnel draws as on. A start that is still preparing (Connecting) is
            // not a tunnel, and the tile has no busy pictogram: it reads as off, which is also
            // what its label says and what a tap then does (stop the start).
            val active = ServiceStateRules.isActiveState(serviceState)
            state = when {
                active -> Tile.STATE_ACTIVE
                serviceState == BaseService.State.Stopping -> Tile.STATE_UNAVAILABLE
                else -> Tile.STATE_INACTIVE
            }
            if (active) label = profileName
            label = label ?: getString(R.string.app_name)
            updateTile()
        }
    }

    private fun toggle() {
        val state = DataStore.serviceState
        when {
            state.canStop -> SagerNet.stopService()
            state == BaseService.State.Stopped || state == BaseService.State.Idle ->
                SagerNet.startServiceQuick()
        }
    }
}

/** Same-process trigger so the tile re-reads shared state without an AIDL callback. */
object TileUpdater {
    fun refresh(context: android.content.Context) {
        runCatching {
            BaseTileService.requestListeningState(
                context, ComponentName(context, TileService::class.java)
            )
        }
    }
}
