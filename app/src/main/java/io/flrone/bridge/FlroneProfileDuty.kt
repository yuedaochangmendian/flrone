package io.flrone.bridge

import io.flrone.flutter.ServiceEngineManager
import io.nekohasekai.sagernet.group.GroupRevisions
import io.nekohasekai.sagernet.group.SubscriptionScheduler

/**
 * The profile editor's platform duties, behind ONE channel arm.
 *
 * ADR 0005 final stage: profiles and groups are Dart-owned data. Every mutation
 * goes through `profiles.applyDocument` into Dart's `ProfileStore`, and Dart's
 * document is what Kotlin (`DartProfileStore`) and Go (`profiles_doc.go`) read
 * to build the core config and the outbound picker. There is no Room writer for
 * either table.
 *
 * What still needs the host is not data ownership but the Go profile codec and
 * the Android platform:
 *
 *  * **the node editor's codec** — `FlroneProfileActions` calls the Go
 *    `profileImport`/`profileNormalize`/`profileValidate`/`profileExport`
 *    actions; there is no Kotlin outbound model any more;
 *  * **the subscription queue** — the Dart owner queues the fetch; the host
 *    keeps the `subscription.fetch` seam and the foreground hold;
 *  * **selection side effects** — `DataStore.selectedProxy`/`currentProfile`
 *    are settings (Kotlin-owned) and a running service must hot-switch;
 *  * **group deletion** — stops the service and drops the routing profile the
 *    subscription provided;
 *  * **the auto-selector runtime** — it runs inside the kernel;
 *  * **narrow document side effects** — a document write cannot perform them
 *    itself: the GroupSort reposition after a test-result clear
 *    (`sort.reposition`), the newest-intent bump before a configuration save
 *    (`revision.edit`) and the subscription poller re-plan after a URL edit
 *    (`subscription.schedule`).
 *
 * The document-only ops that used to live here — `stats`, `reorder`,
 * `clearTestResults`, `nodeList`, `nodeReorder`, and the configuration
 * editor's `config`/`read`/`write` — are Dart-owned now
 * (`ProfileDocumentService`, `flutter/lib/data/profile_document_service.dart`).
 * S7 moved the auto-selector editor's document ops there as well
 * (`autoSelectorInfo`/`Save`/`Pin`/`Create`); only the runtime shadow
 * (`autoSelectorStatus`, `autoSelectorRuntimePin`, `autoSelectorRecheck`) stays
 * on this boundary. They never needed the Throne model for the read/write
 * itself, only the same `profiles.json` document Dart owns. What remains as
 * narrow duties are the side effects a document write cannot perform itself:
 * the GroupSort reposition after a test-result clear (`sort.reposition`), the
 * newest-intent bump before a configuration save (`revision.edit`,
 * `GroupRevisions.edit`) and the subscription poller re-plan after a URL edit
 * (`subscription.schedule`).
 *
 * `FlronePlatformBridge` used to carry 28 named `profiles.*` arms for these. They
 * are one `profiles.platform` call now, with `{op, payload}` and exactly the
 * payload keys the old arms read. `tools/diagnostics/platform_duty_audit.py`
 * holds this table to the Dart call sites, so an op cannot drift or go dead; it
 * also holds the eight Dart-owned ops out of this table explicitly.
 */
object FlroneProfileDuty {

    private typealias Handler = suspend (Map<String, Any?>) -> Any?

