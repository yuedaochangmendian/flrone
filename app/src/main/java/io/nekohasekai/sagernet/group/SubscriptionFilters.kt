package io.nekohasekai.sagernet.group

import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.bg.ProfileValidator
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.GroupSort
import io.nekohasekai.sagernet.database.GroupSortAction
import io.nekohasekai.sagernet.database.GroupSortMethod
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.StoredProfile
import io.nekohasekai.sagernet.database.SubscriptionOptions
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app

/** The post-update filters (GroupUpdater.cpp:183-296): duplicates, insecure nodes and unavailable rows. */
internal object SubscriptionFilters {

    /** [deleted] ids and the report sections to append to the change text; [ok] is false after a database error. */
    class Outcome(
        @JvmField val deleted: List<Long>,
        @JvmField val report: String,
        @JvmField val stopped: ProxyEntity? = null,
        @JvmField val ok: Boolean = true,
    )

    private val NONE = Outcome(emptyList(), "")

    /** Rows written per transaction. */
    private const val WRITE_CHUNK = 500

    /**
     * removeFlagged (GroupUpdater.cpp:208-264): each profile is listed under the first enabled action that claims it.
     * The [members] are loaded only when an action is enabled.
     */
    suspend fun removeFlagged(gid: Long, options: SubscriptionOptions, members: () -> List<ProxyEntity>): Outcome {
        if (!options.removeDuplicates && !options.removeInsecure && !options.removeInvalid) return NONE

        val profiles = members()
        val flagged = HashSet<Long>()
        val doomed = ArrayList<Long>()
        val sections = StringBuilder()
        fun claim(heading: Int, matches: (ProxyEntity) -> Boolean) {
            val names = ArrayList<String>()
            for (profile in profiles) {
                if (profile.id in flagged || !matches(profile)) continue
                flagged.add(profile.id)
                doomed.add(profile.id)
                names.add(StoredProfile.displayTypeAndName(profile.name, profile.type, profile.outboundJson))
            }
            if (names.isNotEmpty()) {
                sections.append('\n').append(app.getString(heading, names.size)).append('\n')
                    .append(SubscriptionRefresh.notice(names, "[-]", "removed"))
            }
        }

        if (options.removeDuplicates) {
            // ProfileFilter::Uniq with keep_last=false: the first profile of each key survives.
            val keys = HashSet<String>()
            val keep = HashSet<Long>()
            for (profile in profiles) {
                if (keys.add(StoredProfile.dedupKey(profile.type, profile.outboundJson))) keep.add(profile.id)
            }
            claim(R.string.subs_removed_duplicates) { it.id !in keep }
        }
        if (options.removeInsecure) {
            val skipCert = DataStore.skipCert
            claim(R.string.subs_removed_insecure) {
                StoredProfile.security(it.type, it.outboundJson, skipCert).insecure
            }
        }
        if (options.removeInvalid) {
            val scan = ProfileValidator.findInvalid(profiles.filter { it.id !in flagged })
            // Every check fails while the core is down: deleting on that verdict would empty the group.
            if (scan.coreUnreachable) {
                Logs.w(app.getString(R.string.subs_invalid_core_unreachable))
            } else {
                claim(R.string.subs_removed_invalid) { it.id in scan.invalid }
            }
        }

        if (doomed.isEmpty()) return NONE
        val outcome = ProfileManager.batchDeleteProfiles(doomed)
        if (!outcome.ok) SubscriptionRefresh.dbError(gid)
        if (outcome.kept.isNotEmpty()) sections.append('\n').append(app.getString(R.string.subs_running_kept))
        return Outcome(outcome.deleted, sections.toString(), outcome.stopped, outcome.ok)
    }

    /** removeUnavailableAndSort (GroupUpdater.cpp:266-296): the follow-ups of the subscription's URL test. */
    suspend fun removeUnavailableAndSort(group: ProxyGroup, options: SubscriptionOptions): Outcome {
        var deleted: List<Long> = emptyList()
        val report = StringBuilder()
        if (options.removeUnavailable) {
            val doomed = ArrayList<Long>()
            val names = ArrayList<String>()
            for (profile in ProfileManager.members(group.id)) {
                if (profile.type == SubscriptionRefresh.AUTOSELECTOR || !profile.isUnavailable()) continue
                doomed.add(profile.id)
                names.add(StoredProfile.displayTypeAndName(profile.name, profile.type, profile.outboundJson))
            }
            if (doomed.isNotEmpty()) {
                val outcome = ProfileManager.batchDeleteProfiles(doomed)
                if (!outcome.ok) SubscriptionRefresh.dbError(group.id)
                deleted = outcome.deleted
                report.append('\n').append(app.getString(R.string.subs_removed_unavailable, names.size)).append('\n')
                    .append(SubscriptionRefresh.notice(names, "[-]", "removed"))
                if (outcome.kept.isNotEmpty()) report.append('\n').append(app.getString(R.string.subs_running_kept))
            }
        }
        if (options.sortByLatency && !GroupSort.sortProfiles(group.id, GroupSortAction(GroupSortMethod.BY_LATENCY))) {
            Logs.i(app.getString(R.string.subs_sort_skipped, group.name))
        }
        return Outcome(deleted, report.toString())
    }

    }
