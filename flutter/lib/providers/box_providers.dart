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
