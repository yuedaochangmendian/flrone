// The CorePlatform duties: the C callback table (throne_callbacks_t) reaches Kotlin
// here, in the same process as the Flutter engine and the Go runtime. This is the
// single platform implementation now that the gobind NativeInterface is gone; the
// kernel reaches it through Core.setPlatform and reports back through Core.*.
package io.flrone.bridge

import android.content.Intent
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.CancellationSignal
import android.os.Process
import android.system.ErrnoException
import androidx.core.app.NotificationCompat
import androidx.core.net.toUri
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.utils.DefaultNetworkListener
import io.nekohasekai.sagernet.utils.PackageCache
import io.nekohasekai.sagernet.utils.WifiStateAccess
import io.flrone.core.Core
import io.flrone.core.CorePlatform
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor
import org.json.JSONArray
import org.json.JSONObject
import java.net.Inet6Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.UnknownHostException
import java.util.Collections
import java.util.WeakHashMap
import java.util.concurrent.ConcurrentHashMap

object FlroneCorePlatform : CorePlatform {

    // DnsResolver queries that need a cancel path are keyed by the bridge ctx
    // handle (the `ctx` carried by dns_exchange / passed to exchangeOnCancel).
    // The Go side cancels through platform_request("dns_cancel", {"ctx": ...})
    // instead of handing a JNI object across the callback table.
    private data class DnsCancelState(val signal: CancellationSignal, val wait: ExchangeWait)
    private val dnsCancelStates = ConcurrentHashMap<Long, DnsCancelState>()

    /** Hard upper bound for a raw DNS query; a cancelled query never calls back. */
    private const val DNS_EXCHANGE_TIMEOUT_MS = 5_000L

    /** `ETIMEDOUT` — reported to Go through [Core.exchangeErrnoCode]. */
    private const val ETIMEDOUT = 110

    // --- tun -------------------------------------------------------------

    /**
     * The kernel needs the VPN mid-start: VpnService builds its Builder from the
     * TunOptions handle, establishes and feeds the fd back with Core.startTun.
     */
    fun openTun(optionsHandle: Long): Int {
        val service = DataStore.vpnService ?: run {
            // Previously a silent -1: the core surfaced it only as "platform callback failed",
            // which hid the real cause (no live VpnService yet, i.e. a start ordering problem).
            Logs.w("bridge: openTun without a live VpnService (serviceMode=${DataStore.serviceMode})")
            return -1
        }
        return runCatching {
            service.openTunJson(Core.tunSpecJson(optionsHandle), VpnTunInterface(service))
        }.getOrElse {
            Logs.w("bridge: openTun failed: ${it.message}")
            android.util.Log.w("ThroneTun", "openTun failed: ${it.javaClass.name}: ${it.message}", it)
            -1
        }
    }

    fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    // protect() covers autoDetectInterfaceControl on Android; VpnTunInterface does it.
    fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    // --- process attribution ---------------------------------------------

    fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return ""
        return runCatching {
            val uid = SagerNet.connectivity.getConnectionOwnerUid(
                ipProtocol,
                java.net.InetSocketAddress(sourceAddress, sourcePort),
                java.net.InetSocketAddress(destinationAddress, destinationPort),
            )
            if (uid == Process.INVALID_UID) return ""
            val names = packageNamesOf(uid)
            JSONObject()
                .put("userId", uid)
                .put("userName", "")
                .put("processPath", "")
                .put("packageNames", JSONArray(names))
                .toString()
        }.getOrElse {
            Logs.w(it)
            ""
        }
    }

    fun packageNamesByUid(uid: Int): String =
        JSONArray(packageNamesOf(uid)).toString()

    private fun packageNamesOf(uid: Int): List<String> {
        if (uid % PackageCache.PER_USER_RANGE <= 1000) return listOf("android")
        // This is called from a Go callback thread while the core is starting.
        // Never block it on the first package enumeration; prewarm() fills the
        // listing shortly after process start and unknown owners are harmless.
        return PackageCache.snapshotOrNull()?.packagesOf(uid).orEmpty()
    }

    // --- default-interface monitor ---------------------------------------

    /** Survives clearInterface: the first network after a loss is a switch too. */
    private class IfaceReportState {
        var name: String? = null
        var index: Int = Int.MIN_VALUE
        var network: Network? = null
        var isExpensive: Boolean = false
        var reported = false
    }

    private val ifaceStates = Collections.synchronizedMap(WeakHashMap<Long, IfaceReportState>())

    /**
     * Interface reports never block the network callback thread: `NetworkCallback` is delivered
     * on a Connectivity handler and a `Thread.sleep` there stalls every other listener (and,
     * below API 26, the shared ConnectivityThread). LinkProperties and the kernel's listener
     * table may lag the callback briefly, so resolution is retried on IO with `yield()` — the
     * next `onCapabilitiesChanged` also re-enters [reportDefaultInterface] and re-checks.
     */
    private val ifaceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun startDefaultInterfaceMonitor(listener: Long): String {
        return runCatching {
            kotlinx.coroutines.runBlocking {
                DefaultNetworkListener.start(listener) { network ->
                    reportDefaultInterface(listener, network)
                }
            }
            ""
        }.getOrElse { it.message ?: "monitor" }
    }

    fun closeDefaultInterfaceMonitor(listener: Long): String {
        ifaceStates.remove(listener)
        return runCatching {
            kotlinx.coroutines.runBlocking { DefaultNetworkListener.stop(listener) }
            ""
        }.getOrElse { it.message ?: "monitor" }
    }

    /** A snapshot of what the Go listener needs to know, resolved off the callback thread. */
    internal data class IfaceSnapshot(val name: String, val index: Int, val isExpensive: Boolean)

    /**
     * The result of one resolution attempt. [snapshot] is null while the platform data has not
     * caught up with the callback yet; [clear] marks a network that is already gone.
     */
    private sealed class IfaceResolution {
        data class Ready(val snapshot: IfaceSnapshot) : IfaceResolution()
        object Retry : IfaceResolution()
        object Clear : IfaceResolution()
    }

    /**
     * Pure state decision for a resolved interface, extracted so a JVM test can pin the
     * "unchanged is not re-reported; a network switch is" rule without Android globals.
     * Returns the values to hand to `updateDefaultInterface`, or null when nothing changed.
     */
    internal object InterfaceReportDecision {
        fun changed(
            previousName: String?,
            previousIndex: Int,
            previousNetwork: Any?,
            previousExpensive: Boolean,
            network: Any?,
            snapshot: IfaceSnapshot,
        ): Boolean {
            if (previousName == snapshot.name && previousIndex == snapshot.index &&
                previousNetwork == network && previousExpensive == snapshot.isExpensive
            ) return false
            return true
        }
    }

    private fun resolveIface(network: Network): IfaceResolution {
        val linkProperties = runCatching { SagerNet.connectivity.getLinkProperties(network) }
            .getOrNull() ?: return IfaceResolution.Retry
        val ifName = linkProperties.interfaceName ?: return IfaceResolution.Retry
        val interfaceIndex = runCatching { NetworkInterface.getByName(ifName).index }
            .getOrNull() ?: return IfaceResolution.Retry
        val capabilities = runCatching { SagerNet.connectivity.getNetworkCapabilities(network) }
            .getOrNull()
        val isExpensive = capabilities?.let {
            it.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                !it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        } ?: false
        return IfaceResolution.Ready(IfaceSnapshot(ifName, interfaceIndex, isExpensive))
    }

    private fun applyIfaceReport(listener: Long, network: Network?, resolution: IfaceResolution) {
        val state = synchronized(ifaceStates) { ifaceStates.getOrPut(listener) { IfaceReportState() } }
        when (resolution) {
            is IfaceResolution.Ready -> {
                val snapshot = resolution.snapshot
                if (!InterfaceReportDecision.changed(
                        state.name, state.index, state.network, state.isExpensive,
                        network, snapshot,
                    )
                ) return
                state.name = snapshot.name
                state.index = snapshot.index
                state.network = network
                state.isExpensive = snapshot.isExpensive
                state.reported = true
                Core.updateDefaultInterface(listener, snapshot.name, snapshot.index, snapshot.isExpensive, false)
            }
            IfaceResolution.Retry, IfaceResolution.Clear -> {
                // A transient lag or a network that vanished before resolution: report a clear
                // so Go does not keep dialing an interface that no longer exists. The next
                // onCapabilitiesChanged re-enters and can restore it.
                state.name = null
                state.index = Int.MIN_VALUE
                state.network = null
                state.isExpensive = false
                Core.updateDefaultInterface(listener, "", -1, false, false)
            }
        }
    }

    private fun reportDefaultInterface(listener: Long, network: Network?) {
        if (network == null) {
            applyIfaceReport(listener, null, IfaceResolution.Clear)
            return
        }
        // The callback returns immediately; retries run on IO, never on the Connectivity
        // handler. A handful of `yield()` turns lets the platform data settle without the
        // 1 s wall-clock stall the old callback-thread sleeps imposed on every listener.
        ifaceScope.launch {
            var resolution = resolveIface(network)
            var attempt = 1
            while (resolution is IfaceResolution.Retry && attempt < IFACE_RESOLVE_ATTEMPTS) {
                kotlinx.coroutines.yield()
                resolution = resolveIface(network)
                attempt++
            }
            if (resolution is IfaceResolution.Retry) {
                Logs.w("bridge: checkDefaultInterfaceUpdate exhausted retries for $network")
            }
            applyIfaceReport(listener, network, resolution)
        }
    }

    private const val IFACE_RESOLVE_ATTEMPTS = 10

    // --- interfaces / wifi -----------------------------------------------

    fun getInterfaces(): String = runCatching {
        @Suppress("DEPRECATION") val networks = SagerNet.connectivity.allNetworks
        val networkInterfaces = NetworkInterface.getNetworkInterfaces().toList()
        val out = JSONArray()
        for (network in networks) {
            val linkProperties = SagerNet.connectivity.getLinkProperties(network) ?: continue
            val networkCapabilities = SagerNet.connectivity.getNetworkCapabilities(network) ?: continue
            val networkInterface = networkInterfaces.find { it.name == linkProperties.interfaceName } ?: continue
            var flags = 0
            if (networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                flags = android.system.OsConstants.IFF_UP or android.system.OsConstants.IFF_RUNNING
            }
            if (networkInterface.isLoopback) flags = flags or android.system.OsConstants.IFF_LOOPBACK
            if (networkInterface.isPointToPoint) flags = flags or android.system.OsConstants.IFF_POINTOPOINT
            if (networkInterface.supportsMulticast()) flags = flags or android.system.OsConstants.IFF_MULTICAST
            val type = when {
                networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 1
                networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 2
                networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 3
                else -> 0
            }
            out.put(
                JSONObject()
                    .put("index", networkInterface.index)
                    .put("mtu", runCatching { networkInterface.mtu }.getOrDefault(0))
                    .put("name", linkProperties.interfaceName)
                    .put("addresses", JSONArray(networkInterface.interfaceAddresses.map { it.toPrefix() }))
                    .put("flags", flags)
                    .put("type", type)
                    .put("dnsServer", JSONArray(linkProperties.dnsServers.mapNotNull { it.hostAddress }))
                    .put(
                        "gateway",
                        JSONArray(
                            linkProperties.routes.filter { it.isDefaultRoute }
                                .mapNotNull { it.gateway?.hostAddress },
                        ),
                    )
                    .put(
                        "metered",
                        !networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
                    ),
            )
        }
        out.toString()
    }.getOrElse {
        Logs.w(it)
        "[]"
    }

    fun readWifiState(): String = try {
        val (ssid, bssid) = WifiStateAccess.read(app)
        JSONObject().put("ssid", ssid).put("bssid", bssid).toString()
    } catch (_: Throwable) {
        ""
    }

    fun clearDnsCache() {}

    // --- notifications ----------------------------------------------------

    fun sendNotification(notificationJson: String): String {
        // Go marshals the Notification struct as is: PascalCase field names.
        val o = runCatching { JSONObject(notificationJson) }.getOrElse { return it.message ?: "notification" }
        fun field(key: String) = o.optString(key).ifBlank { o.optString(key.replaceFirstChar { it.lowercase() }) }
        val channel = field("TypeName").ifBlank { "core" }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            SagerNet.notification.createNotificationChannel(
                android.app.NotificationChannel(channel, channel, android.app.NotificationManager.IMPORTANCE_DEFAULT),
            )
        }
        val builder = NotificationCompat.Builder(app, channel)
            .setSmallIcon(R.drawable.ic_throne_tile)
            .setContentTitle(field("Title"))
            .setContentText(
                listOf(field("Subtitle"), field("Body")).filter { it.isNotBlank() }.joinToString("\n"),
            )
            .setAutoCancel(true)
        val openUrl = field("OpenURL")
        if (openUrl.isNotBlank()) {
            builder.setContentIntent(
                android.app.PendingIntent.getActivity(
                    app, 0, Intent(Intent.ACTION_VIEW, openUrl.toUri()),
                    android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
        }
        SagerNet.notification.notify(field("Identifier"), o.optInt("TypeID"), builder.build())
        return ""
    }

    fun cancelNotification(identifier: String, typeId: Int): String {
        SagerNet.notification.cancel(identifier, typeId)
        return ""
    }

    // --- local DNS transport (blocking; the ctx completes before return) ---

    private const val RCODE_NXDOMAIN = 3

    fun localDnsRaw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    fun localDnsLookup(ctx: Long, network: String, domain: String): String {
        return try {
            val answer = try {
                SagerNet.underlyingNetwork?.getAllByName(domain)
            } catch (e: UnknownHostException) {
                null
            } ?: InetAddress.getAllByName(domain)
            Core.exchangeSuccess(ctx, answer.mapNotNull { it.hostAddress }.joinToString("\n"))
            ""
        } catch (e: UnknownHostException) {
            Core.exchangeErrorCode(ctx, RCODE_NXDOMAIN)
            ""
        } catch (e: Exception) {
            Logs.w(e)
            Core.exchangeErrnoCode(ctx, 114514)
            ""
        }
    }

    fun localDnsExchange(ctx: Long, message: ByteArray): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            runCatching { Core.exchangeErrnoCode(ctx, 95) } // EOPNOTSUPP
            return ""
        }
        val signal = CancellationSignal()
        val wait = ExchangeWait()
        dnsCancelStates[ctx] = DnsCancelState(signal, wait)
        // A cancelled DnsResolver query never calls back, so the cancellation releases the wait itself.
        runCatching { Core.exchangeOnCancel(ctx) }.onFailure { Logs.w(it) }
        val callback = object : android.net.DnsResolver.Callback<ByteArray> {
            override fun onAnswer(answer: ByteArray, rcode: Int) {
                // The state may already have been removed by a timeout/cancel: a late answer must
                // not touch the removed ctx or complete it a second time.
                if (!dnsCancelStates.containsKey(ctx) || !wait.claim()) return
                try {
                    runCatching { Core.exchangeRawSuccess(ctx, answer) }
                        .onFailure { Logs.w(it) }
                } finally {
                    wait.release()
                }
            }

            override fun onError(error: android.net.DnsResolver.DnsException) {
                if (!dnsCancelStates.containsKey(ctx) || !wait.claim()) return
                try {
                    val cause = error.cause
                    val code = if (cause is ErrnoException) cause.errno else {
                        Logs.w(error)
                        114514
                    }
                    runCatching { Core.exchangeErrnoCode(ctx, code) }
                        .onFailure { Logs.w(it) }
                } finally {
                    wait.release()
                }
            }
        }
        try {
            android.net.DnsResolver.getInstance().rawQuery(
                SagerNet.underlyingNetwork,
                message,
                android.net.DnsResolver.FLAG_NO_RETRY,
                Dispatchers.IO.asExecutor(),
                signal,
                callback,
            )
        } catch (e: Exception) {
            // rawQuery may throw synchronously (bad message, no resolver, dead executor). Report a
            // usable errno and release the wait, otherwise the caller would hang until the timeout.
            Logs.w(e)
            if (wait.claim()) runCatching { Core.exchangeErrnoCode(ctx, 114514) }
            wait.release()
        }
        wait.awaitBounded(DNS_EXCHANGE_TIMEOUT_MS) {
            runCatching { signal.cancel() }.onFailure { Logs.w(it) }
            runCatching { Core.exchangeErrnoCode(ctx, ETIMEDOUT) }
                .onFailure { Logs.w(it) }
        }
        dnsCancelStates.remove(ctx)
        return ""
    }

    // --- ADR 0004 P2: the single JSON duty facade -----------------------------
    //
    // Three low-frequency, platform-wide duties now arrive here over the single
    // platform_request callback. Each delegates to the SAME method the typed slot
    // still calls, so there is exactly one implementation per duty (no duplicated
    // behavior). The migrated duties' typed slots remain registered in core.cpp
    // but are no longer invoked by Go; every other duty keeps its typed path.
    //
    // Migration table (method -> payload -> JSON answer; typed slot retained):
    //   use_proc_fs          {} / null        -> JSON boolean true/false
    //   package_names_by_uid {"uid": <int>}   -> JSON string array
    //   clear_dns_cache      {} / null        -> "" (fire-and-forget)
    //   test_session_*        action payload  -> JSON result (ADR 0004 P4a)
    // Still on typed slots (unmigrated): open_tun, protect/resolver_process
    // (tun-scoped, high-frequency), usePlatformAutoDetectInterfaceControl,
    // auto_detect_interface_control, find_connection_owner, interface monitors,
    // get_interfaces, read_wifi_state, notifications and the local-DNS transport.
    // The `testSession` progress push is a UI EventChannel subscription, not a duty.
    override fun platformRequest(method: String, payloadJson: String): String =
        PlatformRequestGuard.guard(method) { dispatchPlatformRequest(method, payloadJson) }

    private fun dispatchPlatformRequest(method: String, payloadJson: String): String {
        val payload = runCatching { JSONObject(payloadJson) }.getOrDefault(JSONObject())
        return when (method) {
            "log" -> {
                io.nekohasekai.sagernet.bg.CoreRuntime.appendCoreLog(
                    payload.optInt("level"),
                    payload.optString("message"),
                )
                ""
            }
            "open_tun" -> openTun(payload.optLong("options")).toString()
            "use_platform_auto_detect_interface_control" -> usePlatformAutoDetectInterfaceControl().toString()
            "use_proc_fs" -> useProcFS().toString()
            "find_connection_owner" -> findConnectionOwner(
                payload.optInt("ipProtocol"),
                payload.optString("sourceAddress"),
                payload.optInt("sourcePort"),
                payload.optString("destinationAddress"),
                payload.optInt("destinationPort"),
            )
            "package_names_by_uid" -> packageNamesByUid(payload.optInt("uid", -1))
            "start_default_interface_monitor" -> startDefaultInterfaceMonitor(payload.optLong("listener"))
            "close_default_interface_monitor" -> closeDefaultInterfaceMonitor(payload.optLong("listener"))
            "get_interfaces" -> getInterfaces()
            "read_wifi_state" -> readWifiState()
            "clear_dns_cache" -> {
                clearDnsCache()
                ""
            }
            "send_notification" -> sendNotification(payloadJson)
            "cancel_notification" -> cancelNotification(
                payload.optString("identifier"),
                payload.optInt("typeId"),
            )
            "dns_raw" -> localDnsRaw().toString()
            "dns_lookup" -> localDnsLookup(
                payload.optLong("ctx"),
                payload.optString("network"),
                payload.optString("domain"),
            )
            "dns_exchange" -> localDnsExchange(
                payload.optLong("ctx"),
                android.util.Base64.decode(payload.optString("message"), android.util.Base64.NO_WRAP),
            )
            "dns_cancel" -> {
                // Claim completed first: a late DnsResolver callback after the cancel must not
                // complete the removed ctx a second time. Release the wait regardless of who won
                // the race, then cancel the query so it does not keep a worker alive.
                dnsCancelStates.remove(payload.optLong("ctx"))?.let { state ->
                    state.wait.claim()
                    state.wait.release()
                    runCatching { state.signal.cancel() }.onFailure { Logs.w(it) }
                }
                ""
            }
            // ADR 0004 P4a: the five test-session controls. Go relays the speedTestSession*
            // actions here; FlroneTestSessions owns the one implementation (the UI feed's
            // visibility hook is registered by FlronePlatformBridge). The feed's `visible`
            // demand signal stays on the channel, so it works with no core attached.
            "test_session_start", "test_session_stop", "test_session_dismiss",
            "test_session_sort", "test_session_remove" ->
                FlroneTestSessions.platformRequest(method, payloadJson)
            else -> "unknown platform_request method: $method"
        }
    }
}

