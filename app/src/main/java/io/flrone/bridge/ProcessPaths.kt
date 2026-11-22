package io.flrone.bridge

/**
 * Path -> package for the connections page's process lookup.
 *
 * Pure (Android-free) on purpose: the APK path is the only input, so the parsing rules can be
 * exercised by a JVM test. Anything that needs the package manager (sourceDir/publicSourceDir
 * matching, label/icon resolution) stays in [BboxApps].
 */
object ProcessPaths {

    private val packageName = Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")

    /**
     * The package an APK path belongs to, or null when the path is not an installed app's APK.
     *
     * User installs live under `/data/app/~~<hash>/<pkg>-<suffix>/base.apk` (Android 10+) or
     * `/data/app/<pkg>-<suffix>/base.apk` (older). System apps live under a partition's `app` or
     * `priv-app` directory; there the directory name is sometimes a package and sometimes just a
     * label, so it is accepted only when it actually looks like a package name.
     */
    fun packageFromApkPath(path: String?): String? {
        if (path.isNullOrBlank()) return null
        val segments = path.split('/').filter { it.isNotEmpty() }
        if (segments.isEmpty()) return null
        val file = segments.last()
        // Only APK files are processes we can attribute; a raw shared-library path is not an app.
        if (!file.endsWith(".apk", ignoreCase = true)) return null

        // /data/app/~~<hash>/<pkg>-<suffix>/base.apk  |  /data/app/<pkg>-<suffix>/base.apk
        if (segments.first() == "data" && segments.getOrNull(1) == "app") {
            val dir = segments.getOrNull(2)?.let { if (it.startsWith("~~")) segments.getOrNull(3) else it }
                ?: return null
            return stripInstallSuffix(dir)?.takeIf(::looksLikePackage)
        }

        // /system/app/<pkg>/<pkg>.apk, /product/priv-app/<pkg>/…, /vendor/app/<pkg>/…, etc.
        if (segments.size >= 4 && segments[0] in systemPartitions &&
            (segments[1] == "app" || segments[1] == "priv-app" || segments[1] == "privapp")
        ) {
            return segments[2].takeIf(::looksLikePackage)
        }
        return null
    }

    private val systemPartitions = setOf("system", "product", "vendor", "odm", "system_ext", "apex")

    /** `com.example-abc123` -> `com.example`; the suffix is the install id, never part of a package. */
    private fun stripInstallSuffix(dir: String): String? {
        val dash = dir.lastIndexOf('-')
        return if (dash > 0) dir.substring(0, dash) else dir
    }

    private fun looksLikePackage(value: String) = packageName.matches(value)
}
