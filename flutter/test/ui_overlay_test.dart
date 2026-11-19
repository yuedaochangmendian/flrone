// ADR 0005 phase 2: the UI-only settings overlay is Dart-owned. These tests
// pin the three properties that keep the two writers from drifting (the reason
// ADR 0002 moved settings back onto the channel in the first place):
//   1. an overlay write survives a cold start (it lives in `preferences`),
//   2. overlay and Kotlin-authoritative keys never overwrite each other,
//   3. settings are re-merged on every read — a fresh host snapshot is never
//      masked by a stale cached whole-map copy.
// The channel test in settings_channel_test.dart keeps covering the service
// keys' reload/restart semantics; here the mock channel answers are minimal.

import 'dart:async';

import 'package:flrone/box.dart';
import 'package:flrone/services/ui_overlay.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uiOnlyKeys never overlaps an authoritative key', () {
    // The two stores must be disjoint: if a key is in both, the merge order
    // decides the winner and one side's write is silently lost.
    for (final key in uiOnlyKeys) {
      expect(key.startsWith('remoteDns'), isFalse);
      expect(key, isNot('mode'));
      expect(key, isNot('allowBypass'));
      expect(key, isNot('enableMux'));
      expect(key, isNot('serviceMode'));
    }
  });

  test('mergeSettings layers overlay over authoritative without mutation', () {
    final host = <String, dynamic>{'adblockEnable': true, 'remoteDns': 'https://dns', 'theme': 'system'};
    final overlay = <String, dynamic>{'theme': 'dark', 'proxySort': 'Name', 'fontSize': 18};
    final merged = mergeSettings(host, overlay);

    // Overlay wins for its own keys.
    expect(merged['theme'], 'dark');
    expect(merged['proxySort'], 'Name');
    expect(merged['fontSize'], 18);
    // Authoritative keys are untouched.
    expect(merged['adblockEnable'], true);
    expect(merged['remoteDns'], 'https://dns');
    // Neither input is mutated (the whole point of a per-read re-merge).
    expect(host['theme'], 'system');
    expect(overlay.length, 3);
  });

  test('merge is recomputed: a new host value is not masked by a stale overlay', () {
    final overlay = <String, dynamic>{'fontSize': 16};
    var host = <String, dynamic>{'adblockEnable': false};
    expect(mergeSettings(host, overlay)['adblockEnable'], false);

    // Simulate a fresh `settings` event from the host changing a service key.
    host = <String, dynamic>{'adblockEnable': true};
    expect(mergeSettings(host, overlay)['adblockEnable'], true);
    // ...while the overlay value still comes from Dart.
    expect(mergeSettings(host, overlay)['fontSize'], 16);
  });

  test('overlay writes stay in preferences, cold start preserves them, and service keys still cross the channel', () async {
    const channel = MethodChannel('test.ui-overlay');
    final events = StreamController<dynamic>.broadcast();
    final prefs = <String, dynamic>{'theme': 'system'};
    final hostSettings = <String, dynamic>{'adblockEnable': false};
    final channelCalls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      channelCalls.add(call);
      switch (call.method) {
        case 'ready':
          return {'version': 'test', 'coreVersion': 'test',
            'dashboard': {'status': 'Stopped'},
            'settings': Map<String, dynamic>.of(hostSettings),
            'preferences': Map<String, dynamic>.of(prefs)};
        case 'settings.set':
          final args = json(call.arguments);
          hostSettings[args['key'] as String] = args['value'];
          return Map<String, dynamic>.of(hostSettings);
        case 'settings.patch':
          hostSettings.addAll(json(call.arguments)['value'] as Map<String, dynamic>);
          return Map<String, dynamic>.of(hostSettings);
        case 'settings.reset':
          return Map<String, dynamic>.of(hostSettings);
        case 'preferences.set':
          prefs.addAll(json(call.arguments)['value'] as Map<String, dynamic>);
          return Map<String, dynamic>.of(prefs);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final box = BoxController(channel: channel, events: events.stream);
    await box.initialize();

    // 1. An overlay write never touches the channel and never raises a badge.
    await box.setSetting('theme', 'dark');
    expect(channelCalls.where((c) => c.method == 'settings.set' || c.method == 'settings.patch'), isEmpty);
    expect(box.settings['theme'], 'dark');
    expect(box.applyRequired, isNull);
    expect(prefs['theme'], 'dark');

    // 2. A service write still goes through settings.set and never overwrites the overlay.
    await box.setSetting('adblockEnable', true, restart: false);
    expect(channelCalls.where((c) => c.method == 'settings.set'), hasLength(1));
    expect(box.settings['adblockEnable'], true);
    expect(box.settings['theme'], 'dark');

    // 3. A batch with both halves splits cleanly.
    await box.setSettings({'fontSize': 20, 'remoteDns': 'https://1.1.1.1/dns-query'}, restart: false);
    expect(prefs['fontSize'], 20);
    expect(hostSettings['remoteDns'], 'https://1.1.1.1/dns-query');
    expect(box.settings['fontSize'], 20);
    expect(box.settings['remoteDns'], 'https://1.1.1.1/dns-query');

    // 4. Cold start: a fresh controller reads both stores and re-merges them.
    final cold = BoxController(channel: channel, events: events.stream);
    await cold.initialize();
    expect(cold.settings['theme'], 'dark');
    expect(cold.settings['fontSize'], 20);
    expect(cold.settings['adblockEnable'], true);
    expect(cold.settings['remoteDns'], 'https://1.1.1.1/dns-query');

    cold.dispose();
    box.dispose();
    await events.close();
  });

  test('reset only drops overlay keys locally and sends authoritative keys to the channel', () async {
    const channel = MethodChannel('test.ui-overlay-reset');
    final events = StreamController<dynamic>.broadcast();
    final prefs = <String, dynamic>{'theme': 'dark', 'fontSize': 18};
    final hostSettings = <String, dynamic>{'adblockEnable': true};
    final channelCalls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      channelCalls.add(call);
      switch (call.method) {
        case 'ready':
          return {'version': 'test', 'coreVersion': 'test',
            'dashboard': {'status': 'Stopped'},
            'settings': Map<String, dynamic>.of(hostSettings),
            'preferences': Map<String, dynamic>.of(prefs)};
        case 'settings.reset':
          return Map<String, dynamic>.of(hostSettings);
        case 'preferences.set':
          final values = json(call.arguments)['value'] as Map<String, dynamic>;
          values.forEach((key, value) {
            if (value == null) {
              prefs.remove(key);
            } else {
              prefs[key] = value;
            }
          });
          return Map<String, dynamic>.of(prefs);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final box = BoxController(channel: channel, events: events.stream);
    await box.initialize();

    await box.resetSettings(['theme', 'adblockEnable']);
    expect(channelCalls.where((c) => c.method == 'settings.reset'), hasLength(1));
    final resetArgs = channelCalls.firstWhere((c) => c.method == 'settings.reset').arguments as Map<dynamic, dynamic>;
    expect(resetArgs['keys'], ['adblockEnable']);
    expect(prefs.containsKey('theme'), isFalse);

    box.dispose();
    await events.close();
  });
}
