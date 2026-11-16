package io.flrone.bridge

import io.nekohasekai.sagernet.aidl.SpeedDisplayData
import io.flrone.model.Traffic
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Turns the service's speed callbacks into the dashboard's figures.
 *
 * The service pushes [SpeedDisplayData] about once a second with the proxy-only rates and the
 * session totals; this holds the latest set for [traffic].
 *
 * It used to also keep a 30 point FloatArray window per direction for the sparkline. Nothing read
 * those arrays: the chart is accumulated on the Dart side from the 1 Hz `rates` event (see
 * `BoxController.trafficWindow`), and the copies in `DashboardState` were never put on the wire.
 * Keeping them cost two 30-element array allocations and ~60 boxed floats every second, for the
 * whole session, including while no UI was attached.
 */
class BboxTrafficMeter {

    private val _traffic = MutableStateFlow(Traffic())
    val traffic: StateFlow<Traffic> = _traffic.asStateFlow()

    @Synchronized
    fun onSpeed(stats: SpeedDisplayData) {
        _traffic.value = Traffic(
            uploadRate = stats.txRateProxy,
            downloadRate = stats.rxRateProxy,
            uploadTotal = stats.txTotal,
            downloadTotal = stats.rxTotal,
        )
    }

    @Synchronized
    fun reset() {
        _traffic.value = Traffic()
    }
}
