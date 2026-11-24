import 'dart:async';
import 'dart:convert';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flrone/pages/configuration.dart';
import 'package:flrone/pages/configuration_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/errors.dart';
import 'support/profile_duty.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the configuration document is its node list and the store reads it', () async {
    const channel = MethodChannel('test.config-store');
    final document = <String, dynamic>{
      'name': 'Sub', 'url': 'https://example.org/sub', 'autoUpdate': true,
      'updateIntervalMinutes': 60,
      'nodes': [
        {'tag': 'node-a', 'type': 'VLESS', 'delay': 120},
        {'tag': 'node-b', 'type': 'Trojan', 'delay': 0},
      ],
    };
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (dutyOp(call) == 'config') {
        return {
        'content': jsonEncode(document), 'formatted': jsonEncode(document), 'revision': 'r1', 'stats': {},
      };
      }
      return null;
    });
    final box = BoxController(channel: channel, events: const Stream.empty());
    final store = ProfileConfigStore(box, {'id': 7});
    addTearDown(() { store.dispose(); box.dispose(); messenger.setMockMethodCallHandler(channel, null); });
    await store.load();
    expect(store.revision, 'r1');
    expect(store.value(const ['name']), 'Sub');
    final nodes = store.entries(const ['nodes']);
    expect(nodes.map((n) => n['tag']), ['node-a', 'node-b']);
    // DNS and routing are not part of the document at all.
    expect(store.entries(const ['dns', 'servers']), isEmpty);
    expect(store.entries(const ['route', 'rules']), isEmpty);
  });

  testWidgets('the configuration page shows the node list and the app-owned settings', (tester) async {
    reportFlutterErrors();
    const channel = MethodChannel('test.config-page');
    final events = StreamController<dynamic>.broadcast();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
        'version': 'test', 'coreVersion': 'test', 'preferences': {'locale': 'en'}, 'dashboard': {'status': 'Stopped'},
      };
      }
      if (dutyOp(call) == 'config') {
        const document = '{"name":"Sub","nodes":[{"tag":"node-a","type":"VLESS","delay":120}]}';
        return {'content': document, 'formatted': document, 'revision': 'r1'};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
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
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
        'version': 'test', 'coreVersion': 'test', 'preferences': {'locale': 'en'}, 'dashboard': {'status': 'Stopped'},
      };
      }
      if (dutyOp(call) == 'config') return {'content': '{}', 'formatted': '{}', 'revision': 'r1'};
      if (dutyOp(call) == 'write') {
        throw PlatformException(code: 'config', message: 'Configuration changed; reload it before saving');
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
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
    expect(find.text('Configuration changed; reload it before saving'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, draft);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('raw editing writes content with a revision without changing profile metadata', (tester) async {
    const channel = MethodChannel('test.raw-config');
    final events = StreamController<dynamic>.broadcast();
    final calls = <MethodCall>[];
    Json wire(String content, String revision) => {'content': content, 'formatted': content, 'revision': revision};
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'ready') return {'version': 'test', 'coreVersion': 'test', 'preferences': {'locale': 'en'}, 'dashboard': {'status': 'Stopped'}};
      if (dutyOp(call) == 'config') return wire('{}', 'loaded-revision');
      if (dutyOp(call) == 'write') return wire(dutyPayload(call)['content'] as String, 'saved-revision');
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const ConfigurationEditor(profile: {'id': 7, 'name': 'Remote', 'remote': true, 'url': 'https://example.org/profile.json'}));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('code-line-1')), findsOneWidget);
    const content = '{\n  "nodes":[{"type":"direct","tag":"direct"}]\n}';
    await tester.enterText(find.byType(TextField).last, content);
    await tester.pump();
    expect(find.byKey(const ValueKey('code-line-3')), findsOneWidget);
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(dutyPayload(calls.singleWhere((call) => dutyOp(call) == 'write')), {
      'id': 7, 'content': content, 'revision': 'loaded-revision',
    });
    expect(calls.where((call) => dutyOp(call) == 'save'), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
