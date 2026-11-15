package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.outbound.json.JsonArray
import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.outbound.json.JsonObject
import io.nekohasekai.sagernet.route.OutboundIds
import io.nekohasekai.sagernet.route.RouteProfile
import io.nekohasekai.sagernet.route.RouteRule
import io.nekohasekai.sagernet.route.RuleType
import io.throneproj.mobile.Mobile

/**
 * The Kotlin face of the kernel's route action bus (ADR 0002, phase 3c).
 *
 * The route documents are kernel-owned: `RouteJsonStore` is read-only on this side and
 * `RouteManager.save` throws once those documents exist, which is the state of every install
 * that has ever opened the routing screen. Two writers here do not go through the UI —
 * [io.nekohasekai.sagernet.group.RemoteRouteUpdater] (a remote profile's periodic refresh) and
 * [io.nekohasekai.sagernet.group.SubscriptionRoute] (a subscription's `routing` header) — and
 * both must still be able to save.
 *
 * `Mobile.runAction` is the synchronous twin of `throne_invoke_action`: same registry, same
 * `ActionResult` JSON, but the answer comes back on the calling thread instead of a Dart
 * message port. That is what makes it callable from a coroutine worker that has no port to
 * reply to.
 *
 * Errors are thrown, never swallowed: a failed save must not leave the caller believing the
 * profile was written.
 */
object RouteActions {

    /** One profile as `saveRouteProfile` takes it, so the caller's model survives the trip. */
    fun save(p: RouteProfile): Long {
        val payload = JsonObject().apply {
            this["id"] = p.id
            this["name"] = p.name
            // Absent (`null`) means "leave untouched" to the Go handler; every field here is
            // the model's own current value, so a remote update writes the whole row it built.
            this["defaultOutbound"] = OutboundIds.toName(p.default_outbound_id)
            this["isRemote"] = p.is_remote
            this["remoteUrl"] = p.remote_url
            this["autoUpdate"] = p.auto_update
            this["endpointIds"] = JsonArray().also { array ->
                for (id in RouteProfileEntity.parseIdJson(p.endpoint_profile_ids)) array.add(id)
            }
            // The rule list, as the editor's rule maps: the handler's ruleRowFromWire keeps every
            // column the map does not name from the row it already had.
            this["rules"] = rulesToWire(p.rules)
            // The subscription binding and the refresh stamp. Both are columns of the row, not
            // editor fields: a create through this path has no earlier row to inherit them from,
            // and a lost `source_gid` would detach the subscription from its profile.
            this["sourceGid"] = p.source_gid
            this["remoteLastUpdate"] = p.remote_last_update
        }
        val answer = invoke("saveRouteProfile", payload)
        return (answer["data"] as? Number)?.toLong()
            ?: error("saveRouteProfile answered no profile id")
    }

    /** Marks [id] as the profile the core builds. */
    fun setCurrent(id: Long) {
        invoke("setCurrentRoute", JsonObject().apply { this["id"] = id })
    }

    /**
     * Runs one action and unwraps its `ActionResult`.
     *
     * The Go side encodes `{id, method, data, code}`; a non-zero `code` carries the handler's
     * error message in `data`. Both are surfaced as an [IllegalStateException] so a caller's
     * existing `catch (e: Exception)` (the update paths already have one) reports a readable
     * message instead of a silent no-op.
     */
    private fun invoke(method: String, payload: JsonObject): JsonObject {
        val request = JsonObject().apply {
            this["id"] = "kotlin:$method"
            this["method"] = method
            this["data"] = payload
        }
        val answer = JsonInput.parseObjectOrNull(Mobile.runAction(request.toCompact()))
            ?: error("$method answered no result")
        val code = answer.integer("code")
        if (code != 0L) {
            error(answer.string("data").ifEmpty { "$method failed with code $code" })
        }
        return answer
    }

    /**
     * The editor's rule maps, mirroring `BboxRoutes.ruleToMap` (the shape the Go
     * `ruleRowFromWire` reads): the type as its token, the outbound as a number and the column
     * groups by name, so every condition the editor can hold round-trips.
     */
    private fun rulesToWire(rules: List<RouteRule>): JsonArray = JsonArray().also { out ->
        for (rule in rules) {
            val map = JsonObject()
            map["name"] = rule.name
            map["type"] = RuleType.values().firstOrNull { it.id == rule.type }?.token
                ?: RuleType.CUSTOM.token
            map["disabled"] = rule.disabled
            map["action"] = rule.action
            map["outbound_id"] = rule.outbound_id
            for (field in RouteRule.STRING_FIELDS) map[field.name] = field.get(rule)
            for (field in RouteRule.LIST_FIELDS) {
                map[field.name] = JsonArray().also { list -> for (value in field.get(rule)) list.add(value) }
            }
            for (field in RouteRule.BOOL_FIELDS) map[field.name] = field.get(rule)
            out.add(map)
        }
    }
}
