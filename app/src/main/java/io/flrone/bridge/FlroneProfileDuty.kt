package io.flrone.bridge

/**
 * The profile editor's platform duties, behind ONE channel arm.
 *
 * ADR 0005 final stage: profiles and groups are Dart-owned data. Every mutation
 * goes through `profiles.applyDocument` into Dart's `ProfileStore`, and Dart's
 * document is what Kotlin (`DartProfileStore`) and Go (`profiles_doc.go`) read
 * to build the core config and the outbound picker. There is no Room writer for
 * either table.
 *
 * What still needs the host is not data ownership but the Throne model and the
 * Android platform:
 *
 *  * **parsing and validation** — share links, base64 subscriptions, JSON/YAML
 *    documents (`ProfileImport`, `OutboundFactory`, `ProfileJson`,
 *    `Outbound.validate`) have no Dart implementation;
 *  * **the subscription queue** — fetching and diffing a group's nodes;
 *  * **selection side effects** — `DataStore.selectedProxy`/`currentProfile`
 *    are settings (Kotlin-owned) and a running service must hot-switch;
 *  * **group deletion** — stops the service and drops the routing profile the
 *    subscription provided;
 *  * **the auto-selector runtime** — it runs inside the kernel;
 *  * **one GroupSort duty** — `sort.reposition` re-applies a kept
 *    BY_TEST_RESULT/BY_LATENCY order after Dart cleared the test columns. The
 *    sort keys read the parsed outbound model Dart does not have; the clear
 *    itself is Dart's now.
 *
 * The document-only ops that used to live here — `stats`, `reorder`,
 * `clearTestResults`, `nodeList`, `nodeReorder` — are Dart-owned now
 * (`ProfileDocumentService`, `flutter/lib/data/profile_document_service.dart`).
 * They never needed the Throne model for the read/write itself, only the same
 * `profiles.json` document Dart owns.
 *
 * `FlronePlatformBridge` used to carry 28 named `profiles.*` arms for these. They
 * are one `profiles.platform` call now, with `{op, payload}` and exactly the
 * payload keys the old arms read. `tools/diagnostics/platform_duty_audit.py`
 * holds this table to the Dart call sites, so an op cannot drift or go dead; it
 * also holds the five Dart-owned ops out of this table explicitly.
 */
object FlroneProfileDuty {

    private typealias Handler = suspend (Map<String, Any?>) -> Any?

