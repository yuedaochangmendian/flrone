package io.flrone.core

import org.json.JSONObject

/**
 * The polling bridge between the Go test hub and the Kotlin runners.
 *
 * A runner starts a session, then [watch] drains `poll_test` on a daemon thread
 * and invokes the same callbacks the retired gobind handler objects carried.
 * Cancellation stays in the kernel: StopTests finishes the session, the poll
 * sees `done`, and the thread ends.
 */
object CoreTest {

    fun startUrlTest(
        request: CoreTestRequest,
        onResult: (tag: String, latencyMs: Int, error: String) -> Unit,
        onVpnStatus: (tag: String, connected: Boolean, state: String, error: String) -> Unit,
        onDone: () -> Unit,
    ) {
        val session = CoreHost.startUrlTest(request)
        watch(session, { event ->
            when (event.optString("kind")) {
                "result" -> onResult(
                    event.optString("tag"),
                    event.optInt("latencyMs"),
                    event.optString("error"),
                )
                "vpn" -> onVpnStatus(
                    event.optString("tag"),
                    event.optBoolean("connected"),
                    event.optString("state"),
                    event.optString("error"),
                )
            }
        }, onDone)
    }

    fun startIpTest(
        request: CoreTestRequest,
        onResult: (tag: String, ip: String, country: String, error: String) -> Unit,
        onDone: () -> Unit,
    ) {
        val session = CoreHost.startIpTest(request)
        watch(session, { event ->
            if (event.optString("kind") == "result") {
                onResult(
                    event.optString("tag"),
                    event.optString("ip"),
                    event.optString("country"),
                    event.optString("error"),
                )
            }
        }, onDone)
    }

    fun startSpeedTest(
        request: CoreTestRequest,
        onResult: (SpeedTest) -> Unit,
        onDone: () -> Unit,
    ) {
        val session = CoreHost.startSpeedTest(request)
        watch(session, { event ->
            if (event.optString("kind") == "result") {
                onResult(
                    SpeedTest(
                        tag = event.optString("tag"),
                        dlSpeed = event.optString("dlSpeed"),
                        ulSpeed = event.optString("ulSpeed"),
                        latency = event.optInt("latency"),
                        serverName = event.optString("serverName"),
                        serverCountry = event.optString("serverCountry"),
                        error = event.optString("error"),
                        cancelled = event.optBoolean("cancelled"),
                        dlBytes = event.optLong("dlBytes"),
                        ulBytes = event.optLong("ulBytes"),
                        running = event.optBoolean("running"),
                    ),
                )
            }
        }, onDone)
    }

    private fun watch(session: Int, onEvent: (JSONObject) -> Unit, onDone: () -> Unit) {
        Thread({
            var cursor = 0
            try {
                while (true) {
                    val batch = CoreHost.pollTest(session, cursor)
                    for (event in batch.events) onEvent(event)
                    cursor = batch.cursor
                    if (batch.done) break
                    Thread.sleep(POLL_INTERVAL_MS)
                }
            } catch (_: Throwable) {
                // The session/caller went away; the kernel side stops on its own.
            } finally {
                onDone()
            }
        }, "core-test-$session").apply { isDaemon = true }.start()
    }

    private const val POLL_INTERVAL_MS = 100L
}
