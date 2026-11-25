package io.flrone.flutter

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flrone.core.CoreHost
import io.nekohasekai.sagernet.BuildConfig
import io.nekohasekai.sagernet.SagerNet
import android.os.Build
import android.os.Debug
import io.nekohasekai.sagernet.Key
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.RouteJsonStore
import io.nekohasekai.sagernet.utils.CrashStore
import io.nekohasekai.sagernet.database.DnsServerHistory
import io.nekohasekai.sagernet.database.GroupRepo
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.RouteRepo
import io.nekohasekai.sagernet.database.SettingsRegistry
import io.nekohasekai.sagernet.group.SubscriptionClient
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.ktx.readableMessage
import io.nekohasekai.sagernet.ktx.streamUri
import io.nekohasekai.sagernet.ktx.triggerFullRestart
import io.nekohasekai.sagernet.ui.json.engine.JsonTree
import io.nekohasekai.sagernet.ui.json.engine.JsonType
import io.nekohasekai.sagernet.update.UpdateChecker
import moe.matsuri.nb4a.utils.LogRedactor
import io.flrone.bridge.FlroneApi
import io.flrone.bridge.publishedConnectionCount
import io.flrone.bridge.BootGate
import io.flrone.bridge.BulkWire
import io.flrone.bridge.ChinaApps
import io.flrone.bridge.ConnectionsSampler
import io.flrone.bridge.TrafficAggregator
import io.flrone.bridge.FlroneApps
import io.flrone.bridge.FlroneBackup
import io.flrone.bridge.FlroneBridge
import io.flrone.bridge.FlroneCommands
import io.flrone.bridge.LegacyDocumentSeed
import io.flrone.bridge.LegacyRoomReader
import io.flrone.bridge.UiDocuments
import io.flrone.bridge.FlroneEgress
import io.flrone.bridge.FlroneGroupsWire
import io.flrone.bridge.FlroneKernel
import io.flrone.bridge.FlroneLogcat
import io.flrone.bridge.FlroneLogs
import io.flrone.bridge.FlroneMemory
import io.flrone.bridge.FlroneMode
import io.flrone.bridge.FlroneProbeSession
import io.flrone.bridge.FlroneProfileWire
import io.flrone.bridge.FlroneProfileDuty
import io.flrone.bridge.FlroneProfiles
import io.flrone.bridge.FlroneRoomSnapshot
import io.flrone.bridge.FlroneTestSessions
import io.flrone.bridge.DartProfileStore
import io.flrone.bridge.DartProfileWriter
import io.flrone.bridge.Capabilities
import io.flrone.bridge.Apply
import io.flrone.bridge.EventPump
import io.flrone.bridge.NOTIFICATION_LIVE_KEYS
import io.flrone.bridge.UI_ONLY_KEYS
// Aliased: this file also uses android.provider.Settings for the battery-optimisation intents.
import io.flrone.bridge.Settings as ThroneSettings
import io.flrone.model.FlroneUiState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import okhttp3.OkHttpClient
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.net.NetworkInterface
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * The two halves of the dashboard push key (D2).
 *
 * [state] is everything a screen cannot reconstruct from a later traffic sample — the running
 * status, the profile, the mode, memory and the catalog revision. [traffic] is the byte counters
 * and the rates, which the next sample replaces anyway.
 *
 * Pure JVM (no Android, no box): the split is pinned by a unit test without an emulator.
 */
internal data class UiWireKey(val state: String, val traffic: String)

/**
 * Whether a wire-key change is worth a push.
 *
 * A visible UI wants every change: the chart and the totals both move, so any difference in
 * the key is allowed through (an identical key still ends as a no-op in [FlronePlatformBridge.pushState]'s
 * own baselines). A hidden UI has no frame to draw, so a traffic-only move is skipped — the
 * counters change every second, and building, encoding, pumping and decoding a dashboard and
 * a rates map nothing renders was pure cost. A state change still goes through: it is what
 * makes the first frame after resume correct, and it is rare enough that it never became the
 * noise the traffic half did.
 *
 * The caller records the key even when this answers false, so the comparison is always against
 * the newest values. The resume arm of `ui.visible` then pushes one fresh sample, and that push
 * carries whatever the traffic moved while hidden (its dashboard baseline was not advanced here).
 */
internal fun shouldPushUiWire(previous: UiWireKey?, next: UiWireKey, visible: Boolean): Boolean =
    previous == null || previous.state != next.state || (visible && previous.traffic != next.traffic)

/**
 * The host side of B-box's own interface.
 *
 * B-box's Flutter screens talk to Android through exactly two channels — `io.flrone/box` for calls and
 * `io.flrone/events` for pushes — and know nothing about the app behind them. This class implements that
 * contract over Throne: the state comes from [FlroneBridge], the writes go through [FlroneCommands], and the payloads
 * are shaped the way the Dart side reads them (`box.dart`, `dashboard.dart`, `proxies.dart`, `profiles.dart`).
 *
 * Methods are grouped by whether the answer can be produced synchronously: anything that has to touch the database,
 * the package manager, the network or a system dialog goes through [respond], which moves it off the channel thread
 * and turns a thrown exception into the platform error the UI shows.
 *
 * A handful of screens ask for things Throne has no equivalent of — a terminal, SSH sessions, Tailscale, Taildrop,
 * USB devices and HTTP request capture. Those answer with an error, which the UI reports as a snackbar rather than
 * rendering something invented.
 */
