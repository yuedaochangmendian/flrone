package io.flrone.bridge

/**
 * The connections headline the dashboard wire publishes (S6).
 *
 * The count loop ([io.flrone.flutter.ThroneBoxBridge]) polls the core's list length while the
 * UI is visible and the service is connected. The wire asks this rule instead of reading the
 * field raw so a stopped service can never publish the last session's count: a stop that lands
 * between two polls would otherwise leave a stale number on the card for up to a tick.
 *
 * Pure JVM so the rule is pinned without an Android box.
 */
internal fun publishedConnectionCount(running: Boolean, counted: Int): Int =
    if (running) counted.coerceAtLeast(0) else 0
