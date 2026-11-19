package io.nekohasekai.sagernet.bg

import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.readableMessage
import io.flrone.core.CoreHost
import io.nekohasekai.sagernet.outbound.json.JsonValues
import io.nekohasekai.sagernet.outbound.json.jsonObjectOf

/** The core's QUIC handshake signature (core/mobile/amnezia.go), called in-process since P6; failures travel in "error". */
object QuicSignature {

    /** Returns `{"error","packets"}`, packets being up to five `<b 0x…>` values for I1..I5 in order. */
    fun generate(domain: String): String = try {
        val packets = CoreHost.genQuicSignature(domain)
        jsonObjectOf("error" to "", "packets" to JsonValues.stringArray(packets)).toCompact()
    } catch (e: Throwable) {
        Logs.w(e)
        jsonObjectOf("error" to e.readableMessage).toCompact()
    }
}
