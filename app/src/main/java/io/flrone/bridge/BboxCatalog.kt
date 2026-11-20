package io.flrone.bridge

import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.SubUserInfo
import io.nekohasekai.sagernet.bg.autoselector.AutoSelectorProfiles
import io.flrone.model.ProfileInfo
import io.flrone.model.ProxyGroup as UiGroup
import io.flrone.model.ProxyNode
import java.text.DateFormat
import java.util.Date

/**
 * Reads Throne's catalog and maps it onto the model B-box's screens render.
 *
 * The two data models are close but not the same shape. Throne's [ProxyGroup] is a tab that holds profiles, and its
 * subscription fields live on that tab; B-box's *profile* is the subscription and its *group* is the selector inside
 * it. So the mapping is:
 *
 * - a Throne group becomes a B-box group, its members become the group's nodes, and the selected profile is the
 *   group's selection;
 * - a subscription group also becomes a B-box profile card, carrying the quota and expiry of its last fetch.
 *
 * Nothing here writes: the catalog is a snapshot the bridge rebuilds after every change notification.
 */
object BboxCatalog {

    /** `Custom : Outbound("custom")`: the one type whose label depends on the row's own config. */
    private const val CUSTOM_TYPE = "custom"

    data class Catalog(
        val groups: List<UiGroup> = emptyList(),
        val profiles: List<ProfileInfo> = emptyList(),
        val current: ProfileInfo? = null,
        val totalNodes: Int = 0,
        /** The group holding the selected profile, which is what B-box calls the selected profile. */
        val selectedGroupId: Long = 0L,
    )

    /**
     * Resolves a profile's type label once per type.
     *
     * `ProxyEntity.displayType()` reads the row's outbound JSON (`outbound.displayType().ifEmpty { type }`),
     * and the label is a property of the outbound class, which `type` selects — so one row per type answers
     * for all of them. `custom` is the exception: its label comes from the config's own subtype and `type`,
     * so it is resolved per row.
     */
    internal class TypeLabels {
        private val labels = HashMap<String, String>()

        /** Outbound JSON reads this instance asked for; one per type, one per custom row. */
        var parses = 0
            private set

        fun of(type: String, resolve: () -> String): String {
            if (type == CUSTOM_TYPE) {
                parses++
                return resolve()
            }
            labels[type]?.let { return it }
            parses++
            return resolve().also { labels[type] = it }
        }
    }

    /** Blocking; call from an IO dispatcher. */
    fun load(): Catalog {
        val selected = DataStore.selectedProxy
        val groups = DartProfileStore.groups()
        // One read for every member instead of one query per group: `getByGroup` was called once
        // per group — G+1 queries, each a full `SELECT *` including the row's outbound JSON — on
        // every catalog refresh, which runs after every selection and every landed test result.
        // The Dart document reader returns all rows from one parse; the per-group order is restored
        // below with the columns the group index is keyed on.
        val allMembers = DartProfileStore.profiles()
        val byGroup = allMembers.groupBy { it.groupId }
        val entities = groups.map { group ->
            group to byGroup[group.id].orEmpty()
                .sortedWith(compareBy<ProxyEntity>({ it.userOrder }, { it.id }))
        }
        val labels = TypeLabels()
        // The selection is resolved in one pass: the old code re-scanned every group's members
        // three more times (selected name/id, the current profile's owning group, the selected
        // group), which is O(n²) over a large catalog.
        var selectedEntity: ProxyEntity? = null
        var selectedGroupId = 0L
        for ((group, members) in entities) {
            val hit = members.firstOrNull { it.id == selected } ?: continue
            selectedEntity = hit
            selectedGroupId = group.id
            break
        }
        val uiGroups = entities.map { (group, members) ->
            val isSelected = group.id == selectedGroupId
            UiGroup(
                id = group.id,
                tag = group.displayName(),
                type = if (group.isSubscription) "subscription" else "group",
                selected = if (isSelected) selectedEntity?.displayName().orEmpty() else "",
                selectedId = if (isSelected) selectedEntity?.id ?: 0L else 0L,
                selectable = true,
                nodes = members.map { node(it, labels) },
            )
        }
        // Every selectable group needs a profile card: B-box derives "can start" from selectedProfile, so a local
        // group that is not also a profile would leave a valid selection unable to start the service.
        val profiles = entities.map { (group, members) ->
            profileOf(group, members, selected)
        }
        val current = selectedEntity?.let { profile ->
            ProfileInfo(
                id = profile.id,
                name = profile.displayName(),
                type = profile.displayType(),
                subtitle = groups.firstOrNull { it.id == selectedGroupId }?.displayName()
                    ?.takeIf { it.isNotBlank() },
                selected = true,
            )
        }
        return Catalog(
            groups = uiGroups,
            profiles = profiles,
            current = current,
            // Summed per group, not `allMembers.size`: a profile whose gid names no existing
            // group was never counted before and must not appear in the dashboard total now.
            totalNodes = entities.sumOf { it.second.size },
            selectedGroupId = selectedGroupId,
        )
    }

