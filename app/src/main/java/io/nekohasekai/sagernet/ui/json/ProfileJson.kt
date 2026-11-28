package io.nekohasekai.sagernet.ui.json

import io.nekohasekai.sagernet.outbound.Outbound
import io.nekohasekai.sagernet.outbound.json.JsonObject
import io.nekohasekai.sagernet.ui.json.engine.JsonFormatter

/**
 * Formats a typed profile's ExportToJson / Throne stored form as indented JSON text for the bridge's nodeConfig.
 */
object ProfileJson {

    fun text(outbound: Outbound): String = text(outbound.exportToJson())

    fun text(json: JsonObject): String {
        if (json.isEmpty()) return ""
        val compact = json.toCompact()
        return JsonFormatter.format(compact) ?: compact
    }

}
