import 'dart:async';
import 'package:flrone/main.dart';
import 'package:flrone/pages/tools.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<BoxController> mount(WidgetTester tester, String channelName) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(360, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    final channel = MethodChannel(channelName);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready'
        ? {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}}
        : null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await events.close();
    });
    return box;
  }

  testWidgets('pressing a tool or settings row colours only its icon', (tester) async {
    await mount(tester, 'test.tool_icon');
    openPage(tester.element(find.byType(HomePage)), const ToolsPage());
    await tester.pumpAndSettle();

    // With no capability manifest every entry renders: the toolbox rows and the settings rows
    // share the same widget, so both must behave the same.
    for (final label in ['Requests', 'General']) {
      final row = find.widgetWithText(ListItem, label);
      expect(row, findsOneWidget, reason: label);
      GlyphIcon glyph() =>
          tester.widget<GlyphIcon>(find.descendant(of: row, matching: find.byType(GlyphIcon)).first);
      final scheme = Theme.of(tester.element(row)).colorScheme;
      // At rest the glyph inherits the row's muted colour; nothing paints a chip behind it.
      expect(glyph().color, isNull, reason: '$label at rest');

      final gesture = await tester.startGesture(tester.getCenter(row));
      await tester.pump();
      // Applied as soon as the pointer goes down: only the glyph takes the theme colour.
      expect(glyph().color, scheme.primary, reason: '$label pressed');

      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(glyph().color, isNull, reason: '$label released');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('pressing a panel card colours only its title icon', (tester) async {
    await mount(tester, 'test.card_tint');
    openPage(
      tester.element(find.byType(HomePage)),
      BoxPage(title: 'Probe', children: [
        BoxPanel(onTap: () {}, child: PanelTitle('Speed', AppGlyphs.speed)),
      ]),
    );
    await tester.pumpAndSettle();

    final title = find.byType(PanelTitle);
    GlyphIcon icon() => tester.widget<GlyphIcon>(find.descendant(of: title, matching: find.byType(GlyphIcon)));
    final scheme = Theme.of(tester.element(title)).colorScheme;
    expect(icon().color, scheme.onSurfaceVariant);

    final gesture = await tester.startGesture(tester.getCenter(title));
    await tester.pump();
    expect(icon().color, scheme.primary);

    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(icon().color, scheme.onSurfaceVariant);
    expect(tester.takeException(), isNull);
  });
}