    /**
     * One row of the catalog. The name comes from the column, not from `displayName()`, because the
     * latter parses the outbound JSON to answer a question the column already answers; the parse is
     * kept for the rare row whose name is empty, where the address is the only label there is.
     */
    private fun node(profile: ProxyEntity, labels: TypeLabels) = ProxyNode(
        id = profile.id,
        tag = profile.name?.takeIf { it.isNotEmpty() }
            ?: runCatching { profile.displayName() }.getOrDefault(""),
        // A row whose outbound cannot be parsed still renders, with its stored type as the label:
        // one bad row must not cost the whole catalog (the caller turns a throw into an empty list).
        type = runCatching { labels.of(profile.type) { profile.displayType() } }
            .getOrDefault(profile.type),
        delay = profile.latency,
        testedAt = profile.latencyAt * 1000L,
        isSelector = profile.type == AutoSelectorProfiles.TYPE,
    )

    private fun profileOf(group: ProxyGroup, members: List<ProxyEntity>, selected: Long): ProfileInfo {
        val info = group.subInfo
        val containsSelected = members.any { it.id == selected }
        return ProfileInfo(
            id = group.id,
            name = group.displayName(),
            type = if (group.isSubscription) "subscription" else "group",
            subtitle = subtitle(group, members),
            traffic = if (group.isSubscription) trafficOf(info) else null,
            expiry = if (group.isSubscription) expiryOf(info) else null,
            selected = containsSelected,
            url = group.url.orEmpty(),
            updatedAt = group.subLastUpdate * 1000L,
            autoUpdate = !group.skipAutoUpdate,
            interval = group.subOptions.updateInterval,
        )
    }

    private fun subtitle(group: ProxyGroup, members: List<ProxyEntity>): String {
        val host = runCatching { java.net.URI(group.url).host }.getOrNull()
        val count = "${members.size} nodes"
        return listOfNotNull(host?.takeIf { it.isNotBlank() }, count).joinToString(" · ")
    }

    /** "12.3 GB / 100 GB" or the used figure when the provider gave no quota. */
    fun trafficOf(info: SubUserInfo): String? {
        if (!info.valid) return null
        val used = formatBytes(info.used)
        return if (info.hasQuota && info.total > 0) "$used / ${formatBytes(info.total)}" else used
    }

    fun expiryOf(info: SubUserInfo): String? {
        if (!info.valid || info.expire <= 0L) return null
        val date = DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(info.expire * 1000L))
        return if (info.isExpired()) "Expired $date" else "Until $date"
    }

    fun formatBytes(bytes: Long): String {
        if (bytes <= 0L) return "0 B"
        val units = arrayOf("B", "KB", "MB", "GB", "TB", "PB")
        var value = bytes.toDouble()
        var unit = 0
        while (value >= 1024 && unit < units.lastIndex) {
            value /= 1024
            unit++
        }
        return if (unit == 0) "${value.toLong()} ${units[unit]}" else String.format("%.1f %s", value, units[unit])
    }
}
