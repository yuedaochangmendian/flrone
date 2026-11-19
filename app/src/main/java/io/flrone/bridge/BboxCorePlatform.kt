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
import java.util.concurrent.CountDownLatch

object BboxCorePlatform : CorePlatform {

    // DnsResolver queries that need a cancel path are keyed by the bridge ctx
    // handle (the `ctx` carried by dns_exchange / passed to exchangeOnCancel).
    // The Go side cancels through platform_request("dns_cancel", {"ctx": ...})
    // instead of handing a JNI object across the callback table.
    private data class DnsCancelState(val signal: CancellationSignal, val done: CountDownLatch)
    private val dnsCancelStates = ConcurrentHashMap<Long, DnsCancelState>()

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
        return PackageCache.snapshot().packagesOf(uid)
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

    private fun reportDefaultInterface(listener: Long, network: Network?) {
        val state = synchronized(ifaceStates) { ifaceStates.getOrPut(listener) { IfaceReportState() } }
        if (network == null) {
            state.name = null
            state.index = Int.MIN_VALUE
            state.network = null
            state.isExpensive = false
            Core.updateDefaultInterface(listener, "", -1, false, false)
            return
        }
        // LinkProperties / NetworkInterface may lag behind the callback briefly.
        repeat(10) {
            val linkProperties = SagerNet.connectivity.getLinkProperties(network) ?: run {
                Thread.sleep(100)
                return@repeat
            }
            val interfaceIndex = try {
                NetworkInterface.getByName(linkProperties.interfaceName).index
            } catch (e: Exception) {
                Thread.sleep(100)
                return@repeat
            }
            val capabilities = SagerNet.connectivity.getNetworkCapabilities(network)
            val isExpensive = capabilities?.let {
                it.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                    !it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            } ?: false
            val ifName = linkProperties.interfaceName ?: run {
                Thread.sleep(100)
                return@repeat
            }
            val sameInterface = state.name == ifName && state.index == interfaceIndex &&
                state.network == network
            if (sameInterface && state.isExpensive == isExpensive) return
            state.name = ifName
            state.index = interfaceIndex
            state.network = network
            state.isExpensive = isExpensive
            state.reported = true
            Core.updateDefaultInterface(listener, ifName, interfaceIndex, isExpensive, false)
            return
        }
        Logs.w("bridge: checkDefaultInterfaceUpdate exhausted retries for $network")
        state.name = null
        state.index = Int.MIN_VALUE
        state.network = null
        state.isExpensive = false
        Core.updateDefaultInterface(listener, "", -1, false, false)
    }

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
            Core.exchangeErrnoCode(ctx, 95) // EOPNOTSUPP
            return ""
        }
        val signal = CancellationSignal()
        val done = CountDownLatch(1)
        dnsCancelStates[ctx] = DnsCancelState(signal, done)
        // A cancelled DnsResolver query never calls back, so the cancellation releases the wait itself.
        Core.exchangeOnCancel(ctx)
        val callback = object : android.net.DnsResolver.Callback<ByteArray> {
            override fun onAnswer(answer: ByteArray, rcode: Int) {
                Core.exchangeRawSuccess(ctx, answer)
                done.countDown()
            }

            override fun onError(error: android.net.DnsResolver.DnsException) {
                val cause = error.cause
                if (cause is ErrnoException) {
                    Core.exchangeErrnoCode(ctx, cause.errno)
                } else {
                    Logs.w(error)
                    Core.exchangeErrnoCode(ctx, 114514)
                }
                done.countDown()
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
            done.await()
        } finally {
            dnsCancelStates.remove(ctx)
        }
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
    override fun platformRequest(method: String, payloadJson: String): String {
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
                dnsCancelStates.remove(payload.optLong("ctx"))?.let { state ->
                    state.signal.cancel()
                    state.done.countDown()
                }
                ""
            }
            // ADR 0004 P4a: the six test-session controls. Go relays the speedTestSession*
            // actions here; BboxTestSessions owns the one implementation (the UI feed's
            // visibility hook is registered by ThroneBoxBridge).
            "test_session_start", "test_session_stop", "test_session_dismiss",
            "test_session_sort", "test_session_remove", "test_session_visible" ->
                BboxTestSessions.platformRequest(method, payloadJson)
            else -> "unknown platform_request method: $method"
        }
    }
}

/**
 * The pure part of the platform_request dispatcher: maps a method name and its
 * JSON payload onto the three migrated duties. Kept free of Android globals so a
 * JVM test can exercise the real routing code (not a copy). BboxCorePlatform
 * injects its own three methods; the typed slots call those same methods.
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
