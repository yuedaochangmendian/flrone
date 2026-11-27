// The rule-set picker follows Prism's selection-sheet shape: the sets already on
// the rule come first, and the catalog below is paged in as the reader scrolls.

import 'dart:async';
import 'dart:io';

import 'package:flrone/core/action.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';
import 'support/fake_route_kernel.dart';

/// The home page only settles once the routing screen has a kernel to ask; the
/// test never opens it, but the mount must not sit on a loading state.
Object? routeFixtures(ActionMethod method, Object? data) {
  switch (method) {
    case ActionMethod.getGlobalRules:
      return {'rules': const <Object?>[], 'version': 0, 'etag': 'e' * 64};
    case ActionMethod.saveGlobalRules:
      return {'rules': data is Map ? data['rules'] ?? const [] : const [], 'version': 1, 'etag': 'e' * 64};
    case ActionMethod.saveGlobalRulesPatch:
      return {'version': 1, 'etag': 'e' * 64, 'ids': const []};
    default:
      return null;
  }
}

/// The picker reads `srslist.h` from disk, so a widget test has to hand the
/// real event loop a turn after every load; [settle] does that and then paints
/// the result. `pumpAndSettle` cannot be used while a load is in flight — its
/// spinner never stops under fake time.
Future<void> settle(WidgetTester tester) async {
  // A load crosses several async hops (platform fact -> file read -> setState);
  // each hop needs a fake-time pump to deliver its microtask and a real-time
  // turn to let file I/O finish.
  for (var i = 0; i < 4; i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
  }
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  testWidgets('the picker shows the selected sets first and pages the catalog', (tester) async {
    reportFlutterErrors();
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // The reader resolves files/routeprofiles/srslist.h from the database's
    // parent directory, exactly as the app does. Setup is synchronous on
    // purpose: awaiting real I/O inside testWidgets deadlocks fake time.
    final root = Directory.systemTemp.createTempSync('rule_set_picker');
    addTearDown(() => root.deleteSync(recursive: true));
    final database = Directory('${root.path}/databases')..createSync(recursive: true);
    File('${root.path}/files/routeprofiles/srslist.h')
      ..createSync(recursive: true)
      ..writeAsStringSync([
        for (var index = 0; index < 120; index++)
          '{"set-${index.toString().padLeft(3, '0')}", "https://example.test/s$index.srs"}',
      ].join('\n'));

    // The app resolves `data.path` at startup for the profiles store; handing
    // it a real path there starts document file I/O that never completes under
    // fake time (a permanent spinner). Keep it unresolved until the picker
    // itself asks.
    String? exposedPath;
    const channel = MethodChannel('test.rule-set-picker');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'ready':
          return {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': 'Stopped'},
            'preferences': {'locale': 'en'},
          };
        case 'data.path':
          return exposedPath == null
              ? null
              : {'path': exposedPath, 'version': 18};
        case 'preferences.set':
          return <String, dynamic>{};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final events = StreamController<dynamic>.broadcast();
    addTearDown(events.close);
    final box = BoxController(channel: channel, events: events.stream);
    box.debugAttach(FakeRouteKernel(routeFixtures), NoopKernelWorker());
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    exposedPath = '${database.path}/sager_net.db';

    openPage(
      tester.element(find.byType(HomePage)),
      RouteRuleEditorPage(
        // The editor receives rules through ruleFromWire, so the flat list key
        // is `rule_set` (the wire's `rule_set_json` is translated there).
        initial: ruleFromWire(const {
          'action': 'route',
          'outbound_id': -2,
          'rule_set_json': ['set-100'],
        }),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Rule set'));
    await settle(tester);

    // The set already on the rule heads the picker, above the catalog section.
    // The editor behind the sheet also shows `set-100` in its summary row, so
    // every picker assertion is scoped to the picker's own scroll view.
    final list = find.byType(CustomScrollView).last;
    final selectedRow = find.descendant(of: list, matching: find.text('set-100'));
    expect(find.text('Selected'), findsOneWidget);
    expect(find.text('All rule sets'), findsOneWidget);
    expect(selectedRow, findsOneWidget);
    expect(
      tester.getTopLeft(selectedRow).dy,
      lessThan(tester.getTopLeft(find.text('All rule sets')).dy),
      reason: 'the selected set comes first',
    );

    // Page one is 50 entries; later pages append only as the reader scrolls.
    expect(find.text('set-000'), findsOneWidget);
    expect(find.text('set-119'), findsNothing);
    for (var i = 0; i < 20 && find.text('set-119').evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -800));
      await settle(tester);
    }
    expect(find.text('set-119'), findsOneWidget, reason: 'the third page loaded');
    expect(tester.takeException(), isNull);
  });
}
