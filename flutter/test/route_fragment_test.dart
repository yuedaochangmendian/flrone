// The Routing screen is now one global rule table: it reads getGlobalRules,
// edits the list in memory, and commits with a whole-table saveGlobalRules.
// These tests use the same fake kernel the app uses, so an assertion about the
// wire is an assertion about what the Go side actually receives.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';
import 'support/fake_route_kernel.dart';

Map<String, Object?> rule(String name, {int disabled = 0, String outbound = 'direct'}) => {
      'name': name,
      'type': 'custom',
      'disabled': disabled != 0,
      'action': 'route',
      'outbound_id': outbound == 'direct' ? -2 : -1,
      'domain_suffix_json': <String>['example.test'],
      'invert': false,
      'no_drop': false,
    };

void main() {
  late StreamController<dynamic> events;
  late List<Map<String, Object?>> globalRules;
  late List<Map<String, Object?>> savedRules;
  late NoopKernelWorker worker;

  Object? routeFixtures(ActionMethod method, Object? data) {
    final payload = data is Map ? data : const <String, dynamic>{};
    switch (method) {
      case ActionMethod.getGlobalRules:
        return {'rules': globalRules};
      case ActionMethod.saveGlobalRules:
        savedRules = [
          for (final entry in payload['rules'] as List? ?? const [])
            Map<String, Object?>.from(entry as Map),
        ];
        globalRules = savedRules;
        return {'rules': savedRules};
      case ActionMethod.deleteGlobalRule:
        return null;
      default:
        return null;
    }
  }

  Future<void> mount(WidgetTester tester, {List<Map<String, Object?>>? rules}) async {
    reportFlutterErrors();
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    globalRules = rules ?? [rule('Direct LAN'), rule('Proxy list', outbound: 'proxy')];
    savedRules = const [];
    worker = NoopKernelWorker();

    const channel = MethodChannel('test.route-fragment');
    events = StreamController<dynamic>.broadcast();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'preferences': {'locale': 'en'},
          'dashboard': {'status': 'Stopped'},
        };
      }
      if (call.method == 'groups.nodes') return {'nodes': const []};
      return null;
    });
    final box = BoxController(channel: channel, events: events.stream);
    box.debugAttach(FakeRouteKernel(routeFixtures), worker);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });
  }

  Future<void> openRouting(WidgetTester tester) async {
    openPage(tester.element(find.byType(HomePage)), const RoutingPage());
    await tester.pumpAndSettle();
  }

  testWidgets('loads the global rules as one ordered list', (tester) async {
    await mount(tester);
    await openRouting(tester);

    expect(find.byType(GlobalRulesPage), findsOneWidget);
    expect(find.text('Direct LAN'), findsOneWidget);
    expect(find.text('Proxy list'), findsOneWidget);
    expect(find.text('Rules (2)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty table shows the empty state and an add action', (tester) async {
    await mount(tester, rules: const []);
    await openRouting(tester);

    expect(find.text('No rules yet'), findsOneWidget);
    expect(find.byTooltip('Add rule'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an added rule commits the whole table through saveGlobalRules', (tester) async {
    await mount(tester, rules: [rule('Direct LAN')]);
    await openRouting(tester);

    // The add flow opens the rule editor; its Save answers a new rule, which
    // the list appends locally. Only the list's Save writes to the kernel.
    await tester.tap(find.byTooltip('Add rule'));
    await tester.pumpAndSettle();
    expect(find.byType(RouteRuleEditorPage), findsOneWidget);
    await tester.tap(find.descendant(
      of: find.byType(RouteRuleEditorPage),
      matching: find.byTooltip('Save'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Rules (2)'), findsOneWidget);
    expect(savedRules, isEmpty, reason: 'adding is local until the list is saved');

    await tester.tap(find.descendant(
      of: find.byType(GlobalRulesPage),
      matching: find.byTooltip('Save'),
    ));
    await tester.pumpAndSettle();
    expect(savedRules, hasLength(2));
    expect(savedRules.first['name'], 'Direct LAN');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a save sends every loaded rule in order', (tester) async {
    await mount(tester, rules: [rule('First'), rule('Second')]);
    await openRouting(tester);
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(savedRules.map((r) => r['name']), ['First', 'Second']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the menu keeps resource update, settings and rule import', (tester) async {
    await mount(tester);
    await openRouting(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();

    expect(find.text('Update resources'), findsOneWidget);
    expect(find.text('Routing settings'), findsOneWidget);
    expect(find.text('Import rules'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Update resources asks the worker once', (tester) async {
    await mount(tester);
    await openRouting(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update resources'));
    await tester.pumpAndSettle();
    expect(worker.updateRuleSetsCalls, 1);
    expect(tester.takeException(), isNull);
  });

  test('a share link and the same JSON both parse to rules', () {
    final link = routeShareLink(
      name: 'Shared',
      defaultOutbound: 'proxy',
      rules: [rule('DNS')],
    );
    final document = parseRouteDocument(link);
    expect(document, isNotNull);
    expect(document!.name, 'Shared');
    expect(document.rules, hasLength(1));
    final plain = parseRouteDocument(
      '{"name":"Plain","default_outbound":"direct","rules":[{"action":"reject"}]}',
    );
    expect(plain!.rules.single['action'], 'reject');
  });

  test('the remote URL guard refuses private and loopback hosts', () {
    expect(isSafeRemoteRouteUrl('https://example.com/route.json'), isTrue);
    expect(isSafeRemoteRouteUrl('http://127.0.0.1/route.json'), isFalse);
    expect(isSafeRemoteRouteUrl('http://localhost/route.json'), isFalse);
    expect(isSafeRemoteRouteUrl('ftp://example.com/route.json'), isFalse);
  });
}
