import 'dart:async';
import 'package:flrone/components/tool_icon.dart';
import 'package:flrone/main.dart';
import 'package:flrone/pages/tools.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pressing a tool or settings row tints its icon with the theme', (tester) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(360, 1600);
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

    // With no capability manifest every entry renders: the toolbox rows and the settings rows
    // share the same widget, so both must behave the same.
    for (final label in ['Requests', 'General']) {
      final row = find.widgetWithText(ListItem, label);
      expect(row, findsOneWidget, reason: label);
      final icon = find.descendant(of: row, matching: find.byType(ToolIcon));
      expect(icon, findsOneWidget, reason: label);
      final container = find.descendant(of: icon, matching: find.byType(Container)).first;
      ShapeDecoration decoration() => tester.widget<Container>(container).decoration! as ShapeDecoration;
      final scheme = Theme.of(tester.element(icon)).colorScheme;
      expect(decoration().color, const Color(0x00000000), reason: '$label at rest');

      final gesture = await tester.startGesture(tester.getCenter(row));
      await tester.pump();
      // The colour is applied as soon as the pointer goes down, with no fade or sparkle.
      expect(decoration().color, scheme.primaryContainer, reason: '$label pressed');
      expect(
        tester.widget<GlyphIcon>(find.descendant(of: icon, matching: find.byType(GlyphIcon))).color,
        scheme.onPrimaryContainer,
        reason: '$label pressed glyph',
      );

      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(decoration().color, const Color(0x00000000), reason: '$label released');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
