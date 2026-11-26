package io.nekohasekai.sagernet.utils

import android.annotation.TargetApi
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.ktx.Logs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.channels.actor
import kotlinx.coroutines.runBlocking
import java.net.UnknownHostException

object DefaultNetworkListener {
    // The actor body lives in NetworkListenerCore with Android injected, so a plain JVM test can
    // drive the real message handling. One throwing listener must never cancel this actor: it
    // would permanently kill the shared channel for every other user of the default network.
    private val core = NetworkListenerCore(
        register = ::register,
        unregister = ::unregister,
        clock = SystemClock::elapsedRealtime,
        // Diagnostics: network event timeline for night / airplane mode (compare with Go
        // UpdateDefaultInterface). The elapsed covers every listener; Update storms on a flaky
        // signal, so only Put/Lost go to info and Update is debug.
        diagnostics = { event, network, size, elapsed ->
            val line = "DefaultNetworkListener $event network=$network listeners=$size elapsed=${elapsed}ms thread=${Thread.currentThread().name}"
            if (event == "Update") Logs.d(line) else Logs.i(line)
        },
    )
    private val networkActor = GlobalScope.actor<NetworkListenerCore.Message>(Dispatchers.Unconfined) {
        core.run(channel)
    }

    suspend fun start(key: Any, listener: (Network?) -> Unit) {
        val message = NetworkListenerCore.Message.Start(key) { token -> listener(token as Network?) }
        networkActor.send(message)
        // send only queues the message; the Start branch and the cached network's first callback may still be pending.
        // Wait for processed, or a test box created meanwhile may get default=nil from the Go monitor
        // and its first dial fails before updateDefaultInterface(wlan0, index).
        message.processed.await()
    }

    suspend fun get(): Network = if (fallback) @TargetApi(23) {
        SagerNet.connectivity.activeNetwork
            ?: throw UnknownHostException() // failed to listen, return current if available
    } else NetworkListenerCore.Message.Get().run {
        networkActor.send(this)
        @Suppress("UNCHECKED_CAST")
        response.await() as Network
    }

    suspend fun stop(key: Any) = networkActor.send(NetworkListenerCore.Message.Stop(key))

    // NB: below API 26 this runs on ConnectivityThread; 26+ dispatches through the callbackHandler given to register
    // onto a dedicated worker thread (dispatching to the main thread through mainHandler once blocked the UI
    // for seconds with several test listeners and onCapabilitiesChanged storms)
    private object Callback : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            Logs.d("DefaultNetworkListener onAvailable enter network=$network thread=${Thread.currentThread().name}")
            runBlocking { networkActor.send(NetworkListenerCore.Message.Put(network)) }
        }

        override fun onCapabilitiesChanged(
            network: Network, networkCapabilities: NetworkCapabilities
        ) { // it's a good idea to refresh capabilities
            // Storm source: debug per event (info would flood the log)
            Logs.d("DefaultNetworkListener onCapabilitiesChanged enter network=$network thread=${Thread.currentThread().name}")
            runBlocking { networkActor.send(NetworkListenerCore.Message.Update(network)) }
        }

        override fun onLost(network: Network) {
            Logs.d("DefaultNetworkListener onLost enter network=$network thread=${Thread.currentThread().name}")
            runBlocking { networkActor.send(NetworkListenerCore.Message.Lost(network)) }
        }
    }

    private var fallback = false
    private val request = NetworkRequest.Builder().apply {
        addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
        if (Build.VERSION.SDK_INT == 23) {  // workarounds for OEM bugs
            removeCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            removeCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL)
        }
    }.build()
    private val callbackThread = HandlerThread("DefaultNetworkListener").apply { start() }
    private val callbackHandler = Handler(callbackThread.looper)

    /**
     * Unfortunately registerDefaultNetworkCallback is going to return VPN interface since Android P DP1:
     * https://android.googlesource.com/platform/frameworks/base/+/dda156ab0c5d66ad82bdcf76cda07cbc0a9c8a2e
     *
     * This makes doing a requestNetwork with REQUEST necessary so that we don't get ALL possible networks that
     * satisfies default network capabilities but only THE default network. Unfortunately, we need to have
     * android.permission.CHANGE_NETWORK_STATE to be able to call requestNetwork.
     *
     * Source: https://android.googlesource.com/platform/frameworks/base/+/2df4c7d/services/core/java/com/android/server/ConnectivityService.java#887
     */
    private fun register() {
        try {
            fallback = false
            when (Build.VERSION.SDK_INT) {
                in 31..Int.MAX_VALUE -> @TargetApi(31) {
                    SagerNet.connectivity.registerBestMatchingNetworkCallback(
                        request, Callback, callbackHandler
                    )
                }
                in 28 until 31 -> @TargetApi(28) {  // we want REQUEST here instead of LISTEN
                    SagerNet.connectivity.requestNetwork(request, Callback, callbackHandler)
                }
                in 26 until 28 -> @TargetApi(26) {
                    SagerNet.connectivity.registerDefaultNetworkCallback(Callback, callbackHandler)
                }
                in 24 until 26 -> @TargetApi(24) {
                    SagerNet.connectivity.registerDefaultNetworkCallback(Callback)
                }
                else -> {
                    SagerNet.connectivity.requestNetwork(request, Callback)
                    // known bug on API 23: https://stackoverflow.com/a/33509180/2245107
                }
            }
        } catch (e: Exception) {
            Logs.w(e)
            fallback = true
        }
    }

    private fun unregister() = SagerNet.connectivity.unregisterNetworkCallback(Callback)
}
