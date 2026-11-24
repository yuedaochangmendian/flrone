package io.nekohasekai.sagernet.group

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.zip.GZIPInputStream
import java.util.zip.InflaterInputStream

/**
 * Some subscription servers send a gzip or zlib body without saying so in
 * `Content-Encoding`, which is the only signal OkHttp decompresses on. Sniff
 * the two container magics before the body is decoded as UTF-8
 * (FlClash's `decompressUnlabeled`, common/request.dart:192-208).
 *
 * A body that expands past [MAX_DECOMPRESSED_BYTES] is refused instead of
 * filling the heap; a body that starts with a magic but fails to inflate is
 * returned untouched, as FlClash does, so a plain base64 body whose first two
 * bytes look like a zlib header is not rejected by the sniff.
 */
internal object SubscriptionCompression {

    /** A compressed subscription that expands past this is refused instead of filling the heap. */
    const val MAX_DECOMPRESSED_BYTES = 128L * 1024 * 1024

    private class TooLarge : IOException()

    fun decode(bytes: ByteArray): ByteArray {
        if (!isGzip(bytes) && !isZlib(bytes)) return bytes
        return try {
            val input = if (isGzip(bytes)) {
                GZIPInputStream(ByteArrayInputStream(bytes))
            } else {
                InflaterInputStream(ByteArrayInputStream(bytes))
            }
            input.use(::readCapped)
        } catch (e: TooLarge) {
            throw IOException(
                "the decompressed subscription is larger than " +
                    "${MAX_DECOMPRESSED_BYTES / (1024 * 1024)} MiB",
                e,
            )
        } catch (_: Exception) {
            // Not actually a compressed body, or corrupt: let the importer
            // report the body it received rather than replacing it.
            bytes
        }
    }

    private fun isGzip(bytes: ByteArray): Boolean =
        bytes.size >= 2 &&
            (bytes[0].toInt() and 0xFF) == 0x1F &&
            (bytes[1].toInt() and 0xFF) == 0x8B

    private fun isZlib(bytes: ByteArray): Boolean =
        bytes.size >= 2 &&
            (bytes[0].toInt() and 0xFF) == 0x78 &&
            (((bytes[0].toInt() and 0xFF) shl 8) or (bytes[1].toInt() and 0xFF)) % 31 == 0

    private fun readCapped(input: InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            total += read
            if (total > MAX_DECOMPRESSED_BYTES) {
                throw TooLarge()
            }
            output.write(buffer, 0, read)
        }
        return output.toByteArray()
    }
}
