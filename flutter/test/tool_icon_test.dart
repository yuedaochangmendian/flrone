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

  testWidgets('pressing a tool or settings row lifts it and colours only its icon', (tester) async {
    await mount(tester, 'test.tool_icon');
    openPage(tester.element(find.byType(HomePage)), const ToolsPage());
    await tester.pumpAndSettle();

    bool lifted(Finder row) => tester
        .widgetList<AnimatedContainer>(
          find.descendant(of: row, matching: find.byType(AnimatedContainer)),
        )
        .any((container) {
          final decoration = container.decoration;
          return decoration is ShapeDecoration &&
              (decoration.shadows?.isNotEmpty ?? false);
        });

    // With no capability manifest every entry renders: the toolbox rows and the settings rows
    // share the same widget, so both must behave the same.
    for (final label in ['Requests', 'General']) {
      final row = find.widgetWithText(ListItem, label);
      expect(row, findsOneWidget, reason: label);
      final scheme = Theme.of(tester.element(row)).colorScheme;
      // Bettbox's pressed card wash: 7% primary over the fill, while the row lifts on a shadow.
      expect(
        tester.widget<Card>(find.descendant(of: row, matching: find.byType(Card))).pressTint,
        scheme.primary.withValues(alpha: 0.07),
        reason: '$label row wash',
      );
      GlyphIcon glyph() =>
          tester.widget<GlyphIcon>(find.descendant(of: row, matching: find.byType(GlyphIcon)).first);
      // At rest the glyph inherits the row's muted colour; nothing paints a chip behind it.
      expect(glyph().color, isNull, reason: '$label at rest');
      expect(lifted(row), isFalse, reason: '$label at rest lift');

      final gesture = await tester.startGesture(tester.getCenter(row));
      await tester.pumpAndSettle();
      // Applied as soon as the pointer goes down: the glyph takes the theme colour and the
      // row lifts.
      expect(glyph().color, scheme.primary, reason: '$label pressed');
      expect(lifted(row), isTrue, reason: '$label pressed lift');

      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(glyph().color, isNull, reason: '$label released');
      expect(lifted(row), isFalse, reason: '$label released lift');
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
