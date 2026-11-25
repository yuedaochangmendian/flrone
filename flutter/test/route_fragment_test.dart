// The Routing screen is now one global rule table: it reads getGlobalRules,
// edits the list in memory, and commits with a whole-table saveGlobalRules.
// These tests use the same fake kernel the app uses, so an assertion about the
// wire is an assertion about what the Go side actually receives.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
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

  /// The rule rows currently built: one FlClash-style card each.
  int rowCount() => find.byType(SelectedDecorationListItem).evaluate().length;

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
    expect(rowCount(), 2);
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

    // The add flow opens the rule editor; its Save answers a new rule, and the
    // list commits every mutation at once (FlClash's added-rules behaviour).
    await tester.tap(find.byTooltip('Add rule'));
    await tester.pumpAndSettle();
    expect(find.byType(RouteRuleEditorPage), findsOneWidget);
    await tester.tap(find.descendant(
      of: find.byType(RouteRuleEditorPage),
      matching: find.byTooltip('Save'),
    ));
    await tester.pumpAndSettle();
    expect(rowCount(), 2);
    expect(savedRules, hasLength(2), reason: 'the list commits the new rule');
    expect(savedRules.first['name'], 'Direct LAN');
    expect(tester.takeException(), isNull);
  });

  testWidgets('every change sends the whole table in order', (tester) async {
    await mount(tester, rules: [rule('First'), rule('Second')]);
    await openRouting(tester);

    // Re-saving one rule still writes the entire table, in list order.
    await tester.tap(find.text('First'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(RouteRuleEditorPage),
      matching: find.byTooltip('Save'),
    ));
    await tester.pumpAndSettle();
    expect(savedRules.map((r) => r['name']), ['First', 'Second']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the menu keeps resource update and settings', (tester) async {
    await mount(tester);
    await openRouting(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();

    expect(find.text('Update resources'), findsOneWidget);
    expect(find.text('Routing settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Update resources runs and reports without throwing', (tester) async {
    await mount(tester);
    await openRouting(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update resources'));
    await tester.pumpAndSettle();
    // A stopped tunnel skips the core's rule-set refetch; the banner explains
    // the skip rather than leaving a dead menu item.
    expect(worker.updateRuleSetsCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('each delete banner restores its own snapshot', (tester) async {
    await mount(tester, rules: [rule('First'), rule('Second'), rule('Third')]);
    await openRouting(tester);

    // Deleting one rule lives in its editor now: open the row, then Delete. Two
    // deletions in a row must each keep their own undo snapshot — the visible
    // banner is the first delete's, so its undo restores all three rows.
    Future<void> deleteRule(String name) async {
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
    }

    await deleteRule('First');
    expect(rowCount(), 2);

    // The undo banner covers the first row while it is up; the second row is
    // clear of it and exercises the same path.
    await deleteRule('Third');
    expect(rowCount(), 1);

    final banner = find.textContaining('Rule deleted');
    expect(banner, findsOneWidget);
    await tester.tap(banner);
    await tester.pumpAndSettle();
    expect(rowCount(), 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving after a change needs no prompt: the change is saved', (tester) async {
    await mount(tester, rules: [rule('First')]);
    await openRouting(tester);

    await tester.tap(find.byTooltip('Add rule'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(RouteRuleEditorPage),
      matching: find.byTooltip('Save'),
    ));
    await tester.pumpAndSettle();
    expect(rowCount(), 2);
    expect(savedRules, hasLength(2));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a row reads as a type, a value and a coloured target', (tester) async {
    await mount(tester, rules: [
      rule('Direct LAN'),
      rule('Proxy list', outbound: 'proxy'),
    ]);
    await openRouting(tester);

    // FlClash's row layout: the match kind and the target are the two tokens a
    // reader scans; the value is the subtitle.
    expect(find.text('DOMAIN-SUFFIX'), findsNWidgets(2));
    expect(find.text('DIRECT'), findsOneWidget);
    expect(find.text('PROXY'), findsOneWidget);
    expect(find.text('Direct LAN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bottom search filters the rule cards', (tester) async {
    await mount(tester, rules: [rule('Direct LAN'), rule('Proxy list', outbound: 'proxy')]);
    await openRouting(tester);
    expect(rowCount(), 2);

    await tester.enterText(find.byKey(const Key('route-rule-search')), 'proxy');
    await tester.pumpAndSettle();
    expect(rowCount(), 1);
    expect(find.text('Proxy list'), findsOneWidget);
    expect(find.text('Direct LAN'), findsNothing);

    await tester.enterText(find.byKey(const Key('route-rule-search')), 'no-such-rule');
    await tester.pumpAndSettle();
    expect(find.text('No search results'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the row circle selects rules for one batch delete', (tester) async {
    await mount(tester, rules: [rule('First'), rule('Second')]);
    await openRouting(tester);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    // Selection replaces the add/quick actions with delete and select-all.
    expect(find.byTooltip('Select all'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete the selected rules?'), findsOneWidget);
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    expect(rowCount(), 1);
    expect(find.textContaining('Rules deleted'), findsOneWidget);
    expect(savedRules.map((entry) => entry['name']), ['Second'],
        reason: 'the batch delete commits like every other mutation');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long press drags a rule card and the new order is saved', (tester) async {
    await mount(tester, rules: [rule('First'), rule('Second')]);
    await openRouting(tester);

    final gesture = await tester.startGesture(tester.getCenter(find.text('First')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(savedRules.map((entry) => entry['name']), ['Second', 'First']);
    expect(tester.takeException(), isNull);
  });
}