    private val handlers: LinkedHashMap<String, Handler> = linkedMapOf(
        // --- group card and selection -------------------------------------
        // Selection is Dart-owned (ADR 0008 S4): Dart resolves the member/group
        // from the profiles document, writes profile_selection.json, and asks the
        // host to mirror the settled choice into settings for widgets/service.
        "selection.mirror" to { payload ->
            FlroneCommands.mirrorSelection(
                payload.requireLong("profileId"),
                payload.requireLong("groupId"),
            )
        },
        "delete" to { payload ->
            FlroneCommands.deleteProfile(payload.requireLong("id"))
            null
        },
        "update" to { payload ->
            FlroneCommands.updateSubscription(payload.requireLong("id"))
            null
        },
        // The narrow GroupSort remainder of the old clearTestResults: Dart
        // cleared the document, Kotlin repositions rows in a group kept sorted
        // by test result. Payload `id` is the group id.
        "sort.reposition" to { payload ->
            FlroneProfiles.repositionTestResults(payload.requireLong("id"))
            null
        },
        // The narrow remainders of the old configuration `write` (the document
        // edit is Dart's now). `revision.edit` is the user-save intent bump
        // (`GroupRevisions.edit`) and must run BEFORE Dart's document write: a
        // subscription answer already downloading for the group is stale from
        // that moment on. `subscription.schedule` (`SubscriptionScheduler`)
        // re-plans the poller after a URL edit, so a new subscription is picked
        // up without a restart.
        "revision.edit" to { payload ->
            GroupRevisions.edit(payload.requireLong("id"))
            null
        },
        "subscription.schedule" to { _ ->
            SubscriptionScheduler.schedule()
            null
        },
        // --- group editor -------------------------------------------------
        "save" to { payload -> FlroneProfiles.save(payload) },
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
        "nodeTuningInfo" to { payload -> FlroneNodeTuning.info(payload.requireLong("id")) },
        "nodeTuningSave" to { payload ->
            FlroneNodeTuning.save(payload.requireLong("id"), payload.valueMap("value"))
        },

        // --- auto selector ---------------------------------------------------
        // The editor's document ops (info/save/pin/create) are Dart-owned now
        // (S7, ProfileDocumentService): the selector row is the same
        // `profiles.json` Dart writes. Only the runtime shadow stays here —
        // the live status, the pin notice and a recheck request.
        "autoSelectorStatus" to { _ -> FlroneProfiles.autoSelectorStatus() },
        "autoSelectorRuntimePin" to { payload ->
            FlroneProfiles.autoSelectorRuntimePin(payload.requireLong("memberId"))
            null
        },
        "autoSelectorRecheck" to { _ ->
            FlroneProfiles.autoSelectorRecheck()
            null
        },
    )

    /** The ops this boundary answers; the duty audit compares it with Dart. */
    val names: Set<String> get() = handlers.keys

    /**
     * Ops whose Kotlin body persists rows through `DartProfileWriter`. S6 made
     * the service engine the only document owner; make sure it exists before
     * the body runs so a write cannot fall into the bridge-mode no-op.
     */
    private val documentWriteOps: Set<String> = setOf(
        "save", "update", "delete",
        "nodeCreate", "nodeUpdate", "nodeDelete", "nodeTuningSave",
    )

    /**
     * Runs [op] against [payload]. An unknown op fails loudly: a typo on the
     * Dart side must not look like "nothing to do".
     */
    suspend fun invoke(op: String, payload: Map<String, Any?>): Any? {
        val handler = handlers[op] ?: error("unknown profile platform duty: $op")
        if (op in documentWriteOps && !ServiceEngineManager.ensureDocumentOwner()) {
            error("profiles document owner is unavailable: $op")
        }
        return handler(payload)
    }
}

// Payload readers. The Dart side sends JSON maps, so a number arrives as
// Int/Long/Double depending on the platform channel codec.

private fun Map<String, Any?>.requireLong(key: String): Long =
    (this[key] as? Number)?.toLong() ?: error("Missing $key")

private fun Map<String, Any?>.string(key: String): String =
    this[key] as? String ?: ""

/**
 * The old arms read `value` with a fallback to the whole argument map, because
 * the Dart facade sent the value at the top level for the "form save" calls.
 * Keep that tolerance: [payload] itself is the value document in that case.
 */
private fun Map<String, Any?>.valueMap(key: String): Map<String, Any?> {
    val value = this[key] as? Map<*, *> ?: return this
    return value.entries.associate { it.key.toString() to it.value }
}