class FlronePlatformBridge(
    private val activity: FragmentActivity,
    private val messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler, Closeable {

    private val channel = MethodChannel(messenger, "io.flrone/box")
    private val events = EventChannel(messenger, "io.flrone/events")

    private val scope = activity.lifecycleScope

    /**
     * Single-threaded worker for building log payloads. FlroneLogs/Logcat can emit up to 1500
     * entries per batch; mapping those to wire maps on Main stalled frames. One worker keeps
     * the (reset/firstId-ordered) sequence of emitted batches intact while running off Main.
     */
    private val logWireDispatcher = Dispatchers.Default.limitedParallelism(1)
    private var sink: EventChannel.EventSink? = null
    private var stateJob: Job? = null

    /**
     * The one outbound queue: every push below is enqueued there, batched, and delivered on
     * the main thread. Bulk payloads are encoded on the producing thread (see [emitBulk]).
     */
    private val eventPump = EventPump(
        scheduler = object : EventPump.Scheduler {
            private val handler = Handler(Looper.getMainLooper())

            override fun post(delayMillis: Long, task: Runnable): () -> Unit {
                handler.postDelayed(task, delayMillis)
                return { handler.removeCallbacks(task) }
            }
        },
        deliver = { event -> sink?.success(event) },
    )

    /** Bettbox's `tick1s`: one traffic sample per second, independent of whether a number changed. */
    private var ratesTick: Job? = null

    /** B-box keeps its interface preferences in a store of its own; so does the port. */
    private val preferences = activity.getSharedPreferences("bbox_ui", Context.MODE_PRIVATE)

    // Written by `ready` (on IO, see respondIo) and read by pushState on main, hence @Volatile.
    @Volatile private var lastDashboard: Map<String, Any?>? = null
    @Volatile private var lastRates: Map<String, Any?>? = null
    @Volatile private var lastProfiles: List<Map<String, Any?>>? = null
    @Volatile private var lastGroups: List<Map<String, Any?>>? = null

    /** True once `ready` has answered, so pushState does not repeat that snapshot as an event. */
    @Volatile
    private var readyServed = false

    /** The catalog revision and node-delivery flag the last pushed rows were built from. */
    @Volatile
    private var sentCatalog: Pair<Long, Boolean>? = null

    /** Only the Proxies screen needs node rows; every other screen renders counts. */
    @Volatile
    private var groupsVisible = false

    /**
     * Whether the UI can be seen, from the Dart lifecycle observer (`ui.visible`). A hidden app
     * draws no frame, so the 1 s rates tick skips its sample rather than building and shipping a
     * dashboard snapshot nothing renders; the state collector below also skips a traffic-only
     * change (see [shouldPushUiWire]). The first tick after resume pushes a fresh point, and the
     * resume arm pushes one immediately so the totals that moved while hidden are not stale.
     */
    @Volatile
    private var uiVisible = true

    /** The connections screen, the memory panel and the log screen each hold one subscription while they are open. */
    private var connectionsJob: Job? = null
    private var memoryJob: Job? = null

    /** Why the last connections poll failed, surfaced by `connections.state`. */
    @Volatile private var connectionsError: String? = null

    /**
     * The live connection count published in the dashboard wire (S6).
     *
     * The connections card used to read a hardcoded 0 unless the user had opened the full
     * connections page in this session (that page's feed is what populated the sampled list).
     * [connectionCountJob] polls only the length of the core's own list, never mapping it into
     * rows, so the card has a real source without starting the ConnectionsSampler feed.
     */
    @Volatile private var connectionCount = 0
    private var connectionCountJob: Job? = null

    /** Twice the core's 1 s dashboard cadence: a count line is a headline, not a rate. */
    private val connectionCountIntervalMs = 2_000L

    /** Attribution poller behind the traffic ledger; lives until `trafficStats.watch` disables it. */
    private var trafficAggregator: TrafficAggregator? = null

    /** Detaches the trim listener `attach` installs; null while the bridge is closed. */
    private var stopTrimObserver: (() -> Unit)? = null

    /** The update queue's change reports, for as long as the host lives. */
    private var reportsJob: Job? = null

    /** The update queue's state transitions (queued/running/idle), for as long as the host lives. */
    private var subscriptionStateJob: Job? = null

    /** The batch test panel's state feed, polled only while the panel shows it. */
    private var testSessionJob: Job? = null

    /**
     * One stable instance: `FlroneTestSessions` compares the hook by identity when the
     * bridge closes, and `::setTestSessionVisible` creates a new object every time.
     */
    private val testSessionVisibilitySink: (Boolean) -> Unit = ::setTestSessionVisible

    @Volatile
    private var lastTestSession: Map<String, Any?>? = null

    /** Probe sessions: one HTTP client per id, tunneled through the running service. */
    private val probes = ConcurrentHashMap<String, FlroneProbeSession>()

    /** The URI the app was opened with, handed to the UI once. */
    private var pendingIntent: String? = null

    /** The intent instance whose payload was already offered to the UI; a repeat take must not re-deliver it. */
    private var deliveredIntent: Intent? = null

    /** Set when an intent arrived while no event sink was attached; raised again in [onListen]. */
    private var intentAvailablePending = false

    @Volatile
    private var lanBusy = false

    /** Set when a write only takes effect on a process restart, cleared once the UI was told. */
    @Volatile
    private var restartPending = false

    fun attach() {
        channel.setMethodCallHandler(this)
        events.setStreamHandler(this)
        DartProfileWriter.attach(messenger)
        // The bus's `visible` control and the channel subscription arm both funnel through
        // FlroneTestSessions.setVisible; this bridge owns the EventChannel sink and the poll,
        // so it registers that one hook here (and drops it on close).
        FlroneTestSessions.registerVisibilitySink(testSessionVisibilitySink)
        // Memory pressure reaches the UI as an event: ART's own gc/trimHeap cannot collect Dart
        // objects, so the decoded-image cache and the UI's own lists only shrink if Dart is told.
        stopTrimObserver = FlroneMemory.observeTrim { level -> emit("memoryTrim", mapOf("level" to level)) }
        // Subscription change reports (SubscriptionReportDialog.observe): popups, errors, status
        // lines and reload hints of the update queue, forwarded while the host is alive. A report
        // that arrives before the UI listens is dropped, as the native window drops them while closed.
        reportsJob = scope.launch {
            SubscriptionClient.reports.collect { report -> emitReport(report) }
        }
        // Queue state transitions drive the profile refresh spinner. Kept on a separate
        // collector from reports: a successful refresh produces no report, but still
        // goes queued -> running -> idle and must hold the spinner for that whole span.
        subscriptionStateJob = scope.launch {
            SubscriptionClient.stateEvents.collect { event ->
                // State lane: a dropped "idle" leaves the profile refresh spinner turning
                // forever, because no later event repeats the transition.
                emit("subscriptionState", mapOf("gid" to event.gid, "state" to event.state), EventPump.Lane.STATE)
            }
        }
    }

    override fun close() {
        FlroneTestSessions.unregisterVisibilitySink(testSessionVisibilitySink)
        stopTrimObserver?.invoke()
        stopTrimObserver = null
        stateJob?.cancel()
        ratesTick?.cancel()
        connectionsJob?.cancel()
        connectionCountJob?.cancel()
        connectionCountJob = null
        memoryJob?.cancel()
        reportsJob?.cancel()
        subscriptionStateJob?.cancel()
        testSessionJob?.cancel()
        testSessionJob = null
        probes.keys.forEach { closeProbe(it) }
        probes.clear()
        FlroneLogs.stop()
        FlroneLogcat.stop()
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        DartProfileWriter.detach()
        // Deliberate flush before the sink goes away: this is a dispose path, so an event
        // produced a frame ago is worth delivering; afterwards the pump discards.
        eventPump.flushNow()
        eventPump.detach()
        sink = null
        // The service bridge owns the host-stop callback; closing the UI must not
        // clear it (the kernel is owned by the service engine, not by this Activity).
    }

    // ------------------------------------------------------------------------------------------------ events

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        sink = eventSink
        eventPump.attach()
        if (intentAvailablePending) {
            intentAvailablePending = false
            // Ready-adjacent and lost if dropped: the pending intent would wait for the next
            // one, because nothing re-raises the ping after this subscribe.
            emit("intentAvailable", true, EventPump.Lane.STATE)
        }
        stateJob?.cancel()
        stateJob = scope.launch {
            var sent: UiWireKey? = null
            FlroneBridge.state
                .map { it.wireKey() }
                .distinctUntilChanged()
                .collect { key ->
                    val previous = sent
                    sent = key
                    // A hidden UI skips a change that only moved traffic: the next visible
                    // sample (the rates tick, or the resume arm of `ui.visible`) repeats it,
                    // so the push would buy nothing but an encoded frame nobody draws.
                    if (!shouldPushUiWire(previous, key, uiVisible)) return@collect
                    pushState()
                }
        }
        // The dashboard sparkline is a window in time, not a list of changes: Bettbox appends one
        // sample per second (`tick1s`), so an idle tunnel scrolls to zero instead of freezing on
        // its last peak. A sample is pushed every second while the service runs, and not at all
        // while it is stopped — the window belongs to the session that produced it.
        //
        // In ffiMode this side owns no TrafficUpdater, so the meter stays at zero and a sample
        // would only push those zeros: the FFI driver's status feed is the sparkline's source
        // then, and the two would alternate on screen once a second.
        //
        // `uiVisible` is the FlClash rule for the same ticker: a backgrounded app has no frame
        // to draw, so it stops sampling until the lifecycle observer reports it visible again.
        // The loop itself keeps running — a first tick after resume lands within the second.
        ratesTick?.cancel()
        ratesTick = scope.launch {
            while (isActive) {
                delay(1_000)
                if (!FlroneKernel.ffiMode && uiVisible && DataStore.serviceState.connected) pushState(sampleRate = true)
            }
        }
        startConnectionCountLoop()
    }

    /**
     * Polls the core's connection count for the dashboard card (S6).
     *
     * Only while the UI is visible and the service is connected, on the same visibility rule
     * as the rates tick: a backgrounded app draws no frame, and a stopped service has no
     * connections. The list is asked for its length only — the full row mapping and the
     * ConnectionsSampler feed belong to the connections page, which still starts on demand.
     * A changed count pushes a dashboard frame; an unchanged one costs one HTTP call per tick.
     */
    private fun startConnectionCountLoop() {
        connectionCountJob?.cancel()
        connectionCountJob = scope.launch {
            while (isActive) {
                delay(connectionCountIntervalMs)
                // FFI mode has no service-side box: the driver owns this field, and asking the
                // (absent) core would only log a failure every tick.
                if (!uiVisible || !DataStore.serviceState.connected || FlroneKernel.ffiMode) {
                    // A stop ends the session's connections; clear the count so a later start
                    // cannot inherit the previous session's last number.
                    if (!DataStore.serviceState.connected) connectionCount = 0
                    continue
                }
                val count = withContext(Dispatchers.IO) {
                    runCatching { FlroneApi.connections().size }.getOrNull()
                } ?: continue
                if (count != connectionCount) {
                    connectionCount = count
                    pushState()
                }
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        // Discard rather than flush: the Dart side just unsubscribed, so a queued event has no
        // reader left — and the pump's timer must not call into a sink about to become null.
        eventPump.detach()
        stateJob?.cancel()
        stateJob = null
        ratesTick?.cancel()
        ratesTick = null
        connectionCountJob?.cancel()
        connectionCountJob = null
        sink = null
    }

    /**
     * Queues one event for the UI.
     *
     * The lane is the delivery guarantee, not a priority hint: [EventPump.Lane.STATE] is for
     * the snapshots whose loss leaves a screen permanently wrong (a settings/preferences
     * document, the subscription queue's transitions, a waiting intent) and is never evicted
     * while any room is left; the default priority lane carries everything that a later push
     * would repeat (dashboard, rates, profiles, the counts-only groups snapshot, notices,
     * probes); the bulk feeds go through [emitBulk].
     */
    private fun emit(type: String, value: Any?, lane: EventPump.Lane = EventPump.Lane.PRIORITY) {
        eventPump.enqueue(type, value, lane)
    }

    /**
     * [emit] for a feed whose size follows the payload (log tails, the connection list, the
     * Proxies node rows).
     *
     * The value is encoded inside the pump's [EventPump.enqueue], on the producing thread and
     * only while a listener is attached, so an unwatched feed costs one counter increment and
     * the platform thread only copies bytes. The UI decodes it where it can afford to — inline
     * for a small batch, on a background isolate above 50 KiB (see [BulkWire]).
     */
    private fun emitBulk(type: String, value: Any?) {
        // A null value encodes to nothing; an empty frame would only fail on the UI side with a
        // generic codec error, so refuse it here, where the cause is still known.
        if (value == null) {
            Logs.w("bulk event $type encoded to nothing; dropped")
            return
        }
        eventPump.enqueue(type, value, EventPump.Lane.BULK, encode = BulkWire::encode)
    }

    /**
     * Pushes whatever changed since the last push: the dashboard, the rates and the catalog are
     * separate events. [sampleRate] forces the rates through even when the numbers are identical,
     * because the sparkline needs one point per second rather than one per change.
     *
     * The catalog half is rebuilt only when `FlroneBridge.catalogRevision` moved — a repository change
     * or the Proxies screen toggling node delivery — because a rates sample used to rebuild every
     * node row and structurally compare it once a second for nothing.
     */
    private fun pushState(sampleRate: Boolean = false) {
        // `ready` answers with this same snapshot; emitting it here too made the first frame build
        // and decode the whole catalog a second time.
        if (!readyServed) return
        val state = FlroneBridge.state.value
        val dashboard = dashboardWire(state)
        if (dashboard != lastDashboard) {
            lastDashboard = dashboard
            emit("dashboard", dashboard)
        }
        val rates = mapOf(
            "upload" to state.dashboard.traffic.uploadRate,
            "download" to state.dashboard.traffic.downloadRate,
            "memoryBytes" to (state.dashboard.memory?.inUse ?: 0L),
        )
        if (sampleRate || rates != lastRates) {
            lastRates = rates
            emit("rates", rates)
        }
        val catalog = FlroneBridge.catalogRevision to groupsVisible
        if (catalog == sentCatalog) return
        sentCatalog = catalog
        val profiles = profilesWire(state)
        if (profiles != lastProfiles) {
            lastProfiles = profiles
            emit("profiles", profiles)
        }
        val groups = groupsWire(state, withItems = groupsVisible)
        if (groups != lastGroups) {
            lastGroups = groups
            // With the Proxies screen open this carries every node row — ~134 B/node, the
            // largest payload the UI bridge sends — so it goes through the bulk lane, where
            // the UI decodes it inline or on an isolate above 50 KiB instead of on its frame
            // path. A bulk frame can wait one drain behind a priority one, and the rows are a
            // snapshot the next `groups.visible` rebuilds, so nothing needs a spill: this is
            // the biggest UI payload and the isolate threshold already covers it.
            if (groupsVisible) emitBulk("groups", groups) else emit("groups", groups)
        }
    }

    /** The Proxies screen asks for node rows on open and gives them back on close. */
    private fun setGroupsVisible(visible: Boolean) {
        if (groupsVisible == visible) return
        groupsVisible = visible
        // The payload shape changes with the flag, so the previous copy is not a baseline for it.
        lastGroups = null
        pushState()
    }

    /**
     * The change key behind the state collector, split so a hidden UI can skip a
     * traffic-only move (see [shouldPushUiWire]). The state half holds the fields a screen
     * cannot reconstruct from a later sample; the traffic half holds the counters and rates
     * the next sample replaces.
     */
    private fun FlroneUiState.wireKey(): UiWireKey = UiWireKey(
        state = buildString {
            append(dashboard.status.running).append(dashboard.status.transitioning)
            append(dashboard.status.startedAt).append(dashboard.profile?.id)
            append(dashboard.memory?.inUse).append(dashboard.mode)
            // The catalog revision stands in for `groups.hashCode()` + `profiles.hashCode()`: those two
            // walked every node once a second to answer a question the revision already answers.
            append(FlroneBridge.catalogRevision)
        },
        traffic = buildString {
            append(dashboard.traffic.uploadTotal).append(dashboard.traffic.downloadTotal)
            append(dashboard.traffic.uploadRate).append(dashboard.traffic.downloadRate)
        },
    )

    // ------------------------------------------------------------------------------------------------ calls

    /**
     * A malformed call: a missing or unparsable argument, distinct from a failure while handling a
     * well-formed one. Answered with the `invalid_argument` platform code so the UI can tell
     * "this screen sent something wrong" apart from "the operation failed".
     */
    private class InvalidArgument(message: String) : Exception(message)

    private fun invalidArgument(message: String): Nothing = throw InvalidArgument(message)

    /**
     * An entity id from the call arguments.
     *
     * A missing id used to fall back to -1, which the repositories answered with an empty result
     * or a generic "No such …" — a malformed call then looked exactly like a deleted row.
     * Requiring the argument names the real fault instead.
     */
    private fun MethodCall.requireId(name: String = "id"): Long =
        (argument<Number>(name) ?: invalidArgument("Missing $name")).toLong()

    /**
     * Runs [block] on the scope's dispatcher (the main thread) and answers the call with whatever it
     * produces. A thrown exception becomes the platform error whose message the UI shows, so a
     * failure is never a silent empty screen. A block that does I/O must switch dispatchers itself.
     *
     * The [Throwable] arm is not belt-and-braces: `onMethodCall`'s own Throwable catch only covers
     * the synchronous dispatch, and `lifecycleScope` has no exception handler, so an `Error` thrown
     * from inside a launched block left the Result unanswered (Dart waits forever) and took the
     * process down. Same failure class as the historical `NoSuchMethodError` / ICU
     * `ExceptionInInitializerError` crashes.
     */
    private fun MethodChannel.Result.respond(block: suspend () -> Any?) {
        if (!scope.isActive) {
            error("cancelled", "Activity closed", null)
            return
        }
        scope.launch {
            try {
                val answer = block()
                // The reply payload is StandardMethodCodec-encoded inside
                // success(); ServiceBridge has answered from a background
                // dispatcher since day one (the codec and the messenger are
                // thread-safe), so the encode runs off the main thread — a
                // multi-MB `backup.open` envelope must not stall UI frames.
                withContext(Dispatchers.IO) { success(answer) }
            } catch (e: CancellationException) {
                error("cancelled", e.message ?: "Operation cancelled", null)
                throw e
            } catch (e: InvalidArgument) {
                Logs.w(e)
                error("invalid_argument", e.message ?: "Invalid argument", null)
            } catch (e: Exception) {
                Logs.w(e)
                error("failed", e.message ?: e.javaClass.simpleName, null)
            } catch (e: Throwable) {
                Logs.w(e)
                error("fatal", e.message ?: e.javaClass.simpleName, null)
            }
        }
    }

    /**
     * [respond] for the handlers whose work is disk-bound: the block runs on [Dispatchers.IO] and the
     * reply is encoded and sent there too (same thread-safe codec/messenger contract ServiceBridge
     * relies on). Use this for a block that opens a database or is the first to touch a preferences
     * file — `data.path`'s Room open can migrate on disk, and a cold `ready` loads the
     * settings/preferences documents. Keep [respond] for blocks that touch UI, services or
     * single-threaded host state; blocks that mix both should take [respond] and switch inside.
     */
    private fun MethodChannel.Result.respondIo(block: suspend () -> Any?) {
        if (!scope.isActive) {
            error("cancelled", "Activity closed", null)
            return
        }
        scope.launch {
            try {
                withContext(Dispatchers.IO) { success(block()) }
            } catch (e: CancellationException) {
                error("cancelled", e.message ?: "Operation cancelled", null)
                throw e
            } catch (e: InvalidArgument) {
                Logs.w(e)
                error("invalid_argument", e.message ?: "Invalid argument", null)
            } catch (e: Exception) {
                Logs.w(e)
                error("failed", e.message ?: e.javaClass.simpleName, null)
            } catch (e: Throwable) {
                // See respond(): an Error here would leave the call unanswered and crash.
                Logs.w(e)
                error("fatal", e.message ?: e.javaClass.simpleName, null)
            }
        }
    }

    /**
     * Starts the background service and, in VPN mode, waits until it exists before answering.
     *
     * `SagerNet.startService()` only posts a startForegroundService intent, so it returns before
     * the service object is created. Dart calls this immediately before the FFI kernel start, and
     * the core asks the platform for the tun as part of that start: with the wait removed, openTun
     * saw a null `DataStore.vpnService` and every start died with "configure tun interface:
     * bridge: platform callback failed". Answering the channel call only after the live VpnService
     * is registered makes the ordering deterministic instead of a race.
     */
    private suspend fun startServiceAndAwaitTun() {
        KernelServiceActions.startServiceAndAwaitTun()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                // The first payload reads three JSON documents and walks DataStore, so it is disk
                // work; the pushState baselines it sets are volatile.
                "ready" -> result.respondIo { serveReady() }
                "service.start" -> result.respond {
                    startServiceAndAwaitTun()
                    null
                }
                "service.stop" -> {
                    KernelServiceActions.stopService()
                    result.success(null)
                }
                "service.reload" -> {
                    KernelServiceActions.reloadService()
                    // S7: a reload rebuilds the route even when the selection looks identical.
                    FlroneBridge.routeMoved()
                    result.success(null)
                }
                // The dashboard's "Restart required" Apply: an AppRestart-level change (the log
                // buffer) only takes effect in a new process, so this is a rebirth — stop the
                // service, then relaunch — not a reload. The launch posts itself off-thread, so
                // answer before the process goes away.
                "app.restart" -> {
                    result.success(true)
                    triggerFullRestart(app)
                }
                "mode.set" -> {
                    val mode = call.argument<String>("mode") ?: invalidArgument("Missing mode")
                    FlroneCommands.setMode(mode)
                    // The mode moves the route by definition; the next wire would also see it, but
                    // a probe in flight across the tap must not answer under the old mode.
                    FlroneBridge.routeMoved()
                    result.success(null)
                }
                "groups.select" -> result.respond {
                    val group = call.argument<String>("group") ?: invalidArgument("Missing group")
                    val tag = call.argument<String>("tag") ?: invalidArgument("Missing tag")
                    val nodeId = call.argument<Int>("nodeId")?.toLong()
                    FlroneCommands.selectProxyAwait(group, tag, nodeId)
                    null
                }
                "groups.test" -> {
                    val tag = call.argument<String>("tag") ?: invalidArgument("Missing tag")
                    val profileIds = call.argument<List<Any>>("profileIds")
                        .orEmpty()
                        .mapNotNull { (it as? Number)?.toLong() }
                    result.respond { FlroneCommands.testNodeAwait(tag, profileIds) }
                }
                // ADR 0004 P4a: the five session controls (start/stop/dismiss/sort/remove)
                // now arrive over the JSON action bus -> platform_request -> FlroneTestSessions.
                // `visible` is NOT a session control: it is the UI feed's demand signal for
                // this bridge's EventChannel sink, so it stays on the channel. The bus's
                // `speedTestSessionVisible` also reaches the same shared setter through a
                // registered hook; this arm just keeps the BoxDataSubscription path live.
                "groups.testSession.visible" -> {
                    FlroneTestSessions.setVisible(call.argument<Boolean>("visible") == true)
                    result.success(null)
                }
                // ADR 0005 final stage: profiles/groups are Dart-owned data, written
                // through `profiles.applyDocument` into Dart's ProfileStore. The named
                // `profiles.*` arms this file used to carry are ONE duty boundary now:
                // what is left needs the Throne outbound model (parsing/validation),
                // the subscription queue, a Kotlin-owned selection setting, or the
                // auto-selector runtime. `FlroneProfileDuty` lists every op, and
                // tools/diagnostics/platform_duty_audit.py holds it to the Dart call
                // sites. `profiles.list`, `profiles.scan` and `profiles.scan.close`
                // were dead (no Dart caller; QR scanning uses `scan.qr` +
                // `profiles.platform/decodeIntent`).
                "profiles.platform" -> {
                    val op = call.argument<String>("op") ?: invalidArgument("Missing op")
                    @Suppress("UNCHECKED_CAST")
                    val payload = call.argument<Map<String, Any?>>("payload").orEmpty()
                    result.respond { FlroneProfileDuty.invoke(op, payload) }
                }
                // The group settings form: every ProxyGroup field the native editor exposes, with the
                // choices and defaults its menus resolve to. The save validates with the native
                // editor's own checks and reloads the service when a running route re-pointed.
                "groupSettings.get" -> result.respond {
                    FlroneProfiles.groupSettings(call.requireId())
                }
                "groupSettings.set" -> {
                    @Suppress("UNCHECKED_CAST")
                    val values = call.argument<Map<String, Any?>>("value") ?: call.arguments as? Map<String, Any?>
                    result.respond { FlroneProfiles.saveGroupSettings(values.orEmpty()) }
                }
                "files.open" -> {
                    val uri = call.argument<String>("uri").orEmpty()
                    result.respond { FlroneProfiles.decodeFile(uri) }
                }
                // SAF file picker (platform UI): the dialog is the platform's, and
                // the picked text is decoded by the same importer behind
                // `profiles.platform/decodeIntent`.
                "files.pickProfile" -> result.respond { importFile() }
                // Preferences are one JSON document under one key: every write re-serialises the
                // whole map and rewrites the file, so this is disk IO like ready.
                "preferences.set" -> {
                    @Suppress("UNCHECKED_CAST")
                    val values = call.argument<Map<String, Any?>>("value").orEmpty()
                    result.respondIo { writePreferences(values) }
                }
                // ADR 0005 phase 2: settings.get is gone. The merged full view (Dart overlay
                // winning over Kotlin rows) is delivered on `ready` and on every `settings`
                // event, and Dart re-merges it with its overlay on each read instead of caching
                // a whole map — the drift the ADR warns about. The write methods are retained
                // but narrowed to the authoritative keys Dart does not own: an overlay key must
                // never reach this channel (defensive — Dart splits it out first). Fail loudly
                // rather than write a Room row for a key in the preferences document.
                "settings.set" -> {
                    val key = call.argument<String>("key") ?: invalidArgument("Missing key")
                    if (key in UI_ONLY_KEYS) invalidArgument("UI-only setting must not cross the channel: $key")
                    val value = call.argument<Any>("value")
                    val restart = call.argument<Boolean>("restart") == true
                    // applySettings rewrites the settings document and settingsWire re-reads it: both
                    // are disk work. reloadService only posts a broadcast, so it is safe here too.
                    result.respondIo {
                        val answer = applyAndAnswerSettings(mapOf(key to value))
                        if (restart && DataStore.serviceState.canStop) {
                            SagerNet.reloadService()
                            FlroneBridge.routeMoved()
                        } else if (key in NOTIFICATION_LIVE_KEYS && DataStore.serviceState.canStop) {
                            // The General page promises these apply on the next notification
                            // update without a restart — push them to the live notification.
                            KernelServiceActions.applyNotificationSettings()
                        }
                        answer
                    }
                }
                "settings.patch" -> {
                    @Suppress("UNCHECKED_CAST")
                    val values = call.argument<Map<String, Any?>>("value").orEmpty()
                    val overlay = values.keys.filter { it in UI_ONLY_KEYS }
                    if (overlay.isNotEmpty()) {
                        invalidArgument("UI-only settings must not cross the channel: $overlay")
                    }
                    result.respondIo {
                        val answer = applyAndAnswerSettings(values)
                        if (values.keys.any { it in NOTIFICATION_LIVE_KEYS } && DataStore.serviceState.canStop) {
                            KernelServiceActions.applyNotificationSettings()
                        }
                        answer
                    }
                }
                "settings.reset" -> {
                    val keys = call.argument<List<Any>>("keys").orEmpty().filterIsInstance<String>()
                    result.respondIo {
                        val need = if (keys.isEmpty()) {
                            ThroneSettings.resetAll()
                        } else {
                            keys.mapNotNull { ThroneSettings.reset(it) }.maxByOrNull { it.ordinal }
                        } ?: Apply.None
                        // On demand only: a reset that changed nothing leaves the running core alone,
                        // a Reload rebuilds its config now, and AppRestart raises the badge only a
                        // process restart clears (log level, log buffer).
                        when {
                            need == Apply.AppRestart -> {
                                restartPending = true
                                emit("applyRequired", "Restart")
                            }
                            need == Apply.Reload && DataStore.serviceState.canStop -> {
                                SagerNet.reloadService()
                                FlroneBridge.routeMoved()
                            }
                        }
                        // reset() writes through ThroneSettings, not applySettings, so this arm
                        // still pushes the event itself — once, and answers with the same map.
                        // State lane: it is the one push of the reset, not a repeat of a poll.
                        val wire = settingsWire()
                        emit("settings", wire, EventPump.Lane.STATE)
                        wire
                    }
                }
                // The DNS server fields offer presets plus the servers typed before (DnsServerHistory::Fill).
                "dns.suggestions" -> result.respondIo {
                    mapOf(
                        "remote" to DnsServerHistory.remoteSuggestions(),
                        "direct" to DnsServerHistory.directSuggestions(),
                    )
                }
                // A kernel-side write to the Room profile/group tables cannot fire
                // GroupRepo's listeners, so the catalog Dart renders would stay stale.
                "data.refresh" -> {
                    // A Dart-side document write (the one-time migration, a backup
                    // restore's replaceAll) does not pass through
                    // DartProfileWriter.applyDocument, so it would miss that
                    // path's cache invalidation; drop the Kotlin snapshot here
                    // or the catalog can answer the pre-write rows.
                    DartProfileStore.invalidate()
                    FlroneBridge.scheduleRefresh(immediate = true)
                    result.success(null)
                }
                // The Proxies screen asks for the node rows on open and gives them back on close;
                // `ready` and every other screen only get the counts.
                "groups.visible" -> {
                    setGroupsVisible(call.argument<Boolean>("visible") == true)
                    result.success(null)
                }
                // The outbound picker in the rule editor needs names, not rows: id and tag only.
                "groups.nodes" -> result.respondIo {
                    mapOf("nodes" to nodesWire(FlroneBridge.state.value))
                }
                // What Wi-Fi rules need (location, background, services): the native walk-through
                // runs its dialogs and answers whether everything was granted. The caller saves the
                // rule either way — a refusal leaves the rules inactive, as in the native editor.
                "wifiPermissions.ensure" -> result.respond {
                    (activity as? FlroneActivity)?.ensureWifiPermissions() ?: false
                }
                // The scan screen asks for the camera before the host's scan activity opens:
                // a refusal comes back as false rather than an activity that closes with no reason.
                "permissions.camera" -> result.respond {
                    (activity as? FlroneActivity)?.ensureCameraPermission() ?: false
                }
                // The scan screen opens the host's ZXing activity; the decoded payload comes
                // back when the activity closes (null when it was dismissed).
                "scan.qr" -> result.respond {
                    (activity as? FlroneActivity)?.scanQrCode()
                }
                "url.open" -> {
                    val url = call.argument<String>("url").orEmpty()
                    FlroneCommands.openUrl(url)
                    result.success(null)
                }
                "intent.take" -> result.success(takeIntent())

                // --- live views, each owned by the screen that opened it
                // `pause` is the activity gate's park: the feed stops but the rows and the
                // closed ring stay, so a route covering the page or a background interval
                // does not blank a list the user is about to look at again.
                "connections.visible" -> {
                    setConnectionsFeed(
                        visible = call.argument<Boolean>("visible") == true,
                        pause = call.argument<Boolean>("pause") == true,
                    )
                    result.success(null)
                }
                // Why an empty list is empty: tunnel state, API switch, reachability, port.
                "connections.state" -> result.respondIo {
                    val state = FlroneApi.state().toMutableMap()
                    connectionsError?.let { state["pumpError"] = it }
                    state
                }
                // One-tap fix for a disabled Clash API: write the port, then the caller restarts
                // the core so the freshly generated config actually serves it.
                "connections.enableApi" -> result.respondIo {
                    val changed = FlroneApi.enableApi()
                    mapOf("changed" to changed, "state" to FlroneApi.state())
                }
                // OkHttp is synchronous; the channel thread is the main thread, where it throws
                // NetworkOnMainThreadException. Same for memoryWire below.
                "connections.close" -> result.respond {
                    withContext(Dispatchers.IO) {
                        FlroneApi.close(call.argument<String>("id").orEmpty())
                    }
                    null
                }
                "connections.closeAll" -> result.respond {
                    withContext(Dispatchers.IO) { FlroneApi.closeAll() }
                    null
                }
                // The Dart lifecycle observer's view of the app: while hidden the 1 s rates
                // tick above stops sampling and the state collector skips a traffic-only
                // change, because no frame would draw the result.
                "ui.visible" -> {
                    val visible = call.argument<Boolean>("visible") ?: invalidArgument("Missing visible")
                    val resumed = visible && !uiVisible
                    uiVisible = visible
                    // A hidden interval skipped traffic-only pushes; the first visible frame
                    // must not wait up to a second for the rates tick to carry the moved
                    // totals, so push one sample now (the tick's baseline catches up after).
                    if (resumed) pushState(sampleRate = true)
                    result.success(null)
                }
                "logs.visible" -> {
                    setLogsVisible(call.argument<Boolean>("visible") == true)
                    result.success(null)
                }
                "logs.clear" -> result.respond {
                    val batch = withContext(Dispatchers.IO) {
                        FlroneLogs.clear()
                        FlroneLogs.Batch(reset = true, defaultLogLevel = FlroneLogs.level())
                    }
                    emitBulk("logs", FlroneLogs.wire(batch))
                    null
                }
                // The system logcat tab: same shape as the core log's events, a different source.
                // The durable crash records: core.log rotates, these files survive until pruned.
                "crashes.list" -> result.respond {
                    withContext(Dispatchers.IO) {
                        // Prune on read too: records older than the window otherwise
                        // survive until the next crash happens to fire.
                        CrashStore.prune()
                        CrashStore.list().map { file ->
                            mapOf("name" to file.name, "size" to file.length(), "time" to file.lastModified())
                        }
                    }
                }
                "crashes.read" -> result.respond {
                    val name = call.argument<String>("name").orEmpty()
                    // The name comes back from crashes.list; anything path-like is rejected outright.
                    require(name.isNotEmpty() && !name.contains('/') && !name.contains('\\') && !name.contains("..")) {
                        "bad crash log name"
                    }
                    withContext(Dispatchers.IO) { mapOf("name" to name, "content" to CrashStore.read(name)) }
                }
                "logs.logcat.visible" -> {
                    if (call.argument<Boolean>("visible") == true) {
                        // The level arrives with the subscription and becomes logcat's filter
                        // spec, so the ring records at the floor the screen shows.
                        // wire() maps up to 1500 entries: build it on the ordered log worker
                        // (off Main), then emit posts to UI. The single-thread dispatcher keeps
                        // batch order and reset/firstId semantics identical.
                        FlroneLogcat.start(scope, call.argument<String>("level")) { batch ->
                            scope.launch(logWireDispatcher) { emitBulk("logcat", FlroneLogcat.wire(batch)) }
                        }
                    } else {
                        FlroneLogcat.stop()
                    }
                    result.success(null)
                }
                "logs.logcat.clear" -> result.respond {
                    withContext(Dispatchers.IO) { FlroneLogcat.clear() }
                    null
                }
                "dashboard.memory.visible" -> {
                    setMemoryVisible(call.argument<Boolean>("visible") == true)
                    result.success(null)
                }
                "dashboard.releaseMemory" -> result.respond {
                    // The button used to be a DEBUG-only System.gc() and a success reply: release
                    // builds showed "Memory released" while doing nothing. Run the complete trim on
                    // IO (it notifies the UI to drop decoded images, then ART gc/trimHeap) and
                    // answer true only when it actually ran. The Go/Dart heaps stay untouched.
                    withContext(Dispatchers.IO) { FlroneMemory.release() }
                    true
                }

                // --- diagnostics and the status card's probes
                "dashboard.egress" -> result.respond { egressWire(force = call.argument<Boolean>("force") == true) }
                // Building the client spawns OkHttp's dispatcher/pool and reads
                // DataStore: off the channel thread, like every other probe call.
                "dashboard.probe.open" -> result.respond {
                    probes.computeIfAbsent(call.argument<String>("id").orEmpty()) {
                        FlroneProbeSession(probeClient())
                    }
                    null
                }
                "dashboard.probe.get" -> result.respond { probeGet(call) }
                "dashboard.probe.close" -> {
                    closeProbe(call.argument<String>("id").orEmpty())
                    result.success(null)
                }
                "dashboard.qualityCache.get" -> result.respondIo { qualityCache(call.argument<String>("ip").orEmpty()) }
                "dashboard.qualityCache.put" -> result.respondIo {
                    val ip = call.argument<String>("ip").orEmpty()
                    @Suppress("UNCHECKED_CAST")
                    val value = call.argument<Any>("value")
                    writeQualityCache(ip, value)
                    null
                }

                // --- LAN access to the running proxy
                "dashboard.lan.refresh" -> result.respondIo { lanWire() }
                "dashboard.lan.set" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    val port = call.argument<Int>("port")
                    result.respond { lanSet(enabled, port) }
                }

                // --- per-app access control
                "apps.list" -> {
                    val refresh = call.argument<Boolean>("refresh") == true
                    val system = call.argument<Boolean>("system") == true
                    val nonInternet = call.argument<Boolean>("nonInternet") == true
                    // Package-manager scans belong off the main thread (the channel thread is it).
                    result.respond {
                        withContext(Dispatchers.IO) { FlroneApps.list(refresh, system, nonInternet) }
                            .map(FlroneApps.App::wire)
                    }
                }
                "apps.icon" -> result.respond {
                    withContext(Dispatchers.IO) { FlroneApps.icon(call.argument<String>("package").orEmpty()) }
                }
                // connections rows: path -> {package,label,icon} in one IO round trip, cached per path.
                "apps.process" -> result.respondIo {
                    FlroneApps.process(call.argument<String>("path").orEmpty())
                }
                // The access screen's smart selection: every installed package the mainland
                // rules call domestic. One query per app at most, cached per install.
                "apps.china" -> result.respond {
                    withContext(Dispatchers.IO) { ChinaApps.packages() }
                }
                // Starts/stops the per-connection attribution poller behind the traffic ledger.
                // It keeps running while the process lives (the UI may be gone); Dart re-arms it
                // on the next launch when the ledger setting is on.
                "trafficStats.watch" -> {
                    // Deliberate exception to the UI-only rule (`ui.visible`): this poller is the
                    // traffic ledger's data feed, so it keeps running while the app is hidden —
                    // a gap would leave whatever ran in the background unattributed.
                    val enabled = call.argument<Boolean>("enabled") == true
                    val details = call.argument<Boolean>("details") != false
                    trafficAggregator?.stop()
                    trafficAggregator = if (enabled) {
                        TrafficAggregator(scope) { payload -> emit("trafficDeltas", payload) }
                            .also { it.start(details) }
                    } else {
                        null
                    }
                    result.success(true)
                }

                // --- backup, restore and WebDAV -----------------------------------------------------
                // ADR 0005 phase 4: `backup.create` / `backup.restore` are gone. The Room snapshot and
                // THRN byte codec now live in Dart (`services/backup_write.dart` + `backup_store.dart`);
                // the host contributes only two facts Dart cannot derive (the UI documents and this
                // device's name/id) through the retained data-plane handlers below. `backup.open` —
                // the SAF picker's read-only decode — stays native; it returns the staged envelope
                // the confirmation dialog reads directly.
                "backup.open" -> result.respond { openBackupDocument() }
                // The UI documents a full-scope restore brings back. The native `backup.restore` used
                // to write these inline after the Room commit; with the Room write in Dart, the host
                // keeps only this narrow, idempotent writer around the same private helpers. The
                // WebDAV account is stripped by the caller and is never restored from a backup.
                "data.applyBackupUi" -> result.respondIo {
                    @Suppress("UNCHECKED_CAST")
                    val ui = call.argument<Map<String, Any?>>("ui") ?: emptyMap<String, Any?>()
                    (ui["preferences"] as? Map<*, *>)?.let { writePreferences(it.mapKeys { (key, _) -> key.toString() }) }
                    (ui["settings"] as? Map<*, *>)?.let { writeJsonMap(SETTINGS_KEY, it.mapKeys { (key, _) -> key.toString() }) }
                    (ui["quality"] as? Map<*, *>)?.let { writeJsonMap(QUALITY_KEY, it.mapKeys { (key, _) -> key.toString() }) }
                    // State lane: a restore replaces both documents wholesale and nothing
                    // re-reads them afterwards, so a lost push leaves the screens on the
                    // pre-restore values until the app is restarted.
                    emit("preferences", readPreferences(), EventPump.Lane.STATE)
                    emit("settings", settingsWire(), EventPump.Lane.STATE)
                    null
                }
                // ADR 0005 phases 0/1/4: all WebDAV channel methods are gone.
                // `webdav.check`, `webdav.get`/`webdav.set` moved to Dart earlier; phase 4 moved
                // `webdav.upload`/`webdav.read` to `services/backup_webdav.dart` (transport + index)
                // over the Dart-owned `backup.create` bytes (`services/backup_write.dart`). The four
                // Room rows remain only as the legacy-account fold on ready and the mirror of Dart
                // account writes.

                // --- documents and the share sheet
                "document.save" -> {
                    val name = call.argument<String>("name").orEmpty()
                    val content = call.argument<String>("content").orEmpty()
                    // Log exports carry credentials (URLs, keys); the native export always redacts
                    // (LogExport.build with redact = true), and so must anything that asks for it here.
                    val redact = call.argument<Boolean>("redact") == true
                    result.respond {
                        val text = withContext(Dispatchers.IO) {
                            if (!redact) content else {
                                val redactor = LogRedactor(hideDestinations = false)
                                content.lineSequence().joinToString("\n", transform = redactor::redact)
                            }
                        }
                        saveDocument(name, text)
                    }
                }
                "share.text" -> {
                    val content = call.argument<String>("content").orEmpty()
                    result.respond { shareText(content) }
                }
                "config.check" -> result.respond { checkConfig(call.argument<String>("content").orEmpty()) }

                // --- the FFI path's slim surface (FlroneKernel): Dart drives the kernel
                // directly over dart:ffi and only DB/build work crosses here. ---
                // The one platform fact Dart cannot derive: where Room keeps its file.
                // `/data/data/<pkg>/databases` needs the package name, which the Dart side
                // has no way to learn, so it asks once at startup and then opens the file
                // itself. This is the last data-plane call on the channel.
                // The retired `routes.list` channel fallback is gone: the routing
                // data plane is the kernel's single table, with no legacy import.
                "data.path" -> {
                    // ADR 0006 stage C2c2b2: nothing here opens a database. The retired Room file
                    // is only touched by LegacyRoomReader during the one-time seed, and the live
                    // data plane is documents. `path` stays in the answer because Dart derives the
                    // documents directory from it; the old `version` key (Room's schema number) is
                    // gone with Room itself.
                    result.respondIo {
                        val file = activity.getDatabasePath(Key.DB_PROFILE)
                        // ADR 0002 phase 3c: the kernel owns the route documents and writes
                        // them under its base path, which the host sets to filesDir in
                        // CoreRuntime.setup. This side only reads, so the two must name the
                        // same directory.
                        RouteJsonStore.directory =
                            java.io.File(activity.filesDir, "documents")
                        // ADR 0006 stage C1: the settings/markers documents live
                        // in the same directory. The mount is NOT here (stage C2):
                        // SagerNet.onCreate names it in every process, so a service
                        // that starts before any Dart engine reads the same store.
                        // ADR 0005 final stage: the same directory holds the
                        // Dart-owned profiles.json. Set the read view here so the
                        // first config.build after ready sees the document.
                        DartProfileStore.directory = RouteJsonStore.directory
                        // ADR 0005 phase 3: the rule-set picker reads srslist.h
                        // in pure Dart from filesDir/routeprofiles. Seed the
                        // APK's bundled snapshot first — refresh may not have
                        // run yet on a fresh install, and the Dart reader has no
                        // asset access.
                        RouteRepo.ensureCatalog()
                        // ADR 0005 phase 4: the backup write path is Dart-owned. These are the
                        // facts Dart cannot derive (app version, this device's id/name for the
                        // THRN meta, the localised default group name, and the two UI documents
                        // the envelope embeds). Read-only; the `data.applyBackupUi` handler is
                        // the only writer, and the WebDAV credential is stripped by the caller.
                        mapOf(
                            "path" to file.absolutePath,
                            "appVersion" to BuildConfig.VERSION_NAME,
                            "deviceId" to DataStore.deviceId,
                            "deviceName" to DataStore.effectiveDeviceName(),
                            "defaultGroupName" to io.nekohasekai.sagernet.database.GroupRepo.defaultGroupName(),
                            "backupUi" to mapOf(
                                "preferences" to readPreferencesForBackup(),
                                "settings" to readJsonMap(SETTINGS_KEY),
                                "quality" to readJsonMap(QUALITY_KEY),
                            ),
                        )
                    }
                }
                // ADR 0005 final stage: the one-time legacy export for Dart's
                // profiles document (ADR 0006 stage C2c2a moved it off Room).
                //
                // Dart used to open Room itself over dart:ffi, but an Android app
                // cannot dlopen the platform's SQLite: `libsqlite3.so` is not on
                // AOSP system images and `libsqlite.so` is not in
                // public.libraries.txt, so that reader answers null on a stock
                // device. `LegacyRoomReader` reads the retired file with the
                // framework SQLite, read-only and without Room, in the same column
                // shape `DartProfileWriter.profileRow/groupRow` maps; Dart stays
                // the only writer of the document. The reader answers the route/
                // settings/marker rows only while their documents are absent, and
                // empty lists when the file is missing or unreadable.
                "data.legacyRows" -> result.respondIo {
                    LegacyRoomReader.snapshot(java.io.File(activity.filesDir, "documents"))
                }
                // In-app diagnostics: the *Kotlin* view of the Dart-owned
                // profiles document. Dart's own status can say "1 group / 1
                // profile" while this process sees nothing (a missing directory,
                // a parse failure, a stale file); the data page shows both so a
                // "imported but not displayed" report is diagnosable without
                // logcat. Read-only; no cache is mutated.
                "data.profilesView" -> result.respondIo {
                    val groups = runCatching { DartProfileStore.groups().size }
                    val profiles = runCatching { DartProfileStore.profiles().size }
                    mapOf(
                        "directory" to (DartProfileStore.directory?.absolutePath ?: ""),
                        "exists" to DartProfileStore.documentExists(),
                        "groups" to groups.getOrDefault(-1),
                        "profiles" to profiles.getOrDefault(-1),
                        "error" to (groups.exceptionOrNull() ?: profiles.exceptionOrNull())
                            ?.let { error ->
                                // The exception this read actually threw first;
                                // `lastError` is a global "most recent parse
                                // failure" and can describe an unrelated
                                // earlier read.
                                error.message?.takeIf { it.isNotEmpty() }
                                    ?: DartProfileStore.lastError.orEmpty()
                            }
                            .orEmpty(),
                    )
                }
                // ADR 0006 stage C2c1: the backup container's SQL transport. It
                // replaces `data.roomSql`, whose `openRoom` op handed Dart a live
                // Room connection; this arm has no live-database handle at all and
                // only opens files in the app's own storage (see
                // FlroneRoomSnapshot.confinedContainerFile — `sager_net.db`, the
                // documents directory and the rule-set catalog are refused).
                // Stage C2c2a: the DAO row pumps are gone too; the backup's data
                // plane reads the documents (profiles.json, the kernel route
                // documents, settings.json/markers.json) and uses this arm only as
                // the container's SQL transport.
                "backup.container" -> result.respondIo {
                    @Suppress("UNCHECKED_CAST")
                    val args = (call.arguments as? Map<String, Any?>).orEmpty()
                    when (args["op"]) {
                        "open" -> FlroneRoomSnapshot.openContainer(args)
                        "close" -> { FlroneRoomSnapshot.closeContainer(args); null }
                        "exec" -> FlroneRoomSnapshot.exec(args)
                        "query" -> FlroneRoomSnapshot.query(args)
                        // NO_WRAP on the encode: dart's base64Decode rejects
                        // DEFAULT's 76-column newlines (decode below stays
                        // DEFAULT — it accepts either form).
                        // The path is Dart's; the object confines it to the app's
                        // own storage before anything is read or written (see
                        // FlroneRoomSnapshot.confinedContainerFile).
                        "readBytes" -> mapOf("bytes" to android.util.Base64.encodeToString(
                            FlroneRoomSnapshot.confinedContainerFile(args["path"] as? String ?: "").readBytes(),
                            android.util.Base64.NO_WRAP))
                        "writeBytes" -> {
                            FlroneRoomSnapshot.confinedContainerFile(args["path"] as? String ?: "").writeBytes(
                                android.util.Base64.decode(args["bytes"] as? String ?: "", android.util.Base64.DEFAULT))
                            null
                        }
                        else -> error("unknown backup.container op: ${args["op"]}")
                    }
                }
                // ADR 0006 stage C2c2a: the backup's settings/markers documents.
                // The export reads the live settings/markers documents through the
                // snapshot ops (the host is their only writer, and the Dart side
                // cannot read the documents directory through `backup.container`).
                // A restore merges/replaces them in one call each: the merge rules
                // (device-local, Android-only, selection repair) live in
                // FlroneRoomSnapshot.restoreSettings, so the writer stays singular.
                "settings.snapshot" -> result.respondIo { FlroneRoomSnapshot.settingsSnapshot() }
                "markers.snapshot" -> result.respondIo { FlroneRoomSnapshot.markersSnapshot() }
                "settings.restore" -> result.respondIo {
                    @Suppress("UNCHECKED_CAST")
                    val args = (call.arguments as? Map<String, Any?>).orEmpty()
                    FlroneRoomSnapshot.restoreSettings(args)
                }
                "markers.restore" -> result.respondIo {
                    @Suppress("UNCHECKED_CAST")
                    val args = (call.arguments as? Map<String, Any?>).orEmpty()
                    FlroneRoomSnapshot.restoreMarkers(args)
                    null
                }
                // Attaching the documents directory: establish the read-only views of
                // the Go/Dart-owned documents, seed the UI documents (per-file skip),
                // and publish host facts (batteryExempt) that Go's settingsWire reads.
                // No legacy route format exists: a missing `global_route_rules.json`
                // is an empty rule table and the build starts from Default.
                "data.documents" -> result.respondIo {
                    val dir = java.io.File(activity.filesDir, "documents")
                    // ADR 0005 phase 3: the routing screen no longer takes the
                    // `data.path` -> SQLite path, so establish the read-only view
                    // of the Go-owned documents here (this runs on every attach,
                    // before any config.build). RouteJsonStore must name the same
                    // directory as route_store.go's documentsDir or ConfigGenerator
                    // and the group route picker read a stale snapshot.
                    RouteJsonStore.directory = dir
                    DartProfileStore.directory = dir
                    // SettingsJsonStore is already mounted here: SagerNet.onCreate
                    // names it in every process (ADR 0006 stage C2), before any
                    // settings read in this one.
                    val seeded = LegacyDocumentSeed.seedUiDocuments(dir,
                        preferences.getString("settings", null),
                        preferences.getString("value", null))
                    UiDocuments.directory = dir
                    publishHostFacts(dir)
                    mapOf("seeded" to seeded)
                }
                // Wi-Fi rules in ffiMode: Dart asks the core whether the config needs Wi-Fi
                // state and enables the monitor here. Only the Android callback stays on this
                // side; every change is announced so the core re-reads the SSID/BSSID.
                "wifi.watch" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    FlroneKernel.onWifiChanged = if (enabled) {
                        { emit("wifi.state", true) }
                    } else {
                        null
                    }
                    DataStore.baseService?.watchWifiRules(enabled)
                    result.success(null)
                }
                // Lifecycle breadcrumbs from the FFI driver, written into the same core.log the
                // log screen shows. A restart loop is otherwise invisible: the core simply
                // closes, and nothing in its own output says who asked for it or why.
                "log.note" -> result.respondIo {
                    KernelServiceActions.note(call.argument<String>("text").orEmpty())
                    null
                }
                "config.build" -> result.respond {
                    // The native DB owns the selection. Dart sends no id: a UI/group
                    // id or 0 is never a ProxyEntity id and used to fail every start
                    // with "profile 0 is gone". Ignore any stale argument entirely.
                    KernelServiceActions.buildStartOptions()
                }
                "state.setMode" -> result.respondIo {
                    FlroneKernel.setMode(call.argument<String>("mode") ?: invalidArgument("Missing mode"))
                    null
                }
                // The service used to write these two right after proxy.init(); the FFI driver
                // owns the start now, so it reports them once the core is actually up.
                "state.markRunning" -> result.respondIo {
                    val ids = (call.argument<List<*>>("involvedProfileIds") ?: emptyList<Any?>())
                        .mapNotNull { (it as? Number)?.toLong() }
                    KernelServiceActions.markRunning(ids, (call.argument<Number>("routeId"))?.toLong() ?: 0L)
                    null
                }
                "state.clearRunning" -> result.respondIo {
                    KernelServiceActions.clearRunning()
                    null
                }
                // The kernel's status snapshot from the service engine; this is the sole
                // source of the notification's speed line (there is no service-side traffic looper).
                "state.stats" -> {
                    KernelServiceActions.publishKernelStats(
                        txRate = (call.argument<Number>("txRate"))?.toLong() ?: 0L,
                        rxRate = (call.argument<Number>("rxRate"))?.toLong() ?: 0L,
                        txTotal = (call.argument<Number>("txTotal"))?.toLong() ?: 0L,
                        rxTotal = (call.argument<Number>("rxTotal"))?.toLong() ?: 0L,
                    )
                    result.success(null)
                }
                "updates.check" -> result.respond { updatesWire() }
                "battery.open" -> result.respondIo {
                    openBatterySettings()
                    settingsWire()
                }
                "systemProxy.set" -> {
                    // Upstream's switch: the VPN service writes its mixed inbound into the system
                    // settings, which API 29 allows and the proxy-only mode cannot do at all.
                    val enabled = call.argument<Boolean>("enabled") == true
                    if (!systemProxyAvailable()) {
                        result.error("unsupported", "The system HTTP proxy needs VPN mode and Android 10 or newer", null)
                    } else {
                        // DataStore is a Room row: the write and the read-back are both queries.
                        result.respondIo {
                            DataStore.appendHttpProxy = enabled
                            if (DataStore.serviceState.canStop) {
                                SagerNet.reloadService()
                                FlroneBridge.routeMoved()
                            }
                            mapOf("available" to true, "enabled" to DataStore.appendHttpProxy)
                        }
                    }
                }
                else -> result.error(
                    "unsupported",
                    "This screen is not wired to Throne yet: ${call.method}",
                    null,
                )
            }
        } catch (e: InvalidArgument) {
            Logs.w(e)
            result.error("invalid_argument", e.message ?: "Invalid argument", null)
        } catch (e: Exception) {
            Logs.w(e)
            result.error("failed", e.message ?: e.javaClass.simpleName, null)
        } catch (e: Throwable) {
            // An Error (NoSuchMethodError on an older API, ExceptionInInitializerError,
            // a ClassCastException from a hostile wire map) used to escape this
            // callback and crash the app — the same class of failure as the old
            // longVersionCode crash. Answer with an error instead.
            Logs.w(e)
            result.error("fatal", e.message ?: e.javaClass.simpleName, null)
        }
    }

    // -------------------------------------------------------------------------------------------- live views

    /**
     * Starts, parks or stops the connections feed, in the three states the page's activity gate
     * asks for. Opening the screen is side-effect free: the API is enabled at service start
     * (FlroneKernel.buildStartOptions), only when the user has not explicitly turned it off.
     * Flipping it here used to overwrite clashApiEnabled and reload the running tunnel just
     * because the user looked at the list.
     *
     *  - `visible` — the 1.5 s sample loop runs.
     *  - `!visible, pause` — **parked**: the loop stops and the rate window restarts, but the
     *    rows already emitted and the closed ring stay. The page keeps its list while it is
     *    covered by another route or the app is in the background, and resumes with one full
     *    page (the loop samples before its first delay) instead of a blank flash. While parked
     *    the only sampling left is the S6 count loop's list-length poll
     *    (`startConnectionCountLoop` → `dashboard.connections`), which has its own visibility
     *    rule.
     *  - `!visible` — **off** (the page closed): the rows and the ring are dropped so the card
     *    cannot show the last session's list as live; one empty page is sent once.
     */
    private fun setConnectionsFeed(visible: Boolean, pause: Boolean) {
        connectionsJob?.cancel()
        connectionsJob = null
        // A reopen starts a fresh rate window (see ConnectionsSampler.resetWindow): its first
        // sample reports 0 B/s instead of averaging the time the page was closed or covered.
        connectionsSampler.resetWindow()
        if (!visible) {
            // Parked: the page still shows what it has, so the rows (and the ring inside
            // them) are the history a resume continues from — clearing here was what made a
            // covered page look empty for a tick.
            if (pause) return
            // The feed is off, so the rows the UI kept are no longer being updated: clear them
            // once rather than leaving a stale list (and a stale Active count on the card) to
            // look live. A reopen re-emits the whole page, closed ring included.
            if (lastConnections != null) {
                lastConnections = null
                emitBulk("connections", emptyList<Map<String, Any?>>())
            }
            connectionsSampler.resetRows()
            return
        }
        // No FlroneApi.enable / reloadService / applyRequired here: opening the page must never
        // reconfigure the core or rewrite a user-visible setting.
        connectionsJob = scope.launch {
            while (isActive) {
                val now = SystemClock.elapsedRealtime()
                val attempt = withContext(Dispatchers.IO) {
                    runCatching { FlroneApi.connections() }.onFailure {
                        connectionsError = it.readableMessage
                        Logs.w(it)
                    }
                }
                val live = attempt.getOrDefault(emptyList())
                if (attempt.isSuccess) connectionsError = null
                val rows = connectionsSampler.sample(live, now, System.currentTimeMillis())
                // Only a change is worth a frame: an idle tunnel's rows (0 B/s, same totals)
                // are identical tick after tick, so the screen is not rebuilt for nothing.
                if (rows != lastConnections) {
                    lastConnections = rows
                    emitBulk("connections", rows)
                }
                delay(1500)
            }
        }
    }

    @Volatile
    private var lastConnections: List<Map<String, Any?>>? = null

    /** Rates, cumulative totals and the closed ring; pure JVM so its contract is unit-tested. */
    private val connectionsSampler = ConnectionsSampler()

    private fun setLogsVisible(visible: Boolean) {
        if (!visible) {
            FlroneLogs.stop()
            return
        }
        // wire() now runs inside FlroneLogs on a background dispatcher; emit posts to UI.
        FlroneLogs.start(scope) { emitBulk("logs", it) }
    }

    /**
     * The client publishes its model every 100 ms; the panel's feed relays at 400 ms and only what
     * changed, which is what the native panel's diffing achieved on a slower path.
     */
    private fun setTestSessionVisible(visible: Boolean) {
        testSessionJob?.cancel()
        testSessionJob = null
        if (!visible) {
            lastTestSession = null
            return
        }
        testSessionJob = scope.launch {
            while (isActive) {
                val wire = withContext(Dispatchers.IO) { FlroneTestSessions.wire() }
                if (wire != lastTestSession) {
                    lastTestSession = wire
                    emit("testSession", wire)
                }
                delay(400)
            }
        }
    }

    /**
     * One queue report, split the way the native window splits it: a reload hint re-applies the
     * running config when it only moved that config's content and raises the apply badge
     * otherwise, an error or an untitled status line is a snackbar, a popup opens the change
     * window. The group's name rides along so the UI never has to ask.
     */
    private suspend fun emitReport(report: SubscriptionClient.Report) {
        val groupName = withContext(Dispatchers.IO) {
            runCatching { GroupRepo.get(report.gid)?.displayName() }.getOrNull()
        }
        when {
            report.reload -> {
                // The queue only asks when a refresh re-pointed something a build resolves. The
                // question the UI has to answer is whether that build would still be the running
                // config; when it would, the change is its content and a reload applies it in
                // place (FlClash's applyProfileDebounce). The state lane: a hint lost here leaves
                // the running tunnel silently stale — no badge and no reload — and no later push
                // repeats it.
                val contentOnly = withContext(Dispatchers.IO) {
                    runCatching { reloadChangesContentOnly() }.getOrDefault(false)
                }
                if (contentOnly) {
                    emit("configChanged", mapOf("gid" to report.gid), EventPump.Lane.STATE)
                } else {
                    emit("applyRequired", "Reload")
                }
            }

            report.error -> emit("subscriptionReport", mapOf(
                "kind" to "error",
                "groupName" to groupName,
                "text" to report.text.ifBlank { report.title },
            ))

            report.popup -> emit("subscriptionReport", mapOf(
                "kind" to "popup",
                "groupName" to groupName,
                "title" to report.title.ifBlank {
                    app.getString(io.nekohasekai.sagernet.R.string.grp_change_of, groupName.orEmpty())
                },
                "text" to report.text,
            ))

            report.title.isEmpty() && report.text.isNotBlank() -> emit("subscriptionReport", mapOf(
                "kind" to "status",
                "text" to report.text,
            ))
        }
    }

    /**
     * Whether a reload hint describes a content-only change of the running config.
     *
     * There is one global rule table now, so the only build input a refresh can move is the
     * selected profile. Equal to the running fact means only rules or node rows changed and a
     * reload applies them in place; a different selection is a switch and keeps the explicit
     * apply badge. A stopped service answers false, as does a connection whose facts cannot be
     * read — the failure direction is the badge, never a reload on a guess.
     */
    private fun reloadChangesContentOnly(): Boolean {
        val runningProfile = ProfileManager.runningProfileId()
        if (runningProfile <= 0L) return false
        return DataStore.selectedProxy == runningProfile
    }

    /** Memory is cheap to read but not free on a television, so it is sampled only while a panel shows it. */
    private fun setMemoryVisible(visible: Boolean) {
        memoryJob?.cancel()
        memoryJob = null
        if (!visible) return
        memoryJob = scope.launch {
            while (isActive) {
                // memoryWire() only calls Debug.getMemoryInfo and Runtime (no HTTP
                // any more), but a 2 s sample still belongs off the main looper.
                emit("memory", withContext(Dispatchers.IO) { memoryWire() })
                delay(2000)
            }
        }
    }

    /**
     * What the memory panel shows, all of it from Android's own accounting.
     *
     * `Debug.MemoryInfo` reports PSS — what the process actually has resident — and splits it by
     * allocator: `dalvikPss` for the ART heap, `nativePss` for native allocations (the Go runtime is
     * one) and `otherPss` for the rest. The three add up to `totalPss`, so the panel can show four
     * numbers that agree with each other without any arithmetic of its own.
     *
     * The core used to grade itself instead: `Status().Memory` is the heap the Go runtime has
     * *mapped*, which is a different quantity from resident memory and can exceed RSS. On a 286 MB
     * process it read 319 MB, and every way of folding it into the panel produced a part larger
     * than the whole.
     *
     * `heapInuse`/`heapIdle` stay the ART heap's own counters: they answer "how full is the heap",
     * which PSS cannot.
     */
    private fun memoryWire(): Map<String, Any?> {
        val runtime = Runtime.getRuntime()
        val heapUsed = runtime.totalMemory() - runtime.freeMemory()
        val info = Debug.MemoryInfo()
        Debug.getMemoryInfo(info)
        fun kb(value: Int) = value.toLong() * 1024
        return mapOf(
            "total" to runtime.maxMemory(),
            "app" to kb(info.dalvikPss),
            "core" to kb(info.nativePss),
            "other" to kb(info.otherPss),
            "rss" to kb(info.totalPss),
            "running" to DataStore.serviceState.connected,
            "remote" to false,
            "heapInuse" to heapUsed,
            "heapIdle" to (runtime.totalMemory() - heapUsed),
        )
    }

    // -------------------------------------------------------------------------------------------- probes and egress

    private fun probeClient(): OkHttpClient {
        val builder = OkHttpClient.Builder()
            .connectTimeout(6, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .callTimeout(16, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
        // Same route as the egress probe: the mixed inbound only while the core answers it. A connected session with
        // no mixed inbound has no routed route at all, so the session refuses rather than grade the phone's own
        // uplink as an exit; a stopped service keeps the device network, which is the answer the card knows is direct.
        val route = if (DataStore.serviceState.connected) {
            FlroneEgress.tunnelRoute() ?: error(FlroneEgress.NO_TUNNEL_ROUTE)
        } else {
            null
        }
        return FlroneEgress.applyRoute(builder, route).build()
    }

    private suspend fun probeGet(call: MethodCall): Map<String, Any?> {
        // Capture the session before dispatching; a late request must never reopen a closed one.
        val session = probes[call.argument<String>("id").orEmpty()]
            ?: throw CancellationException("IP probe session closed")
        val url = call.argument<String>("url").orEmpty()
        val timeout = call.argument<Int>("timeoutMillis") ?: 8000
        return withContext(Dispatchers.IO) { session.get(url, timeout.toLong()) }
    }

    private fun closeProbe(id: String) {
        probes.remove(id)?.close()
    }

    private suspend fun egressWire(force: Boolean = false): Map<String, Any?> = withContext(Dispatchers.IO) {
        // The probe reaches the internet through the mixed inbound, which nothing answers until the core is up. Rather
        // than leaving the card blank while stopped, ask over the phone's own connection: the answer is the address
        // this device appears as without the tunnel, and `direct` tells the screen which of the two it is looking at.
        // A connected session with no mixed inbound (disabled in VPN mode, no port) has no route at all: the probe
        // fails and the error reaches the card. It must not answer over the device network, because `direct: false`
        // would then present the phone's own address as the tunnel's exit.
        val direct = !DataStore.serviceState.connected
        val cachedAt = FlroneEgress.cachedAt(direct)
        var failure: String? = null
        val info = FlroneEgress.probe(force = force, direct = direct) { failure = it }
        val checkedAt = FlroneEgress.cachedAt(direct)
        if (force && failure != null && checkedAt == cachedAt) error(failure!!)
        if (info.isEmpty) error(failure ?: "Unreachable")
        if (force) FlroneEgress.touch(direct)
        val reportedAt = FlroneEgress.cachedAt(direct)
        // "Look up exit country" (General → Exit detection) turns the country
        // off at the card, not at the probe: the address and ISP still come
        // from the same answer, only the country fields are withheld. Without
        // this the toggle was stored and never read.
        val countryOn = DataStore.exitCountryLookup
        // S7: the route version this answer belongs to, read after the probe finished. A route
        // that moved while the request was in flight (a proxy switch, a mode change, a reload)
        // stamps a newer version here than the one the card started under, so the card discards
        // this address instead of painting the old exit under the new selection.
        val routeVersion = FlroneBridge.routeVersion()
        mapOf(
            "ip" to info.ip,
            "country" to info.country.takeIf { countryOn },
            "countryName" to info.countryName.takeIf { countryOn },
            "region" to info.region,
            "city" to info.city,
            "isp" to info.isp,
            "organization" to info.organization,
            "asn" to info.asn,
            "type" to info.type,
            // Honest by construction: the probe only fills this slot over the mixed inbound, so a cached answer from
            // an earlier connected session is not shown as a direct one, and a failed tunnel probe never lands here.
            "direct" to direct,
            "ipSource" to (info.source?.substringAfter("://")?.substringBefore('/') ?: "ipwho.is"),
            // A fresh probe carries the moment it was measured; a normal cache hit keeps that
            // honest time, while a forced failure above never reaches this wire at all.
            "checkedAt" to (reportedAt.takeIf { it > 0 } ?: System.currentTimeMillis()),
            "routeVersion" to routeVersion,
        )
    }

    private fun qualityCache(ip: String): Map<String, Any?>? {
        if (ip.isBlank()) return null
        val stored = readJsonMap(QUALITY_KEY)
        @Suppress("UNCHECKED_CAST")
        return stored[ip] as? Map<String, Any?>
    }

    private fun writeQualityCache(ip: String, value: Any?) {
        if (ip.isBlank()) return
        val merged = readJsonMap(QUALITY_KEY).toMutableMap()
        if (value == null) merged.remove(ip) else merged[ip] = value
        // Bounded: an entry per IP the user has ever connected through would grow without limit.
        if (merged.size > 512) {
            val oldest = merged.keys.take(merged.size - 512)
            oldest.forEach { merged.remove(it) }
        }
        writeJsonMap(QUALITY_KEY, merged)
    }

    // ------------------------------------------------------------------------------------------------ LAN access

    /**
     * Whether the running service answers on the LAN.
     *
     * Throne's mixed inbound binds to a configured address; loopback keeps the proxy private to the device and a
     * wildcard address shares it with everything on the same network. That choice *is* the LAN switch, so this reads
     * and writes the same setting the core configuration is built from.
     */
    private fun lanWire(): Map<String, Any?> {
        val shared = isSharedInbound()
        val port = DataStore.inboundSocksPort
        val addresses = lanAddresses()
        val endpoints = if (shared && DataStore.serviceState.connected) {
            addresses.map { "$it:$port" }
        } else {
            emptyList()
        }
        return mapOf(
            "addresses" to addresses,
            "canToggle" to true,
            "running" to (shared && DataStore.serviceState.connected),
            "enabled" to shared,
            "profileId" to (FlroneBridge.catalog.selectedGroupId.takeIf { it > 0 } ?: -1),
            "revision" to "$port-${DataStore.inboundAddress}",
            "stamp" to "$port-${DataStore.inboundAddress}",
            "error" to null,
            "bindings" to listOf(
                mapOf(
                    "tag" to "mixed",
                    "type" to "mixed",
                    "tls" to false,
                    "authentication" to false,
                    "port" to port,
                    "endpoints" to endpoints,
                    "lan" to shared,
                )
            ),
            "activeBindings" to if (endpoints.isEmpty()) emptyList<Map<String, Any?>>() else listOf(
                mapOf("tag" to "mixed", "type" to "mixed", "port" to port, "endpoints" to endpoints, "lan" to true)
            ),
        )
    }

    private suspend fun lanSet(enabled: Boolean, port: Int?): Map<String, Any?> = withContext(Dispatchers.IO) {
        if (lanBusy) error("Already switching the LAN listener")
        lanBusy = true
        try {
            if (port != null) DataStore.inboundSocksPort = port
            // One "on" value for the whole app: SettingsRegistry.LAN_ADDRESS ("::"),
            // the same literal the settings schema writes and the consumers
            // (FlroneEgress, Nets) special-case. Writing "0.0.0.0"
            // here made every `if (it == "::")` check miss and left the LAN
            // listener bound to an address the rest of the code did not expect.
            val address = if (enabled) SettingsRegistry.LAN_ADDRESS else SettingsRegistry.LOOPBACK_ADDRESS
            if (address != DataStore.inboundAddress) {
                DataStore.inboundAddress = address
                if (DataStore.serviceState.canStop) SagerNet.reloadService()
            }
            lanWire().also { emit("lan", it) }
        } finally {
            lanBusy = false
        }
    }

    private fun isSharedInbound(): Boolean {
        val address = DataStore.inboundAddress
        return address.isNotBlank() && address != SettingsRegistry.LOOPBACK_ADDRESS && address != "127.0.0.1" && address != "::1"
    }

    private fun lanAddresses(): List<String> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filter { !it.isLoopbackAddress && it.hostAddress?.contains(':') != true }
            .mapNotNull { it.hostAddress }
    }.getOrDefault(emptyList())

    // ------------------------------------------------------------------------------------------------ documents

    private suspend fun saveDocument(name: String, content: String): Boolean? {
        val host = activity as? FlroneActivity ?: return false
        val mime = when {
            name.endsWith(".json", ignoreCase = true) -> "application/json"
            name.endsWith(".log", ignoreCase = true) -> "text/plain"
            else -> "application/octet-stream"
        }
        val uri = host.pickSaveTarget(name, mime) ?: return null
        return withContext(Dispatchers.IO) {
            runCatching {
                // A null stream means nothing was written; reporting success here would let the
                // UI confirm an export that did not happen.
                val output = host.contentResolver.openOutputStream(uri) ?: error("cannot open $uri")
                output.use { it.write(content.toByteArray(Charsets.UTF_8)) }
                true
            }.onFailure { Logs.w(it) }.getOrDefault(false)
        }
    }

    private suspend fun shareText(content: String): Boolean {
        if (content.isBlank()) return false
        return runCatching {
            activity.startActivity(
                Intent.createChooser(
                    Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, content),
                    null,
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        }.onFailure { Logs.w(it) }.getOrDefault(false)
    }

    /**
     * The local "Restore" entry: the user picks the file, and either the JSON envelope the local
     * "Backup" entry wrote or a `.thrbackup` container ends up as the same staged payload the WebDAV
     * read produces. A cancelled picker answers null, which the page treats as "nothing chosen"
     * rather than "no backup"; a file that is neither is an error the page can show.
     */
    private suspend fun openBackupDocument(): Map<String, Any?>? {
        val host = activity as? FlroneActivity ?: error("The file picker is unavailable")
        val uri = host.pickDocument() ?: return null
        val bytes = withContext(Dispatchers.IO) {
            host.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } ?: error("The selected file cannot be read")
        return FlroneBackup.open(bytes)
            ?: FlroneBackup.openJson(bytes.toString(Charsets.UTF_8))
            ?: error("This is not a Throne backup")
    }

    /** A picked file becomes the same draft a pasted link becomes, so both open the same editor. */
    private suspend fun importFile(): Map<String, Any?>? {
        val host = activity as? FlroneActivity ?: return null
        val uri = host.pickDocument() ?: return null
        val text = withContext(Dispatchers.IO) {
            runCatching {
                host.contentResolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) }
            }.getOrNull()
        }.orEmpty()
        if (text.isBlank()) return null
        return FlroneProfiles.decodeIntent(text.trim())
    }

    // ------------------------------------------------------------------------------------------------ JSON editing

    /** The document keys a group's configuration may carry; everything else is an app setting. */
    private val CONFIG_KEYS = setOf("name", "url", "autoUpdate", "updateIntervalMinutes", "nodes")

    /** "DNS, routing rules and log settings are app settings": the Throne split the document follows. */
    private fun refuseForeignConfigKey(key: String): Nothing =
        error("\"$key\" is not part of the configuration; DNS, routing rules and log settings are app settings")

    /**
     * The configuration is the group's manifest — name, url, autoUpdate, updateIntervalMinutes and its nodes.
     * DNS and routing live in the app settings as in Throne, so those keys are refused here instead of being
     * dropped by a save that only reads the manifest.
     */
    private suspend fun checkConfig(content: String): Any? = withContext(Dispatchers.IO) {
        val parsed = JsonTree.parse(content)
        val root = parsed.root ?: error(parsed.error.ifBlank { "Not valid JSON" })
        if (root.type != JsonType.Object) error("The configuration must be a JSON object")
        for (key in root.keys) if (key !in CONFIG_KEYS) refuseForeignConfigKey(key)
        root.member("name")?.takeIf { it.type != JsonType.String }?.let { error("\"name\" must be a string") }
        root.member("url")?.takeIf { it.type != JsonType.String }?.let { error("\"url\" must be a string") }
        root.member("autoUpdate")?.takeIf { it.type != JsonType.Bool }?.let { error("\"autoUpdate\" must be true or false") }
        root.member("updateIntervalMinutes")?.takeIf { it.type != JsonType.Number }?.let { error("\"updateIntervalMinutes\" must be a number") }
        root.member("nodes")?.takeIf { it.type != JsonType.Array }?.let { error("\"nodes\" must be an array") }
        null
    }

    // ------------------------------------------------------------------------------------------------ updates

    private suspend fun updatesWire(): Map<String, Any?> = withContext(Dispatchers.IO) {
        when (val result = UpdateChecker.check(app, withNotes = true)) {
            is UpdateChecker.Result.UpToDate -> mapOf(
                "available" to false,
                "version" to BuildConfig.VERSION_NAME,
                "hasMetadata" to true,
            )
            is UpdateChecker.Result.Available -> {
                val offer = result.offer
                mapOf(
                    "available" to true,
                    "version" to offer.versionName,
                    "notes" to offer.notes,
                    "hasMetadata" to true,
                    "downloadUrl" to offer.apk?.url,
                    "url" to offer.release.htmlUrl,
                )
            }
            is UpdateChecker.Result.Failed -> mapOf(
                "available" to false,
                "version" to BuildConfig.VERSION_NAME,
                "hasMetadata" to false,
            )
        }
    }

    private fun openBatterySettings() {
        runCatching {
            activity.startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:${app.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }.onFailure {
            runCatching {
                activity.startActivity(
                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }.onFailure { Logs.w(it) }
        }
    }

    /** The system HTTP proxy is written by the VPN service, so proxy-only mode cannot offer it. */
    private fun systemProxyAvailable(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && DataStore.serviceMode == Key.MODE_VPN

    private fun batteryExempt(): Boolean = runCatching {
        val power = activity.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        power.isIgnoringBatteryOptimizations(activity.packageName)
    }.getOrDefault(false)

    /** Publishes host facts (batteryExempt) so Go's settingsWire can read them. */
    private fun publishHostFacts(dir: java.io.File) {
        UiDocuments.writeHostFacts(mapOf("batteryExempt" to batteryExempt()))
    }

    /**
     * The share / open-with payload, delivered once per intent: the first `intent.take` after an
     * intent arrives consumes it (per the ready payload's contract), and a later intent starts the
     * cycle again — [notifyIntentAvailable] tells the UI to ask again. Two intents before either is
     * taken keep only the latest, as `setIntent` replaced the first.
     */
    private fun takeIntent(): String? {
        if (pendingIntent == null) {
            val intent = activity.intent
            if (intent != null && intent !== deliveredIntent) {
                // A file arrives in the data slot when it was opened (VIEW) and in the stream slot when it
                // was shared (SEND); the text slot is the QR scanner's and the share sheet's.
                pendingIntent = intent.takeIf { it.action != Intent.ACTION_MAIN }?.dataString
                    ?: intent.getStringExtra(Intent.EXTRA_TEXT)
                    ?: intent.streamUri?.toString()
                deliveredIntent = intent
            }
        }
        return pendingIntent.also { pendingIntent = null }
    }

    /**
     * A new intent has replaced the old one; the UI picks it up with `intent.take`. When the UI is
     * not attached the intent still waits for the next `ready`, so nothing is lost — only the ping
     * is, and the pending flag re-raises it in [onListen].
     */
    fun notifyIntentAvailable() {
        if (sink == null) {
            intentAvailablePending = true
            return
        }
        // State lane: the ping is not repeated, so a dropped one strands the intent until the
        // next share replaces it.
        emit("intentAvailable", true, EventPump.Lane.STATE)
    }

    // ------------------------------------------------------------------------------------------------ payloads

    /**
     * Answers `ready` and seeds the pushState baselines with what it just sent.
     *
     * Without the baselines the first push after this answer would rebuild the catalog and emit it
     * again — the very duplicate this release removes — and pushState stays silent until this has
     * answered, so nothing is emitted twice around the first frame.
     */
    @Suppress("UNCHECKED_CAST")
    private fun serveReady(): Map<String, Any?> {
        val payload = readyPayload()
        lastDashboard = payload["dashboard"] as? Map<String, Any?>
        lastProfiles = payload["profiles"] as? List<Map<String, Any?>>
        lastGroups = payload["groups"] as? List<Map<String, Any?>>
        sentCatalog = FlroneBridge.catalogRevision to groupsVisible
        readyServed = true
        return payload
    }

    private fun readyPayload(): Map<String, Any?> = mapOf(
        "version" to BuildConfig.VERSION_NAME,
        // The version CI injects into the core (`-ldflags -X constant.Version`). It used to be a
        // literal placeholder here, so the settings page could not tell which core an APK carried.
        "coreVersion" to runCatching { CoreHost.version() }.getOrNull()?.trim().orEmpty(),
        // The upstream commit the AAR was built from; short enough for a subtitle.
        "coreRef" to BuildConfig.THRONE_CORE_REF.orEmpty(),
        "systemAccentColor" to 0xFF6750A4.toInt(),
        "dashboard" to dashboardWire(FlroneBridge.state.value),
        "profiles" to profilesWire(FlroneBridge.state.value),
        // Counts only: the node rows are the largest thing the bridge carries, and the first
        // screen does not render them. `groups.visible` sends them when the Proxies screen opens.
        "groups" to groupsWire(FlroneBridge.state.value, withItems = groupsVisible),
        "settings" to settingsWire(),
        "capabilities" to Capabilities.map(),
        // ADR 0005 phase 1: fold a legacy Room WebDAV account in on upgrade. The
        // Dart store reads this value; there is no longer a webdav.get channel.
        "preferences" to preferencesWithLegacyWebDav(),
        "lan" to lanWire(),
        "tools" to emptyMap<String, Any?>(),
        "diagnostics" to mapOf(
            "stun" to emptyMap<String, Any?>(),
            "quality" to emptyMap<String, Any?>(),
        ),
        "intent" to takeIntent(),
        // A low-RAM device gets a smaller decoded-image budget than the 50 MiB the UI assumes.
        "lowRam" to lowRamDevice(),
        // The badge an AppRestart-level write or reset raised; it clears only when the restart
        // gives the process a fresh [restartPending].
        "applyRequired" to (if (restartPending) "Restart" else null),
    )

    /** `ActivityManager.isLowRamDevice`: Android's own memory class, not a build flag of ours. */
    private fun lowRamDevice(): Boolean = runCatching {
        (app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).isLowRamDevice
    }.getOrDefault(false)

    private fun dashboardWire(state: FlroneUiState): Map<String, Any?> {
        val dashboard = state.dashboard
        val status = when {
            dashboard.status.transitioning && dashboard.status.statusText == "Stopping" -> "Stopping"
            dashboard.status.transitioning -> "Starting"
            dashboard.status.running -> "Started"
            else -> "Stopped"
        }
        // FlroneMode.get(), systemProxyAvailable() (serviceMode) and appendHttpProxy are each a
        // SettingsStore point query. pushState builds this on Main up to 1 Hz, so serve all three
        // from one snapshot (a single SELECT *) instead — same values, one query, consistent view.
        // The store's snapshot is thread-scoped, so an IO settings wire cannot observe these rows.
        val store = DataStore.configurationStore
        return store.withSnapshot(store.all()) {
            val selectedProfileId = FlroneBridge.catalog.selectedGroupId.takeIf { it > 0 } ?: -1
            val mode = FlroneMode.get().id
            // S7: stamp the version from the same values this map carries, so a probe answer can
            // never be attributed to a route other than the one beside it. The stamp moves when
            // the selection, the mode, the running session or any group's selected member moves,
            // and whenever a reload/route switch bumped it explicitly.
            val routeVersion = FlroneBridge.noteRoute(
                status = status,
                selectedProfileId = selectedProfileId,
                mode = mode,
                startedAt = dashboard.status.startedAt,
                groups = dashboard.groups,
            )
            mapOf(
                "status" to status,
                "selectedProfileId" to selectedProfileId,
                "selectedProfileName" to (dashboard.profile?.name ?: ""),
                "modes" to dashboard.modes,
                // Read the store instead of the cached copy: the cached mode only changes on a
                // catalog refresh, and between the switch tap and that refresh the dashboard would
                // otherwise emit the previous mode back to Dart and revert the chip highlight.
                "mode" to mode,
                "startedAt" to dashboard.status.startedAt,
                "uploadTotal" to dashboard.traffic.uploadTotal,
                "downloadTotal" to dashboard.traffic.downloadTotal,
                // S6: the count loop polls only the rows' length while the UI is visible and the
                // core is connected; the full ConnectionsSampler feed stays off until the page opens.
                "connections" to publishedConnectionCount(dashboard.status.running, connectionCount),
                "routeVersion" to routeVersion,
                "memory" to (dashboard.memory?.inUse ?: 0L),
                "goroutines" to 0,
                // Only the VPN service can hand its mixed inbound to apps as the system HTTP proxy.
                "systemProxyAvailable" to systemProxyAvailable(),
                "systemProxy" to DataStore.appendHttpProxy,
                "deprecated" to emptyList<Map<String, Any?>>(),
            )
        }
    }

    private fun profilesWire(state: FlroneUiState): List<Map<String, Any?>> =
        FlroneProfileWire.profiles(state.profiles)

    /**
     * The groups the UI renders. [withItems] is false until the Proxies screen asks for them; the
     * shaping itself lives in [FlroneGroupsWire] so the contract is unit-tested.
     */
    private fun groupsWire(state: FlroneUiState, withItems: Boolean): List<Map<String, Any?>> =
        FlroneGroupsWire.groups(state.dashboard.groups, withItems)

    /** The outbound picker's list: every node of every group, id and tag only. */
    private fun nodesWire(state: FlroneUiState): List<Map<String, Any?>> =
        FlroneGroupsWire.nodes(state.dashboard.groups)

    /**
     * The authoritative half of the settings map. ADR 0005 phase 2: the UI-only overlay keys
     * ([UI_ONLY_KEYS]) are Dart-owned now and layered on top by the UI on every read, so the host
     * no longer needs to carry them as authority. The legacy document is still folded in first for
     * bridge-mode compatibility and upgrades; the Dart overlay always wins over any stale copy.
     * Real Throne storage from [ThroneSettings] wins over the legacy document, then the derived and
     * read-only keys settle last. This wire is sent on `ready` and on every `settings` event — there
     * is no `settings.get` channel any more.
     */
    private fun settingsWire(): Map<String, Any?> {
        val result = LinkedHashMap<String, Any?>()
        // Legacy overlay layer: UiDocuments (Go-owned) with prefs fallback for bridge mode.
        result.putAll(UiDocuments.readUiSettings().ifEmpty { readJsonMap(SETTINGS_KEY) })
        result.putAll(ThroneSettings.read())
        result["fontSize"] = (result["fontSize"] as? Number)?.toInt() ?: 0
        result["perAppManaged"] = false
        result["perAppManagedList"] = emptyList<String>()
        result["batteryExempt"] = batteryExempt()
        return result
    }

    /**
     * Writes go to real Throne storage when [ThroneSettings] knows the key. ADR 0005 phase 2:
     * [UI_ONLY_KEYS] are rejected before reaching here (Dart owns them in `preferences`), so the
     * else branch only sees genuinely unknown keys, kept for backward compatibility. A key that
     * only applies on a process restart is remembered in [restartPending] so `ready` can tell the
     * UI to show the badge.
     */
    private fun applySettings(values: Map<String, Any?>) {
        val overlay = readJsonMap(SETTINGS_KEY).toMutableMap()
        values.forEach { (key, value) ->
            if (ThroneSettings.has(key)) {
                if (ThroneSettings.set(key, value) == Apply.AppRestart) restartPending = true
                // A typed DNS server joins its suggestion list (RouteProfileActivity's save does the same).
                when (key) {
                    "remoteDns" -> (value as? String)?.let(DnsServerHistory::rememberRemote)
                    "directDns" -> (value as? String)?.let(DnsServerHistory::rememberDirect)
                }
            } else {
                if (value == null) overlay.remove(key) else overlay[key] = value
            }
        }
        writeJsonMap(SETTINGS_KEY, overlay)
    }

    /**
     * One settings write plus the single read that answers both the caller and every other
     * listener: the map is computed once and both emitted and returned (previously
     * `applySettings` emitted one read and each caller read again, i.e. two full 158-key
     * passes per save).
     */
    private fun applyAndAnswerSettings(values: Map<String, Any?>): Map<String, Any?> {
        applySettings(values)
        val wire = settingsWire()
        // State lane: the settings document is a whole snapshot, and a listener that misses
        // it keeps rendering the pre-write values with no correction on the way.
        emit("settings", wire, EventPump.Lane.STATE)
        return wire
    }

    // ------------------------------------------------------------------------------------------------ JSON stores

    /** Preferences are one JSON document so bool, number, list and nested map types survive the round trip. */
    private fun writePreferences(values: Map<String, Any?>): Map<String, Any?> {
        val merged = readPreferences().toMutableMap()
        values.forEach { (key, value) ->
            if (value == null) merged.remove(key) else merged[key] = value
        }
        writeJsonMap(PREFERENCES_KEY, merged)
        // Boot guard (wave 4): the engine's 300 ms automatic start is gated on the launch marker,
        // and a tile/boot start holds no Flutter engine to read this document from. Mirror the one
        // preference to documents/boot_guard.json for BaseService (`BootGate.PREFERENCE_KEY` is
        // Dart's `BootGuard.preferenceKey`). Best effort: without the mirror the gate stays open,
        // which is exactly the pre-gate behaviour.
        if (!BootGate.mirror(BootGate.mirrorFile(activity.filesDir), merged[BootGate.PREFERENCE_KEY])) {
            Logs.w("preferences: could not mirror the boot marker")
        }
        // The app's light/dark choice lives in these prefs, but the native screens
        // that outlive Flutter (UpdateActivity, the notification's SwitchActivity)
        // are themed from DataStore.nightTheme, which nothing else writes. Mirror
        // the choice so those screens stop ignoring it.
        (values["theme"] as? String)?.let { theme ->
            val mode = when (theme) {
                "light" -> 2   // MODE_NIGHT_NO
                "dark" -> 1    // MODE_NIGHT_YES
                else -> 0      // MODE_NIGHT_FOLLOW_SYSTEM
            }
            if (DataStore.nightTheme != mode) DataStore.nightTheme = mode
        }
        return merged
    }

    private fun readPreferences(): Map<String, Any?> = readJsonMap(PREFERENCES_KEY)

    // ADR 0005 phases 1/4 -------------------------------------------------------------
    // The WebDAV account is one `webdavAccount` value in the preferences document,
    // written by Dart's WebDavAccountStore. These two helpers are the only native code
    // that touches it, and neither is an authority: one folds an upgrade's legacy Room
    // account into the document, the other mirrors the document value back to Room for
    // legacy compatibility. Phase 4's WebDAV transport is fully Dart-owned and no longer
    // reads those rows; the mirror is kept so older Throne code paths still see the account.

    /**
     * The preferences document as the UI sees it on `ready`. On an upgrade from a build
     * that kept the account in Room, fold that legacy value in once — only when no
     * Dart-owned value exists — so the account survives the move. Idempotent: after the
     * first fold the key is present and this is a plain read.
     */
    private fun preferencesWithLegacyWebDav(): Map<String, Any?> {
        val current = readPreferences()
        if (current.containsKey(WEBDAV_ACCOUNT_KEY)) return current
        val legacy = FlroneBackup.webdav() ?: return current
        val merged = current.toMutableMap()
        merged[WEBDAV_ACCOUNT_KEY] = legacy
        writeJsonMap(PREFERENCES_KEY, merged)
        return merged
    }

    /**
     * Preferences embedded in a backup's `flrone_ui` meta. The account carries a
     * password and is device-local (SettingsRegistry.DEVICE_LOCAL_KEYS): it must not
     * travel in a .thrbackup or a local JSON export, and a restore must not overwrite
     * this device's account. Kept out of the backup payload exactly as the Room rows
     * were filtered out of the settings table.
     */
    private fun readPreferencesForBackup(): Map<String, Any?> =
        readPreferences().filterKeys { it != WEBDAV_ACCOUNT_KEY }

    private fun readJsonMap(key: String): Map<String, Any?> {
        val stored = preferences.getString(key, null) ?: return emptyMap()
        return runCatching {
            when (val parsed = FlroneBackup.jsonToWire(JSONObject(stored))) {
                is Map<*, *> -> parsed.entries.associate { it.key.toString() to it.value }
                else -> emptyMap()
            }
        }.getOrDefault(emptyMap())
    }

    private fun writeJsonMap(key: String, values: Map<String, Any?>) {
        val json = JSONObject()
        values.forEach { (name, value) -> json.put(name, wireToJson(value)) }
        preferences.edit().putString(key, json.toString()).apply()
    }

    private fun wireToJson(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        JSONObject.NULL, is JSONObject, is JSONArray -> value
        is Boolean, is Number, is String -> value
        is Map<*, *> -> JSONObject(value.entries.associate { it.key.toString() to wireToJson(it.value) })
        is Collection<*> -> JSONArray(value.map(::wireToJson))
        is Array<*> -> JSONArray(value.map(::wireToJson))
        else -> value.toString()
    }

    private companion object {
        const val PREFERENCES_KEY = "value"
        const val SETTINGS_KEY = "settings"
        const val QUALITY_KEY = "ipQuality"
        // ADR 0005 phase 1: the WebDAV account lives under this key in the
        // preferences document; it is device-local and never goes into a backup.
        const val WEBDAV_ACCOUNT_KEY = "webdavAccount"
    }
}
