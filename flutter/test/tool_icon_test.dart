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

  testWidgets('pressing a tool or settings row colours its icon and label, in the entry colour', (tester) async {
    await mount(tester, 'test.tool_icon');
    openPage(tester.element(find.byType(HomePage)), const ToolsPage());
    await tester.pumpAndSettle();

    // The toolbox and settings rows share the widget; each entry owns a Bettbox palette
    // colour, and only the leading glyph wears it.
    const expected = {
      'Connections': ToolColors.purple,
      'Logs': ToolColors.teal,
      'General': ToolColors.blue,
      'Notification': ToolColors.orange,
      'Appearance': ToolColors.pink,
      'TUN': ToolColors.purple,
      'Routing': ToolColors.teal,
      'DNS': ToolColors.green,
      'Network toolbox': ToolColors.cyan,
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
      // No row wash and no lift: the icon and label are the feedback.
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
      Text labelText() =>
          tester.widget<Text>(find.descendant(of: row, matching: find.text(label)).first);
      final brightness = Theme.of(tester.element(row)).brightness;
      final resolved = entry.value.resolve(brightness);
      // At rest the glyph and label inherit the row's own colours.
      expect(glyph().color, isNull, reason: '$label glyph at rest');
      expect(labelText().style?.color, isNull, reason: '$label text at rest');
      expect(labelText().style?.fontWeight, isNull, reason: '$label weight at rest');

      final gesture = await tester.startGesture(tester.getCenter(row));
      await tester.pump();
      // Applied as soon as the pointer goes down: glyph and label take the entry colour.
      expect(glyph().color, resolved, reason: '$label glyph pressed');
      expect(labelText().style?.color, resolved, reason: '$label text pressed');
      expect(labelText().style?.fontWeight, FontWeight.w700, reason: '$label weight pressed');

      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(glyph().color, isNull, reason: '$label glyph released');
      expect(labelText().style?.color, isNull, reason: '$label text released');
      expect(labelText().style?.fontWeight, isNull, reason: '$label weight released');
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
    Text titleText() => tester.widget<Text>(find.descendant(of: title, matching: find.text('Speed 0')));
    final scheme = Theme.of(tester.element(title)).colorScheme;
    expect(icon().color, scheme.onSurfaceVariant);
    expect(titleText().style?.color, isNot(scheme.primary));
    // The card paints no wash of its own; the title row is the whole feedback.
    expect(tester.widget<Card>(find.descendant(of: panel, matching: find.byType(Card))).pressTint,
        const Color(0x00000000));

    final gesture = await tester.startGesture(tester.getCenter(title));
    await tester.pump();
    expect(icon().color, scheme.primary);
    expect(titleText().style?.color, scheme.primary);

    // Dragging to scroll cancels the row's tap; the icon must stay coloured until the finger
    // lifts, which is the press the user is still making.
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    expect(icon().color, scheme.primary, reason: 'still held while dragging');
    expect(titleText().style?.color, scheme.primary, reason: 'title still held while dragging');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(icon().color, scheme.onSurfaceVariant);
    expect(titleText().style?.color, isNot(scheme.primary));
    expect(tester.takeException(), isNull);
  });
}
