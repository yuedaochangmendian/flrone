package io.nekohasekai.sagernet.bg.proto

import io.flrone.core.CoreHost
import io.nekohasekai.sagernet.data.config.GeneratedConfig
import org.json.JSONArray
import org.json.JSONObject

/**
 * The test config (BuildTestConfig) now comes from the Go builder through the
 * `build_test_config` host call: ConfigGenerator is gone, so the Kotlin test
 * session, probe and subscription-filter paths share the same port the golden
 * harness compares byte for byte.
 *
 * The Go reply carries GeneratedConfig's fields; this wrapper only maps the
 * JSON shapes (Long-keyed maps arrive as string keys).
 */
object TestConfigBuilder {

    fun buildTest(profileIds: List<Long>): GeneratedConfig = try {
        buildTestOrThrow(profileIds)
    } catch (error: Exception) {
        GeneratedConfig.failure(error.message ?: error.toString())
    }

    /**
     * [buildTest] with the envelope kept apart: a call that never reached the builder (an unreadable document, an
     * outdated core, a panic) throws instead of reading as a failed build. The profile validator deletes rows on
     * [GeneratedConfig.error] and must never delete one because it could not ask.
     */
    fun buildTestOrThrow(profileIds: List<Long>): GeneratedConfig {
        val data = CoreHost.call(
            "build_test_config",
            JSONObject().put("profileIds", JSONArray(profileIds)),
        ) as? JSONObject ?: throw CoreHost.HostCallException("build_test_config answered no data")

        val outboundTags = data.optJSONArray("outboundTags").toStringList()
        val tagToProfileId = data.optJSONObject("tagToProfileId").toLongMap()
        val fullConfigs = data.optJSONObject("fullConfigs").toStringMap()
        val skipped = data.optJSONObject("skipped").toStringMap()
        return GeneratedConfig(
            coreConfig = data.optString("coreConfig"),
            outboundTags = outboundTags,
            tagToProfileId = tagToProfileId,
            fullConfigs = fullConfigs,
            skipped = skipped,
            error = if (data.isNull("error")) null else data.optString("error"),
        )
    }

    private fun JSONArray?.toStringList(): List<String> {
        if (this == null) return emptyList()
        return buildList(length()) {
            for (index in 0 until length()) add(optString(index))
        }
    }

    private fun JSONObject?.toStringMap(): Map<Long, String> {
        if (this == null) return emptyMap()
        val out = LinkedHashMap<Long, String>()
        for (key in keys()) {
            out[key.toLongOrNull() ?: continue] = optString(key)
        }
        return out
    }

    private fun JSONObject?.toLongMap(): Map<String, Long> {
        if (this == null) return emptyMap()
        val out = LinkedHashMap<String, Long>()
        for (key in keys()) {
            out[key] = optLong(key)
        }
        return out
    }
}
