package io.nekohasekai.sagernet.database

import android.os.Parcelable
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.ktx.app
import kotlinx.parcelize.IgnoredOnParcel
import kotlinx.parcelize.Parcelize

/**
 * The desktop's `groups` row (GroupsRepo.cpp:20-43) without `profiles_json` (membership and order live in
 * `profiles.gid` / `profiles.user_order`) and with `display_order` (the desktop's `groups_order` table flattened).
 * A group is a subscription iff [url] is not empty. [columnWidthJson] is desktop table state, stored opaque.
 */
@Parcelize
data class ProxyGroup(
    var id: Long = 0L,
    var archive: Boolean = false,
    var skipAutoUpdate: Boolean = false,
    var name: String = "",
    var url: String = "",
    /** The raw Subscription-UserInfo header of fetches before [subMetadata]; refreshes clear it. */
    var info: String = "",
    /** Epoch seconds. */
    var subLastUpdate: Long = 0L,
    /** Profile ids; -1 (or any id <= 0) = none. */
    var frontProxyId: Long = -1L,
    var landingProxyId: Long = -1L,
    var columnWidthJson: String = "",
    /** The first visible row of the list, -1 = top. */
    var scrollLastProfile: Int = -1,
    var autoClearUnavailable: Boolean = false,
    /** [TestBy] */
    var testSortBy: Int = 0,
    /** [TrafficBy] */
    var trafficSortBy: Int = 0,
    /** [TestShowItems] */
    var testItemsToShow: Int = 0,
    /** [TypeBy] */
    var typeSortBy: Int = 0,
    var subOptions: SubscriptionOptions = SubscriptionOptions(),
    /** The last fetch's [SubUserInfo]; read it through [subInfo]. */
    var subMetadata: SubUserInfo = SubUserInfo(),
    /** The [GroupSortMethod] ordinal the group is kept sorted by; read both through [sort]. */
    var sortMethod: Int = 0,
    var sortDescending: Boolean = false,
    var displayOrder: Long = 0L,
    /** The routing profile this group's profiles connect with; -1 (or a profile that is gone) follows the global one (Group.h). */
    var routeId: Long = -1L,
    /** Subscription refreshes save the routing profile the subscription provides as this group's own (Group.h). */
    var importSubRoute: Boolean = false,
) : Parcelable {

    /**
     * The single-node container (Throne's Default group).
     *
     * A document-only flag, not a stored column: the explicit marker replaced
     * matching the group by its localized default name, which broke whenever a
     * translation changed. Documents written before it existed fall back to the
     * name match, and the group is backfilled on the next write.
     */
    @IgnoredOnParcel
    var single: Boolean = false

    val isSubscription: Boolean get() = url.isNotEmpty()

    /** Group::sort, the order kept as the profiles change; RAW keeps the manual order (GroupsRepo.cpp groupFromJson). */
    val sort: GroupSortAction
        get() {
            val method = GroupSortMethod.of(sortMethod)
            return GroupSortAction(method, method != GroupSortMethod.RAW && sortDescending)
        }

    /** Group::SortReads: whether a change of [input] can move a row of the kept sort. */
    fun sortReads(input: SortInput): Boolean = GroupSort.reads(sort.method, input)

    /** Group::KeepsSorted. */
    fun keepsSorted(): Boolean = sortReads(SortInput.MEMBERSHIP)

    /** GroupsRepo.cpp:110-112: rows written before `sub_metadata_json` keep the raw header in [info]. */
    val subInfo: SubUserInfo
        get() = if (subMetadata.valid || info.isEmpty()) subMetadata else SubUserInfo.parseHeader(info)

    fun displayName(): String = name.takeIf { it.isNotBlank() } ?: app.getString(R.string.group_default_name)

    companion object {
        const val TABLE = "groups"
    }

}
