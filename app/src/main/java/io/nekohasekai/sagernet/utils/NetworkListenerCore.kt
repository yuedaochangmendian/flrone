package io.nekohasekai.sagernet.utils

import io.nekohasekai.sagernet.ktx.Logs
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.ReceiveChannel

/**
 * The decision body of [DefaultNetworkListener]'s shared actor, with the Android globals
 * injected so a plain JVM test can drive the real message handling.
 *
 * The actor runs on `Dispatchers.Unconfined` — the callback thread for a network event. An
 * exception escaping one listener would cancel the actor and permanently kill the shared
 * channel, so every callback (and the pending-request completion on a new network) is isolated
 * here: one bad listener is logged and the rest of the listeners, the pending `get()` callers
 * and later messages still run. The network token is `Any` here (production passes
 * `android.net.Network`, a test passes a plain string); the Android boundary casts it back.
 */
internal class NetworkListenerCore(
    private val register: () -> Unit,
    private val unregister: () -> Unit,
    private val clock: () -> Long = System::nanoTime,
    private val diagnostics: (event: String, network: Any?, listeners: Int, elapsed: Long) -> Unit =
        { _, _, _, _ -> },
) {

    sealed class Message {
        class Start(val key: Any, val listener: (Any?) -> Unit) : Message() {
            val processed = CompletableDeferred<Unit>()
        }

        class Get : Message() {
            val response = CompletableDeferred<Any?>()
        }

        class Stop(val key: Any) : Message()

        class Put(val network: Any) : Message()
        class Update(val network: Any) : Message()
        class Lost(val network: Any) : Message()
    }

    private val listeners = mutableMapOf<Any, (Any?) -> Unit>()
    private var network: Any? = null
    private val pendingRequests = ArrayList<Message.Get>()

    /** One listener may throw; the actor and the other listeners must not notice. */
    private fun notify(key: Any, event: String, value: Any?, listener: (Any?) -> Unit) {
        runCatching { listener(value) }.onFailure { error ->
            Logs.w("DefaultNetworkListener $event listener $key threw", error)
        }
    }

    /** Drains the actor channel. Kept as the single loop so every message passes [handle]. */
    suspend fun run(channel: ReceiveChannel<Message>) {
        for (message in channel) handle(message)
    }

    internal fun handle(message: Message) {
        when (message) {
            is Message.Start -> {
                try {
                    if (listeners.isEmpty()) register()
                    listeners[message.key] = message.listener
                    if (network != null) message.listener(network)
                    message.processed.complete(Unit)
                } catch (error: Throwable) {
                    val removed = listeners.remove(message.key) != null
                    if (removed && listeners.isEmpty()) runCatching { unregister() }
                    message.processed.completeExceptionally(error)
                }
            }

            is Message.Get -> {
                check(listeners.isNotEmpty()) { "Getting network without any listeners is not supported" }
                val current = network
                if (current == null) {
                    pendingRequests += message
                } else {
                    // A pending caller must not be left hanging because a completion threw.
                    runCatching { message.response.complete(current) }
                }
            }

            is Message.Stop -> if (listeners.isNotEmpty() && // was not empty
                listeners.remove(message.key) != null && listeners.isEmpty()
            ) {
                network = null
                unregister()
            }

            is Message.Put -> {
                val started = clock()
                network = message.network
                // Complete every pending get() before notifying listeners: a listener can throw,
                // but it can no longer strand a caller or stop the remaining completions.
                try {
                    pendingRequests.forEach { runCatching { it.response.complete(message.network) } }
                } finally {
                    pendingRequests.clear()
                }
                // Snapshot: a listener is allowed to stop itself. Iterating the live map would
                // throw ConcurrentModificationException from the iterator (outside any one
                // listener's runCatching) and strand the remaining listeners.
                listeners.toList().forEach { (key, listener) ->
                    notify(key, "Put", message.network, listener)
                }
                diagnostics("Put", message.network, listeners.size, clock() - started)
            }

            is Message.Update -> if (network == message.network) {
                val started = clock()
                listeners.toList().forEach { (key, listener) ->
                    notify(key, "Update", message.network, listener)
                }
                diagnostics("Update", message.network, listeners.size, clock() - started)
            }

            is Message.Lost -> if (network == message.network) {
                val started = clock()
                network = null
                listeners.toList().forEach { (key, listener) -> notify(key, "Lost", null, listener) }
                diagnostics("Lost", message.network, listeners.size, clock() - started)
            }
        }
    }
}
