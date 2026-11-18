package io.nekohasekai.sagernet.bg.test

import io.flrone.core.CoreTest
import io.nekohasekai.sagernet.database.ProxyEntity

/** Egress IP and country tests (runIpProbe, TestRunner.cpp:234-293): results stream as the core reports them. */
internal class IpTestRunner(session: TestSession) : LatencySweep(session) {

    override fun start(probe: TestProbe, batch: List<ProxyEntity>, emit: (ProbeResult) -> Unit, done: () -> Unit) {
        val request = probe.request().apply {
            timeoutMs = session.options.timeoutMs
            maxConcurrency = session.options.concurrency
        }
        CoreTest.startIpTest(
            request,
            onResult = { tag, ip, country, error ->
                guarded {
                    val id = probe.profileOf(tag) ?: return@guarded
                    emit(ProbeResult(id, ip = ip, country = country, error = error))
                }
            },
            onDone = { guarded(done) },
        )
    }

    override fun report(results: List<ProbeResult>) = session.reportIp(results)

    /** Not tested: the desktop only flags the latency in memory for an invalid candidate. */
    override fun invalid(profileId: Long, reason: String) = ProbeResult(profileId, error = reason, measured = false)
}
