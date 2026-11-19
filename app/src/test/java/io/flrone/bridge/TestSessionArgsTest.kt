package io.flrone.bridge

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ADR 0004 P4a: the payload shape Go relays into platform_request. Exercises
 * the real decoder (TestSessionArgs) so a key rename on the Dart/Go side fails
 * a JVM test instead of starting a session with default arguments.
 */
class TestSessionArgsTest {

    @Test
    fun `start decodes every field and widens ids`() {
        val args = TestSessionArgs.parse(
            JSONObject("""{"kind":2,"groupId":42,"profileIds":[7,8],"testCurrent":false,"speedMode":1}"""),
        )
        assertEquals(2, args.kind)
        assertEquals(42L, args.groupId)
        assertEquals(listOf(7L, 8L), args.ids)
        assertEquals(false, args.testCurrent)
        assertEquals(1, args.speedMode)
    }

    @Test
    fun `start defaults match the channel arm`() {
        val args = TestSessionArgs.parse(JSONObject("""{"kind":1}"""))
        assertEquals(0L, args.groupId)
        assertTrue(args.ids.isEmpty())
        assertEquals(false, args.testCurrent)
        assertEquals(-1, args.speedMode)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `start rejects a missing kind`() {
        TestSessionArgs.parse(JSONObject("{}"))
    }

    @Test
    fun `long array ignores non-numeric entries`() {
        val payload = JSONObject("""{"ids":[1,"x",null,3]}""")
        assertEquals(listOf(1L, 3L), TestSessionArgs.longArray(payload, "ids"))
        assertTrue(TestSessionArgs.longArray(JSONObject("{}"), "ids").isEmpty())
    }
}
