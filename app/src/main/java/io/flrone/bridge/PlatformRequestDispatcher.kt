// The one `platform_request` dispatcher, shared by production and the JVM test.
// FlroneCorePlatform hands it the live host handlers; the test injects fakes. Keeping a single
// `when` here is what makes the test pin the real method names/payload shape rather than a mirror.
package io.flrone.bridge

import org.json.JSONObject

/**
 * The JSON `platform_request` router. [hosts] holds one lambda per Android/platform duty so
 * this class has no Android dependency and can run on a bare JVM. Production supplies the live
 * FlroneCorePlatform handlers; [PlatformRequestRouterTest] supplies counting fakes. The unknown
 * branch deliberately returns the same error string as the app so the test pins it too.
 */
internal class PlatformRequestDispatcher(private val hosts: Hosts) {

    /** Host handlers behind the single duty facade. No Android types leak into this boundary. */
    internal data class Hosts(
        val appendCoreLog: (level: Int, message: String) -> Unit,
        val openTun: (options: Long) -> Int,
        val usePlatformAutoDetectInterfaceControl: () -> Boolean,
        val useProcFS: () -> Boolean,
        val findConnectionOwner: (
            ipProtocol: Int,
            sourceAddress: String,
            sourcePort: Int,
            destinationAddress: String,
            destinationPort: Int,
        ) -> String,
        val packageNamesByUid: (uid: Int) -> String,
        val startDefaultInterfaceMonitor: (listener: Long) -> String,
        val closeDefaultInterfaceMonitor: (listener: Long) -> String,
        val getInterfaces: () -> String,
        val readWifiState: () -> String,
        val clearDnsCache: () -> Unit,
        val sendNotification: (payloadJson: String) -> String,
        val cancelNotification: (identifier: String, typeId: Int) -> String,
        val localDnsRaw: () -> String,
        val localDnsLookup: (ctx: Long, network: String, domain: String) -> String,
        val localDnsExchange: (ctx: Long, message: String) -> String,
        val cancelDnsExchange: (ctx: Long) -> String,
        val testSession: (method: String, payloadJson: String) -> String,
    )

    fun dispatch(method: String, payloadJson: String): String {
        val payload = runCatching { JSONObject(payloadJson) }.getOrDefault(JSONObject())
        return when (method) {
            "log" -> {
                hosts.appendCoreLog(payload.optInt("level"), payload.optString("message"))
                ""
            }
            "open_tun" -> hosts.openTun(payload.optLong("options")).toString()
            "use_platform_auto_detect_interface_control" -> hosts.usePlatformAutoDetectInterfaceControl().toString()
            "use_proc_fs" -> hosts.useProcFS().toString()
            "find_connection_owner" -> hosts.findConnectionOwner(
                payload.optInt("ipProtocol"),
                payload.optString("sourceAddress"),
                payload.optInt("sourcePort"),
                payload.optString("destinationAddress"),
                payload.optInt("destinationPort"),
            )
            "package_names_by_uid" -> hosts.packageNamesByUid(payload.optInt("uid", -1))
            "start_default_interface_monitor" -> hosts.startDefaultInterfaceMonitor(payload.optLong("listener"))
            "close_default_interface_monitor" -> hosts.closeDefaultInterfaceMonitor(payload.optLong("listener"))
            "get_interfaces" -> hosts.getInterfaces()
            "read_wifi_state" -> hosts.readWifiState()
            "clear_dns_cache" -> {
                hosts.clearDnsCache()
                ""
            }
            "send_notification" -> hosts.sendNotification(payloadJson)
            "cancel_notification" -> hosts.cancelNotification(
                payload.optString("identifier"),
                payload.optInt("typeId"),
            )
            "dns_raw" -> hosts.localDnsRaw()
            "dns_lookup" -> hosts.localDnsLookup(
                payload.optLong("ctx"),
                payload.optString("network"),
                payload.optString("domain"),
            )
            "dns_exchange" -> hosts.localDnsExchange(
                payload.optLong("ctx"),
                payload.optString("message"),
            )
            "dns_cancel" -> hosts.cancelDnsExchange(payload.optLong("ctx"))
            // ADR 0004 P4a: the five test-session controls. Go relays the speedTestSession*
            // actions here; FlroneTestSessions owns the one implementation (the UI feed's
            // visibility hook is registered by FlronePlatformBridge). The feed's `visible`
            // demand signal stays on the channel, so it works with no core attached.
            "test_session_start", "test_session_stop", "test_session_dismiss",
            "test_session_sort", "test_session_remove" ->
                hosts.testSession(method, payloadJson)
            else -> "unknown platform_request method: $method"
        }
    }
}
