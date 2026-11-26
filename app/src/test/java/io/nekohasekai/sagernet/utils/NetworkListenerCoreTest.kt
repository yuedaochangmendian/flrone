package io.nekohasekai.sagernet.utils

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The default-network actor ran on `Dispatchers.Unconfined` — the callback thread for a
 * Put/Update/Lost event. A listener throwing used to escape the `forEach`, cancel the actor and
 * permanently kill the shared channel for every other user. These tests drive the real message
 * handler ([NetworkListenerCore]) on a plain JVM with a fake network token and fake register hooks.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class NetworkListenerCoreTest {

    private class Harness {
        var registrations = 0
            private set
        var unregistrations = 0
            private set
        val core = NetworkListenerCore(
            register = { registrations++ },
            unregister = { unregistrations++ },
        )

        suspend fun start(key: Any, listener: (String?) -> Unit) {
            val message = NetworkListenerCore.Message.Start(key) { token -> listener(token as String?) }
            core.handle(message)
            message.processed.await()
        }

        suspend fun get() = NetworkListenerCore.Message.Get().run {
            core.handle(this)
            withTimeout(1000) { response.await() as String? }
        }

        fun stop(key: Any) = core.handle(NetworkListenerCore.Message.Stop(key))
        fun put(network: String) = core.handle(NetworkListenerCore.Message.Put(network))
        fun update(network: String) = core.handle(NetworkListenerCore.Message.Update(network))
        fun lost(network: String) = core.handle(NetworkListenerCore.Message.Lost(network))
    }

    @Test
    fun `a throwing listener does not silence the healthy one on Put Update or Lost`() = runBlocking {
        val h = Harness()
        val seen = ArrayList<String?>()
        h.start("bad") { throw IllegalStateException("listener exploded") }
        h.start("good") { seen.add(it) }
        assertEquals(1, h.registrations)

        h.put("wlan0")
        assertEquals(listOf("wlan0"), seen)
        h.update("wlan0")
        assertEquals(listOf("wlan0", "wlan0"), seen)
        h.lost("wlan0")
        assertEquals(listOf("wlan0", "wlan0", null), seen)
    }

    @Test
    fun `a throwing listener does not strand pending gets or later messages`() = runBlocking {
        val h = Harness()
        val seen = ArrayList<String?>()
        h.start("bad") { throw IllegalStateException("listener exploded") }
        h.start("good") { seen.add(it) }

        // Get with no cached network goes into the pending queue; a throwing listener on Put must
        // not stop the pending request from being completed.
        val pending = NetworkListenerCore.Message.Get()
        h.core.handle(pending)
        h.put("eth0")
        assertEquals("eth0", withTimeout(1000) { pending.response.await() as String? })
        assertEquals(listOf("eth0"), seen)
        // The actor still answers gets from its cached network and still takes a Stop.
        assertSame("eth0", h.get())
        h.stop("bad")
        h.stop("good")
        assertEquals(1, h.unregistrations)
    }

    @Test
    fun `the actor loop keeps consuming after a throwing listener`() = runBlocking {
        val h = Harness()
        val channel = Channel<NetworkListenerCore.Message>(Channel.UNLIMITED)
        val deliveries = ArrayList<String?>()
        h.start("bad") { throw IllegalStateException("listener exploded") }
        h.start("good") { deliveries.add(it) }
        val job = launch { h.core.run(channel) }

        channel.send(NetworkListenerCore.Message.Put("wlan0"))
        channel.send(NetworkListenerCore.Message.Update("wlan0"))
        channel.send(NetworkListenerCore.Message.Lost("wlan0"))
        channel.close()
        withTimeout(1000) { job.join() }
        assertFalse(job.isCancelled)
        assertEquals(listOf("wlan0", "wlan0", null), deliveries)
    }

    @Test
    fun `a listener that stops itself during Put does not strand the remaining listeners`() = runBlocking {
        val h = Harness()
        val seen = ArrayList<String?>()
        h.start("self-stop") {
            h.stop("self-stop")
            seen.add(it)
        }
        h.start("good") { seen.add(it) }
        h.put("wlan0")
        assertEquals(listOf("wlan0", "wlan0"), seen)
        assertTrue(h.unregistrations == 0) // the good listener is still registered
    }
}
