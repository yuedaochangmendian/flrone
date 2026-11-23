package io.flrone.bridge

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import javax.crypto.spec.SecretKeySpec

/**
 * The credential envelope's pure halves (alignment item S10).
 *
 * `SecureBox`'s `AndroidKeyStore` adapter is device-only: the mockable `android.jar` cannot run a
 * KeyStore or a `KeyGenParameterSpec`, and a real one would need instrumentation. What can be held
 * still on a plain JVM is everything around it — the envelope layout, the base64, AES/GCM over an
 * arbitrary key, and the channel's argument contract — and that is what this suite drives. The
 * adapter is then a thin KeyStore lookup plus [AesGcm], so a device-side failure left is a KeyStore
 * one (`SecureBox.open` answers null and `seal` answers `seal_failed`).
 */
class SecureBoxTest {

    private val key = SecretKeySpec(ByteArray(32) { it.toByte() }, "AES")
    private val otherKey = SecretKeySpec(ByteArray(32) { (it + 1).toByte() }, "AES")

    // --- base64 (RFC 4648 §10 vectors) ---------------------------------------------------------

    @Test
    fun `base64 matches the RFC 4648 vectors`() {
        val vectors = listOf(
            "" to "",
            "f" to "Zg==",
            "fo" to "Zm8=",
            "foo" to "Zm9v",
            "foob" to "Zm9vYg==",
            "fooba" to "Zm9vYmE=",
            "foobar" to "Zm9vYmFy",
        )
        for ((plain, encoded) in vectors) {
            assertEquals("encoding $plain", encoded, base64Encode(plain.toByteArray()))
            assertArrayEquals("decoding $encoded", plain.toByteArray(), base64Decode(encoded)!!)
        }
    }

    @Test
    fun `base64 round-trips every length up to two quanta`() {
        for (size in 0..24) {
            val bytes = ByteArray(size) { (it * 37 + 11).toByte() }
            assertArrayEquals("size $size", bytes, base64Decode(base64Encode(bytes))!!)
        }
    }

    @Test
    fun `base64 rejects anything that is not one padded quantum sequence`() {
        assertNull("a truncated quantum", base64Decode("Zm9"))
        assertNull("a bad character", base64Decode("Zm9v!"))
        assertNull("padding mid-string", base64Decode("Zg==Zg=="))
        assertNull("one pad in a full quantum", base64Decode("Zg==Zm9v"))
        assertNull("padding in the third slot alone", base64Decode("Z=g="))
    }

    // --- envelope ------------------------------------------------------------------------------

    @Test
    fun `the envelope is the version prefix plus the nonce and ciphertext`() {
        val nonce = ByteArray(EnvelopeCodec.NONCE_BYTES) { it.toByte() }
        val ciphertext = ByteArray(EnvelopeCodec.TAG_BYTES) { (it + 1).toByte() }
        val token = EnvelopeCodec.encode(nonce, ciphertext)

        assertTrue(token.startsWith("enc:v1:"))
        assertTrue(EnvelopeCodec.isSealed(token))
        val (parsedNonce, parsedBody) = EnvelopeCodec.decode(token)!!
        assertArrayEquals(nonce, parsedNonce)
        assertArrayEquals(ciphertext, parsedBody)
    }

    @Test
    fun `a token this build did not write is malformed, not guessed at`() {
        assertNull("plaintext", EnvelopeCodec.decode("hunter2"))
        assertNull("a future version", EnvelopeCodec.decode("enc:v2:AAAAAAAAAAAAAAAA"))
        assertNull("empty", EnvelopeCodec.decode(""))
        assertNull("not base64", EnvelopeCodec.decode("enc:v1:!!!!"))
        assertNull("base64 but truncated", EnvelopeCodec.decode("enc:v1:AAAA"))
        assertFalse(EnvelopeCodec.isSealed("hunter2"))
    }

    // --- AES/GCM over an arbitrary key ----------------------------------------------------------

    @Test
    fun `seal then open returns the plaintext`() {
        val token = AesGcm.seal(key, "old-secret")
        assertTrue(token.startsWith("enc:v1:"))
        assertNotEquals("the envelope must not contain the plaintext", "old-secret", token)
        assertEquals("old-secret", AesGcm.open(key, token))
    }

    @Test
    fun `every seal uses a fresh nonce`() {
        val first = EnvelopeCodec.decode(AesGcm.seal(key, "same"))!!.first
        val second = EnvelopeCodec.decode(AesGcm.seal(key, "same"))!!.first
        assertFalse("two seals share a nonce", first.contentEquals(second))
    }

    @Test
    fun `a tampered ciphertext does not open`() {
        val token = AesGcm.seal(key, "old-secret")
        val (nonce, ciphertext) = EnvelopeCodec.decode(token)!!
        ciphertext[0] = (ciphertext[0].toInt() xor 0x01).toByte()
        assertNull(AesGcm.open(key, EnvelopeCodec.encode(nonce, ciphertext)))
    }

    @Test
    fun `a different key does not open`() {
        val token = AesGcm.seal(key, "old-secret")
        assertNull("the keystore was reset and a new key was minted", AesGcm.open(otherKey, token))
    }

    @Test
    fun `open never throws on a malformed token`() {
        for (token in listOf("", "hunter2", "enc:v1:", "enc:v2:AAAA", "enc:v1:AAAA")) {
            assertNull(token, AesGcm.open(key, token))
        }
    }

    @Test
    fun `a non-ascii password survives the round trip`() {
        val password = "пароль-密码-🔑"
        assertEquals(password, AesGcm.open(key, AesGcm.seal(key, password)))
    }

    // --- channel argument contract -------------------------------------------------------------

    @Test
    fun `seal and open read their value`() {
        assertEquals(SecureCall.Seal("s"), parseSecureCall("seal", mapOf("value" to "s")))
        assertEquals(SecureCall.Open("enc:v1:AAAA"), parseSecureCall("open", mapOf("value" to "enc:v1:AAAA")))
        // `open` accepts any string: a malformed token is its ordinary null answer.
        assertEquals(SecureCall.Open(""), parseSecureCall("open", mapOf("value" to "")))
    }

    @Test
    fun `a missing or non-string value is an argument error`() {
        assertTrue(parseSecureCall("seal", null) is SecureCall.Invalid)
        assertTrue(parseSecureCall("seal", mapOf("value" to 5)) is SecureCall.Invalid)
        assertTrue(parseSecureCall("seal", "not-a-map") is SecureCall.Invalid)
        assertTrue(parseSecureCall("open", emptyMap<String, Any?>()) is SecureCall.Invalid)
        // Sealing nothing would look exactly like a stored empty secret.
        assertTrue(parseSecureCall("seal", mapOf("value" to "")) is SecureCall.Invalid)
    }

    @Test
    fun `any other method is notImplemented territory`() {
        assertEquals(SecureCall.Unknown, parseSecureCall("delete", mapOf("value" to "s")))
        assertEquals(SecureCall.Unknown, parseSecureCall("", null))
    }
}
