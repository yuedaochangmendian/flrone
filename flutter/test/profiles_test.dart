import 'dart:async';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flrone/components/configuration_card.dart';
import 'package:flrone/pages/configurations.dart';
import 'package:flrone/pages/nodes.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/profile_duty.dart';

const _remote = {'id': 1, 'name': 'Remote A', 'remote': true,
  'url': 'https://example.org/config.json', 'autoUpdate': true, 'interval': 120, 'updatedAt': 1700000000000};
const _local = {'id': 2, 'name': 'Local B', 'remote': false};
const _remoteB = {'id': 4, 'name': 'Remote B', 'remote': true,
  'url': 'https://example.org/b.json', 'autoUpdate': false, 'interval': 120, 'updatedAt': 0};
const _remoteC = {'id': 5, 'name': 'Remote C', 'remote': true,
  'url': 'https://example.org/c.json', 'autoUpdate': false, 'interval': 120, 'updatedAt': 0};

Future<BoxController> _mount(WidgetTester tester, {List<Json> profiles = const [_remote, _local],
  int selected = 1, bool remoteSession = false, StreamController<dynamic>? eventController,
  Json dashboard = const {}, Json preferences = const {},
  Future<dynamic> Function(MethodCall)? handler}) async {
  tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
  addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  const channel = MethodChannel('test.profiles');
  final events = eventController ?? StreamController<dynamic>.broadcast();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  // The host answers a preferences write with the whole merged document; kept
  // here because the startup marker write must not drop the seeded keys.
  final prefs = <String, dynamic>{'locale': 'en', ...preferences};
  messenger.setMockMethodCallHandler(channel, (call) async {
    if (call.method == 'ready') {
      return {
        'version': 'test', 'coreVersion': 'test', 'profiles': profiles,
        'preferences': Map<String, dynamic>.from(prefs),
        'dashboard': {'status': 'Stopped', 'selectedProfileId': selected,
          if (remoteSession) ...{'remote': 'Server', 'remoteConnected': true}, ...dashboard},
      };
    }
    if (call.method == 'preferences.set') {
      prefs.addAll(json((call.arguments as Map)['value']));
      await handler?.call(call);
      return Map<String, dynamic>.from(prefs);
    }
    return handler?.call(call);
  });
  final box = BoxController(channel: channel, events: events.stream);
  await tester.pumpWidget(BoxApp(controller: box));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await events.close();
    messenger.setMockMethodCallHandler(channel, null);
  });
  return box;
}

Future<void> _profiles(WidgetTester tester) async {
  await tester.tap(find.text('Profiles').last);
  await tester.pumpAndSettle();
}

/// The toolbar's "Update all" callback, read off the shell's own action list.
VoidCallback _updateAllAction(WidgetTester tester) => tester
    .widget<Scaffold>(find.byType(Scaffold).first)
    .menuItems
    .firstWhere((item) => item.label == 'Update all')
    .onPressed!;

/// Pumps fake time ahead until [finder] matches: the run's settle window is a
/// real delay, so a fixed pump count would race the aggregate surface.
Future<void> _pumpUntil(WidgetTester tester, Finder finder, {int steps = 40}) async {
  for (var step = 0; step < steps && finder.evaluate().isEmpty; step++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets);
}

