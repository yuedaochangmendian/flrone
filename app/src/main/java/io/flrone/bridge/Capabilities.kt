package io.flrone.bridge

import android.os.Build
import io.nekohasekai.sagernet.BuildConfig
import io.nekohasekai.sagernet.SagerNet

/**
 * The single source of truth for what the Flutter UI may show.
 *
 * The host advertises this manifest on `ready`, and the UI prunes its navigation from it instead of
 * leaving entries that could only ever open an empty page. Every flag here is a screen this bridge
 * actually answers: the B-box-only features that had no counterpart (local SSH terminal, request
 * capture, remote sessions, crash/oom/power reports, STUN and network-quality sampling, the
 * Tailscale/OpenVPN/OpenConnect/usbip endpoints, Taildrop) were removed from the app together with
 * their flags, not left advertised-but-false.
 *
 * Keep this list in step with [ThroneBoxBridge]'s dispatch: a capability is only true when the
 * channels behind it exist, so the UI never opens a page that fails every call.
 */
object Capabilities {

    fun map(): Map<String, Any> = mapOf(

        "routes" to true,          // route profiles/rules are kernel-owned over the action bus; see BboxActions (presets) and route_actions.go
        "autoSelector" to true,    // type=autoselector nodes over profiles.autoSelector*, see BboxProfiles

        // --- Throne has it ------------------------------------------------------------------------
        "connections" to true,     // core's own clash-api /connections, see BboxApi
        "logs" to true,            // core.log tail, see BboxLogs
        "groups" to true,          // subscription groups
        "memory" to true,          // core's /memory endpoint, see the memory wire
        "proxyGroups" to true,     // groups.list / groups.select / groups.test
        "clashModes" to true,      // mode.set (rule / global / direct)
        "perApp" to true,          // PROXY_APPS / BYPASS_MODE / INDIVIDUAL
        "backup" to true,          // .thrbackup and WebDAV, see BboxBackup
        "lanProxy" to true,        // mixed inbound "Allow LAN" plus its port
        "tv" to SagerNet.isTv,     // the profiles toolbar's previous / next server over profiles.switchRelative
        "update" to BuildConfig.IN_APP_UPDATER,
        // The VPN service can write its mixed inbound into the system HTTP settings, which Android
        // only allows from API 29 and only outside the proxy-only service mode.
        "systemProxy" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q),
    )
}
