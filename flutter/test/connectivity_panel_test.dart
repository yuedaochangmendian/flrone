import 'dart:async';

import 'package:flrone/components/connectivity/connectivity_page.dart';
import 'package:flrone/components/connectivity/connectivity_panel.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The dashboard's service-status card: FlClash's header + two-column grid. Without a probe
/// run every cell is in its unknown state; the test covers the layout and the tap-through.
void main() {
  testWidgets('the service status card shows the pinned grid and opens the page', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);

    final events = StreamController<dynamic>.broadcast();
    addTearDown(events.close);
    const channel = MethodChannel('test.service-status');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'dashboard': {'status': 'Stopped'},
          'preferences': {'locale': 'en'},
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Service status'), findsOneWidget);
    // The default pinned set, in the grid.
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('Cloudflare'), findsOneWidget);
    expect(find.text('E-Hentai'), findsOneWidget);
    // No probe has run: every cell shows the idle dash (other cards use the same glyph).
    final panel = find.byType(ConnectivityPanel);
    expect(find.descendant(of: panel, matching: find.text('—')), findsNWidgets(3));

    await tester.ensureVisible(find.text('Service status'));
    await tester.pump();
    await tester.tap(find.text('Service status'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ConnectivityPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
