import 'dart:async';

import 'package:flrone/box.dart';
import 'package:flrone/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the lifecycle observer tells the host whether the UI is visible', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.ui-visibility');
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'ready'
          ? {
              'version': 'test',
              'coreVersion': 'test',
              'preferences': {'locale': 'en'},
              'dashboard': {'status': 'Stopped'},
            }
          : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();

    List<bool?> visibility() => [
          for (final call in calls)
            if (call.method == 'ui.visible') (call.arguments as Map)['visible'] as bool?,
        ];

    expect(visibility(), isEmpty, reason: 'a resumed start needs no signal: the host defaults to visible');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(visibility(), [false], reason: 'a hidden app stops the host rates sample');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(visibility(), [false, false]);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(visibility(), [false, false, true]);

    // `inactive` is still on screen (split screen, the shade, a system dialog): the
    // dashboard must keep sampling there, exactly as the refresh gate does.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(visibility(), [false, false, true, true]);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
