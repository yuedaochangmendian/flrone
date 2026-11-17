import 'dart:async';
import 'package:flrone/components/tool_icon.dart';
import 'package:flrone/main.dart';
import 'package:flrone/pages/tools.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pressing a tool row tints its icon with the theme', (tester) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(360, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.tool_icon');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready'
        ? {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}}
        : null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const ToolsPage());
    await tester.pumpAndSettle();

    // With no capability manifest every tool entry renders; the first one is in view.
    final row = find.widgetWithText(ListItem, 'Requests');
    expect(row, findsOneWidget);
    expect(find.byType(ToolIcon), findsWidgets);
    final icon = find.descendant(of: row, matching: find.byType(ToolIcon));
    expect(icon, findsOneWidget);
    final container = find.descendant(of: icon, matching: find.byType(AnimatedContainer));
    ShapeDecoration decoration() => tester.widget<AnimatedContainer>(container).decoration! as ShapeDecoration;

    final scheme = Theme.of(tester.element(icon)).colorScheme;
    expect(decoration().color, const Color(0x00000000));

    final gesture = await tester.startGesture(tester.getCenter(row));
    // Tap-down fires after the press timeout; the state update then schedules a rebuild.
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    // The row's press surface publishes its state; the icon follows it with the theme colour.
    expect(decoration().color, scheme.primaryContainer);
    expect(tester.widget<GlyphIcon>(find.descendant(of: icon, matching: find.byType(GlyphIcon))).color,
        scheme.onPrimaryContainer);

    // Cancelling keeps the page in place and returns the icon to rest.
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(decoration().color, const Color(0x00000000));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
