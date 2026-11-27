package io.nekohasekai.sagernet.bg.proto

/**
 * The core working-directory paths the config and its post-start duties share.
 * They used to live on ConfigGenerator; the generator is gone, the paths are not.
 */
object CorePaths {
    /** The api service's `dashboard.path`, relative to the core's working dir. */
    const val DASHBOARD_PATH = "sb-dashboard"

    /** The empty binary rule-set a deferred start begins uncached sets with. */
    const val EMPTY_RULE_SET_PATH = "empty-rule-set.srs"
}
