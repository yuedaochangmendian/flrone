// The Routing screen is now one global rule table: it reads getGlobalRules,
// edits the list in memory, and commits with a whole-table saveGlobalRules.
// These tests use the same fake kernel the app uses, so an assertion about the
// wire is an assertion about what the Go side actually receives.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/core/kernel_control.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';
import 'support/fake_route_kernel.dart';

Map<String, Object?> rule(String name, {int disabled = 0, String outbound = 'direct', int id = 0}) => {
      'id': id,
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
  late Map<String, dynamic>? lastPatch;
  late int revision;
  late NoopKernelWorker worker;

  /// The rule rows currently built: one FlClash-style card each.
  int rowCount() => find.byType(SelectedDecorationListItem).evaluate().length;

  Object? routeFixtures(ActionMethod method, Object? data) {
    final payload = data is Map ? data : const <String, dynamic>{};
    switch (method) {
      case ActionMethod.getGlobalRules:
        return {'rules': globalRules, 'version': revision, 'etag': 'e' * 64};
      case ActionMethod.saveGlobalRules:
        savedRules = [
          for (final entry in payload['rules'] as List? ?? const [])
            Map<String, Object?>.from(entry as Map),
        ];
        globalRules = savedRules;
        return {'rules': savedRules, 'version': ++revision, 'etag': 'e' * 64};
      case ActionMethod.saveGlobalRulesPatch:
        lastPatch = Map<String, dynamic>.from(payload);
        // Mirror the Go patch semantics closely enough for the widget tests:
        // reject a stale base, apply adds/updates/deletes and the explicit
        // order (0 placeholders resolve to newly allocated ids in sequence).
        if ((payload['baseVersion'] as num?)?.toInt() != revision) {
          throw KernelProxyException(
            'stale global rules view',
            code: 'core_-1',
            details: {
              'kind': 'stale',
              'version': revision,
              'etag': 'e' * 64,
            },
          );
        }
        final byId = <int, Map<String, Object?>>{
          for (final r in globalRules)
            if (r['id'] is num) (r['id'] as num).toInt(): Map<String, Object?>.from(r),
        };
        var maxId = byId.keys.fold<int>(0, (a, b) => a > b ? a : b);
        for (final id in payload['deleted'] as List? ?? const []) {
          byId.remove((id as num).toInt());
        }
        final addedIds = <int>[];
        for (final entry in payload['added'] as List? ?? const []) {
          final row = Map<String, Object?>.from(entry as Map);
          final explicit = row['id'] is num ? (row['id'] as num).toInt() : 0;
          final id = explicit > 0 && !byId.containsKey(explicit) ? explicit : ++maxId;
          row['id'] = id;
          byId[id] = row;
          addedIds.add(id);
        }
        for (final entry in payload['updated'] as List? ?? const []) {
          final row = Map<String, Object?>.from(entry as Map);
          final id = (row['id'] as num).toInt();
          byId[id] = {...?byId[id], ...row};
        }
        final order = payload['order'] as List? ?? const [];
        final used = <int>{};
        var nextAdded = 0;
        final ordered = <Map<String, Object?>>[];
        for (final value in order) {
          var id = (value as num).toInt();
          if (id == 0) id = addedIds[nextAdded++];
          if (byId.containsKey(id) && used.add(id)) ordered.add(byId[id]!);
        }
        globalRules = ordered;
        savedRules = ordered;
        revision++;
        return {'version': revision, 'etag': 'e' * 64, 'ids': addedIds};
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
    // Give every seeded rule a stable id, the way Go's getGlobalRules answer
    // carries one. Patches identify rows by id, never by position.
    globalRules = [
      for (var i = 0; i < globalRules.length; i++)
        {...globalRules[i], 'id': i + 1},
    ];
    savedRules = const [];
    lastPatch = null;
    revision = 1;
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
    expect(lastPatch, isNotNull);
    expect(lastPatch!['baseVersion'], 1);
    expect(lastPatch!['added'], hasLength(1), reason: 'the new rule is an add, not a full-table write');
    expect(lastPatch!['order'], [1, 0], reason: 'the explicit order reserves a slot for the added row');
    expect(tester.takeException(), isNull);
  });

  testWidgets('every change sends one patch guarded by the loaded version', (tester) async {
    await mount(tester, rules: [rule('First'), rule('Second')]);
    await openRouting(tester);

    // Re-saving one rule sends a patch with the loaded version as its base and
    // the full display order — never a whole-table replace.
    await tester.tap(find.text('First'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(RouteRuleEditorPage),
      matching: find.byTooltip('Save'),
    ));
    await tester.pumpAndSettle();
    expect(savedRules.map((r) => r['name']), ['First', 'Second']);
    expect(lastPatch!['baseVersion'], 1);
    expect(lastPatch!['order'], [1, 2]);
    expect(lastPatch!['added'], isEmpty);
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

  testWidgets('the rule cards share one rounded group', (tester) async {
    await mount(tester, rules: [rule('First'), rule('Second')]);
    await openRouting(tester);

    // `DecorationListItem` takes its corners from the row's place in the group;
    // without `ItemPositionProvider` every card drew square.
    final positions = tester
        .widgetList<ItemPositionProvider>(find.descendant(
          of: find.byType(GlobalRulesPage),
          matching: find.byType(ItemPositionProvider),
        ))
        .map((provider) => provider.position)
        .toList();
    expect(positions, [ItemPosition.start, ItemPosition.end]);
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

  testWidgets('a stale refusal keeps the draft and surfaces a clear error', (tester) async {
    await mount(tester, rules: [rule('First')]);
    await openRouting(tester);

    // Simulate another writer moving the store after the page loaded its base.
    revision = 2;
    await tester.tap(find.byTooltip('Add rule'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(RouteRuleEditorPage),
      matching: find.byTooltip('Save'),
    ));
    await tester.pumpAndSettle();

    // The added rule stays on screen: no silent merge and no renumber.
    expect(rowCount(), 2);
    expect(find.textContaining('Rules changed elsewhere'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
