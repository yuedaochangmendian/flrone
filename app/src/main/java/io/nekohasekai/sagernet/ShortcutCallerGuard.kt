package io.nekohasekai.sagernet

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

/**
 * Android half of the exported-shortcut caller check. Resolves the launching package and the
 * default HOME launcher, then delegates the decision to the pure [ShortcutCallerTrust].
 *
 * `getLaunchedFromPackage()` exists since API 23 (our minSdk is 24) and reports the package
 * that started the activity — for a pinned shortcut that is the launcher, for our widget's
 * PendingIntent it is this app. The HOME launcher is resolved fresh per launch so a launcher
 * change is honoured without an app restart. `ACTION_CREATE_SHORTCUT` is exempt: that is the
 * launcher asking us to *create* a shortcut, not to toggle anything.
 */
internal object ShortcutCallerGuard {

    /** True when the caller may cause a VPN toggle; activities must finish without acting otherwise. */
    fun isTrustedCaller(activity: Activity): Boolean {
        if (activity.intent?.action == Intent.ACTION_CREATE_SHORTCUT) return true
        val caller = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) activity.launchedFromPackage else null
        }.getOrNull()
        val home = resolveHomeLauncherPackages(activity.packageManager)
        return ShortcutCallerTrust.isTrusted(caller, activity.packageName, home)
    }

    private fun resolveHomeLauncherPackages(pm: PackageManager): Set<String> {
        val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PackageManager.MATCH_DEFAULT_ONLY or PackageManager.GET_RESOLVED_FILTER
        } else {
            PackageManager.MATCH_DEFAULT_ONLY
        }
        return runCatching {
            pm.resolveActivity(home, flags)?.activityInfo?.packageName
                ?.let { setOf(it) }
                ?: emptySet()
        }.getOrDefault(emptySet())
    }
}