/**
 * The pure JNI boundary guard for `platform_request`. FlroneCorePlatform is reached from
 * Go-owned threads; not one exception may cross back into C. The JNI thunk clears a pending
 * Java exception, but the Go caller would then read a null/bogus answer as a duty result —
 * for `start_default_interface_monitor` or `send_notification` that is a non-empty "error"
 * string that silently poisons state. Wrapping the whole dispatch here (including JSON
 * parsing, Base64, notification and tun calls) turns a throw into a plain error string, and
 * leaves every success shape byte-for-byte unchanged. Pure so a JVM test can pin the shape.
 */
internal object PlatformRequestGuard {
    fun guard(method: String, dispatch: () -> String): String = runCatching(dispatch)
        .getOrElse { error ->
            "platform_request failed: $method: ${error.message ?: error.javaClass.name}"
        }
}

/**
 * A JVM-only seam for the three migrated platform_request duties: the production dispatch
 * lives in [dispatchPlatformRequest] (which also covers all the other duties and the JNI
 * guard), and this object mirrors just these three entries with injected dependencies so
 * [PlatformRequestRouterTest] can pin their names/payload shape without an Android runtime.
 * Kept deliberately — it is a test seam, not the production router; changing a duty here
 * without changing `dispatchPlatformRequest` does not change the app.
 */