void main() {
  test('compact update ages preserve unknown values and reference thresholds', () {
    final now = DateTime.utc(2026, 10, 29, 12);
    for (final (age, en, zh) in [
      (const Duration(seconds: 59), 'Just now', '刚刚'),
      (const Duration(minutes: 1), '1m ago', '1 分钟前'),
      (const Duration(hours: 1), '1h ago', '1 小时前'),
      (const Duration(days: 1), '1d ago', '1 天前'),
      (const Duration(days: 30), '1mo ago', '1 个月前'),
      (const Duration(days: 365), '1y ago', '1 年前'),
    ]) {
      final updated = now.subtract(age).millisecondsSinceEpoch;
      expect(configurationUpdateLabel(updated, now, chinese: false), en);
      expect(configurationUpdateLabel(updated, now, chinese: true), zh);
    }
    expect(configurationUpdateLabel(0, now, chinese: false), 'Unknown');
    expect(configurationUpdateLabel(null, now, chinese: true), '未知');
    expect(configurationUpdateLabel(now.add(const Duration(days: 1)).millisecondsSinceEpoch, now, chinese: false), 'Just now');
  });

  testWidgets('subscriptionState events drive the refresh spinner across the whole download', (tester) async {
    final events = StreamController<dynamic>.broadcast();
    final box = await _mount(tester, eventController: events);
    await _profiles(tester);
    final remoteCard = find.byWidgetPredicate((w) => w is ConfigurationCard && w.profile['id'] == 1);

    // The enqueue returns in milliseconds; the live queue state is what keeps the card
    // spinning while the download runs. Profile card id == group id (FlroneCatalog.profileOf).
    expect(tester.widget<ConfigurationCard>(remoteCard).updating, isFalse);
    expect(box.subscriptionStates, isEmpty);

    events.add({'type': 'subscriptionState', 'value': {'gid': 1, 'state': 1}}); // QUEUED
    await tester.pump();
    await tester.pump();
    expect(box.subscriptionStates[1], 1);
    expect(tester.widget<ConfigurationCard>(remoteCard).updating, isTrue);
    // Update-all is disabled while a group is queued/running.
    expect(tester.widget<Scaffold>(find.byType(Scaffold).first).menuItems
        .firstWhere((item) => item.label == 'Update all').onPressed, isNull);

    events.add({'type': 'subscriptionState', 'value': {'gid': 1, 'state': 2}}); // RUNNING
    await tester.pump();
    await tester.pump();
    expect(box.subscriptionStates[1], 2);
    expect(tester.widget<ConfigurationCard>(remoteCard).updating, isTrue);

    events.add({'type': 'subscriptionState', 'value': {'gid': 1, 'state': 0}}); // IDLE
    await tester.pump();
    await tester.pump();
    expect(box.subscriptionStates, isEmpty);
    expect(tester.widget<ConfigurationCard>(remoteCard).updating, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty state opens the add menu and canceled file import stays on profiles', (tester) async {
    final calls = <String>[];
    await _mount(tester, profiles: [], handler: (call) async { calls.add(dutyOp(call) ?? call.method); return null; });
    await _profiles(tester);
    await tester.tap(find.text('Add profile').last);
    await tester.pumpAndSettle();
    expect(find.byType(AddConfigurationPage), findsNothing);
    for (final label in ['Scan QR code', 'File', 'Import from URL', 'Clipboard', 'New profile']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    expect(calls.where((method) => method == 'files.pickProfile'), hasLength(1));
    expect(find.byType(ConfigurationForm), findsNothing);
    expect(calls, isNot(contains('save')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote and local menus keep sing-box operations and source link semantics', (tester) async {
    String? copied;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = json(call.arguments)['text'] as String;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await _mount(tester);
    await _profiles(tester);
    final remoteCard = find.byWidgetPredicate((w) => w is ConfigurationCard && w.profile['id'] == 1);
    final localCard = find.byWidgetPredicate((w) => w is ConfigurationCard && w.profile['id'] == 2);
    final remote = tester.widget<ConfigurationCard>(remoteCard);
    final local = tester.widget<ConfigurationCard>(localCard);
    expect(remote.menuItems.map((item) => item.label), ['Edit', 'Update', 'Copy link', 'QR code', 'Share', 'Export', 'Delete']);
    expect(local.menuItems.map((item) => item.label), ['Edit', 'Share', 'Export', 'Delete']);
    expect(remote.menuItems.last.danger, isTrue);
    remote.menuItems.singleWhere((item) => item.label == 'Copy link').onPressed!();
    await tester.pump();
    expect(copied, _remote['url']);
    expect(find.descendant(of: localCard, matching: find.text('Unknown')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local update times are visible on the dashboard and refresh with native metadata', (tester) async {
    final events = StreamController<dynamic>.broadcast();
    await _mount(tester, selected: 2, eventController: events);
    expect(find.text('Last updated Unknown'), findsOneWidget);
    final updatedAt = DateTime.now().millisecondsSinceEpoch;
    events.add({'type': 'profiles', 'value': [_remote, {..._local, 'updatedAt': updatedAt}]});
    await tester.pumpAndSettle();
    expect(find.text('Last updated Just now'), findsOneWidget);
    expect(find.byTooltip('Last updated: ${localDate(updatedAt)}'), findsOneWidget);
    await _profiles(tester);
    final localCard = find.byWidgetPredicate((w) => w is ConfigurationCard && w.profile['id'] == 2);
    expect(find.descendant(of: localCard, matching: find.text('Just now')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only enabled automatic updates validate the minimum interval', (tester) async {
    Json? saved;
    await _mount(tester, handler: (call) async {
      if (dutyOp(call) == 'save') saved = dutyPayload(call);
      return null;
    });
    openForm(tester.element(find.byType(HomePage)), const ConfigurationForm(initial: _remote));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(2), '14');
    await tester.tap(find.byTooltip('Save').last);
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(find.byType(ConfigurationForm), findsOneWidget);
    await tester.tap(find.text('Auto update'));
    await tester.pumpAndSettle();
    expect(find.text('Update interval'), findsNothing);
    await tester.tap(find.byTooltip('Save').last);
    await tester.pumpAndSettle();
    expect(saved, {..._remote, 'autoUpdate': false});
    expect(find.byType(ConfigurationForm), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('normal page reveals selection while picker starts at the top and waits for success', (tester) async {
    var fail = true;
    await _mount(tester, selected: 39,
      profiles: [for (var id = 1; id <= 40; id++) {'id': id, 'name': 'Profile $id', 'remote': false}],
      handler: (call) async {
        if (dutyOp(call) == 'select' && fail) throw PlatformException(code: 'apply', message: 'Apply failed');
        return null;
      });
    await _profiles(tester);
    expect(find.text('Profile 39').hitTestable(), findsOneWidget);
    expect(find.text('Profile 1').hitTestable(), findsNothing);
    openForm(tester.element(find.byType(HomePage)), const ConfigurationsPage(picker: true));
    await tester.pumpAndSettle();
    expect(find.text('Profile 1').hitTestable(), findsOneWidget);
    final picker = find.byWidgetPredicate((w) => w is ConfigurationsPage && w.picker);
    await tester.tap(find.text('Profile 1'));
    await tester.pumpAndSettle();
    expect(picker, findsOneWidget);
    fail = false;
    await tester.tap(find.text('Profile 1'));
    await tester.pumpAndSettle();
    expect(picker, findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final picker in [false, true]) {
    for (final (blockedStatus, resumedStatus) in [('Starting', 'Started'), ('Starting', 'Stopped'), ('Stopping', 'Stopped')]) {
      testWidgets('profile selection submits during a transition (picker: $picker, $blockedStatus to $resumedStatus)', (tester) async {
        final events = StreamController<dynamic>.broadcast();
        final selections = <dynamic>[];
        await _mount(tester, eventController: events, handler: (call) async {
          if (dutyOp(call) == 'select') selections.add(dutyPayload(call)['id']);
          return null;
        });
        if (picker) {
          openForm(tester.element(find.byType(HomePage)), const ConfigurationsPage(picker: true));
          await tester.pumpAndSettle();
        } else {
          await _profiles(tester);
        }
        events.add({'type': 'dashboard', 'value': {'status': blockedStatus, 'selectedProfileId': 1}});
        // The starting indicator animates continuously while the picker is open.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        // FlClash never disables its profile cards on a transition: the tap
        // goes through, and the selection epoch (KernelService's reload
        // skipIf) lets the newest request win over any queued rebuild.
        await tester.tap(find.text('Local B').hitTestable());
        await tester.pump();
        expect(selections, [2], reason: 'a transition must not swallow the tap');
        events.add({'type': 'dashboard', 'value': {'status': resumedStatus, 'selectedProfileId': 1}});
        await tester.pumpAndSettle();
        if (picker) expect(find.byWidgetPredicate((w) => w is ConfigurationsPage && w.picker), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('sort uses final indices and keeps the draft after a native conflict', (tester) async {
    var fail = true;
    final orders = <dynamic>[];
    await _mount(tester, handler: (call) async {
      if (dutyOp(call) == 'reorder') {
        orders.add(dutyPayload(call)['ids']);
        if (fail) throw PlatformException(code: 'conflict', message: 'Profile list changed; refresh and retry');
      }
      return null;
    });
    openForm(tester.element(find.byType(HomePage)), const ConfigurationOrderPage());
    await tester.pumpAndSettle();
    tester.widget<ReorderableListView>(find.byType(ReorderableListView)).onReorderItem!(0, 1);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save').last);
    await tester.pumpAndSettle();
    expect(orders, [[2, 1]]);
    expect(find.byType(ConfigurationOrderPage), findsOneWidget);
    fail = false;
    await tester.tap(find.byTooltip('Save').last);
    await tester.pumpAndSettle();
    expect(orders, [[2, 1], [2, 1]]);
    expect(find.byType(ConfigurationOrderPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote sessions expose no local profile actions', (tester) async {
    await _mount(tester, remoteSession: true, dashboard: {'profileName': 'Private local profile'},
      profiles: [{'id': 1, 'name': 'Private local profile'}]);
    expect(find.text('Remote configuration'), findsOneWidget);
    expect(find.text('Private local profile'), findsNothing);
    await _profiles(tester);
    expect(find.text('Disconnect remote session to edit local profiles'), findsOneWidget);
    expect(find.byType(ConfigurationCard), findsNothing);
    expect(find.byType(AddConfigurationMenu), findsNothing);
    expect(find.byTooltip('Update all'), findsNothing);
    expect(find.byTooltip('Reorder'), findsNothing);
  });

  test('remote profile links preserve names in the sing-box fragment', () {
    const name = '工作 #1 & home';
    const url = 'https://example.com/profile.json?token=a%26b';
    final link = Uri.parse(remoteConfigurationLink({'name': name, 'url': url}));
    expect(link.scheme, 'sing-box');
    expect(link.host, 'import-remote-profile');
    expect(Uri.decodeComponent(link.fragment), name);
    expect(link.queryParameters, {'url': url});
  });

  testWidgets('new profiles save the entered name and original sing-box content', (tester) async {
    Json? saved;
    await _mount(tester, handler: (call) async {
      if (dutyOp(call) == 'save') saved = dutyPayload(call);
      return null;
    });
    openForm(tester.element(find.byType(HomePage)),
      const ConfigurationForm(initial: {'content': '{"log":{"level":"info"}}'}));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'My profile');
    await tester.tap(find.byTooltip('Save').last);
    await tester.pumpAndSettle();
    expect(saved?['name'], 'My profile');
    expect(saved?['content'], '{"log":{"level":"info"}}');
    expect(find.byType(ConfigurationForm), findsNothing);
  });

  testWidgets('a subscription may be saved without a name', (tester) async {
    Json? saved;
    await _mount(tester, handler: (call) async {
      if (dutyOp(call) == 'save') saved = dutyPayload(call);
      return null;
    });
    openForm(tester.element(find.byType(HomePage)),
      const ConfigurationForm(initial: _remote));
    await tester.pumpAndSettle();
    // The host names the subscription from its Profile-Title or URL host.
    await tester.enterText(find.byType(TextFormField).first, '');
    await tester.tap(find.byTooltip('Save').last);
    await tester.pumpAndSettle();
    expect(saved?['name'], '');
    expect(find.byType(ConfigurationForm), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('binary subscription metadata survives the import form', (tester) async {
    Json? saved;
    await _mount(tester, handler: (call) async {
      if (dutyOp(call) == 'save') saved = dutyPayload(call);
      return null;
    });
    const imported = {'name': 'Imported subscription', 'content': '{}', 'remote': true,
      'url': 'https://example.com/config.json', 'autoUpdate': false, 'interval': 120, 'updatedAt': 1700000000000};
    openForm(tester.element(find.byType(HomePage)), const ConfigurationForm(initial: imported));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save').last);
    await tester.pumpAndSettle();
    expect(saved, imported);
    expect(find.byType(ConfigurationForm), findsNothing);
  });

  testWidgets('skipDeleteConfirmation deletes without asking', (tester) async {
    // The General page offers this switch; before this change it was stored and
    // never read, so the confirm dialog appeared no matter what the user chose.
    Json? deleted;
    final box = await _mount(tester, handler: (call) async {
      if (dutyOp(call) == 'delete') deleted = dutyPayload(call);
      return null;
    });
    box.settings = {'skipDeleteConfirmation': true};
    await _profiles(tester);

    final card = tester.widget<ConfigurationCard>(find.byType(ConfigurationCard).first);
    card.menuItems.last.onPressed!();
    await tester.pumpAndSettle();

    expect(find.text('Delete this profile?'), findsNothing,
        reason: 'the switch must suppress the confirm dialog');
    expect(deleted, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without the switch a delete still asks first', (tester) async {
    Json? deleted;
    final box = await _mount(tester, handler: (call) async {
      if (dutyOp(call) == 'delete') deleted = dutyPayload(call);
      return null;
    });
    box.settings = {'skipDeleteConfirmation': false};
    await _profiles(tester);

    final card = tester.widget<ConfigurationCard>(find.byType(ConfigurationCard).first);
    card.menuItems.last.onPressed!();
    await tester.pumpAndSettle();

    expect(find.text('Delete this profile?'), findsOneWidget);
    expect(deleted, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bar button switches mode and configuration together', (tester) async {
    final ops = <String>[];
    String? selected;
    await _mount(tester, profiles: const [
      _remote,
      _local,
      // The single-node container: marked `single`, so the profile grid hides it.
      {'id': 3, 'name': 'Single nodes', 'remote': false, 'single': true},
    ], handler: (call) async {
      final op = dutyOp(call);
      if (op != null) ops.add(op);
      if (op == 'select') selected = dutyPayload(call)['id']?.toString();
      if (op == 'nodeList') {
        return {
          'groupId': 3,
          'groupName': 'Single nodes',
          'nodes': [
            {'id': 11, 'name': 'Node A', 'type': 'vmess', 'delay': 42, 'testedAt': 0},
            {'id': 12, 'name': 'Node B', 'type': 'hysteria2', 'delay': 0, 'testedAt': 0},
          ],
        };
      }
      return null;
    });
    await _profiles(tester);

    // The two modes show their own content: the container is not a profile card.
    expect(find.text('Single nodes'), findsNothing);
    expect(find.text('Remote A'), findsOneWidget);

    // The bar's button flips to the node page (Bettbox's single control).
    final switchButton = find.byKey(const ValueKey('profiles-mode-switch'));
    await tester.tap(switchButton);
    await tester.pumpAndSettle();

    expect(find.text('Node A'), findsOneWidget);
    expect(find.text('Node B'), findsOneWidget);
    expect(ops, contains('nodeList'));
    // Mode and configuration switch together: the container becomes current.
    expect(selected, '3');

    // Adding is the shared bottom-right circle; the bar carries the sort plus
    // the same Profiles/Nodes switch the grid has.
    final addNode = find.byTooltip('Add node');
    final page = tester.getRect(find.byType(Scaffold).first);
    expect(tester.getRect(addNode).center.dx, greaterThan(page.center.dx));
    expect(tester.getRect(addNode).center.dy, greaterThan(page.center.dy));
    expect(find.byTooltip('Reorder'), findsOneWidget);

    // The switch stays on the node bar: it is how the user goes back.
    expect(switchButton, findsOneWidget, reason: 'the node bar keeps the switch');
    await tester.tap(switchButton);
    await tester.pumpAndSettle();
    // ...and going back restores the subscription the user was on.
    expect(selected, '1');
    expect(find.text('Remote A'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // A horizontal swipe moves between the two pages too.
    await tester.fling(find.byType(IndexedStack), const Offset(-400, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text('Node A'), findsOneWidget);
    await tester.fling(find.byType(IndexedStack), const Offset(400, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text('Remote A'), findsOneWidget);
  });

  testWidgets('the node bar sorts the current node list, not the profile grid', (tester) async {
    var lists = 0;
    final orders = <Json>[];
    await _mount(tester, profiles: const [
      _remote,
      {'id': 3, 'name': 'Single nodes', 'remote': false, 'single': true},
    ], handler: (call) async {
      switch (dutyOp(call)) {
        case 'nodeList':
          lists++;
          return {
            'groupId': 3,
            'groupName': 'Single nodes',
            'nodes': [
              {'id': 11, 'name': 'Node A', 'type': 'vmess', 'delay': 42, 'testedAt': 0},
              {'id': 12, 'name': 'Node B', 'type': 'hysteria2', 'delay': 0, 'testedAt': 0},
            ],
          };
        case 'nodeReorder':
          orders.add(dutyPayload(call));
          return null;
      }
      return null;
    });
    await _profiles(tester);
    await tester.tap(find.byKey(const ValueKey('profiles-mode-switch')));
    await tester.pumpAndSettle();
    expect(find.text('Node A'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nodes-reorder')));
    await tester.pumpAndSettle();
    expect(find.byType(NodeOrderPage), findsOneWidget);
    expect(find.byType(ConfigurationOrderPage), findsNothing,
        reason: 'the node sort must not reorder the profile grid');

    tester.widget<ReorderableListView>(find.byType(ReorderableListView)).onReorderItem!(0, 1);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save').last);
    await tester.pumpAndSettle();

    expect(orders, [
      {'groupId': 3, 'ids': [12, 11]},
    ]);
    expect(find.byType(NodeOrderPage), findsNothing);
    expect(lists, 2, reason: 'the node list reloads after the save');
    expect(find.text('Node A'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single-node import ends on the node page with the imported node', (tester) async {
    final ops = <String>[];
    Json? saved;
    // The clipboard is the import source; _mount does not mock the platform channel.
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async =>
        call.method == 'Clipboard.getData' ? {'text': 'ss://node-a'} : null);
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await _mount(tester, profiles: const [
      _remote,
      // The node container is hidden from the grid; importing its first node must still end somewhere visible.
      {'id': 3, 'name': 'Single nodes', 'remote': false, 'single': true},
    ], handler: (call) async {
      final op = dutyOp(call);
      if (op != null) ops.add(op);
      switch (op) {
        case 'decodeIntent':
          return {'name': 'Node A', 'url': '', 'remote': false, 'autoUpdate': false,
            'interval': 0, 'content': 'ss://node-a', 'nodeCount': 1};
        case 'save':
          saved = dutyPayload(call);
          return 3;
        case 'nodeList':
          return {'groupId': 3, 'groupName': 'Single nodes', 'nodes': [
            {'id': 9, 'name': 'Node A', 'type': 'vmess', 'delay': 0, 'testedAt': 0},
          ]};
      }
      return null;
    });
    await _profiles(tester);
    expect(find.text('Single nodes'), findsNothing, reason: 'the container is not a profile card');

    final fab = find.byTooltip('Add profile');
    expect(fab, findsOneWidget);
    final fabRect = tester.getRect(fab);
    final page = tester.getRect(find.byType(Scaffold).first);
    expect(fabRect.center.dx, greaterThan(page.center.dx), reason: 'the add action sits bottom-right');
    expect(fabRect.center.dy, greaterThan(page.center.dy));

    await tester.tap(fab);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clipboard'));
    await tester.pumpAndSettle();
    // One link is reviewed in the form, then imported by the host into the node container. Single
    // nodes always belong to that container, so the form saves directly — even though another
    // profile is on screen, it never asks for a target group.
    expect(find.byType(ConfigurationForm), findsOneWidget);
    await tester.tap(find.byTooltip('Save').last);
    await tester.pumpAndSettle();

    expect(saved?['content'], 'ss://node-a');
    expect(saved?['url'], '');
    // The form closed and the screen switched to the node page, where the imported node is listed.
    expect(find.byType(ConfigurationForm), findsNothing);
    expect(find.text('Node A'), findsOneWidget);
    expect(ops, containsAllInOrder(['decodeIntent', 'save', 'nodeList']));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the profiles/nodes mode is remembered across launches', (tester) async {    final saved = <String, dynamic>{};
    await _mount(
      tester,
      // The last session was left on the node page.
      preferences: {'profilesMode': 1},
      handler: (call) async {
        if (call.method == 'preferences.set') {
          saved.addAll(json((call.arguments as Map)['value']));
          return <String, dynamic>{'locale': 'en', ...saved};
        }
        return null;
      },
    );
    await _profiles(tester);
    // The node page is the one on screen: the header carries the node action
    // and the profile cards are not rendered.
    expect(find.byTooltip('Add node'), findsOneWidget);
    expect(find.byType(ConfigurationCard), findsNothing);
    // Switching back to the grid records the mode for the next launch.
    await tester.fling(find.byType(IndexedStack), const Offset(400, 0), 1200);
    await tester.pumpAndSettle();
    expect(saved['profilesMode'], 0);
    expect(find.byType(ConfigurationCard), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('update all ends in one dialog that lists every failed profile beside the success count', (tester) async {
    final updates = <int>[];
    final box = await _mount(tester, profiles: const [_remote, _remoteB, _remoteC, _local],
      handler: (call) async {
        if (dutyOp(call) == 'update') {
          final id = (dutyPayload(call)['id'] as num).toInt();
          updates.add(id);
          if (id != _remoteB['id']) throw PlatformException(code: 'queue', message: 'Download refused');
        }
        return null;
      });
    await _profiles(tester);
    _updateAllAction(tester)();
    await _pumpUntil(tester, find.text('Some profiles were not updated'));
    // Only the subscriptions ran: the local profile has no queue entry.
    expect(updates, [1, 4, 5]);
    expect(find.byType(AlertDialog), findsOneWidget);
    // The successful profile is counted, not hidden behind the failures.
    expect(find.text('Updated: 1 · Failed: 2'), findsOneWidget);
    expect(find.text('Remote A: Download refused'), findsOneWidget);
    expect(find.text('Remote C: Download refused'), findsOneWidget);
    expect(find.text('Remote B: Download refused'), findsNothing);
    expect(find.text('Tap update all again to retry the failed profiles.'), findsOneWidget);
    // One surface for the whole run: the refusals did not also stack as banners.
    expect(find.textContaining('Download refused'), findsNWidgets(2));
    expect(box.subscriptionCollector, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unnamed download error is shown but does not undercount the update summary', (tester) async {
    final events = StreamController<dynamic>.broadcast();
    final box = await _mount(tester, eventController: events);
    await _profiles(tester);
    _updateAllAction(tester)();
    await tester.pump();
    // A queue-level error carries no profile name: it is still surfaced, but
    // it must not be counted as a failed profile (attempted - failures).
    events.add({'type': 'subscriptionReport', 'value': {
      'kind': 'error', 'text': 'Queue unavailable',
    }});
    await _pumpUntil(tester, find.text('Some profiles were not updated'));
    expect(find.text('Updated: 1 · Failed: 0'), findsOneWidget);
    expect(find.text('Queue unavailable'), findsOneWidget);
    expect(box.subscriptionCollector, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a clean update all run ends in a single banner', (tester) async {
    final updates = <int>[];
    final box = await _mount(tester, profiles: const [_remote, _remoteB, _local],
      handler: (call) async {
        if (dutyOp(call) == 'update') updates.add((dutyPayload(call)['id'] as num).toInt());
        return null;
      });
    await _profiles(tester);
    _updateAllAction(tester)();
    await _pumpUntil(tester, find.text('Updated 2 profiles'));
    expect(updates, [1, 4]);
    expect(find.byType(AlertDialog), findsNothing);
    // The quiet seam is one-shot: the next report surfaces normally again.
    expect(box.subscriptionCollector, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a download report is folded into the run instead of popping as a second surface', (tester) async {
    final events = StreamController<dynamic>.broadcast();
    final box = await _mount(tester, eventController: events);
    await _profiles(tester);
    _updateAllAction(tester)();
    await tester.pump();
    // The download's own outcome is a report event, not the enqueue's answer.
    events.add({'type': 'subscriptionReport', 'value': {
      'kind': 'error', 'groupName': 'Remote A', 'text': 'Download failed',
    }});
    await _pumpUntil(tester, find.text('Some profiles were not updated'));
    expect(find.text('Updated: 0 · Failed: 1'), findsOneWidget);
    // Held by the collector, so the error is listed once instead of also
    // arriving as a transient banner while the dialog is up.
    expect(find.text('Remote A: Download failed'), findsOneWidget);
    expect(find.textContaining('Download failed'), findsOneWidget);
    expect(box.subscriptionCollector, isNull);
    // The seam is one-shot: a later report is a banner again.
    events.add({'type': 'subscriptionReport', 'value': {
      'kind': 'error', 'groupName': 'Remote A', 'text': 'Later failure',
    }});
    await tester.pump();
    await tester.pump();
    expect(find.text('Remote A: Later failure'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
