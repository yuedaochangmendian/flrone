// Network-check facade decoding and the page's idle/running/done/error states.
//
// The Go handler's wire shape is pinned by scan_actions_test.go; this file pins
// the Dart side. The page uses a runnerOverride so the states are exercised
// without a core, a kernel or a channel. Only the values the core actually
// returned are shown — no invented progress, no fabricated fields.

import 'dart:async';

import 'package:flrone/components/form.dart';
import 'package:flrone/pages/network_scan.dart';
import 'package:flrone/providers/box_providers.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'support/errors.dart';
import 'support/test_app.dart';

void main() {
  group('decodeNetworkCheck', () {
    test('decodes an up verdict with no resolvers', () {
      final result = decodeNetworkCheck({'up': true, 'error': '', 'system_resolvers': []});
      expect(result.up, isTrue);
      expect(result.error, isEmpty);
      expect(result.systemResolvers, isEmpty);
    });

    test('decodes a DNS check with the resolvers the core actually asked', () {
      final result = decodeNetworkCheck({
        'up': false,
        'error': 'no system resolver answered: i/o timeout',
        'system_resolvers': ['1.1.1.1', '8.8.8.8'],
      });
      expect(result.up, isFalse);
      expect(result.error, 'no system resolver answered: i/o timeout');
      expect(result.systemResolvers, ['1.1.1.1', '8.8.8.8']);
    });

    test('a missing or malformed reply is not invented into a success', () {
      final missing = decodeNetworkCheck(null);
      expect(missing.up, isFalse);
      expect(missing.systemResolvers, isEmpty);

      final partial = decodeNetworkCheck({'error': 'boom'});
      expect(partial.up, isFalse);
      expect(partial.error, 'boom');
      expect(partial.systemResolvers, isEmpty);

      final badResolvers = decodeNetworkCheck({'up': true, 'system_resolvers': 'not-a-list'});
      expect(badResolvers.up, isTrue);
      expect(badResolvers.systemResolvers, isEmpty);
    });

    test('a message-port style map with non-string values is coerced to text', () {
      final result = decodeNetworkCheck({'up': 1, 'system_resolvers': [1, 2]});
      // `up` must be the boolean true, not a truthy number.
      expect(result.up, isFalse);
      expect(result.systemResolvers, ['1', '2']);
    });
  });

  group('NetworkScanPage states', () {
    Future<void> mountPage(
      WidgetTester tester, {
      required Future<NetworkCheckResult> Function(bool, String, int) runner,
    }) async {
      reportFlutterErrors();
      NetworkScanPage.runnerOverride = runner;
      addTearDown(() => NetworkScanPage.runnerOverride = null);
      tester.view.physicalSize = const Size(420, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      addTearDown(events.close);
      const channel = MethodChannel('test.network.scan');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ready') {
          return {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': 'Stopped'},
            'settings': <String, dynamic>{},
            'preferences': <String, dynamic>{},
          };
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final box = BoxController(channel: channel, events: events.stream);
      addTearDown(box.dispose);
      // The runnerOverride means the page never reaches the kernel, but the
      // page is a ConsumerWidget and reads boxControllerProvider in build.
      // Override it with the controller we just made; no second instance.
      await tester.pumpWidget(TestApp(
        child: ProviderScope(
          overrides: [boxControllerProvider.overrideWithValue(box)],
          child: const NetworkScanPage(),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> enterTargets(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(FormRowTextField).first, text);
      await tester.pump();
    }

    testWidgets('a done run shows only the core-returned verdict', (tester) async {
      var receivedDns = false;
      var receivedInput = '';
      await mountPage(tester, runner: (dns, input, timeout) async {
        receivedDns = dns;
        receivedInput = input;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return const NetworkCheckResult(
          up: true,
          error: '',
          systemResolvers: [],
        );
      });
      expect(find.text('Run check'), findsOneWidget);
      expect(find.text('Result'), findsNothing);

      await enterTargets(tester, '1.1.1.1:53');
      await tester.tap(find.text('Run check'));
      // The run is in flight: no result has been invented yet.
      await tester.pump(const Duration(milliseconds: 5));
      expect(find.text('Checking…'), findsOneWidget);
      expect(find.text('Result'), findsNothing);

      await tester.pumpAndSettle();
      expect(receivedDns, isFalse);
      expect(receivedInput, '1.1.1.1:53');
      expect(find.text('Result'), findsOneWidget);
      expect(find.text('Reachable'), findsOneWidget);
      expect(find.text('Yes'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a DNS run shows the resolvers the core asked', (tester) async {
      await mountPage(tester, runner: (dns, input, timeout) async {
        return NetworkCheckResult(
          up: false,
          error: 'no system resolver answered: i/o timeout',
          systemResolvers: input.split(','),
        );
      });
      await enterTargets(tester, '1.1.1.1,8.8.8.8');
      await tester.tap(find.text('DNS resolver check'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run check'));
      await tester.pumpAndSettle();

      expect(find.text('Resolvers asked'), findsOneWidget);
      expect(find.text('1.1.1.1, 8.8.8.8'), findsOneWidget);
      expect(find.text('no system resolver answered: i/o timeout'), findsOneWidget);
      expect(find.text('No'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed run shows an error and no result', (tester) async {
      await mountPage(tester, runner: (dns, input, timeout) async {
        throw StateError('kernel went away');
      });
      await enterTargets(tester, '1.1.1.1:53');
      await tester.tap(find.text('Run check'));
      await tester.pumpAndSettle();

      expect(find.text('Result'), findsNothing);
      expect(find.textContaining('kernel went away'), findsOneWidget);
      expect(find.text('Run check'), findsOneWidget, reason: 'the button is usable again');
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty target list is refused before any run', (tester) async {
      var calls = 0;
      await mountPage(tester, runner: (dns, input, timeout) async {
        calls++;
        return const NetworkCheckResult(up: true, error: '', systemResolvers: []);
      });
      await tester.tap(find.text('Run check'));
      await tester.pumpAndSettle();

      expect(calls, 0);
      expect(find.textContaining('Check failed'), findsOneWidget);
      expect(find.text('Result'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