internal object PlatformRequestRouter {
    fun dispatch(
        method: String,
        payloadJson: String,
        useProcFS: () -> Boolean,
        packageNamesByUid: (Int) -> String,
        clearDnsCache: () -> Unit,
    ): String = runCatching {
        when (method) {
            "use_proc_fs" -> useProcFS().toString()
            "package_names_by_uid" -> {
                val uid = runCatching { JSONObject(payloadJson).optInt("uid", -1) }.getOrDefault(-1)
                packageNamesByUid(uid)
            }
            "clear_dns_cache" -> {
                clearDnsCache()
                ""
            }
            else -> "unknown platform_request method: $method"
        }
    }.getOrElse { it.message ?: "platform_request failed" }
}

/** The tun-scoped Android duties: protect keeps sockets out of the VPN. */
class VpnTunInterface(private val service: android.net.VpnService) : io.flrone.core.TunInterface {
    override fun protect(fd: Int) {
        service.protect(fd)
    }

    override fun resolverProcess(protocol: Int, source: String, target: String, uid: Int): String = runCatching {
        val nextUid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            SagerNet.connectivity.getConnectionOwnerUid(
                protocol,
                socketAddress(source),
                socketAddress(target),
            )
        } else {
            uid
        }
        if (nextUid == -1) return ""
        app.packageManager?.getPackagesForUid(nextUid)?.firstOrNull() ?: ""
    }.getOrElse {
        Logs.w(it)
        ""
    }
}

private fun java.net.InterfaceAddress.toPrefix(): String {
    return if (address is Inet6Address) {
        "${Inet6Address.getByAddress(address.address).hostAddress}/$networkPrefixLength"
    } else {
        "${address.hostAddress}/$networkPrefixLength"
    }
}

/** `"host:port"` / `"[v6]:port"` as the kernel passes connection endpoints. */
private fun socketAddress(value: String): java.net.InetSocketAddress {
    val sep = value.lastIndexOf(':')
    return if (sep > 0) {
        val host = value.substring(0, sep).removeSurrounding("[", "]")
        val port = value.substring(sep + 1).toIntOrNull() ?: 0
        java.net.InetSocketAddress(host, port)
    } else {
        java.net.InetSocketAddress(value, 0)
    }
}
