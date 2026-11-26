package io.nekohasekai.sagernet

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Truth table for the exported quick-toggle caller check. Each activity is `exported` so a
 * pinned launcher shortcut can start it, which also lets any app launch it; the Android half
 * resolves `getLaunchedFromPackage()` and the default HOME launcher and feeds them here. The
 * tunnel may flip only for our own package (widget), the system UI, or the current launcher.
 */
class ShortcutCallerTrustTest {

    private val own = "com.throneflclash"

    @Test
    fun `own package is trusted`() {
        assertTrue(ShortcutCallerTrust.isTrusted(own, own))
    }

    @Test
    fun `the resolved default HOME launcher is trusted`() {
        assertTrue(
            ShortcutCallerTrust.isTrusted(
                "com.google.android.apps.nexuslauncher", own,
                homePackages = setOf("com.google.android.apps.nexuslauncher"),
            )
        )
    }

    @Test
    fun `system UI is trusted`() {
        assertTrue(ShortcutCallerTrust.isTrusted("com.android.systemui", own))
        assertTrue(
            ShortcutCallerTrust.isTrusted(
                "com.samsung.android.systemui", own,
                systemUiPackages = ShortcutCallerTrust.SYSTEM_UI_PACKAGES,
            )
        )
    }

    @Test
    fun `an arbitrary app is refused`() {
        assertFalse(
            ShortcutCallerTrust.isTrusted(
                "com.evil.app", own,
                homePackages = setOf("com.google.android.apps.nexuslauncher"),
            )
        )
    }

    @Test
    fun `null or blank caller is refused`() {
        assertFalse(ShortcutCallerTrust.isTrusted(null, own))
        assertFalse(ShortcutCallerTrust.isTrusted("", own))
        assertFalse(ShortcutCallerTrust.isTrusted("   ", own))
    }

    @Test
    fun `a launcher change takes effect on the next launch`() {
        val oldLauncher = "com.old.launcher"
        val newLauncher = "com.new.launcher"
        assertFalse(
            ShortcutCallerTrust.isTrusted(oldLauncher, own, homePackages = setOf(newLauncher))
        )
        assertTrue(
            ShortcutCallerTrust.isTrusted(newLauncher, own, homePackages = setOf(newLauncher))
        )
    }
}
