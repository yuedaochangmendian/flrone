import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../box.dart';
import '../components/connectivity/connectivity_store.dart';

/// The single [BoxController] the app already owns (created in `main`).
///
/// It is injected with `overrideWithValue` at the root; reading it without
/// that override is a programming error, not a fallback. The pilot only ever
/// *reads* this provider — writes keep going through the controller's own API
/// (`context.box.*`), so Riverpod never becomes a second writer to reconcile.
final boxControllerProvider =
    Provider<BoxController>((ref) => throw UnimplementedError('overridden in main'));

/// Exposes the process-wide [ConnectivityStore] singleton.
///
/// The store is already a [ChangeNotifier] and the single source of truth for
/// probe state. A plain [Provider] is used deliberately over
/// `ChangeNotifierProvider`: Riverpod disposes a `ChangeNotifierProvider`'s
/// notifier when its scope goes away, which would kill this app-wide singleton.
/// Consumers `ref.watch` this provider for the instance, and subscribe to the
/// store's own notifications with a `ListenableBuilder`/`AnimatedBuilder` so
/// rebuilds come from the store itself — there is no second copy to keep in
/// sync and nothing is ever written back to Riverpod.
final connectivityStoreProvider = Provider<ConnectivityStore>((ref) {
  return ConnectivityStore.instance;
});

/// One-way notification bridge from the app-owned [BoxController] into Riverpod.
///
/// [BoxController] is a [ChangeNotifier], but a plain [Provider] does not
/// rebuild when its value notifies. We deliberately do **not** turn
/// `boxControllerProvider` into a `ChangeNotifierProvider`: Riverpod owns and
/// disposes that notifier, while the controller is owned (and disposed) by
/// `BoxApp`. Instead this tiny notifier only forwards `stateChanges` — the
/// aspect that covers settings and preferences — so derived providers can
/// re-read fresh values from the controller. It holds no data of its own: the
/// bridge is a notification, never a second source of truth, and nothing is
/// ever written back through it.
final boxStateChangesProvider = ChangeNotifierProvider<ChangeNotifier>((ref) {
  final box = ref.watch(boxControllerProvider);
  return _BoxStateChangesBridge(box.stateChanges);
});

class _BoxStateChangesBridge extends ChangeNotifier {
  _BoxStateChangesBridge(this._source) {
    _source.addListener(_onChanged);
  }

  final Listenable _source;

  void _onChanged() => notifyListeners();

  // ChangeNotifierProvider calls dispose() on its notifier; remove our source
  // subscription there. Never dispose the source — the controller owns itself.
  @override
  void dispose() {
    _source.removeListener(_onChanged);
    super.dispose();
  }
}

/// The merged settings map, read fresh from [BoxController] on every rebuild.
///
/// The controller recomputes `settings` as `mergeSettings(host, preferences)`
/// on each read (ADR 0005 phase 2), so a cached whole-map copy would mask a
/// fresh host snapshot. Watching [boxStateChangesProvider] invalidates this
/// provider whenever settings/preferences change; the value itself is always
/// re-read from the controller. Writes stay on `context.box.setSetting()`.
final settingsProvider = Provider<Json>((ref) {
  ref.watch(boxStateChangesProvider);
  return ref.watch(boxControllerProvider).settings;
});

/// The preferences overlay, read fresh from [BoxController] on every rebuild.
///
/// Same one-way bridge and no-cache rule as [settingsProvider]. Appearance
/// reads this instead of `context.box.preferences`; writes stay on
/// `context.box.setPreference(s)`.
final preferencesProvider = Provider<Json>((ref) {
  ref.watch(boxStateChangesProvider);
  return ref.watch(boxControllerProvider).preferences;
});
