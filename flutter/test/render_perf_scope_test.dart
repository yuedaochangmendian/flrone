// A covered page is kept alive by PageSwitcher's Offstage, where TickerMode
// reports false but a plain Timer keeps firing. The status card's run-time
// clock used to tick once a second behind the active tab: a rebuild and a
// repaint of an invisible card on every host traffic tick.
//
// This test pins the fix with the real app shell: the clock pauses while its
// tab is covered and resumes when it is shown again. Unlike rebuild_scope_test
// (controller batching) and rebuild_isolation_test (provider selectors), it
// measures a lifecycle signal that neither of those covers.

import 'dart:async';

import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';

void main() {
  testWidgets('the status clock pauses while its tab is covered', (tester) async {
    reportFlutterErrors();
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final events = StreamController<dynamic>.broadcast();
    addTearDown(events.close);
    const channel = MethodChannel('test.covered-clock');
    final startedAt = DateTime.now().millisecondsSinceEpoch - 3600 * 1000;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'preferences': const {'locale': 'en'},
          'dashboard': {
            'status': 'Started',
            'startedAt': startedAt,
            'routeVersion': 1,
            'modes': <String>[],
          },
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(BoxApp(
      controller: BoxController(channel: channel, events: events.stream),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Run time'), findsOneWidget);

    /// Counts rebuilds of the private clock during one long pump. Dirty-widget
    /// counters are per widget type because State.setState rebuilds in place.
    Future<int> ticks() async {
      var count = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget.runtimeType.toString() == '_RuntimeValue') count++;
      };
      await tester.pump(const Duration(seconds: 3));
      debugOnRebuildDirtyWidget = null;
      return count;
    }

    expect(await ticks(), greaterThan(0),
        reason: 'the visible card must keep its second-by-second clock');

    // Switch tabs: PageSwitcher keeps the dashboard mounted but offstage, and
    // wraps it in TickerMode(enabled: false). The clock must read that signal.
    await tester.tap(find.text('Tools').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(await ticks(), 0,
        reason: 'a tab covered by PageSwitcher must not tick its invisible clock');

    // Coming back restarts the timer and catches the clock up to wall time.
    await tester.tap(find.text('Dashboard').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(await ticks(), greaterThan(0),
        reason: 'returning to the tab resumes the clock');
    expect(tester.takeException(), isNull);
  });
}
