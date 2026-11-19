package io.nekohasekai.sagernet.bg

import android.content.ComponentName
import android.graphics.drawable.Icon
import android.service.quicksettings.Tile
import androidx.annotation.RequiresApi
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.SagerDatabase
import android.service.quicksettings.TileService as BaseTileService

/**
 * Quick settings tile. Service + tile now share one process (P6), so the tile reads the live
 * DataStore.serviceState directly instead of binding the service over AIDL. State changes push a
 * listening-state request so onStartListening re-reads it while the tile is visible.
 */
@RequiresApi(24)
class TileService : BaseTileService() {
    private val tileIcon by lazy { Icon.createWithResource(this, R.drawable.ic_throne_tile) }

    override fun onStartListening() {
        super.onStartListening()
        refresh()
    }

    override fun onClick() {
        if (isLocked) unlockAndRun(this::toggle) else toggle()
    }

    private fun refresh() {
        val state = DataStore.serviceState
        val profile = DataStore.baseService?.data?.proxy?.profile
            ?: SagerDatabase.proxyDao.getById(DataStore.selectedProxy)
        updateTile(state, profile?.displayName())
    }

    private fun updateTile(serviceState: BaseService.State, profileName: String?) {
        qsTile?.apply {
            label = null
            icon = tileIcon
            when (serviceState) {
                BaseService.State.Idle -> state = Tile.STATE_INACTIVE
                BaseService.State.Connecting -> state = Tile.STATE_ACTIVE
                BaseService.State.Connected -> {
                    label = profileName
                    state = Tile.STATE_ACTIVE
                }

                BaseService.State.Stopping -> state = Tile.STATE_UNAVAILABLE
                BaseService.State.Stopped -> state = Tile.STATE_INACTIVE
            }
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
