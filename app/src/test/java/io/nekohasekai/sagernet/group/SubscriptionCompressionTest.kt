package io.nekohasekai.sagernet.group

import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets
import java.util.zip.DeflaterOutputStream
import java.util.zip.GZIPOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

/** A panel may send a gzip/zlib body without Content-Encoding; SubscriptionFetch sniffs it. */
class SubscriptionCompressionTest {

    private val text = "ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388#Node%20A"

    private fun compress(gzip: Boolean): ByteArray {
        val out = ByteArrayOutputStream()
        val stream = if (gzip) GZIPOutputStream(out) else DeflaterOutputStream(out)
        stream.use { it.write(text.toByteArray(StandardCharsets.UTF_8)) }
        return out.toByteArray()
    }

    @Test
    fun `a plain body is returned untouched`() {
        val plain = text.toByteArray(StandardCharsets.UTF_8)
        assertArrayEquals(plain, SubscriptionCompression.decode(plain))
    }

    @Test
    fun `gzip without content encoding is decompressed`() {
        val body = SubscriptionCompression.decode(compress(gzip = true))
        assertEquals(text, String(body, StandardCharsets.UTF_8))
    }

    @Test
    fun `zlib without content encoding is decompressed`() {
        val body = SubscriptionCompression.decode(compress(gzip = false))
        assertEquals(text, String(body, StandardCharsets.UTF_8))
    }

    @Test
    fun `a body whose magic is not a real gzip stream stays untouched`() {
        val body = compress(gzip = true).copyOf(10)
        assertArrayEquals(body, SubscriptionCompression.decode(body))
    }
}
