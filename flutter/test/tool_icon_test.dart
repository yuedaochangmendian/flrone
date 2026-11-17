import 'dart:async';
import 'package:flrone/components/tool_icon.dart';
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

  testWidgets('pressing a tool or settings row colours only its icon, in the entry colour', (tester) async {
    await mount(tester, 'test.tool_icon');
    openPage(tester.element(find.byType(HomePage)), const ToolsPage());
    await tester.pumpAndSettle();

    // The toolbox and settings rows share the widget; each entry owns a Bettbox palette
    // colour, and only the leading glyph wears it.
    const expected = {
      'Requests': ToolColors.blue,
      'Connections': ToolColors.purple,
      'Logs': ToolColors.teal,
      'Terminal': ToolColors.green,
      'Remote control': ToolColors.orange,
      'General': ToolColors.blue,
      'Notification': ToolColors.orange,
      'Appearance': ToolColors.pink,
      'TUN': ToolColors.purple,
      'Routing': ToolColors.teal,
      'DNS': ToolColors.green,
      'Testing': ToolColors.cyan,
      'Core': ToolColors.burntOrange,
      'Access control': ToolColors.indigo,
      'Backup and restore': ToolColors.blueDeep,
      'Advanced settings': ToolColors.orchid,
      'About': ToolColors.indigo,
    };
    for (final entry in expected.entries) {
      final label = entry.key;
      final row = find.widgetWithText(ListItem, label);
      expect(row, findsOneWidget, reason: label);
      // No row wash and no lift: the icon is the only feedback.
      expect(
        tester.widget<Card>(find.descendant(of: row, matching: find.byType(Card))).pressTint,
        const Color(0x00000000),
        reason: '$label row wash',
      );
      expect(
        find.descendant(of: row, matching: find.byType(AnimatedContainer)),
        findsNothing,
        reason: '$label row shadow',
      );
      GlyphIcon glyph() =>
          tester.widget<GlyphIcon>(find.descendant(of: row, matching: find.byType(GlyphIcon)).first);
      final brightness = Theme.of(tester.element(row)).brightness;
      // At rest the glyph inherits the row's muted colour.
      expect(glyph().color, isNull, reason: '$label at rest');

      final gesture = await tester.startGesture(tester.getCenter(row));
      await tester.pump();
      // Applied as soon as the pointer goes down: only the glyph takes the entry colour.
      expect(glyph().color, entry.value.resolve(brightness), reason: '$label pressed');

      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(glyph().color, isNull, reason: '$label released');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a card keeps its icon coloured while the finger drags to scroll', (tester) async {
    await mount(tester, 'test.card_tint');
    openPage(
      tester.element(find.byType(HomePage)),
      BoxPage(title: 'Probe', children: [
        for (var index = 0; index < 14; index++)
          BoxPanel(onTap: () {}, child: PanelTitle('Speed $index', AppGlyphs.speed)),
      ]),
    );
    await tester.pumpAndSettle();

    final panel = find.byType(BoxPanel).first;
    final title = find.descendant(of: panel, matching: find.byType(PanelTitle));
    GlyphIcon icon() => tester.widget<GlyphIcon>(find.descendant(of: title, matching: find.byType(GlyphIcon)));
    final scheme = Theme.of(tester.element(title)).colorScheme;
    expect(icon().color, scheme.onSurfaceVariant);
    // The card paints no wash of its own; the icon is the whole feedback.
    expect(tester.widget<Card>(find.descendant(of: panel, matching: find.byType(Card))).pressTint,
        const Color(0x00000000));

    final gesture = await tester.startGesture(tester.getCenter(title));
    await tester.pump();
    expect(icon().color, scheme.primary);

    // Dragging to scroll cancels the row's tap; the icon must stay coloured until the finger
    // lifts, which is the press the user is still making.
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    expect(icon().color, scheme.primary, reason: 'still held while dragging');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(icon().color, scheme.onSurfaceVariant);
    expect(tester.takeException(), isNull);
  });
}
