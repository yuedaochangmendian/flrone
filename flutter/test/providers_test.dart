import 'dart:async';

import 'package:flrone/components/connectivity/connectivity_page.dart';
import 'package:flrone/components/connectivity/connectivity_store.dart';
import 'package:flrone/main.dart';
import 'package:flrone/pages/settings.dart';
import 'package:flrone/pages/connections.dart';
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

    await tester.pumpWidget(BoxApp(controller: box));
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

  group('page-layer read-only providers', () {
    const channel = MethodChannel('test.page-providers');

    BoxController makeBox(StreamController<dynamic> events) {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready'
          ? {'version': '1.0', 'coreVersion': 'core', 'dashboard': {'status': 'Stopped'}}
          : null);
      return BoxController(channel: channel, events: events.stream);
    }

    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    test('all field providers read the same injected controller', () {
      final events = StreamController<dynamic>.broadcast();
      addTearDown(events.close);
      final box = makeBox(events);
      addTearDown(box.dispose);
      final container = ProviderContainer(
        overrides: [boxControllerProvider.overrideWithValue(box)],
      );
      addTearDown(container.dispose);

      expect(container.read(boxControllerProvider), same(box));
      expect(container.read(dashboardProvider), same(box.dashboard));
      expect(container.read(configurationsProvider), same(box.configurations));
      expect(container.read(groupsProvider), same(box.groups));
      expect(container.read(connectionsProvider), same(box.connections));
      expect(container.read(logsProvider), same(box.logs));
      expect(container.read(logcatProvider), same(box.logcat));
      expect(container.read(testSessionProvider), same(box.testSession));
      expect(container.read(capabilitiesProvider), same(box.capabilities));
      expect(container.read(versionProvider), box.version);
      expect(container.read(runningProvider), box.running);
      expect(container.read(boxStateProvider), same(box));
    });

    test('field providers throw without a controller override (no silent fallback)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(() => container.read(dashboardProvider), throwsA(isA<UnimplementedError>()));
      expect(() => container.read(groupsProvider), throwsA(isA<UnimplementedError>()));
      expect(() => container.read(testSessionProvider), throwsA(isA<UnimplementedError>()));
      expect(() => container.read(boxStateProvider), throwsA(isA<UnimplementedError>()));
    });

    testWidgets('ConnectionsPage rebuilds when the connections provider changes', (tester) async {
      tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      final events = StreamController<dynamic>.broadcast();
      addTearDown(events.close);
      final box = makeBox(events);

      await tester.pumpWidget(BoxApp(controller: box));
      await tester.pumpAndSettle();
      openPage(tester.element(find.byType(HomePage)), const ConnectionsPage());
      await tester.pumpAndSettle();
      expect(find.text('No connections'), findsOneWidget);

      // A bridge event replaces the connections list; the watched provider
      // invalidates and the ConsumerStatefulWidget rebuilds with the new row.
      events.add({
        'type': 'connections',
        'value': [
          {
            'id': 1, 'createdAt': 1700000000000, 'network': 'tcp',
            'destination': 'example.com:443', 'outbound': 'proxy', 'rule': 'geosite',
            'source': '10.0.0.2:5', 'upload': 0, 'download': 0,
            'uploadTotal': 0, 'downloadTotal': 0,
          },
        ],
      });
      await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(find.text('No connections'), findsNothing);
      expect(find.text('example.com:443'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AboutPage rebuilds when a watched version provider notifies', (tester) async {
      tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      final events = StreamController<dynamic>.broadcast();
      addTearDown(events.close);
      final box = makeBox(events);

      await tester.pumpWidget(BoxApp(controller: box));
      await tester.pumpAndSettle();
      openPage(tester.element(find.byType(HomePage)), const AboutPage());
      await tester.pumpAndSettle();
      expect(find.text('v1.0'), findsOneWidget);

      // Mutate the field and notify through the controller's own Listenable —
      // the one-way bridge forwards it, invalidating versionProvider.
      box.version = '9.9';
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      box.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('v9.9'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('component-layer read-only providers', () {
    const channel = MethodChannel('test.component-providers');

    BoxController makeBox(StreamController<dynamic> events) {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready'
          ? {'version': '1.0', 'coreVersion': 'core', 'dashboard': {'status': 'Stopped'}}
          : null);
      return BoxController(channel: channel, events: events.stream);
    }

    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    test('derived LAN providers read the same injected controller', () {
      final events = StreamController<dynamic>.broadcast();
      addTearDown(events.close);
      final box = makeBox(events);
      addTearDown(box.dispose);
      final container = ProviderContainer(
        overrides: [boxControllerProvider.overrideWithValue(box)],
      );
      addTearDown(container.dispose);

      expect(container.read(boxControllerProvider), same(box));
      expect(container.read(lanAddressesProvider), box.lanAddresses);
      expect(container.read(lanCopyTextProvider), box.lanCopyText);
      expect(container.read(lanProxyEndpointsProvider), box.lanProxyEndpoints);
      expect(container.read(canSetLanProxyProvider), box.canSetLanProxy);
      expect(container.read(lanChangingProvider), box.lanChanging);
    });

    test('derived LAN providers throw without a controller override (no silent fallback)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(() => container.read(lanAddressesProvider), throwsA(isA<UnimplementedError>()));
      expect(() => container.read(lanCopyTextProvider), throwsA(isA<UnimplementedError>()));
      expect(() => container.read(lanProxyEndpointsProvider), throwsA(isA<UnimplementedError>()));
      expect(() => container.read(canSetLanProxyProvider), throwsA(isA<UnimplementedError>()));
      expect(() => container.read(lanChangingProvider), throwsA(isA<UnimplementedError>()));
    });

    test('LAN providers read only the controller injected in their own scope', () {
      final firstEvents = StreamController<dynamic>.broadcast();
      final secondEvents = StreamController<dynamic>.broadcast();
      addTearDown(firstEvents.close);
      addTearDown(secondEvents.close);
      final first = makeBox(firstEvents);
      final second = makeBox(secondEvents);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      // Give the two controllers distinct LAN state so a wrong-instance read is observable.
      first.lan = {'addresses': ['10.0.0.1'], 'canToggle': true};
      second.lan = {'addresses': ['10.0.0.2', '10.0.0.3'], 'canToggle': false};
      second.lanChanging = true;

      final firstScope = ProviderContainer(overrides: [boxControllerProvider.overrideWithValue(first)]);
      final secondScope = ProviderContainer(overrides: [boxControllerProvider.overrideWithValue(second)]);
      addTearDown(firstScope.dispose);
      addTearDown(secondScope.dispose);

      expect(firstScope.read(boxControllerProvider), same(first));
      expect(secondScope.read(boxControllerProvider), same(second));
      expect(firstScope.read(lanAddressesProvider), ['10.0.0.1']);
      expect(secondScope.read(lanAddressesProvider), ['10.0.0.2', '10.0.0.3']);
      expect(firstScope.read(lanCopyTextProvider), '10.0.0.1');
      expect(secondScope.read(lanCopyTextProvider), '10.0.0.2');
      expect(firstScope.read(lanProxyEndpointsProvider), isEmpty);
      expect(secondScope.read(lanProxyEndpointsProvider), isEmpty);
      expect(firstScope.read(canSetLanProxyProvider), first.canSetLanProxy);
      expect(secondScope.read(canSetLanProxyProvider), second.canSetLanProxy);
      expect(firstScope.read(lanChangingProvider), false);
      expect(secondScope.read(lanChangingProvider), true);
    });

    test('LAN providers follow the controller through stateChanges, never a provider write', () async {
      final events = StreamController<dynamic>.broadcast();
      addTearDown(events.close);
      final hosted = <String, dynamic>{};
      const writeChannel = MethodChannel('test.lan-provider-write');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(writeChannel, (call) async {
        if (call.method == 'ready') {
          return {'version': '1.0', 'coreVersion': 'core', 'dashboard': {'status': 'Stopped'}};
        }
        if (call.method == 'preferences.set') {
          hosted.addAll((json(call.arguments)['value'] as Map).cast<String, dynamic>());
          return hosted;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(writeChannel, null));
      final box = BoxController(channel: writeChannel, events: events.stream);
      addTearDown(box.dispose);
      await box.initialize();

      final container = ProviderContainer(overrides: [boxControllerProvider.overrideWithValue(box)]);
      addTearDown(container.dispose);

      final initial = container.read(lanAddressesProvider);
      expect(initial, box.lanAddresses);
      expect(container.read(lanCopyTextProvider), box.lanCopyText);
      expect(container.read(canSetLanProxyProvider), box.canSetLanProxy);
      expect(container.read(lanChangingProvider), box.lanChanging);

      // A direct field mutation (no stateChanges notification) leaves the
      // provider's cached value untouched: it has no setter to push into and
      // only re-evaluates when the controller notifies its listeners.
      box.lan = {'addresses': ['10.0.0.9'], 'canToggle': true};
      expect(box.lanAddresses, ['10.0.0.9'], reason: 'the controller did change');
      expect(container.read(lanAddressesProvider), initial,
          reason: 'no stateChanges notification => no provider re-evaluation');

      // A write through the controller's own API notifies stateChanges; the
      // provider then re-reads fresh from the controller. No value is ever
      // written back to Riverpod — the controller remains the single writer.
      expect(await box.setPreference('lanProbe', true), isTrue);
      expect(container.read(lanAddressesProvider), box.lanAddresses);
      expect(container.read(lanAddressesProvider), ['10.0.0.9']);
      expect(container.read(lanCopyTextProvider), box.lanCopyText);
      expect(container.read(canSetLanProxyProvider), box.canSetLanProxy);
    });

    testWidgets('a component watching a field provider rebuilds when the bridge notifies', (tester) async {
      final events = StreamController<dynamic>.broadcast();
      addTearDown(events.close);
      final box = makeBox(events);
      addTearDown(box.dispose);
      box.dashboard = {'status': 'Stopped'};

      // Component-layer widgets watch the same narrow read-only providers the
      // pages use. Watching dashboardProvider subscribes to the one-way bridge;
      // no value is ever written back to Riverpod.
      await tester.pumpWidget(ProviderScope(
        overrides: [boxControllerProvider.overrideWithValue(box)],
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: _DashboardStatusProbe(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('status=Stopped'), findsOneWidget);

      // Mutate through the controller's own field and notify its Listenable —
      // the one-way bridge invalidates dashboardProvider, rebuilding the probe.
      box.dashboard = {'status': 'Started'};
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      box.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('status=Started'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Minimal component-shaped consumer used to verify the notification bridge
/// rebuilds watchers of the read-only field providers (same contract the
/// migrated `components/**` widgets rely on).
class _DashboardStatusProbe extends ConsumerWidget {
  const _DashboardStatusProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      Text('status=${ref.watch(dashboardProvider)['status']}');
}