    private val handlers: LinkedHashMap<String, Handler> = linkedMapOf(
        // --- group card and selection -------------------------------------
        "select" to { payload ->
            FlroneCommands.selectProfileAwait(payload.requireLong("id"))
            null
        },
        // The live selector switch's two halves (groups_actions.go owns the switch itself):
        // `persistSelection` writes the settings the next start reads and must NOT reload;
        // `selectMember` persists and raises the reload the configurations' own selection path
        // raises. A caller that already switched in place uses the first; every other tap uses
        // the second, which is the reload the old `groups.select` arm ended up performing.
        "persistSelection" to { payload ->
            FlroneCommands.persistSelection(
                payload.string("group"),
                payload.string("tag"),
                payload.longOrNull("nodeId"),
            )
            null
        },
        "selectMember" to { payload ->
            FlroneCommands.selectMemberAwait(
                payload.string("group"),
                payload.string("tag"),
                payload.longOrNull("nodeId"),
            )
            null
        },
        "delete" to { payload ->
            FlroneCommands.deleteProfile(payload.requireLong("id"))
            null
        },
        "update" to { payload ->
            FlroneCommands.updateSubscription(payload.requireLong("id"))
            null
        },
        // The television's previous/next server (TvControls.switchServer).
        "switchRelative" to { payload ->
            FlroneCommands.switchServer(payload.int("step", 0))
            null
        },
        // The narrow GroupSort remainder of the old clearTestResults: Dart
        // cleared the document, Kotlin repositions rows in a group kept sorted
        // by test result. Payload `id` is the group id.
        "sort.reposition" to { payload ->
            FlroneProfiles.repositionTestResults(payload.requireLong("id"))
            null
        },
        // --- group editor -------------------------------------------------
        "save" to { payload -> FlroneProfiles.save(payload) },
        "config" to { payload -> FlroneProfiles.config(payload.requireLong("id")).wire() },
        "read" to { payload -> FlroneProfiles.read(payload.requireLong("id")) },
        "write" to { payload ->
            FlroneProfiles.write(
                payload.requireLong("id"),
                payload["revision"] as? String,
                payload.string("content"),
            ).wire()
        },
        "decodeIntent" to { payload -> FlroneProfiles.decodeIntent(payload.string("uri")) },

        // --- nodes ---------------------------------------------------------
        "nodeLink" to { payload ->
            FlroneProfiles.nodeLink(payload.string("group"), payload.string("tag"), payload["json"] == true)
        },
        "nodeConfig" to { payload -> FlroneProfiles.nodeConfig(payload.requireLong("id")) },
        "nodeCreate" to { payload -> FlroneProfiles.commitNode(payload) },
        "createNode" to { payload -> FlroneProfiles.createNode(payload.string("type")) },
        "nodeParse" to { payload -> FlroneProfiles.parseNodeText(payload.string("text")) },
        "nodeUpdate" to { payload ->
            FlroneProfiles.updateNode(
                payload.requireLong("id"),
                payload["name"] as? String,
                payload["content"] as? String,
            )
        },
        "nodeDelete" to { payload ->
            FlroneProfiles.deleteNode(payload.requireLong("id"))
            null
        },
        "nodeTuningInfo" to { payload -> FlroneProfiles.nodeTuningInfo(payload.requireLong("id")) },
        "nodeTuningSave" to { payload ->
            FlroneProfiles.nodeTuningSave(payload.requireLong("id"), payload.valueMap("value"))
        },

        // --- auto selector ---------------------------------------------------
        "autoSelectorCreate" to { payload ->
            FlroneProfiles.createAutoSelector(payload.longOrNull("groupId"), payload["name"] as? String)
        },
        "autoSelectorInfo" to { payload -> FlroneProfiles.autoSelectorInfo(payload.requireLong("id")) },
        "autoSelectorSave" to { payload ->
            FlroneProfiles.autoSelectorSave(payload.requireLong("id"), payload.valueMap("value"))
        },
        "autoSelectorStatus" to { _ -> FlroneProfiles.autoSelectorStatus() },
        "autoSelectorPin" to { payload ->
            FlroneProfiles.autoSelectorPin(payload.requireLong("id"), payload.requireLong("memberId"))
        },
        "autoSelectorRecheck" to { _ ->
            FlroneProfiles.autoSelectorRecheck()
            null
        },
    )

    /** The ops this boundary answers; the duty audit compares it with Dart. */
    val names: Set<String> get() = handlers.keys

    /**
     * Runs [op] against [payload]. An unknown op fails loudly: a typo on the
     * Dart side must not look like "nothing to do".
     */
    suspend fun invoke(op: String, payload: Map<String, Any?>): Any? {
        val handler = handlers[op] ?: error("unknown profile platform duty: $op")
        return handler(payload)
    }
}

// Payload readers. The Dart side sends JSON maps, so a number arrives as
// Int/Long/Double depending on the platform channel codec.

private fun Map<String, Any?>.requireLong(key: String): Long =
    (this[key] as? Number)?.toLong() ?: error("Missing $key")

private fun Map<String, Any?>.longOrNull(key: String): Long? =
    (this[key] as? Number)?.toLong()

private fun Map<String, Any?>.string(key: String): String =
    this[key] as? String ?: ""

private fun Map<String, Any?>.int(key: String, fallback: Int): Int =
    (this[key] as? Number)?.toInt() ?: fallback

/**
 * The old arms read `value` with a fallback to the whole argument map, because
 * the Dart facade sent the value at the top level for the "form save" calls.
 * Keep that tolerance: [payload] itself is the value document in that case.
 */
private fun Map<String, Any?>.valueMap(key: String): Map<String, Any?> {
    val value = this[key] as? Map<*, *> ?: return this
    return value.entries.associate { it.key.toString() to it.value }
}
