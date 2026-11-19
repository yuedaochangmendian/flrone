import 'dart:async';

import 'package:flrone/components/connectivity/connectivity_page.dart';
import 'package:flrone/components/connectivity/connectivity_store.dart';
import 'package:flrone/main.dart';
import 'package:flrone/pages/settings.dart';
import 'package:flrone/providers/box_providers.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('boxControllerProvider is injected via override, not a second instance', () {
    final box = BoxController();
    final container = ProviderContainer(
      overrides: [boxControllerProvider.overrideWithValue(box)],
    );
    addTearDown(container.dispose);
    addTearDown(box.dispose);

    expect(container.read(boxControllerProvider), same(box));
    expect(container.read(boxControllerProvider), same(container.read(boxControllerProvider)));
  });

  test('boxControllerProvider throws without an override (no silent fallback)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(() => container.read(boxControllerProvider), throwsA(isA<UnimplementedError>()));
  });

  test('connectivityStoreProvider returns the one store instance', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(connectivityStoreProvider), same(ConnectivityStore.instance));
    expect(container.read(connectivityStoreProvider), same(ConnectivityStore.instance));
  });

  testWidgets('ConnectivityPage rebuilds when the watched store notifies', (tester) async {
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.providers');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'ready'
          ? {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}}
          : null,
    );
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    addTearDown(events.close);
    final box = BoxController(channel: channel, events: events.stream);

    // Start from a known category set so the labels are deterministic, and
    // restore afterwards to avoid leaking state into other tests.
    final store = ConnectivityStore.instance;
    final originalCategories = Set<ConnectivityCategory>.of(store.categories);
    // The plain Provider does not dispose the singleton, so restoring in
    // teardown is safe and keeps the store clean for other tests.
    addTearDown(() => store.setCategories(originalCategories));
    store.setCategories(ConnectivityCategory.values.toSet());

    await tester.pumpWidget(ProviderScope(
      overrides: [boxControllerProvider.overrideWithValue(box)],
      child: BoxApp(controller: box),
    ));
    await tester.pumpAndSettle();

    // Open the pilot page through the app so it inherits both ProviderScope
    // and the BoxScope the rest of the app already builds.
    openPage(tester.element(find.byType(HomePage)), const ConnectivityPage());
    await tester.pumpAndSettle();
    expect(find.byType(ConnectivityPage), findsOneWidget);

    // The page watches the ChangeNotifier-backed provider. A store mutation
    // that changes what is rendered (here: drop every category) must rebuild
    // it to the empty state — no second write, just a store notifyListeners.
    store.setCategories(<ConnectivityCategory>{});
    await tester.pumpAndSettle();
    expect(find.text('No services selected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('settings read-only providers', () {
    BoxController boxWithSettings(MethodChannel channel, Map<String, dynamic> hosted) {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ready') {
          return {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': 'Stopped'},
            'settings': hosted,
          };
        }
        if (call.method == 'settings.set') {
          final args = json(call.arguments);
          hosted[args['key'] as String] = args['value'];
          return hosted;
        }
        if (call.method == 'settings.patch') {
          hosted.addAll(json(call.arguments)['value'] as Map<String, dynamic>);
          return hosted;
        }
        return null;
      });
      return BoxController(channel: channel);
    }

    test('settingsProvider/preferencesProvider read the injected controller, no cache', () async {
      final hosted = <String, dynamic>{'serviceMode': 'vpn'};
      const channel = MethodChannel('test.settings-providers');
      final box = boxWithSettings(channel, hosted);
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      addTearDown(box.dispose);
      final container = ProviderContainer(
        overrides: [boxControllerProvider.overrideWithValue(box)],
      );
      addTearDown(container.dispose);

      // Same injected instance, no second source of truth.
      expect(container.read(boxControllerProvider), same(box));
      box.settings = hosted;
      expect(container.read(settingsProvider)['serviceMode'], 'vpn');

      // Write through the controller's API. Its stateChanges notifies the
      // bridge, invalidating settingsProvider; the next read merges the fresh
      // host snapshot rather than serving a stale cached whole-map copy.
      await box.setSetting('serviceMode', 'proxy', restart: false);
      expect(container.read(settingsProvider)['serviceMode'], 'proxy');
    });

    test('settingsProvider throws without a controller override (no silent fallback)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(() => container.read(settingsProvider), throwsA(isA<UnimplementedError>()));
      expect(() => container.read(preferencesProvider), throwsA(isA<UnimplementedError>()));
    });

    testWidgets('GeneralPage rebuilds when watched settings change through the bridge', (tester) async {
      tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final hosted = <String, dynamic>{'serviceMode': 'vpn'};
      const channel = MethodChannel('test.settings-rebuild');
      final box = boxWithSettings(channel, hosted);
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));

      await tester.pumpWidget(BoxApp(controller: box));
      await tester.pumpAndSettle();
      openPage(tester.element(find.byType(HomePage)), const GeneralPage());
      await tester.pumpAndSettle();
      expect(find.text('VPN'), findsOneWidget);
      expect(find.text('Proxy only'), findsNothing);

      // Write through the controller's own API (the single writer). The bridge
      // forwards stateChanges, invalidating settingsProvider and rebuilding the
      // ConsumerWidget — no Riverpod write, no second source of truth.
      await box.setSetting('serviceMode', 'proxy', restart: false);
      await tester.pumpAndSettle();
      expect(find.text('Proxy only'), findsOneWidget);
      expect(find.text('VPN'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
