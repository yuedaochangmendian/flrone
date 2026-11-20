package io.flrone.bridge

import android.content.Context
import io.nekohasekai.sagernet.aidl.TrafficData
import io.nekohasekai.sagernet.bg.BaseService
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.GroupRepo
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.ktx.Logs
import moe.matsuri.nb4a.utils.CoreLog
import io.flrone.model.BboxStatus
import io.flrone.model.BboxUiState
import io.flrone.model.DashboardState
import io.flrone.model.MemoryInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * The bridge between Throne's backend and the ported B-box UI.
 *
 * Throne spreads its state over three places: the preference store (`selectedProxy`, the service state mirror), the
 * profile and group repositories, and the routing profile. The old UI read each of them where it needed them, from a
 * fragment that also owned the service connection. This object replaces that: service state changes arrive in process
 * from [BaseService] (see [onServiceState]), the rest are mirrored into a single immutable [BboxUiState], and the UI is
 * handed a snapshot to render.
 *
 * Writes go the other way through [BboxCommands], which keeps the UI free of `SagerNet` and database calls.
 */
object BboxBridge : GroupRepo.Listener, ProfileManager.Listener {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /**
     * Same-process service state notifications. Service + UI share one process, so
     * [BaseService.Data.changeState] and [BaseService.Interface.switchProfile] call this straight
     * into the bridge — there is no AIDL/SagerConnection path. This is BboxBridge's own
     * state-publishing listener: the state itself is read from [DataStore].
     */
    fun onServiceState(state: BaseService.State, profileName: String?, msg: String?) {
        // DataStore mirrors the state synchronously (changeState already wrote it); scope is
        // Main.immediate, so launching here keeps a main-thread callback contract whether
        // changeState came from main or a receiver.
        DataStore.serviceState = state
        scope.launch {
            lastProfileName = profileName.orEmpty()
            // The service state is the other half of a restart loop: the core closing on its own and
            // the service bouncing are indistinguishable from the outside. One line per transition,
            // in the same file the log screen tails, makes the sequence readable after the fact.
            runCatching { CoreLog.write("[service] state -> $state${if (msg.isNullOrEmpty()) "" else " ($msg)"}") }
            when (state) {
                BaseService.State.Connected -> if (connectedAt == null) connectedAt = System.currentTimeMillis()
                // A start invalidates the exit the previous session reported; a stop makes the direct answer stale.
                BaseService.State.Connecting, BaseService.State.Stopping -> BboxEgress.invalidate()
                BaseService.State.Stopped, BaseService.State.Idle -> {
                    connectedAt = null
                    meter.reset()
                    BboxEgress.invalidate()
                }
                else -> Unit
            }
            scheduleRefresh(immediate = true)
        }
    }

    /** The selected profile changed in the service; mirror it into the shared preference store. */
    fun onSelectedProfile(profileId: Long) {
        DataStore.selectedProxy = profileId
        DataStore.currentProfile = profileId
        scheduleRefresh()
    }

    private val _state = MutableStateFlow(BboxUiState())
    val state: StateFlow<BboxUiState> = _state.asStateFlow()

    val meter = BboxTrafficMeter()

    /** The catalog as last read; the Flutter host needs the selected group, which the UI state does not carry. */
    @Volatile
    var catalog: BboxCatalog.Catalog = BboxCatalog.Catalog()
        private set

    /**
     * Moves every time the catalog is re-read. The bridge rebuilds the profile and node rows only
     * when this moves, instead of on every one-second rates sample.
     */
    @Volatile
    var catalogRevision: Long = 0L
        private set

    private var ticker: Job? = null
    private var refreshJob: Job? = null

    /** When the running service reached [BaseService.State.Connected], for the dashboard's run time. */
    private var connectedAt: Long? = null

    private var lastProfileName: String = ""

    @Volatile
    private var installed = false

