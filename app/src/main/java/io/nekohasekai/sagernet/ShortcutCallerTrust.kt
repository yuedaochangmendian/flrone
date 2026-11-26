package io.nekohasekai.sagernet

/**
 * The caller-trust predicate for the exported quick-toggle activities.
 *
 * Those activities are `exported="true"` and take no permission because they are the targets
 * of *pinned launcher shortcuts* and of our own widget PendingIntents — a permission gate would
 * break both. They do flip the VPN, so an arbitrary app must not be able to launch them.
 *
 * The Android half (see [ShortcutCallerGuard]) resolves the caller with
 * `Activity.getLaunchedFromPackage()` and computes the set of trusted packages: our own package
 * (widget / in-app), the system UI, and the resolved default HOME launcher. This object is the
 * pure decision, free of Android classes, so a JVM test can pin the truth table.
 *
 * Limitation: `getLaunchedFromPackage()` reports the *immediate* launching package. A launcher
 * that delegates through a trusted intermediary (a third-party "smart launcher" trampoline)
 * will be refused; that is the conservative direction. The HOME resolution is done per launch,
 * so a launcher change takes effect on the next tap without a restart. Android does not expose
 * a cryptographic "this intent came from a pinned shortcut" token to the target activity, so
 * caller-package trust is the strongest check available that still keeps pinned shortcuts live
 * on API 24-35.
 */
internal object ShortcutCallerTrust {

    /** Packages that ship as the system UI on stock and common OEM ROMs. */
    val SYSTEM_UI_PACKAGES = setOf(
        "com.android.systemui",
        "com.samsung.android.systemui",
        "com.oneplus.systemui",
    )

    /**
     * Whether [caller] may toggle the VPN. [ownPackage] is always trusted (widget/in-app).
     * A caller of `null` is untrusted: an unknown origin must never flip the tunnel.
     */
    fun isTrusted(
        caller: String?,
        ownPackage: String,
        homePackages: Collection<String> = emptyList(),
        systemUiPackages: Collection<String> = SYSTEM_UI_PACKAGES,
    ): Boolean {
        if (caller.isNullOrBlank()) return false
        if (caller == ownPackage) return true
        if (caller in systemUiPackages) return true
        return caller in homePackages
    }
}
