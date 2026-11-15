// The Routing screen, rebuilt to Throne for Android's RouteFragment: one card
// per route profile with the current one badged, the Throne summary line, the
// remote bookkeeping, the pencil and the per-card menu, plus the editor behind
// it.
//
// The screen's writes are the frozen route API: `routeSetCurrent`,
// `routeSaveProfile`, `routeDeleteProfile`, `routeSaveRules`,
// `routeBatchAddRules`. The fake kernel answers them and records what it was
// handed, so an assertion about a write is an assertion about the wire.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';
import 'support/fake_route_kernel.dart';

Map<String, Object?> profile(
  String name, {
  int id = 1,
  bool current = false,
  bool isRemote = false,
  bool isRaw = false,
  int ruleCount = 3,
  String defaultOutbound = 'proxy',
}) => {
      'id': id,
      'name': name,
      'defaultOutbound': defaultOutbound,
      'current': current,
      'isRemote': isRemote,
      'isRaw': isRaw,
      'ruleCount': ruleCount,
      'simpleRuleCount': 0,
    };

Map<String, Object?> rule(String name, {int disabled = 0, String outbound = 'direct'}) => {
      'name': name,
      'type': 'custom',
      'disabled': disabled != 0,
      'action': 'route',
      'outbound_id': outbound == 'direct' ? -2 : -1,
      'domain': <String>['example.test'],
      'domain_suffix': <String>[],
      'ip_cidr': <String>[],
      'rule_set': <String>[],
      'port': <String>[],
      'invert': false,
      'no_drop': false,
      'sniff_override_dest': false,
      'network_is_expensive': false,
      'ip_is_private': false,
      'source_ip_is_private': false,
      'tls_fragment': false,
      'tls_record_fragment': false,
    };

