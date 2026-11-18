package io.flrone.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Kotlin face of the C ABI's JSON host bridge (`throne_host_call`).
 *
 * ADR 0004 retires the gomobile `Mobile.*` helper surface. These helpers keep
 * their Go implementation but cross as one JSON request/response instead of a
 * generated Java class per helper. Every call blocks on the Go side where the
 * original did; callers stay on their existing worker/binder threads.
 */
data class CoreStartOptions(
    val coreConfig: String,
    val needXray: Boolean,
    val xrayConfig: String,
    val xrayOutboundDNSStrategy: String,
    val xrayLazyStart: Boolean,
    val xrayIdleSeconds: Int,
    val xrayFullIdleSeconds: Int,
    val xrayFullConfigs: List<String>,
)

object CoreHost {

    class HostCallException(message: String) : IllegalStateException(message)

    fun newInstance(options: CoreStartOptions): CoreInstance {
        val params = JSONObject()
            .put("coreConfig", options.coreConfig)
            .put("needXray", options.needXray)
            .put("xrayConfig", options.xrayConfig)
            .put("xrayOutboundDNSStrategy", options.xrayOutboundDNSStrategy)
            .put("xrayLazyStart", options.xrayLazyStart)
            .put("xrayIdleSeconds", options.xrayIdleSeconds)
            .put("xrayFullIdleSeconds", options.xrayFullIdleSeconds)
            .put("xrayFullConfigs", JSONArray(options.xrayFullConfigs))
        val data = call("new_instance", params) as? JSONObject
            ?: throw HostCallException("new_instance answered no handle")
        return CoreInstance(data.getLong("handle"))
    }

    fun startUrlTest(request: CoreTestRequest): Int = startTest("start_url_test", request)

    fun startIpTest(request: CoreTestRequest): Int = startTest("start_ip_test", request)

    fun startSpeedTest(request: CoreTestRequest): Int = startTest("start_speed_test", request)

    private fun startTest(method: String, request: CoreTestRequest): Int {
        val data = call(method, JSONObject().put("request", request.toJson())) as? JSONObject
            ?: throw HostCallException("$method answered no session")
        return data.getInt("session")
    }

    data class TestBatch(val events: List<JSONObject>, val cursor: Int, val done: Boolean)

    fun pollTest(session: Int, cursor: Int): TestBatch {
        val data = call("poll_test", JSONObject().put("session", session).put("cursor", cursor)) as? JSONObject
            ?: return TestBatch(emptyList(), cursor, true)
        val rows = data.optJSONArray("events") ?: JSONArray()
        val events = buildList(rows.length()) {
            for (i in 0 until rows.length()) rows.optJSONObject(i)?.let(::add)
        }
        return TestBatch(events, data.optInt("cursor", cursor), data.optBoolean("done"))
    }

    fun cancelTests() {
        call("cancel_test")
    }

    /** Install the Go-side log sink that forwards lines over `platform_request("log")`. */
    fun setLogSink() {
        call("set_log_sink")
    }

    /** Run one host call and return its `data` field (null when the handler has no answer). */
    fun call(method: String, params: JSONObject = JSONObject()): Any? {
        val request = JSONObject()
            .put("method", method)
            .put("params", params)
            .toString()
        val raw = Core.hostCall(request)
        val answer = runCatching { JSONObject(raw) }
            .getOrElse { throw HostCallException("$method answered invalid JSON: ${it.message}") }
        if (!answer.optBoolean("ok", false)) {
            throw HostCallException(answer.optString("error").ifEmpty { "$method failed" })
        }
        return if (answer.has("data") && !answer.isNull("data")) answer.get("data") else null
    }

    fun version(): String = call("version") as? String ?: ""
    fun xrayVersion(): String = call("xray_version") as? String ?: ""
    fun goVersion(): String = call("go_version") as? String ?: ""

    fun setup(basePath: String, workingPath: String, tempPath: String, logMaxLines: Int, debug: Boolean) {
        call(
            "setup",
            JSONObject()
                .put("basePath", basePath)
                .put("workingPath", workingPath)
                .put("tempPath", tempPath)
                .put("logMaxLines", logMaxLines)
                .put("debug", debug),
        )
    }

    fun checkConfig(config: String) = call("check_config", JSONObject().put("config", config))

    fun checkXrayConfig(config: String) = call("check_xray_config", JSONObject().put("config", config))

    fun genQuicSignature(domain: String): List<String> {
        val data = call("gen_quic_signature", JSONObject().put("domain", domain)) as? JSONObject
        val packets = data?.optJSONArray("packets") ?: return emptyList()
        return buildList(packets.length()) {
            for (i in 0 until packets.length()) add(packets.optString(i))
        }
    }

    data class ResolvedDomain(val domain: String, val error: String, val addresses: List<String>)

    fun resolveDomains(coreConfig: String, domains: List<String>): List<ResolvedDomain> {
        val params = JSONObject()
            .put("coreConfig", coreConfig)
            .put("domains", JSONArray(domains))
        val data = call("resolve_domains", params) as? JSONObject
        val results = data?.optJSONArray("results") ?: return emptyList()
        return buildList(results.length()) {
            for (i in 0 until results.length()) {
                val row = results.optJSONObject(i) ?: continue
                val addresses = row.optJSONArray("addresses") ?: JSONArray()
                add(
                    ResolvedDomain(
                        domain = row.optString("domain"),
                        error = row.optString("error"),
                        addresses = buildList(addresses.length()) {
                            for (j in 0 until addresses.length()) add(addresses.optString(j))
                        },
                    ),
                )
            }
        }
    }

    /** Returns the bridge's JSON object with snake_case keys, or throws on a failed registration. */
    fun warpRegister(
        tunnelType: String,
        proxy: String,
        apiHosts: List<String>,
    ): String {
        val params = JSONObject()
            .put("tunnelType", tunnelType)
            .put("proxy", proxy)
            .put("apiHosts", JSONArray(apiHosts))
        val data = call("warp_register", params) as? JSONObject ?: JSONObject()
        return data.put("error", "").toString()
    }

    fun captureDiagnostics(
        durationMs: Int,
        contention: Boolean,
        trace: Boolean,
        attachmentPaths: List<String>,
        outputPath: String,
    ) {
        call(
            "capture_diagnostics",
            JSONObject()
                .put("durationMs", durationMs)
                .put("contention", contention)
                .put("trace", trace)
                .put("attachmentPaths", JSONArray(attachmentPaths))
                .put("outputPath", outputPath),
        )
    }

    fun stopDiagnostics() {
        call("stop_diagnostics")
    }
}
