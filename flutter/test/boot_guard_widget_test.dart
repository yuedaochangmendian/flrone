// The integration half of the boot guard: main.dart evaluates the marker before
// its startup work, tells the user, and marks the launch running once the shell
// is up.

import 'dart:async';

import 'package:flrone/main.dart';
import 'package:flrone/services/boot_guard.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('an interrupted previous launch shows the notice and is recorded', (tester) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);

    const channel = MethodChannel('test.boot-guard');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final preferences = <String, dynamic>{
      'locale': 'en',
      // A launch that was recorded as starting and never reached markRunning.
      BootGuard.preferenceKey: const BootRecord(
        stage: BootStage.starting,
        profileId: 7,
        failureCount: 0,
      ).copyWith(startedAt: DateTime.now().millisecondsSinceEpoch - 2000).encode(),
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'ready':
          return {
            'version': 'test', 'coreVersion': 'test',
            'dashboard': {'status': 'Stopped', 'selectedProfileId': 7},
            'preferences': Map<String, dynamic>.from(preferences),
          };
        case 'preferences.set':
          // The host answers with the merged document.
          preferences.addAll(json((call.arguments as Map)['value']));
          return Map<String, dynamic>.from(preferences);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final events = StreamController<dynamic>.broadcast();
    addTearDown(events.close);
    await tester.pumpWidget(
      BoxApp(controller: BoxController(channel: channel, events: events.stream)),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('previous launch was interrupted before the app was ready'),
      findsOneWidget,
      reason: 'the degraded launch is announced, not silent',
    );

    final record = BootRecord.fromJson(preferences[BootGuard.preferenceKey]);
    expect(record?.stage, BootStage.running, reason: 'the UI really came up');
    expect(record?.failureCount, 1, reason: 'the degraded launch keeps its count');

    await tester.pumpWidget(const SizedBox());
  });
}
