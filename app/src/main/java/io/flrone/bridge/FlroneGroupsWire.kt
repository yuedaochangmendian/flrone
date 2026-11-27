package io.flrone.bridge

import io.flrone.model.ProxyGroup
import io.flrone.model.ProxyNode

/**
 * The group rows the Flutter host renders, kept out of the bridge so the wire contract can be
 * tested without an Activity.
 *
 * One shape, one decision: `ready` and the one-second pump send **counts** (`nodeCount`,
 * `timeouts`) and no rows, because the rows are the largest payload the bridge carries — 134 B per
 * node on the wire, and three copies alive while they are built — and only the Proxies screen
 * renders them. That screen asks for them with `groups.visible`. The rule editor's outbound picker
 * takes id/tag only from the Go `groupNodes` action (the Dart-owned profiles document), not from
 * a second host wire.
 */
internal object FlroneGroupsWire {

    /** The catalog with counts only, or with the node rows when the Proxies screen is open. */
    fun groups(groups: List<ProxyGroup>, withItems: Boolean): List<Map<String, Any?>> = groups.map { group ->
        mapOf(
            "id" to group.id.toInt(),
            "tag" to group.tag,
            "type" to group.type,
            "selected" to group.selected,
            "selectedId" to group.selectedId.toInt(),
            "selectable" to group.selectable,
            // The single-node container: the Proxies screen draws its nodes without
            // the group tab/header when it is the current configuration.
            "single" to group.single,
            "nodeCount" to group.nodes.size,
            // Tested and did not answer. The dashboard chip used to walk every node row for this.
            "timeouts" to group.nodes.count { node -> node.testedAt > 0 && node.delay <= 0 },
            "items" to if (withItems) group.nodes.map(::node) else emptyList<Map<String, Any?>>(),
        )
    }

    private fun node(node: ProxyNode): Map<String, Any?> = mapOf(
        "id" to node.id.toInt(),
        "tag" to node.tag,
        "type" to node.type,
        "delay" to node.delay,
        "testedAt" to node.testedAt,
        "isSelector" to node.isSelector,
    )
}
