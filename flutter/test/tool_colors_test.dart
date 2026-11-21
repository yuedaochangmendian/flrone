import 'package:flrone/components/tool_icon.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('resolved tool colours stay readable on both surfaces', () {
    for (final color in ToolColors.all) {
      expect(_contrast(color.resolve(Brightness.light), const Color(0xFFFFFFFF)), greaterThanOrEqualTo(3.0));
      expect(_contrast(color.resolve(Brightness.dark), const Color(0xFF1B1B1F)), greaterThanOrEqualTo(3.0));
    }
  });

  testWidgets('a focused tool icon lights in its entry colour', (tester) async {
    final states = WidgetStatesController();
    final focus = WidgetStatesController()
      ..update(WidgetState.focused, true);
    addTearDown(states.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(Theme(
      data: ThemeData(brightness: Brightness.light),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: IconTheme(
          data: const IconThemeData(color: Color(0xFF000000)),
          child: ToolIcon(
            glyph: AppGlyphs.settings,
            color: ToolColors.blue,
            states: states,
            focusStates: focus,
          ),
        ),
      ),
    ));
    expect(
      tester.widget<GlyphIcon>(find.byType(GlyphIcon)).color,
      ToolColors.blue.resolve(Brightness.light),
    );
  });
}
