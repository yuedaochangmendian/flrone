package io.nekohasekai.sagernet.bg

import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.readableMessage
import io.flrone.core.CoreHost
import io.nekohasekai.sagernet.outbound.json.jsonObjectOf

/**
 * The core's WARP registration (rpc/warp.go through core/mobile/warp.go), called in-process since P6. Blocks the
 * calling thread for at most 10 s + 10 s per API host; like the desktop RPC, failures travel in "error" instead of as
 * exceptions. Callers must run this off the main thread.
 */
object WarpRegistration {

    /** Returns sorted-key JSON: {"device_id","endpoint","error","ipv4","ipv6","license","peer_public_key","private_key","reserved","token"}. */
    fun register(tunnelType: String, proxy: String, apiHosts: Array<String>): String = try {
        CoreHost.warpRegister(tunnelType, proxy, apiHosts.toList())
    } catch (e: Throwable) {
        Logs.w(e)
        jsonObjectOf("error" to e.readableMessage).toCompact()
    }
}
