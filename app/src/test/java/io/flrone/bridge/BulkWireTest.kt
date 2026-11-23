package io.flrone.bridge

import io.flutter.plugin.common.StandardMessageCodec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

/**
 * The bulk encoder is the one place that reads the platform codec's buffer directly. Flutter
 * 3.50 returns it positioned after the bytes, so the previous read produced an empty payload
 * for every event (the connections list and the logcat feed never arrived); this test fails
 * with a zero-length array in that case.
 */
class BulkWireTest {

    @Test
    fun `a bulk payload is a complete codec message`() {
        val rows = listOf(
            mapOf(
                "id" to "1",
                "upload" to 10L,
                "download" to 20L,
                "network" to "tcp",
                "chain" to listOf("Proxy", "Tokyo"),
                "process" to mapOf("path" to "/data/app/~~x/com.example-1/base.apk"),
            ),
            mapOf("id" to "2", "upload" to 0L, "download" to 0L, "inbound" to null),
        )
        val bytes = BulkWire.encode(rows)
        assertTrue("encode returned an empty payload", bytes.isNotEmpty())
        // decodeMessage checks that the buffer is fully consumed, so this also proves there is
        // no trailing garbage after the position fix.
        val decoded = StandardMessageCodec.INSTANCE.decodeMessage(ByteBuffer.wrap(bytes))
        assertEquals(2, (decoded as List<*>).size)
    }
}
