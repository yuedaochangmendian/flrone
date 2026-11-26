import 'dart:async';
import 'package:flrone/components/data_subscription.dart';
import 'package:flrone/providers/box_providers.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final data in BoxData.values) {
    testWidgets('$data subscriptions share demand and stop when hidden or backgrounded', (tester) async {
      final channel = MethodChannel('test.subscription.${data.name}');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final events = StreamController<dynamic>.broadcast();
      final box = BoxController(channel: channel, events: events.stream);
      final changes = <bool>[];
      // Each BoxData opens its own visibility channel (the _syncData switch).
      final method = switch (data) {
        BoxData.memory => 'dashboard.memory.visible',
        BoxData.logcat => 'logs.logcat.visible',
        BoxData.testSession => 'groups.testSession.visible',
        _ => 'logs.visible',
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ready') return {'version': 'test', 'coreVersion': 'test'};
        expect(call.method, method);
        changes.add(json(call.arguments)['visible'] as bool);
        return null;
      });
      await box.initialize();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      Future<void> mount({bool card = true, bool details = false, bool tickers = true}) async {
        await tester.pumpWidget(ProviderScope(overrides: [boxControllerProvider.overrideWithValue(box)],
          child: BoxScope(controller: box, child: Column(children: [
            PageActivityScope(isActive: card, child: TickerMode(enabled: tickers,
              child: BoxDataSubscription(key: const ValueKey('card'), data: data, child: const SizedBox()))),
            if (details) BoxDataSubscription(key: const ValueKey('details'), data: data, child: const SizedBox()),
          ]))));
        await tester.pump();
      }
      await mount();
      expect(changes, [true]);
      await mount(details: true);
      await mount(card: false, details: true);
      expect(changes, [true], reason: 'The details page still needs the data.');
      await mount(card: false);
      expect(changes, [true, false]);
      await mount();
      expect(changes, [true, false, true]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(changes.last, false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(changes.last, true);
      await mount(tickers: false);
      expect(changes.last, false);
      await mount();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(changes.last, false);
      expect(tester.takeException(), isNull);
      box.dispose();
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });
  }

  testWidgets('a route pushed over the page stops data sampling', (tester) async {
    final channel = MethodChannel('test.subscription.route');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final events = StreamController<dynamic>.broadcast();
    final box = BoxController(channel: channel, events: events.stream);
    final changes = <bool>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') return {'version': 'test', 'coreVersion': 'test'};
      if (call.method == 'logs.visible') {
        changes.add(json(call.arguments)['visible'] as bool);
      }
      return null;
    });
    await box.initialize();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(ProviderScope(
      overrides: [boxControllerProvider.overrideWithValue(box)],
      child: BoxScope(controller: box, child: const MaterialApp(home: SizedBox.expand())),
    ));
    await tester.pumpAndSettle();
    final navigator = Navigator.of(tester.element(find.byType(Navigator)));
    // Mount a subscription inside a real navigator route.
    navigator.push(MaterialPageRoute<void>(
      builder: (_) => PageActivityScope(
        isActive: true,
        child: BoxDataSubscription(data: BoxData.logs, child: const SizedBox.expand()),
      ),
    ));
    await tester.pumpAndSettle();
    expect(changes, [true]);
    // Push another route over the page: the subscription's route is no longer
    // current, so sampling stops even though PageActivityScope is still active.
    navigator.push(MaterialPageRoute<void>(builder: (_) => const SizedBox.expand()));
    await tester.pumpAndSettle();
    expect(changes.last, isFalse,
        reason: 'a covered page must stop sampling while its scope is still active');
    // Pop back: sampling resumes.
    navigator.pop();
    await tester.pumpAndSettle();
    expect(changes.last, isTrue);
    await tester.pumpWidget(const SizedBox());
    await events.close();
    box.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    expect(tester.takeException(), isNull);
  });

}
