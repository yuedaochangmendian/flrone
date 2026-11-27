package io.flrone.bridge

import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.SettingsRegistry
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * The core's optional Clash API, used only for in-place selector switching.
 *
 * Throne's core bundles sing-box's `experimental.clash_api` server. The
 * connections screen and the traffic ledger no longer read it — they use the
 * core's own connection feed (`connections_actions.go`) — but a node tap still
 * uses `PUT /proxies/{name}` to switch a running selector without rebuilding
 * the config. When the API is off (the user's own choice, or a stored negative
 * port) the caller falls back to the reload path.
 */
object FlroneApi {

    /** Thron's default magnitude for `core_box_clash_api`, used when the value has been zeroed. */
    private const val DEFAULT_PORT = 9090

    private const val TIMEOUT_SECONDS = 5L

    data class Server(val host: String, val port: Int, val secret: String)

    @Volatile
    private var client: OkHttpClient? = null

    /** The API as Thron is configured to serve it, whether or not it is currently switched on. */
    fun configured(): Server? {
        val stored = DataStore.coreBoxClashApi
        if (stored == 0) return null
        val address = DataStore.coreBoxClashListenAddr.ifBlank { SettingsRegistry.LOOPBACK_ADDRESS }
        // A wildcard bind is still reachable locally; asking the router for our own LAN name never is.
        val host = if (address == "0.0.0.0" || address == "::") SettingsRegistry.LOOPBACK_ADDRESS else address
        return Server(host, kotlin.math.abs(stored), DataStore.coreBoxClashApiSecret)
    }

    fun enabled(): Boolean = DataStore.coreBoxClashApi > 0

    /**
     * Turns the API on at service start for live node switching, but only when the user has
     * never made a choice. A missing `core_box_clash_api` row means "untouched": the -9090 the
     * getter falls back to is a default, not a stored user decision. A stored negative port is
     * the user's own off switch and is respected (a tap then falls back to the reload path).
     *
     * The connections screen and the traffic ledger no longer read this API — they use the
     * core's connection feed — but `selectProxy` still switches a running selector in place.
     * This runs before the config build, so the freshly generated core config serves the API;
     * flipping it after a tap would force the reload the fast path exists to avoid.
     */
    fun enableForLiveSelection(): Boolean {
        if (enabled()) return false
        if (DataStore.configurationStore.contains(SettingsRegistry.CORE_BOX_CLASH_API.key)) return false
        DataStore.coreBoxClashApi = DEFAULT_PORT
        // Before the config build that follows this call: the port is opened here, so the secret
        // the build emits and the one this client sends are generated once, together.
        DataStore.ensureClashApiSecret()
        return true
    }

    private fun http(): OkHttpClient = client ?: synchronized(this) {
        client ?: OkHttpClient.Builder()
            .connectTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .readTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .callTimeout(TIMEOUT_SECONDS * 2, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
            .build().also { client = it }
    }

    private fun call(server: Server, path: String, method: String = "GET", body: String? = null): String {
        val url = "http://${server.host}:${server.port}$path"
        val request = Request.Builder().url(url).apply {
            if (server.secret.isNotBlank()) header("Authorization", "Bearer ${server.secret}")
            when (method) {
                "DELETE" -> delete()
                "PUT" -> put(body.orEmpty().toRequestBody("application/json; charset=utf-8".toMediaTypeOrNull()))
                else -> get()
            }
        }.build()
        http().newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) error("HTTP ${response.code}${' '}${body.take(120)}")
            return body
        }
    }

    /**
     * Switches one of the running core's selector groups in place — the clash-api's
     * `PUT /proxies/{name}` — instead of rebuilding the whole config to apply a node choice.
     *
     * The API names groups by their outbound tag and lists each group's members under `all`.
     * A tag that matches the display name exactly wins; otherwise a single tag ending in
     * `/<group>` is accepted (the route builder may prefix its outbound tags). Anything
     * ambiguous, missing, or refused answers false, and the caller keeps the reload path —
     * a switch that cannot be proven is not attempted.
     */
    fun selectProxy(group: String, member: String): Boolean {
        val server = configured() ?: return false
        if (!enabled()) return false
        return runCatching {
            val proxies = JSONObject(call(server, "/proxies")).optJSONObject("proxies") ?: return false
            val keys = proxies.keys().asSequence().toList()
            val exact = keys.firstOrNull { it == group }
            val suffixed = if (exact == null) keys.filter { it.endsWith("/$group") } else emptyList()
            val tag = exact ?: suffixed.singleOrNull() ?: return false
            val entry = proxies.optJSONObject(tag) ?: return false
            val all = entry.optJSONArray("all")
            val members = (0 until (all?.length() ?: 0)).map { all!!.optString(it) }
            val picked = members.firstOrNull { it == member }
                ?: members.filter { it.endsWith("/$member") }.singleOrNull()
                ?: if (members.isEmpty()) member else return false
            val payload = JSONObject().put("name", picked).toString()
            call(server, "/proxies/${java.net.URLEncoder.encode(tag, "UTF-8")}", "PUT", payload)
            true
        }.getOrDefault(false)
    }
}
