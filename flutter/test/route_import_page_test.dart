// The import sheet is dismissed while its async work is in flight often enough
// (paste a link, then swipe the sheet away) that a late setState is a real
// crash, not a theoretical one. These tests keep the guards around the two
// await points in RouteImportPage honest.

import 'dart:async';

import 'package:flrone/pages/route_import_page.dart';
import 'package:flrone/providers/box_providers.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/errors.dart';
import 'support/test_app.dart';

void main() {
  late StreamController<dynamic> events;
  late BoxController box;
  Completer<Map<String, dynamic>?>? clipboard;

  Future<void> mountPage(WidgetTester tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('test.route-import');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {'version': 'test', 'coreVersion': 'test', 'preferences': {'locale': 'en'}};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        final pending = clipboard;
        if (pending != null) return await pending.future;
        return {'text': ''};
      }
      return null;
    });
    events = StreamController<dynamic>.broadcast();
    box = BoxController(channel: channel, events: events.stream);
    await box.initialize();
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(channel, null);
      box.dispose();
      events.close();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [boxControllerProvider.overrideWithValue(box)],
      child: BoxScope(controller: box, child: HostApp(home: const RouteImportPage())),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('clipboard read finishing after the page is gone does not throw', (tester) async {
    await mountPage(tester);
    clipboard = Completer<Map<String, dynamic>?>();
    // The paste action is the sheet's own toolbar icon, found by its label.
    tester.widget<Scaffold>(find.byType(Scaffold).first).iconActions
      .firstWhere((item) => item.tooltip == 'Paste').onPressed!();
    await tester.pump();
    expect(clipboard!.isCompleted, isFalse);
    // Dismiss the page while the clipboard round-trip is still pending.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    clipboard!.complete({'text': 'https://example.test/profile.json'});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('an entering preview whose text field is gone does not throw', (tester) async {
    await mountPage(tester);
    // A short, non-route text still takes the async preview path; the page is
    // torn down before the parse completes, so the leading setState must be
    // skipped and the trailing one is already guarded by `mounted && seq`.
    await tester.enterText(find.byKey(const Key('route-import-field')), 'not-a-route');
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // Let the 250ms debounce fire on a disposed state (the timer is cancelled in
    // dispose, so nothing should be scheduled), then drain the parse.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
