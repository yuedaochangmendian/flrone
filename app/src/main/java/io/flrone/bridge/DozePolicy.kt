package io.flrone.bridge

/**
 * Pure policy for device doze. Kept free of Android APIs so the truth table can
 * be pinned by a JVM test: the host reads screen/idle facts from PowerManager
 * and asks this object whether the instance should be paused.
 *
 * Doze requires BOTH conditions — the screen off (not merely the app
 * backgrounded) and the device in idle maintenance. A screen-off alone is the
 * ordinary app-backgrounding hint handled by setScreenOff (auto-selector only);
 * pausing there would starve auto-selector/URLTest/WireGuard periodic recovery.
 */
object DozePolicy {
    @JvmStatic
    fun shouldDoze(screenOn: Boolean, idle: Boolean): Boolean = !screenOn && idle
}
