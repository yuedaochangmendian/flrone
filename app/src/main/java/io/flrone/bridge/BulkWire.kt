package io.flrone.bridge

import io.flutter.plugin.common.StandardMessageCodec

/**
 * Encodes one bulk event payload so the UI isolate can decide where to decode it.
 *
 * The log tails and the connection list are the only feeds whose size is a function of the
 * payload (a 1500-entry logcat batch, a few hundred connections); every other event is a
 * handful of keys. Sending them as `List<Map>` meant the codec decoded them **on the UI
 * isolate**, and — because `ThroneBoxBridge.emit` posts to the platform thread — the
 * *encode* also ran there.
 *
 * FlClash's `coreIsolateDecodeBytes` is the same idea from the other end: the core hands over
 * bytes and the UI uses `compute` above 50 KiB. Here the bytes are one `StandardMessageCodec`
 * message rather than JSON, so the wire stays typed (longs, doubles, nested lists and nulls
 * all survive) and the encode is a buffer write instead of a re-serialization.
 *
 * The encode runs on the producing thread (the log worker / connection pump), so the
 * platform thread only copies a byte array.
 */
internal object BulkWire {

    /** The payload as a codec message; empty when the codec refuses the value. */
    fun encode(value: Any?): ByteArray {
        val buffer = StandardMessageCodec.INSTANCE.encodeMessage(value) ?: return ByteArray(0)
        // Flutter 3.50's codec returns the buffer *positioned after the bytes* (it allocates,
        // puts, and returns without a flip), so reading from the position yielded a zero-length
        // payload for every bulk event: the connections list and the logcat feed never reached
        // the UI. Older codecs return it at position 0. Flip only when nothing remains, which
        // normalises both shapes.
        if (!buffer.hasRemaining()) buffer.flip()
        val bytes = ByteArray(buffer.remaining())
        buffer.get(bytes)
        return bytes
    }
}