void main() {
  late StreamController<dynamic> events;
  late List<Map<String, Object?>> profiles;
  late Map<int, List<Map<String, Object?>>> profileRules;
  late int currentId;

  // What the writes did, for the assertions. `selectedId` is the Go bus's
  // `setCurrentRoute` (the document marker alone); `hostSelectedId` is the
  // channel's `state.setCurrentRoute`, the host pair that also writes Room's
  // settings row. A tap must reach the host and must not reach the bare action.
  late int selectedId;
  late int hostSelectedId;
  late List<Map<String, Object?>> savedProfiles;
  late int deletedId;
  late Map<int, List<Map<String, Object?>>> savedRules;
  late String batchText;
  late int batchProfileId;

  // The fake kernel wants Object?, because two arms answer a bare id.
Object? routeFixtures(ActionMethod method, Object? data) {
    final payload = data is Map ? data : const <String, dynamic>{};
    switch (method) {
      case ActionMethod.getRouteProfiles:
        return {'currentId': currentId, 'profiles': profiles};
      case ActionMethod.getRouteProfile:
        final id = (payload['id'] as num?)?.toInt() ?? 0;
        final found = profiles.where((p) => (p['id'] as num?)?.toInt() == id).firstOrNull;
        if (found == null) {
          return {
            'id': id,
            'name': '',
            'defaultOutbound': 'direct',
            'isRemote': false,
            'remoteUrl': '',
            'autoUpdate': false,
            'isRaw': false,
            'rules': '',
            'ruleCount': 0,
          };
        }
        return {
          ...found,
          'remoteUrl': found['isRemote'] == true ? 'https://example.test/route.json' : '',
          'autoUpdate': found['isRemote'] == true,
          'rules': '',
        };
      case ActionMethod.getRouteRules:
        final id = (payload['id'] as num?)?.toInt() ?? 0;
        return {'rules': profileRules[id] ?? const []};
      case ActionMethod.saveRouteRules:
        final id = (payload['id'] as num?)?.toInt() ?? 0;
        final rules = [
          for (final entry in payload['rules'] as List? ?? const [])
            Map<String, Object?>.from(entry as Map),
        ];
        savedRules[id] = rules;
        profileRules[id] = rules;
        return {'rules': rules};
      case ActionMethod.saveRouteProfile:
        savedProfiles.add(Map<String, Object?>.from(payload));
        final id = (payload['id'] as num?)?.toInt() ?? 0;
        if (id <= 0) {
          profiles = [
            ...profiles,
            profile(payload['name']?.toString() ?? 'New', id: 9, isRemote: payload['isRemote'] == true),
          ];
          return 9;
        }
        profiles = [
          for (final entry in profiles)
            if ((entry['id'] as num?)?.toInt() == id)
              {
                ...entry,
                'name': payload['name'] ?? entry['name'],
                'defaultOutbound': payload['defaultOutbound'] ?? entry['defaultOutbound'],
              }
            else
              entry,
        ];
        return id;
      case ActionMethod.setCurrentRoute:
        // The bare Go action: it moves the kernel's document marker only, and a
        // UI selection must not stop here (SQLite 522).
        selectedId = (payload['id'] as num?)?.toInt() ?? 0;
        currentId = selectedId;
        return {'currentId': currentId};
      case ActionMethod.deleteRouteProfile:
        deletedId = (payload['id'] as num?)?.toInt() ?? 0;
        profiles = [
          for (final entry in profiles)
            if ((entry['id'] as num?)?.toInt() != deletedId) entry,
        ];
        return null;
      case ActionMethod.batchAddRules:
        batchProfileId = (payload['id'] as num?)?.toInt() ?? 0;
        batchText = payload['text']?.toString() ?? '';
        return {'added': 1, 'rules': profileRules[batchProfileId] ?? const []};
      case ActionMethod.resetRouteRules:
        return {'rules': [rule('Route DNS')]};
      default:
        return null;
    }
  }

  Future<void> mount(
    WidgetTester tester, {
    List<Map<String, Object?>>? routeProfiles,
    Map<int, List<Map<String, Object?>>>? rules,
  }) async {
    reportFlutterErrors();
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    profiles = routeProfiles ?? [profile('Default', current: true)];
    currentId = 1;
    profileRules = rules ?? {1: [rule('Route DNS')], 2: [rule('Pinned LAN')]};
    selectedId = 0;
    hostSelectedId = 0;
    savedProfiles = [];
    deletedId = 0;
    savedRules = {};
    batchText = '';
    batchProfileId = 0;

    const channel = MethodChannel('test.route-fragment');
    events = StreamController<dynamic>.broadcast();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'ready':
          return {
            'version': 'test',
            'coreVersion': 'test',
            'preferences': {'locale': 'en'},
            'dashboard': {'status': 'Stopped'},
          };
        case 'groups.nodes':
          return {
            'nodes': [
              {'id': 10, 'tag': 'Node A'},
            ],
          };
      }
      if (call.method == 'routes.presets') {
        return {
          'bundles': [
            {
              'country': 'China',
              'entries': [
                {'name': 'China full', 'url': 'https://example.test/china.json'},
              ],
            },
          ],
        };
      }
      if (call.method == 'state.setCurrentRoute') {
        // The host arm: it writes DataStore.currentRouteId (Room's settings row)
        // and then asks the kernel to move the document marker. Both halves are
        // the host's business, so this only records the id it was handed and the
        // selection the list re-read must show; `selectedId` stays untouched,
        // which is what proves the page never takes the bare Go path.
        final id = ((call.arguments as Map?)?['id'] as num?)?.toInt() ?? 0;
        hostSelectedId = id;
        currentId = id;
        return {'id': id};
      }
      if (call.method == 'routes.ruleSets') {
        return {
          'total': 1,
          'entries': [
            {'name': 'geosite-cn', 'url': 'https://example.test/geosite-cn.srs'},
          ],
        };
      }
      return null;
    });
    final box = BoxController(channel: channel, events: events.stream);
    box.kernel.debugAttach(FakeRouteKernel(routeFixtures), NoopKernelWorker());
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

  group('the route list', () {
    testWidgets('a card per profile, the current one badged with its Throne summary', (tester) async {
      await mount(tester, routeProfiles: [
        profile('Default', current: true),
        profile('Bypass China', id: 2, ruleCount: 4, defaultOutbound: 'direct'),
      ]);
      await openRouting(tester);

      expect(find.text('Default'), findsOneWidget);
      expect(find.text('Bypass China'), findsOneWidget);
      // Throne's summary line: "Default: proxy · 3 rules".
      expect(find.text('Default: proxy · 3 rules'), findsOneWidget);
      expect(find.text('Default: direct · 4 rules'), findsOneWidget);
      expect(find.byType(SelectionBadge), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a remote card carries its remote line and no service switches', (tester) async {
      await mount(tester, routeProfiles: [profile('Subscribed', id: 2, isRemote: true, current: true)]);
      await openRouting(tester);

      expect(find.textContaining('Remote ·'), findsOneWidget);
      expect(find.textContaining('Auto update on'), findsOneWidget);
      // The managed-mode service list is gone: this screen is the profile list.
      expect(find.text('Telegram'), findsNothing);
      expect(find.text('Google'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a raw card says so and cannot become current', (tester) async {
      await mount(tester, routeProfiles: [
        profile('Default', current: true),
        profile('Imported raw', id: 2, isRaw: true),
      ]);
      await openRouting(tester);

      expect(find.text('Read-only'), findsOneWidget);
      await tester.tap(find.text('Imported raw'));
      await tester.pumpAndSettle();
      expect(selectedId, 0, reason: 'a raw profile is never selectable');
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a card makes it current through the host, not the bare action', (tester) async {
      await mount(tester, routeProfiles: [
        profile('Default', current: true),
        profile('Bypass China', id: 2, ruleCount: 4),
      ]);
      await openRouting(tester);

      await tester.tap(find.text('Bypass China'));
      await tester.pumpAndSettle();
      expect(hostSelectedId, 2, reason: 'the tap must write the host pair');
      expect(selectedId, 0, reason: 'the bare Go action writes no settings row (SQLite 522)');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a raw card never reaches the host either', (tester) async {
      await mount(tester, routeProfiles: [
        profile('Default', current: true),
        profile('Imported raw', id: 2, isRaw: true),
      ]);
      await openRouting(tester);

      await tester.tap(find.text('Imported raw'));
      await tester.pumpAndSettle();
      expect(hostSelectedId, 0);
      expect(selectedId, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty list offers the new action instead of a spinner', (tester) async {
      await mount(tester, routeProfiles: []);
      await openRouting(tester);

      expect(find.text('No route profiles yet'), findsOneWidget);
      expect(find.byType(ActivityIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('the card menu', () {
    testWidgets('offers edit, clone, share and delete', (tester) async {
      await mount(tester);
      await openRouting(tester);

      await tester.tap(find.byTooltip('Action'));
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Clone'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      // Update is a remote-only action.
      expect(find.text('Update'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a remote card adds Update to the menu', (tester) async {
      await mount(tester, routeProfiles: [profile('Subscribed', id: 2, isRemote: true, current: true)]);
      await openRouting(tester);

      await tester.tap(find.byTooltip('Action'));
      await tester.pumpAndSettle();
      expect(find.text('Update'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('clone saves a local copy and its rules', (tester) async {
      await mount(tester);
      await openRouting(tester);

      await tester.tap(find.byTooltip('Action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clone'));
      await tester.pumpAndSettle();

      expect(savedProfiles, hasLength(1));
      expect(savedProfiles.single['name'], 'Default clone');
      expect(savedProfiles.single['isRemote'], isFalse);
      // The copy took the source's rules with it.
      expect(savedRules[9], hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('delete asks first, then removes the profile', (tester) async {
      await mount(tester, routeProfiles: [
        profile('Default', current: true),
        profile('Bypass China', id: 2),
      ]);
      await openRouting(tester);

      await tester.tap(find.byTooltip('Action').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this route profile?'), findsOneWidget);

      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      expect(deletedId, 2);
      expect(find.text('Bypass China'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the last profile cannot be deleted', (tester) async {
      await mount(tester);
      await openRouting(tester);

      await tester.tap(find.byTooltip('Action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Delete this route profile?'), findsNothing);
      expect(deletedId, 0);
      expect(tester.takeException(), isNull);
    });
  });

  group('the editor', () {
    testWidgets('the pencil opens the profile with its rules', (tester) async {
      await mount(tester);
      await openRouting(tester);

      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();

      expect(find.byType(RouteProfileEditorPage), findsOneWidget);
      expect(find.text('Route DNS'), findsOneWidget);
      expect(find.text('Rules (1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('save writes the header and the whole rule list', (tester) async {
      await mount(tester);
      await openRouting(tester);
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(savedProfiles, hasLength(1));
      expect(savedProfiles.single['id'], 1);
      expect(savedProfiles.single['name'], 'Default');
      expect(savedRules[1], hasLength(1));
      // The rule went out in the store's column spelling.
      expect(savedRules[1]!.single['domain_json'], ['example.test']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a rule opens its editor, and saving it keeps the other fields', (tester) async {
      await mount(tester);
      await openRouting(tester);
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Route DNS'));
      await tester.pumpAndSettle();
      expect(find.byType(RouteRuleEditorPage), findsOneWidget);
      // The action-driven fields: a route rule has an outbound, no reject method.
      expect(find.text('Outbound'), findsOneWidget);
      expect(find.text('Reject method'), findsNothing);

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(savedRules[1], hasLength(1));
      expect(savedRules[1]!.single['domain_json'], ['example.test']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the delete in the rule editor removes the rule', (tester) async {
      await mount(tester);
      await openRouting(tester);
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Route DNS'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete').first);
      await tester.pumpAndSettle();

      expect(find.text('Rules (0)'), findsOneWidget);
      expect(find.text('No rules yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the add-rule footer opens the rule editor', (tester) async {
      await mount(tester);
      await openRouting(tester);
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add rule').last);
      await tester.pumpAndSettle();

      expect(find.byType(RouteRuleEditorPage), findsOneWidget);
      expect(find.text('Match'), findsOneWidget);
      // The advanced group is collapsed: its fields are not drawn yet.
      expect(find.text('Domain keyword'), findsNothing);
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      expect(find.text('Domain keyword'), findsOneWidget);
      expect(find.text('WiFi access point'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reorder moves a rule in the local list', (tester) async {
      await mount(tester, rules: {
        1: [rule('First'), rule('Second')],
      });
      await openRouting(tester);
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();

      expect(find.text('Rules (2)'), findsOneWidget);
      await tester.tap(find.byTooltip('Move').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move down'));
      await tester.pumpAndSettle();

      // The local list order decides what Save writes.
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(savedRules[1], hasLength(2));
      expect(savedRules[1]!.first['name'], 'Second');
      expect(tester.takeException(), isNull);
    });

    testWidgets('bulk add sends the pasted lines', (tester) async {
      await mount(tester);
      await openRouting(tester);
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Bulk add'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('route-batch-add-field')),
        'suffix:example.com -> proxy',
      );
      await tester.tap(find.text('Add').last);
      await tester.pumpAndSettle();

      expect(batchProfileId, 1);
      expect(batchText, contains('suffix:example.com -> proxy'));
      expect(tester.takeException(), isNull);
    });
  });

  group('the toolbar', () {
    testWidgets('New opens the editor on an empty profile', (tester) async {
      await mount(tester);
      await openRouting(tester);

      await tester.tap(find.byTooltip('New'));
      await tester.pumpAndSettle();

      expect(find.byType(RouteProfileEditorPage), findsOneWidget);
      expect(find.text('New route profile'), findsOneWidget);
      // A new profile is seeded with the DNS hijack rule.
      expect(find.text('Rules (1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the menu reaches the structured and remote new profiles and settings', (tester) async {
      await mount(tester);
      await openRouting(tester);

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Structured profile'), findsOneWidget);
      expect(find.text('Remote profile'), findsOneWidget);
      expect(find.text('Import'), findsOneWidget);
      expect(find.text('Update all remote profiles'), findsOneWidget);
      expect(find.text('Routing settings'), findsOneWidget);
      expect(find.text('Download profiles'), findsOneWidget);
      // No control without a backing call: the rule-set refresh and the
      // repository refresh have no bridge arm in this build.
      expect(find.text('Update rule-sets'), findsNothing);
      expect(find.text('Refresh repository'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Routing settings opens the engine switches', (tester) async {
      await mount(tester);
      await openRouting(tester);

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Routing settings'));
      await tester.pumpAndSettle();

      expect(find.text('Outbound domain strategy'), findsOneWidget);
      expect(find.text('Ad blocking'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Download profiles lists the bundled countries and saves one', (tester) async {
      await mount(tester);
      await openRouting(tester);

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download profiles'));
      await tester.pumpAndSettle();
      expect(find.text('China · 1'), findsOneWidget);

      await tester.tap(find.text('China · 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('China full'));
      await tester.pumpAndSettle();

      expect(savedProfiles, hasLength(1));
      expect(savedProfiles.single['name'], 'China full');
      expect(savedProfiles.single['isRemote'], isTrue);
      expect(savedProfiles.single['remoteUrl'], 'https://example.test/china.json');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Import opens the paste sheet', (tester) async {
      await mount(tester);
      await openRouting(tester);

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();

      expect(find.byType(RouteImportPage), findsOneWidget);
      expect(find.text('Route link or document'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the import codec', () {
    test('a share link and the same JSON both parse to the profile', () {
      final document = parseRouteDocument(routeShareLink(
        name: 'Shared',
        defaultOutbound: 'proxy',
        rules: [rule('DNS')],
      ));
      expect(document, isNotNull);
      expect(document!.name, 'Shared');
      expect(document.defaultOutbound, 'proxy');
      expect(document.rules, hasLength(1));
      // The parsed document is in the editor's shape, which keeps the short
      // names; ruleToWire is what spells them for the store on save.
      expect(document.rules.single['domain'], ['example.test']);

      final plain = parseRouteDocument('{"name":"Plain","default_outbound":"direct","rules":[{"action":"reject"}]}');
      expect(plain!.name, 'Plain');
      expect(plain.rules.single['action'], 'reject');
    });

    test('a bare rule array is a legacy profile', () {
      final document = parseRouteDocument('[{"action":"route","outbound":"proxy","domain":["a.test"]}]');
      expect(document!.legacyArray, isTrue);
      expect(document.rules.single['outbound_id'], -1);
      expect(document.rules.single['domain'], ['a.test']);
    });

    test('a remote-profile link is refused with a reason, not half-imported', () async {
      expect(
        () => importRouteText('throne://remoteroute/abc'),
        throwsA(isA<StateError>()),
      );
      expect(parseRouteDocument('not json at all'), isNull);
    });

    test('the remote URL guard refuses private and loopback hosts', () {
      expect(isSafeRemoteRouteUrl('https://example.com/route.json'), isTrue);
      expect(isSafeRemoteRouteUrl('https://raw.githubusercontent.com/a/b'), isTrue);
      expect(isSafeRemoteRouteUrl('http://127.0.0.1/route.json'), isFalse);
      expect(isSafeRemoteRouteUrl('http://localhost/route.json'), isFalse);
      expect(isSafeRemoteRouteUrl('http://192.168.1.1/route.json'), isFalse);
      expect(isSafeRemoteRouteUrl('http://10.0.0.5/route.json'), isFalse);
      expect(isSafeRemoteRouteUrl('ftp://example.com/route.json'), isFalse);
      expect(isSafeRemoteRouteUrl('intranet/route.json'), isFalse);
    });
  });
}