    fun install(context: Context) {
        if (installed) return
        installed = true
        // ADR 0005 final stage: the first catalog refresh below reads the
        // Dart-owned profiles document, and this is the earliest point in the
        // process where that directory is knowable. Waiting for Dart's
        // `data.path`/`data.documents` calls left a window: a refresh that won
        // the race read no document, cached an empty catalog, and — because the
        // later handlers only set the directory — nothing re-read it, so the
        // profiles screen stayed empty until an unrelated profile write. The
        // handlers set the same path again; the setter drops the parse cache,
        // so the redundant assignment is harmless.
        DartProfileStore.directory = File(context.filesDir, "documents")
        GroupRepo.addListener(this)
        ProfileManager.addListener(this)
        // Service + UI are one process: state changes reach onServiceState directly from
        // BaseService, and the current state/profile are read from DataStore. No binder needed.
        DataStore.baseService?.let { service ->
            onServiceState(service.data.state, service.data.runningProfileName.ifEmpty { null }, null)
        }
        ticker = scope.launch {
            while (isActive) {
                // SupervisorJob does not restart a dead child, so one throw here froze the
                // speed/memory/uptime readout for the rest of the process with no log line
                // (publishRuntime reads Runtime and rebuilds MemoryInfo). Keep the beat going.
                try {
                    publishRuntime()
                } catch (e: Throwable) {
                    Logs.w(e)
                }
                delay(1000)
            }
        }
        scheduleRefresh(immediate = true)
    }

    fun shutdown() {
        if (!installed) return
        installed = false
        GroupRepo.removeListener(this)
        ProfileManager.removeListener(this)
        ticker?.cancel()
        ticker = null
        refreshJob?.cancel()
        refreshJob = null
    }

    // ------------------------------------------------------------------------------------------------ repository callbacks

    override suspend fun groupAdd(group: ProxyGroup) = scheduleRefresh()

    override suspend fun groupUpdated(group: ProxyGroup) = scheduleRefresh()

    override suspend fun groupUpdated(groupId: Long) = scheduleRefresh()

    override suspend fun groupRemoved(groupId: Long) = scheduleRefresh()

    override suspend fun groupsReordered() = scheduleRefresh()

    override suspend fun onAdd(profile: ProxyEntity) = scheduleRefresh()

    override suspend fun onUpdated(data: List<TrafficData>) = Unit

    override suspend fun onUpdated(profile: ProxyEntity, noTraffic: Boolean) = scheduleRefresh()

    override suspend fun onRemoved(groupId: Long, profileId: Long) = scheduleRefresh()

    // ------------------------------------------------------------------------------------------------ state assembly

    /** Debounces bursts of change notifications into one catalog read.
     *  If a change arrives while a refresh is in flight, a trailing refresh is
     *  scheduled so no update is silently dropped. */
    @Volatile
    private var refreshDirty = false

    fun scheduleRefresh(immediate: Boolean = false) {
        if (refreshJob?.isActive == true) {
            refreshDirty = true
            return
        }
        refreshJob = scope.launch {
            if (!immediate) delay(150)
            refreshNow()
            // Drain any changes that landed while the previous refresh was reading the DB.
            while (refreshDirty) {
                refreshDirty = false
                refreshNow()
            }
        }
    }

    private suspend fun refreshNow() {
        // ADR 0005 final stage: Dart is the sole writer of profiles/groups and
        // the document is the read authority. There is no Room -> document
        // publish here any more — every write handler updates the document
        // directly, so a refresh only reloads the catalog from DartProfileStore.
        val loaded = withContext(Dispatchers.IO) {
            runCatching { BboxCatalog.load() }.getOrElse {
                Logs.w(it)
                BboxCatalog.Catalog()
            }
        }
        catalog = loaded
        catalogRevision++
        _state.update { current ->
            current.copy(
                profiles = loaded.profiles,
                totalNodes = loaded.totalNodes,
                dashboard = current.dashboard.copy(
                    groups = loaded.groups,
                    profile = loaded.current,
                    modes = BboxMode.modes,
                    mode = BboxMode.get().id,
                ),
            )
        }
        publishRuntime()
    }

    /** Recomputes the cheap parts every second: status, speed, run time and memory. */
    private fun publishRuntime() {
        val state = DataStore.serviceState
        val traffic = meter.traffic.value
        val runtime = Runtime.getRuntime()
        val used = runtime.totalMemory() - runtime.freeMemory()
        val startedAt = connectedAt
        catalog = catalog
        _state.update { current ->
            current.copy(
                dashboard = current.dashboard.copy(
                    status = BboxStatus(
                        running = state.connected,
                        transitioning = state == BaseService.State.Connecting || state == BaseService.State.Stopping,
                        statusText = when (state) {
                            BaseService.State.Connected -> "Running"
                            BaseService.State.Connecting -> "Connecting"
                            BaseService.State.Stopping -> "Stopping"
                            else -> "Not running"
                        },
                        startedAt = startedAt,
                        remote = false,
                    ),
                    traffic = traffic,
                    memory = MemoryInfo(inUse = used, total = runtime.maxMemory()),
                ),
            )
        }
    }

    /** The name the service reports for the running profile, for the status card's subtitle. */
    fun runningProfileName(): String = lastProfileName
}
