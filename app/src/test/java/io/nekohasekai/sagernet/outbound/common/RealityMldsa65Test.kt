package io.nekohasekai.sagernet.outbound.common

import io.nekohasekai.sagernet.outbound.link.LinkParser
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Xray's REALITY ML-DSA-65 verification key: link `pqv`, JSON `mldsa65_verify`. */
class RealityMldsa65Test {

    private val publicKey = Base64.getUrlEncoder().withoutPadding()
        .encodeToString(ByteArray(32) { it.toByte() })
    private val verifyKey = Base64.getUrlEncoder().withoutPadding()
        .encodeToString(ByteArray(1952) { it.toByte() })

    @Test
    fun `a 1952-byte base64url key is accepted and a short one is not`() {
        assertTrue(isMldsa65VerifyKey(verifyKey))
        assertFalse(isMldsa65VerifyKey("AAAA"))
        assertFalse(isMldsa65VerifyKey(""))
    }

    @Test
    fun `a pqv link value lands in the reality model`() {
        val reality = Reality()
        assertTrue(
            reality.parseFromLink(
                LinkParser.parse("vless://00000000-0000-0000-0000-000000000000@example.com:443?pbk=$publicKey&sid=abcd&pqv=$verifyKey"),
            ),
        )
        assertEquals(verifyKey, reality.mldsa65_verify)
        assertEquals("abcd", reality.short_id)
        assertTrue(reality.exportToLink().any { it.first == "pqv" && it.second == verifyKey })
        assertEquals(verifyKey, reality.exportToJson()["mldsa65_verify"])
    }

    @Test
    fun `json accepts both the snake and camel spellings`() {
        val snake = Reality()
        snake.parseFromJson(
            io.nekohasekai.sagernet.outbound.json.jsonObjectOf(
                "enabled" to true,
                "public_key" to publicKey,
                "mldsa65_verify" to verifyKey,
            ),
        )
        assertEquals(verifyKey, snake.mldsa65_verify)

        val camel = Reality()
        camel.parseFromJson(
            io.nekohasekai.sagernet.outbound.json.jsonObjectOf(
                "enabled" to true,
                "public_key" to publicKey,
                "mldsa65Verify" to verifyKey,
            ),
        )
        assertEquals(verifyKey, camel.mldsa65_verify)
    }
}
