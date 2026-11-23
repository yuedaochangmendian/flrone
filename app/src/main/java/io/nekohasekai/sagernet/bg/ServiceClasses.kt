package io.nekohasekai.sagernet.bg

import io.nekohasekai.sagernet.Key

// Which foreground service a start means, and which one must go first.
//
// `SagerNet.startService` starts the class the current mode names; that is the single point
// every start path reaches (UI bridge, service engine, tile/boot/widget quick start, VPN
// consent). FlClash's ServiceController stops the *other* component before starting the
// selected one (ServiceController.kt:81-85,134-141) — a mode switch otherwise leaves the
// previous tunnel running while the app, its notification and the kernel all believe in the
// new one. The "stop the other class" rule therefore lives in `SagerNet.startService`, and
// this mapping is kept pure so the JVM tests pin it without an Application.

internal object ServiceClasses {

    /** The class the mode runs. */
    fun forMode(mode: String): Class<*> = when (mode) {
        Key.MODE_PROXY -> ProxyService::class.java
        Key.MODE_VPN -> VpnService::class.java
        else -> throw UnknownError("unknown service mode: $mode")
    }

    /** The class a start in [mode] stops first: one tunnel at a time. */
    fun other(mode: String): Class<*> = when (mode) {
        Key.MODE_PROXY -> VpnService::class.java
        Key.MODE_VPN -> ProxyService::class.java
        else -> throw UnknownError("unknown service mode: $mode")
    }
}
