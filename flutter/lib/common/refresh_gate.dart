import 'package:flutter/foundation.dart';

/// Visibility gate for high-frequency refresh work.
///
/// Bettbox's `DashboardRefreshManager` stops ticking when the window is hidden
/// or the dashboard is not on screen. This is the mobile equivalent: when the
/// app is backgrounded the data keeps arriving from the Kotlin side, but the
/// UI is not rebuilt for every push. The pending aspects are replayed once on
/// resume, so nothing is stale when the user comes back.
///
/// This used to also run a 1 s `Timer.periodic` advancing three `ValueNotifier`
/// counters (`tick1s`/`tick2s`/`tick5s`) for consumers that wanted a time base.
/// Nothing ever listened to them — `grep` found only the declarations and the
/// increments — so the timer woke the process every second for the whole session
/// and produced nothing. The gate is now just the foreground/predicate check,
/// which is all any caller ever used.
class RefreshGate extends ChangeNotifier {
  RefreshGate({bool Function()? pageIsDashboard})
      : pageIsDashboard = pageIsDashboard ?? _alwaysDashboard;

  static bool _alwaysDashboard() => true;

  /// The host page reports whether a dashboard-grade refresh is meaningful.
  final bool Function() pageIsDashboard;

  bool _foreground = true;

  bool get foreground => _foreground;

  /// Whether a high-frequency event should rebuild widgets right now.
  bool get shouldRebuild => _foreground && pageIsDashboard();

  /// Called by the app's `WidgetsBindingObserver` on lifecycle changes.
  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    notifyListeners();
  }
}
