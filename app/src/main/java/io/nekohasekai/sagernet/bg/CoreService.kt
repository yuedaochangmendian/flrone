package io.nekohasekai.sagernet.bg

import android.app.Service
import android.content.Intent
import android.os.IBinder

/**
 * Foreground-service host for the diagnostic/core-foreground holders. Since P6 the UI and this
 * service share one process (there is no `:bg` process any more), and Phase B moved every
 * former binder caller (widget/tile/shortcuts, subscriptions, test sessions, WARP) to in-process
 * facades, so this service no longer exposes a binder. It exists solely to keep the process
 * foreground while [CoreForeground] holders are active (CoreForeground starts/stops it).
 */
class CoreService : Service() {

    override fun onCreate() {
        super.onCreate()
        CoreForeground.attach(this)
    }

    /** No AIDL any more: all former binders call the in-process facades directly. */
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        CoreForeground.onStartCommand(this, startId)

    override fun onTimeout(startId: Int, fgsType: Int) = CoreForeground.onTimeout(this)

    override fun onDestroy() {
        CoreForeground.detach(this)
        super.onDestroy()
    }
}
