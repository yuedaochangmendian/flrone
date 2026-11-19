package io.flrone.bridge

import io.nekohasekai.sagernet.bg.proto.SpeedTestSnapshot
import io.nekohasekai.sagernet.bg.test.TestSpec
import io.nekohasekai.sagernet.database.GroupSort
import io.nekohasekai.sagernet.database.GroupSortAction
import io.nekohasekai.sagernet.database.GroupSortMethod
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.TestBy
import io.nekohasekai.sagernet.ui.test.TestSessionClient
import io.nekohasekai.sagernet.ui.test.TestUiState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * The test session's single host implementation (ADR 0004 P4a).
 *
 * Two entry points reach this object:
 *  - the JSON action bus: Go relays `speedTestSession*` through
 *    [BboxCorePlatform.platformRequest] -> [platformRequest] below;
 *  - the UI feed demand: [ThroneBoxBridge] registers its EventChannel polling
 *    hook with [registerVisibilitySink], so the bus's `visible` control and the
 *    subscription path share one implementation (no second copy of the logic).
 *
 * The state model is [TestSessionClient]; this object only shapes its wire form
 * and routes the six controls. Nothing here holds session state of its own.
 */
object BboxTestSessions {

    // The `testSession` push itself stays on the UI EventChannel: ThroneBoxBridge owns
    // the sink and the 400 ms poll. The bus controls *demand* for that feed; the sink
    // registration keeps the emitter in the bridge without duplicating control logic.
    @Volatile
    private var visibilitySink: ((Boolean) -> Unit)? = null

    fun registerVisibilitySink(sink: (Boolean) -> Unit) {
        visibilitySink = sink
    }

    fun unregisterVisibilitySink(sink: (Boolean) -> Unit) {
        if (visibilitySink === sink) visibilitySink = null
    }

    fun setVisible(visible: Boolean) {
        visibilitySink?.invoke(visible)
    }

    /** Starts testing every member of the group; false when another session is still running. */
    suspend fun startGroup(kind: Int, groupId: Long, speedMode: Int = -1): Boolean = withContext(Dispatchers.IO) {
        TestSessionClient.startGroup(kind, groupId, speedMode)
    }

    /** Tests a selection (or the running connection with [testCurrent]); false when one is running. */
    suspend fun startProfiles(kind: Int, profileIds: List<Long>, testCurrent: Boolean, speedMode: Int = -1): Boolean =
        withContext(Dispatchers.IO) {
            if (testCurrent) TestSessionClient.startCurrent(kind, speedMode)
            else TestSessionClient.startProfiles(kind, profileIds, speedMode = speedMode)
        }

    fun stop() = TestSessionClient.stop()

    /** Hides a finished session. */
    fun dismiss() = TestSessionClient.dismiss()

    /**
     * The panel's sort action (TestPanelController.sort): a speed session re-sorts by its metric and
     * records the metric so the next stored result keeps the order; a latency session sorts by latency.
     */
    suspend fun sort(groupId: Long): Boolean = withContext(Dispatchers.IO) {
        val state = TestSessionClient.state.value
        if (groupId <= 0) return@withContext false
        val bySpeed = state.kind == TestSpec.KIND_SPEED && !state.countryMode
        if (bySpeed) {
            val upload = state.speedMode == TestUiState.SPEED_MODE_UPLOAD
            // Kept like the latency sort, so the next stored result re-sorts instead of undoing the order.
            io.nekohasekai.sagernet.database.GroupFields.update(groupId) {
                it.testSortBy = (if (upload) TestBy.UL_SPEED else TestBy.DL_SPEED).value
            }
            GroupSort.sortProfiles(groupId, GroupSortAction(GroupSortMethod.BY_TEST_RESULT, descending = true))
        } else {
            GroupSort.sortProfiles(groupId, GroupSortAction(GroupSortMethod.BY_LATENCY))
        }
    }

    /**
     * The panel's "Remove unavailable" (TestPanelController.removeUnavailable): deletes the failed
     * profiles that still exist and records the rest as gone; answers how many were deleted.
     */
    suspend fun remove(ids: List<Long>): Int = withContext(Dispatchers.IO) {
        if (ids.isEmpty()) return@withContext 0
        val position = ids.withIndex().associate { it.value to it.index }
        val existing = ProfileManager.getProfiles(ids).sortedBy { position[it.id] }
        val existingIds = existing.map { it.id }
        val existingSet = existingIds.toHashSet()
        TestSessionClient.markRemoved(ids.filter { it !in existingSet })
        if (existing.isEmpty()) return@withContext 0
        // The running profile is never stopped by the panel's removal (stopRunning = false).
        val outcome = ProfileManager.batchDeleteProfiles(existingIds, stopRunning = false)
        TestSessionClient.markRemoved(outcome.deleted)
        outcome.deleted.size
    }

    // --- the platform_request bridge -----------------------------------------

