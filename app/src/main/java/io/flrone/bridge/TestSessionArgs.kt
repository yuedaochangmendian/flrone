package io.flrone.bridge

import org.json.JSONObject

/**
 * Pure payload decoding for the test-session action bus (ADR 0004 P4a).
 *
 * Kept free of Android/TestSessionClient so a JVM test can pin the wire shape
 * Go sends through platform_request: which keys are read, how ids are widened
 * to Long, and that a missing `kind` is rejected loudly instead of starting a
 * session with a sentinel value.
 */
internal object TestSessionArgs {

    data class Start(
        val kind: Int,
        val groupId: Long,
        val ids: List<Long>,
        val testCurrent: Boolean,
        val speedMode: Int,
    )

    fun parse(payload: JSONObject): Start {
        val kind = if (payload.has("kind")) payload.optInt("kind") else throw IllegalArgumentException("Missing kind")
        return Start(
            kind = kind,
            groupId = payload.optLong("groupId", 0L),
            ids = longArray(payload, "profileIds"),
            testCurrent = payload.optBoolean("testCurrent", false),
            speedMode = payload.optInt("speedMode", -1),
        )
    }

    fun longArray(payload: JSONObject, key: String): List<Long> {
        val values = payload.optJSONArray(key) ?: return emptyList()
        return (0 until values.length()).mapNotNull { (values.opt(it) as? Number)?.toLong() }
    }
}
