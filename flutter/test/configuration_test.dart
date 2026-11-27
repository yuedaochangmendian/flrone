import 'dart:async';
import 'dart:convert';
import 'package:flrone/data/configuration_store.dart';
import 'package:flrone/data/configuration_store_source.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flrone/pages/configuration.dart';
import 'package:flrone/pages/configuration_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/errors.dart';
import 'support/profile_duty.dart';

/// The Dart-owned configuration document behind the facades: the editor's
/// `config`/`write` and the export `read` are answered by the store now, so a
/// page test seeds one instead of mocking `profiles.platform`.
ConfigurationStore _store() => ConfigurationStore(
      path: '/app/files/documents/profiles.json',
      fs: MemoryConfigurationStoreFs(),
    );

ConfigurationStoreSource _source(ConfigurationStore store) =>
    ConfigurationStoreSource(
      resolvePath: () async => {'path': '/app/databases/sager_net.db'},
      store: store,
    );

NodeRow _node(int id, String name, String type, {int order = 0, int latency = 0}) =>
    NodeRow(
      id: id,
      type: type,
      name: name,
      gid: 7,
      userOrder: order,
      latency: latency,
      outboundJson: '{}',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the configuration document is its node list and the store reads it', () async {
    const channel = MethodChannel('test.config-store');
    final store = _store();
    await store.replaceAll(ProfilesDocument(
      groups: [
        ConfigurationRow(
          id: 7,
          name: 'Sub',
          url: 'https://example.org/sub',
          subOptionsJson: '{"update_interval":60}',
          subLastUpdate: 123,
        ),
      ],
      profiles: [
        _node(1, 'node-a', 'vless', latency: 120),
        _node(2, 'node-b', 'trojan', order: 1),
      ],
    ));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final box = BoxController(
      channel: channel,
      events: const Stream.empty(),
      configurationStoreSource: _source(store),
    );
    final revision = ProfileConfigStore(box, {'id': 7});
    addTearDown(() {
      revision.dispose();
      box.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });
    await revision.load();
    expect(revision.revision, '123');
    expect(revision.value(const ['name']), 'Sub');
    expect(revision.value(const ['updateIntervalMinutes']), 60);
    final nodes = revision.entries(const ['nodes']);
    expect(nodes.map((n) => n['tag']), ['node-a', 'node-b']);
    expect(nodes.map((n) => n['type']), ['VLESS', 'Trojan']);
    // DNS and routing are not part of the document at all.
    expect(revision.entries(const ['dns', 'servers']), isEmpty);
    expect(revision.entries(const ['route', 'rules']), isEmpty);
  });

  test('the export read answers the same manifest text without the channel', () async {
    const channel = MethodChannel('test.config-read');
    final store = _store();
    await store.replaceAll(ProfilesDocument(
      groups: [
        ConfigurationRow(id: 7, name: 'Sub', url: 'https://example.org/sub'),
      ],
      profiles: [_node(1, 'node-a', 'vless', latency: 42)],
    ));
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final box = BoxController(
      channel: channel,
      events: const Stream.empty(),
      configurationStoreSource: _source(store),
    );
    addTearDown(() {
      box.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });

    final text = await box.configurationRead(7);

    expect(jsonDecode(text), {
      'name': 'Sub',
      'url': 'https://example.org/sub',
      'autoUpdate': true,
      'updateIntervalMinutes': 0,
      'nodes': [
        {'tag': 'node-a', 'type': 'VLESS', 'delay': 42},
      ],
    });
    expect(calls.where((call) => dutyOp(call) != null), isEmpty,
        reason: 'the export read is a local document read');
  });

  testWidgets('the configuration page shows the node list and the app-owned settings', (tester) async {
    reportFlutterErrors();
    const channel = MethodChannel('test.config-page');
    final events = StreamController<dynamic>.broadcast();
    final store = _store();
    await store.replaceAll(ProfilesDocument(
      groups: [
        ConfigurationRow(id: 7, name: 'Sub', url: 'https://example.org/sub'),
      ],
      profiles: [_node(1, 'node-a', 'vless', latency: 120)],
    ));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
        'version': 'test', 'coreVersion': 'test', 'preferences': {'locale': 'en'}, 'dashboard': {'status': 'Stopped'},
      };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(
      channel: channel,
      events: events.stream,
      configurationStoreSource: _source(store),
    );
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const ProfileConfigurationPage(profile: {'id': 7, 'name': 'Sub'}));
    await tester.pumpAndSettle();
    expect(find.text('node-a'), findsOneWidget);
    // DNS and routing are app settings the page only points at.
    expect(find.text('DNS'), findsWidgets);
    expect(find.text('Routing'), findsWidgets);
    expect(find.text('Core'), findsWidgets);
    // the per-group editors that never persisted are gone.
    expect(find.text('DNS servers'), findsNothing);
    expect(find.text('Routing rules'), findsNothing);
    expect(find.text('Inbounds'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('a dirty editor asks before discarding and keeps the draft after a failed save', (tester) async {
    reportFlutterErrors();
    const channel = MethodChannel('test.config-sheet');
    final events = StreamController<dynamic>.broadcast();
    final store = _store();
    // One member: the editor's `{"nodes":[]}` draft claims a different
    // membership, so the save is refused exactly as the Kotlin op refused it.
    await store.replaceAll(ProfilesDocument(
      groups: [ConfigurationRow(id: 7, name: 'Remote')],
      profiles: [_node(1, 'node-a', 'vless')],
    ));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
        'version': 'test', 'coreVersion': 'test', 'preferences': {'locale': 'en'}, 'dashboard': {'status': 'Stopped'},
      };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(
      channel: channel,
      events: events.stream,
      configurationStoreSource: _source(store),
    );
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    openForm(tester.element(find.byType(HomePage)), const ConfigurationEditor(profile: {'id': 7, 'name': 'Remote'}));
    await tester.pumpAndSettle();
    const draft = '{"nodes":[]}';
    await tester.enterText(find.byType(TextField).last, draft);
    await tester.pumpAndSettle();
    expect(tester.widget<BoxEditGuard>(find.byType(BoxEditGuard)).dirty, isTrue);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(find.byType(ConfigurationEditor), findsOneWidget);
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(find.text('Node membership is edited on the Proxies screen, not here'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, draft);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('raw editing writes content with a revision without changing profile metadata', (tester) async {
    const channel = MethodChannel('test.raw-config');
    final events = StreamController<dynamic>.broadcast();
    final calls = <MethodCall>[];
    final store = _store();
    await store.replaceAll(ProfilesDocument(
      groups: [
        ConfigurationRow(
          id: 7,
          name: 'Remote',
          url: 'https://example.org/profile.json',
          subLastUpdate: 4,
        ),
      ],
    ));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'ready') return {'version': 'test', 'coreVersion': 'test', 'preferences': {'locale': 'en'}, 'dashboard': {'status': 'Stopped'}};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(
      channel: channel,
      events: events.stream,
      configurationStoreSource: _source(store),
    );
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const ConfigurationEditor(profile: {'id': 7, 'name': 'Remote', 'remote': true, 'url': 'https://example.org/profile.json'}));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('code-line-1')), findsOneWidget);
    const content = '{\n  "nodes":[]\n}';
    await tester.enterText(find.byType(TextField).last, content);
    await tester.pump();
    expect(find.byKey(const ValueKey('code-line-3')), findsOneWidget);
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    // The local write landed: the manifest's nodes round-trip (the group has no
    // members) and no `write`/`save` op crosses the platform duty any more.
    final row = (await store.group(7))!;
    expect(row.name, 'Remote', reason: 'the draft carries no name');
    expect(row.url, 'https://example.org/profile.json');
    expect(row.subLastUpdate, 4);
    expect(calls.where((call) => dutyOp(call) == 'write'), isEmpty);
    expect(calls.where((call) => dutyOp(call) == 'save'), isEmpty);
    // The narrow intent bump precedes the Dart edit.
    final bump = calls.singleWhere((call) => dutyOp(call) == 'revision.edit');
    expect(dutyPayload(bump), {'id': 7});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}