    /**
     * Go's relay for the six `speedTestSession*` actions. Returns a JSON value that
     * Go decodes verbatim into the ActionResult, or a plain error string (which Go
     * turns into a non-zero code / ActionException on the Dart side).
     *
     * `platformRequest` is a synchronous JNI callback, so the suspend controls
     * are driven through [runBlocking] on the callback thread; each one already
     * switches to [Dispatchers.IO] internally for its real work.
     */
    fun platformRequest(method: String, payloadJson: String): String = try {
        val payload = runCatching { JSONObject(payloadJson) }.getOrDefault(JSONObject())
        when (method) {
            "test_session_start" -> {
                val args = TestSessionArgs.parse(payload)
                val started = runBlocking {
                    if (args.groupId > 0) startGroup(args.kind, args.groupId, args.speedMode)
                    else startProfiles(args.kind, args.ids, args.testCurrent, args.speedMode)
                }
                started.toString()
            }
            "test_session_stop" -> {
                stop()
                "true"
            }
            "test_session_dismiss" -> {
                dismiss()
                "true"
            }
            "test_session_sort" -> {
                runBlocking { sort(payload.optLong("groupId", 0L)) }.toString()
            }
            "test_session_remove" -> {
                val ids = TestSessionArgs.longArray(payload, "ids")
                val removed = runBlocking { remove(ids) }
                JSONObject().put("removed", removed).toString()
            }
            "test_session_visible" -> {
                setVisible(payload.optBoolean("visible", false))
                "true"
            }
            else -> "unknown test session method: $method"
        }
    } catch (e: Throwable) {
        (e.message ?: e.javaClass.simpleName)
    }

    /** The state the Dart panel renders; [state.kind] < 0 means no session (idle or dismissed). */
    fun wire(): Map<String, Any?> = wire(TestSessionClient.state.value)

    private fun wire(s: TestUiState): Map<String, Any?> = mapOf(
        "kind" to s.kind,
        "scopeLabel" to s.scopeLabel,
        "running" to s.running,
        "cancelled" to s.cancelled,
        "total" to s.total,
        "done" to s.done,
        "ok" to s.ok,
        "failed" to s.failed,
        "aborted" to s.aborted,
        "pending" to s.pending,
        "testing" to s.testing,
        "preparing" to s.preparing,
        "stopping" to s.stopping,
        "failure" to s.failure.name,
        "groupId" to s.groupId,
        "testCurrent" to s.testCurrent,
        "speedMode" to s.speedMode,
        "countryMode" to s.countryMode,
        "startedAt" to s.startedAt,
        "finishedAt" to s.finishedAt,
        "rows" to s.rows.map { (id, row) ->
            mapOf(
                "id" to id,
                "phase" to row.phase.name,
                "latency" to row.latency,
                "error" to row.error,
                "dlSpeed" to row.dlSpeed,
                "ulSpeed" to row.ulSpeed,
                "country" to row.country,
                "ip" to row.ip,
                "ok" to row.ok,
                "failed" to row.failed,
                "aborted" to row.aborted,
            )
        },
        "histogram" to mapOf(
            "edges" to io.nekohasekai.sagernet.ui.test.LatencyHistogram.EDGES.toList(),
            "bins" to s.histogram.bins,
            "failed" to s.histogram.failed,
            "connectOnly" to s.histogram.connectOnly,
        ),
        "ranking" to s.ranking.map { ranked ->
            mapOf(
                "profileId" to ranked.profileId,
                "name" to ranked.name,
                "latency" to ranked.latency,
                "dlSpeed" to ranked.dlSpeed,
                "ulSpeed" to ranked.ulSpeed,
                "country" to ranked.country,
            )
        },
        "rankable" to s.rankable,
        "countries" to s.countries.map { listOf(it.code, it.count) },
        "distinctIps" to s.distinctIps,
        "speed" to s.speed?.let { live ->
            mapOf(
                "profileId" to live.profileId,
                "name" to live.name,
                "stage" to live.stage,
                "dlBps" to live.dlBps,
                "ulBps" to live.ulBps,
                "dlBytes" to live.dlBytes,
                "ulBytes" to live.ulBytes,
                "pingMs" to live.pingMs,
                "server" to live.server,
                "serverCountry" to live.serverCountry,
                "finished" to live.finished,
                // SpeedLive has neither field: the verdict lives on the row the result
                // was reported against (TestSessionModel.onSpeedResult copies the
                // engine's error code there) and in the stage (STAGE_ERROR /
                // STAGE_CANCELLED). Without them a failed or stopped run reached the
                // UI as a finished one with zeros, and the panel recorded it.
                "error" to s.rows[live.profileId]?.error.orEmpty(),
                "cancelled" to (live.stage == SpeedTestSnapshot.STAGE_CANCELLED),
                "samples" to live.samples.map { listOf(it.t, it.bps, it.upload) },
            )
        },
        "testingProgress" to s.testingProgress?.let { progress ->
            mapOf(
                "from" to progress.from,
                "to" to progress.to,
                "since" to progress.since,
                "durationMs" to progress.durationMs,
            )
        },
        "removed" to s.removed.toList(),
    )
}
