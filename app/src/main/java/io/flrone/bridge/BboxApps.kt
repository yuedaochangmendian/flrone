package io.flrone.bridge

import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.util.LruCache
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.utils.PackageCache
import java.io.ByteArrayOutputStream

/**
 * The installed applications, for the ported UI's access-control screen.
 *
 * This reads Throne's own package cache rather than asking the package manager again, so the list is the one the rest
 * of the app already uses: same row set, same install-time filtering, and a refresh that recomputes it exactly once
 * however many times the UI asks. The screen needs three things Throne's original picker carried implicitly — a label,
 * whether an app can reach the network at all, and whether it is part of the system — so those are resolved here.
 */
object BboxApps {

    data class App(
        val packageName: String,
        val name: String,
        val internet: Boolean,
        val system: Boolean,
        val updatedAt: Long,
    ) {
        /** `apps.list`'s row shape; `package` is the key the UI filters and stores by. */
        fun wire(): Map<String, Any?> = mapOf(
            "package" to packageName,
            "name" to name,
            "internet" to internet,
            "system" to system,
            "updatedAt" to updatedAt,
        )
    }

    /** Install broadcasting is a process-wide registration; doing it here keeps reads cheap wherever they come from. */
    private fun ensureRegistered() = runCatching { PackageCache.register() }.onFailure { Logs.w(it) }

    /**
     * The catalog as the screen wants it. [refresh] recomputes from the package manager, [system] admits system apps
     * and [nonInternet] admits apps that hold no network permission — Throne's own picker excluded both, which is why
     * the UI can ask for narrower sets without filtering anything itself.
     */
    suspend fun list(refresh: Boolean, system: Boolean, nonInternet: Boolean): List<App> {
        ensureRegistered()
        val snapshot = if (refresh) PackageCache.reload() else PackageCache.snapshot()
        // Both answers come from the listing PackageCache already read: `installedPackages` is
        // built from getInstalledPackages(GET_PERMISSIONS) and filtered to the apps that hold
        // INTERNET, so an entry there *is* the permission answer and it carries lastUpdateTime.
        // Asking the package manager per app cost two binder round trips each — about 300 for a
        // 150-app device, on every list and every rescan.
        val permitted = snapshot.installedPackages
        return snapshot.installedApps.entries.mapNotNull { (packageName, info) ->
            val isSystem = info.flags and ApplicationInfo.FLAG_SYSTEM != 0
            if (isSystem && !system) return@mapNotNull null
            val declared = permitted[packageName]
            // "android" is the one row the cache keeps unconditionally, and it does hold INTERNET.
            val internet = declared != null
            if (!internet && !nonInternet) return@mapNotNull null
            App(
                packageName = packageName,
                name = snapshot.loadLabel(packageName),
                internet = internet,
                system = isSystem,
                updatedAt = declared?.lastUpdateTime ?: 0L,
            )
        }.sortedBy { it.name.lowercase() }
    }

    /**
     * Icon PNGs keyed by `package@lastUpdateTime`, so the access list scrolling back over a
     * package does not resolve the drawable and re-compress a 96 px PNG per request. Bounded by
     * byte size (a few MiB at worst); an app update changes the key and the old entry ages out.
     */
    private val iconCache = object : LruCache<String, ByteArray>(4 * 1024 * 1024) {
        override fun sizeOf(key: String, value: ByteArray): Int = value.size
    }

    /** The launcher icon as PNG bytes for Flutter; null when the app ships none. */
    fun icon(packageName: String): ByteArray? {
        ensureRegistered()
        val snapshot = PackageCache.snapshot()
        val info = snapshot.installedApps[packageName] ?: return null
        val key = "$packageName@${snapshot.installedPackages[packageName]?.lastUpdateTime ?: 0L}"
        iconCache.get(key)?.let { return it }
        val drawable = runCatching { info.loadIcon(app.packageManager) }.getOrNull() ?: return null
        return runCatching {
            val bitmap = drawable.toBitmap()
            ByteArrayOutputStream().use { out ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                out.toByteArray().also { iconCache.put(key, it) }
            }
        }.onFailure { Logs.w(it) }.getOrNull()
    }

    /** Flutter gets the launcher icon's own transparency, without a white or masked surround. */
    private fun Drawable.toBitmap(size: Int = 96): Bitmap {
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        setBounds(0, 0, size, size)
        draw(canvas)
        return bitmap
    }
}
