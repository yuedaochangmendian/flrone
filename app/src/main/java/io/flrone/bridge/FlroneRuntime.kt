package io.flrone.bridge

import android.content.Context

/**
 * Process-wide entry point for the B-box bridge.
 *
 * [SagerNet.onCreate] calls [install] in the main process, before any activity exists, so the service connection and
 * the repository listeners are already in place when the first screen composes. Keeping the wiring here rather than
 * in an activity means the state survives rotation and the dashboard has numbers the moment it is drawn.
 */
object FlroneRuntime {

    @Volatile
    private var installed = false

    fun install(context: Context) {
        if (installed) return
        installed = true
        FlroneBridge.install(context)
    }

    fun shutdown() {
        if (!installed) return
        installed = false
        FlroneBridge.shutdown()
    }
}
