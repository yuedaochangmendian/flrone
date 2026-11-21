import 'dart:async';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flrone/components/profile_card.dart';
import 'package:flrone/pages/profiles.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/profile_duty.dart';

const _remote = {'id': 1, 'name': 'Remote A', 'remote': true,
  'url': 'https://example.org/config.json', 'autoUpdate': true, 'interval': 120, 'updatedAt': 1700000000000};
const _local = {'id': 2, 'name': 'Local B', 'remote': false};

Future<BoxController> _mount(WidgetTester tester, {List<Json> profiles = const [_remote, _local],
  int selected = 1, bool remoteSession = false, StreamController<dynamic>? eventController,
  Json dashboard = const {},
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
  messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready' ? {
    'version': 'test', 'coreVersion': 'test', 'profiles': profiles,
    'dashboard': {'status': 'Stopped', 'selectedProfileId': selected,
      if (remoteSession) ...{'remote': 'Server', 'remoteConnected': true}, ...dashboard},
  } : await handler?.call(call));
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
      expect(profileUpdateLabel(updated, now, chinese: false), en);
      expect(profileUpdateLabel(updated, now, chinese: true), zh);
    }
    expect(profileUpdateLabel(0, now, chinese: false), 'Unknown');
    expect(profileUpdateLabel(null, now, chinese: true), '未知');
    expect(profileUpdateLabel(now.add(const Duration(days: 1)).millisecondsSinceEpoch, now, chinese: false), 'Just now');
  });

  testWidgets('subscriptionState events drive the refresh spinner across the whole download', (tester) async {
    final events = StreamController<dynamic>.broadcast();
    final box = await _mount(tester, eventController: events);
    await _profiles(tester);
    final remoteCard = find.byWidgetPredicate((w) => w is ProfileCard && w.profile['id'] == 1);

    // The enqueue returns in milliseconds; the live queue state is what keeps the card
    // spinning while the download runs. Profile card id == group id (BboxCatalog.profileOf).
    expect(tester.widget<ProfileCard>(remoteCard).updating, isFalse);
    expect(box.subscriptionStates, isEmpty);

    events.add({'type': 'subscriptionState', 'value': {'gid': 1, 'state': 1}}); // QUEUED
    await tester.pump();
    await tester.pump();
    expect(box.subscriptionStates[1], 1);
    expect(tester.widget<ProfileCard>(remoteCard).updating, isTrue);
    // Update-all is disabled while a group is queued/running.
    expect(tester.widget<Scaffold>(find.byType(Scaffold).first).iconActions
        .firstWhere((a) => a.tooltip == 'Update all').onPressed, isNull);

    events.add({'type': 'subscriptionState', 'value': {'gid': 1, 'state': 2}}); // RUNNING
    await tester.pump();
    await tester.pump();
    expect(box.subscriptionStates[1], 2);
    expect(tester.widget<ProfileCard>(remoteCard).updating, isTrue);

    events.add({'type': 'subscriptionState', 'value': {'gid': 1, 'state': 0}}); // IDLE
    await tester.pump();
    await tester.pump();
    expect(box.subscriptionStates, isEmpty);
    expect(tester.widget<ProfileCard>(remoteCard).updating, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty state opens the add menu and canceled file import stays on profiles', (tester) async {
    final calls = <String>[];
    await _mount(tester, profiles: [], handler: (call) async { calls.add(dutyOp(call) ?? call.method); return null; });
    await _profiles(tester);
    await tester.tap(find.text('Add profile').last);
    await tester.pumpAndSettle();
    expect(find.byType(AddProfilePage), findsNothing);
    for (final label in ['Scan QR code', 'File', 'Import from URL', 'Clipboard', 'New profile']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    expect(calls.where((method) => method == 'files.pickProfile'), hasLength(1));
    expect(find.byType(ProfileForm), findsNothing);
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
    final remoteCard = find.byWidgetPredicate((w) => w is ProfileCard && w.profile['id'] == 1);
    final localCard = find.byWidgetPredicate((w) => w is ProfileCard && w.profile['id'] == 2);
    final remote = tester.widget<ProfileCard>(remoteCard);
    final local = tester.widget<ProfileCard>(localCard);
    expect(remote.menuItems.map((item) => item.label), ['Edit', 'Group settings', 'Update', 'Copy link', 'QR code', 'Share', 'Export', 'Clear test results', 'Clear traffic statistics', 'Delete']);
    expect(local.menuItems.map((item) => item.label), ['Edit', 'Group settings', 'Share', 'Export', 'Clear test results', 'Clear traffic statistics', 'Delete']);
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
    final localCard = find.byWidgetPredicate((w) => w is ProfileCard && w.profile['id'] == 2);
    expect(find.descendant(of: localCard, matching: find.text('Just now')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only enabled automatic updates validate the minimum interval', (tester) async {
    Json? saved;
    await _mount(tester, handler: (call) async {
      if (dutyOp(call) == 'save') saved = dutyPayload(call);
      return null;
    });
    openForm(tester.element(find.byType(HomePage)), const ProfileForm(initial: _remote));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(2), '14');
    await tester.tap(find.byTooltip('Save').last);
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(find.byType(ProfileForm), findsOneWidget);
    await tester.tap(find.text('Auto update'));
    await tester.pumpAndSettle();
    expect(find.text('Update interval'), findsNothing);
    await tester.tap(find.byTooltip('Save').last);
    await tester.pumpAndSettle();
    expect(saved, {..._remote, 'autoUpdate': false});
    expect(find.byType(ProfileForm), findsNothing);
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
    openForm(tester.element(find.byType(HomePage)), const ProfilesPage(picker: true));
    await tester.pumpAndSettle();
    expect(find.text('Profile 1').hitTestable(), findsOneWidget);
    final picker = find.byWidgetPredicate((w) => w is ProfilesPage && w.picker);
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
          openForm(tester.element(find.byType(HomePage)), const ProfilesPage(picker: true));
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
        if (picker) expect(find.byWidgetPredicate((w) => w is ProfilesPage && w.picker), findsNothing);
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
    openForm(tester.element(find.byType(HomePage)), const ProfileOrderPage());
    await tester.pumpAndSettle();
    tester.widget<ReorderableListView>(find.byType(ReorderableListView)).onReorderItem!(0, 1);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save').last);
    await tester.pumpAndSettle();
    expect(orders, [[2, 1]]);
    expect(find.byType(ProfileOrderPage), findsOneWidget);
    fail = false;
    await tester.tap(find.byTooltip('Save').last);
    await tester.pumpAndSettle();
    expect(orders, [[2, 1], [2, 1]]);
    expect(find.byType(ProfileOrderPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote sessions expose no local profile actions', (tester) async {
    await _mount(tester, remoteSession: true, dashboard: {'profileName': 'Private local profile'},
      profiles: [{'id': 1, 'name': 'Private local profile'}]);
    expect(find.text('Remote configuration'), findsOneWidget);
    expect(find.text('Private local profile'), findsNothing);
    await _profiles(tester);
    expect(find.text('Disconnect remote session to edit local profiles'), findsOneWidget);
    expect(find.byType(ProfileCard), findsNothing);
    expect(find.byType(AddProfileMenu), findsNothing);
    expect(find.byTooltip('Update all'), findsNothing);
    expect(find.byTooltip('Reorder'), findsNothing);
  });

  test('remote profile links preserve names in the sing-box fragment', () {
    const name = '工作 #1 & home';
    const url = 'https://example.com/profile.json?token=a%26b';
    final link = Uri.parse(remoteProfileLink({'name': name, 'url': url}));
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
      const ProfileForm(initial: {'content': '{"log":{"level":"info"}}'}));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'My profile');
    await tester.tap(find.byTooltip('Save').last);
    await tester.pumpAndSettle();
    expect(saved?['name'], 'My profile');
    expect(saved?['content'], '{"log":{"level":"info"}}');
    expect(find.byType(ProfileForm), findsNothing);
  });

  testWidgets('binary subscription metadata survives the import form', (tester) async {
    Json? saved;
    await _mount(tester, handler: (call) async {
      if (dutyOp(call) == 'save') saved = dutyPayload(call);
      return null;
    });
    const imported = {'name': 'Imported subscription', 'content': '{}', 'remote': true,
      'url': 'https://example.com/config.json', 'autoUpdate': false, 'interval': 120, 'updatedAt': 1700000000000};
    openForm(tester.element(find.byType(HomePage)), const ProfileForm(initial: imported));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save').last);
    await tester.pumpAndSettle();
    expect(saved, imported);
    expect(find.byType(ProfileForm), findsNothing);
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

    final card = tester.widget<ProfileCard>(find.byType(ProfileCard).first);
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

    final card = tester.widget<ProfileCard>(find.byType(ProfileCard).first);
    card.menuItems.last.onPressed!();
    await tester.pumpAndSettle();

    expect(find.text('Delete this profile?'), findsOneWidget);
    expect(deleted, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the segment switches to the selected profile\'s nodes', (tester) async {
    final ops = <String>[];
    await _mount(tester, handler: (call) async {
      final op = dutyOp(call);
      if (op != null) ops.add(op);
      if (op == 'nodeList') {
        return {
          'groupId': 1,
          'nodes': [
            {'id': 11, 'name': 'Node A', 'type': 'vmess', 'delay': 42, 'testedAt': 0},
            {'id': 12, 'name': 'Node B', 'type': 'hysteria2', 'delay': 0, 'testedAt': 0},
          ],
        };
      }
      return null;
    });
    await _profiles(tester);

    // The switch is this screen's own header: both pages live in the segment.
    final segment = find.byType(SegmentedControl<int>);
    expect(segment, findsOneWidget);
    await tester.tap(find.descendant(of: segment, matching: find.text('Nodes')));
    await tester.pumpAndSettle();

    expect(find.text('Node A'), findsOneWidget);
    expect(find.text('Node B'), findsOneWidget);
    expect(ops, contains('nodeList'));
    expect(tester.takeException(), isNull);
  });
}
