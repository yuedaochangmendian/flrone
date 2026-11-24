import 'dart:async';

import 'package:flrone/components/status_panel.dart';
import 'package:flrone/providers/box_providers.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as material;

import 'support/errors.dart';

/// The status card mounted on its own, so the test can tear it down and mount it again
/// without disposing the controller (which owns the cache).
Widget _frame(BoxController box) => ProviderScope(
  overrides: [boxControllerProvider.overrideWithValue(box)],
  child: BoxScope(
    controller: box,
    child: MaterialApp(
      locale: const Locale('en'),
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: const [
        BoxUiDelegate(),
        ...GlobalMaterialLocalizations.delegates,
      ],
      theme: material.ThemeData(
        useMaterial3: true,
        colorScheme: material.ColorScheme.fromSeed(
          seedColor: const Color(0xff007aff),
        ),
      ),
      home: Builder(
        builder: (context) => MeasureScope(
          measure: Measure.of(context, 1),
          child: ViewScope(
            size: const Size(360, 800),
            isMobile: true,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(1),
                disableAnimations: true,
              ),
              child: Theme(
                data: ThemeData(
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: const Color(0xff007aff),
                  ),
                ),
                child: material.Scaffold(
                  body: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: const StatusPanel(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

class _Harness {
  final channel = const MethodChannel('test.status-cache');
  final events = StreamController<dynamic>.broadcast();
  final calls = <MethodCall>[];
  final egressIds = <String>[];
  final forces = <bool>[];
  String ip = '203.0.113.9';
  int routeVersion = 1;
  bool failIP = false;
  late BoxController box;

  Map<String, Object?> _ipInfo(String id) => {
    'ip': ip,
    'country': 'GB',
    'city': 'London',
    'direct': false,
    'ipSource': 'www.cloudflare.com',
    'checkedAt': DateTime.now().millisecondsSinceEpoch,
    // Stamped when the answer is produced, like the host.
    'routeVersion': routeVersion,
  };

  Map<String, Object?> _dashboard() => {
    'status': 'Stopped',
    'mode': 'rule',
    'selectedProfileId': 1,
    'startedAt': 1,
    'routeVersion': routeVersion,
  };

  Future<void> mount(WidgetTester tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = json(call.arguments);
      switch (call.method) {
        case 'dashboard.egress':
          egressIds.add(args['id'] as String? ?? '');
          forces.add(args['force'] == true);
          if (failIP) {
            throw PlatformException(
              code: 'unavailable',
              message: 'IP check failed',
            );
          }
          return _ipInfo(args['id'] as String? ?? '');
        case 'dashboard.qualityCache.get':
          return {
            'quality': {
              'ip': args['ip'],
              'source': 'identMe',
              'type': 'business',
              'organization': 'Example Business',
              'asn': 64500,
            },
            'checkedAt': DateTime.now().millisecondsSinceEpoch,
          };
        case 'dashboard.probe.close':
        case 'dashboard.probe.open':
          return null;
      }
      return null;
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      box.dispose();
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });
    box = BoxController(channel: channel, events: events.stream)
      ..dashboard = _dashboard()
      ..configurations = [
        {'id': 1, 'name': 'Profile'},
      ]
      ..groups = []
      ..lan = {
        'addresses': ['192.168.1.2'],
        'stamp': 'wifi:1',
      };
    await _pump(tester);
  }

  /// Tears the card down and mounts it again over the same controller, the way leaving the
  /// dashboard and coming back does. The route has not moved.
  Future<void> remount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await _pump(tester);
  }

  Future<void> _pump(WidgetTester tester) async {
    await tester.pumpWidget(_frame(box));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// A dashboard push that moves the host's route stamp and nothing else.
  void moveRoute() {
    routeVersion = 2;
    box.handleEvent({
      'type': 'dashboard',
      'value': _dashboard(),
    });
  }
}

void main() {
  testWidgets('a remount under the same route reuses the cached egress', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    await tester.pumpAndSettle();
    expect(find.text('203.0.113.9'), findsOneWidget);
    expect(harness.egressIds, hasLength(1));

    await harness.remount(tester);
    await tester.pumpAndSettle();
    expect(
      harness.egressIds,
      hasLength(1),
      reason: 'the answer belongs to the route, not to the card that asked',
    );
    expect(find.text('203.0.113.9'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a route version change re-probes after a cached remount', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    await tester.pumpAndSettle();
    await harness.remount(tester);
    await tester.pumpAndSettle();
    expect(harness.egressIds, hasLength(1));

    harness.ip = '198.51.100.2';
    harness.moveRoute();
    // The card waits out its move-settle window before probing; a focused frame has no
    // ongoing animation, so pump the window explicitly instead of relying on settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(harness.egressIds, hasLength(2));
    expect(find.text('198.51.100.2'), findsOneWidget);
    expect(find.text('203.0.113.9'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a manual refresh bypasses the cached answer', (tester) async {
    final harness = _Harness();
    await harness.mount(tester);
    await tester.pumpAndSettle();
    expect(harness.egressIds, hasLength(1));

    harness.ip = '198.51.100.2';
    await tester.tap(find.byTooltip('Retry'));
    await tester.pumpAndSettle();
    expect(harness.egressIds, hasLength(2));
    expect(harness.forces.last, isTrue, reason: 'a tap asks the host itself');
    expect(find.text('198.51.100.2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a remount reuses the confirmed failure inside its cooldown', (
    tester,
  ) async {
    final harness = _Harness()..failIP = true;
    await harness.mount(tester);
    await tester.pumpAndSettle();
    // S7 confirmation: the retry a second later paints the failure.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(harness.egressIds, hasLength(2));
    expect(find.text('Check failed'), findsOneWidget);

    await harness.remount(tester);
    await tester.pumpAndSettle();
    expect(
      harness.egressIds,
      hasLength(2),
      reason: 'the confirmed failure belongs to the route, not to the card',
    );
    expect(find.text('Check failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
