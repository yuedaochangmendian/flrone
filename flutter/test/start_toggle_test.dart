// The start button's motion contract, taken from FlClash's `_StartToggle`:
// one continuous morph timeline (no icon cross-fade), asymmetric curves, no
// debounce lock — the lifecycle chain and the card's stale-result token own
// serialisation — and a reduce-motion escape that snaps instead of animating.

import 'package:flrone/components/start_toggle.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

double? _morphProgress(WidgetTester tester) {
  for (final paint in tester.widgetList<CustomPaint>(
    find.byType(CustomPaint),
  )) {
    final painter = paint.painter;
    if (painter.runtimeType.toString().contains('MorphPainter')) {
      return (painter as dynamic).progress as double?;
    }
  }
  return null;
}

Widget _toggle({
  required bool running,
  required VoidCallback onTap,
  bool disableAnimations = false,
}) {
  Widget child = Material(
    type: MaterialType.transparency,
    child: Center(
      child: StartToggle(
        size: 88,
        enabled: true,
        running: running,
        suspended: false,
        onTap: onTap,
      ),
    ),
  );
  // Inside TestApp: MaterialApp builds its own MediaQuery up the tree, so an
  // override outside it would be shadowed.
  if (disableAnimations) {
    child = MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: child,
    );
  }
  return TestApp(child: child);
}

void main() {
  testWidgets('the shape morphs continuously instead of cutting', (tester) async {
    await tester.pumpWidget(_toggle(running: false, onTap: () {}));
    await tester.pumpAndSettle();
    expect(_morphProgress(tester), 0);

    await tester.pumpWidget(_toggle(running: true, onTap: () {}));
    await tester.pump(const Duration(milliseconds: 150));
    final mid = _morphProgress(tester);
    // Mid-flight the morph holds a value strictly between the two endpoints:
    // the button is one 450 ms timeline, not a swapped pair of widgets.
    expect(mid, isNotNull);
    expect(mid! > 0 && mid < 1, isTrue, reason: 'mid-morph was $mid');

    await tester.pumpAndSettle();
    expect(_morphProgress(tester), 1);
  });

  testWidgets('reduce motion snaps the morph to its target', (tester) async {
    await tester.pumpWidget(
      _toggle(running: false, onTap: () {}, disableAnimations: true),
    );
    await tester.pumpAndSettle();
    expect(_morphProgress(tester), 0);

    await tester.pumpWidget(
      _toggle(running: true, onTap: () {}, disableAnimations: true),
    );
    // One frame, no settle: an accessibility device sees the end state at once.
    await tester.pump();
    expect(_morphProgress(tester), 1);
  });

  testWidgets('rapid taps all reach the card (no debounce lock)', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_toggle(running: false, onTap: () => taps++));

    await tester.tap(find.byType(StartToggle));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.byType(StartToggle));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.byType(StartToggle));
    await tester.pumpAndSettle();

    // Serialisation lives upstream (the lifecycle chain and the toggle token);
    // the button must not silently swallow real presses.
    expect(taps, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the glyph rides the same target as the shape', (tester) async {
    // The play/pause glyph is a continuous vertex morph driven by its own
    // implicit tween toward the same `running` target; a stop mid-morph must
    // reverse it rather than reset to a fresh end value.
    await tester.pumpWidget(_toggle(running: false, onTap: () {}));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_toggle(running: true, onTap: () {}));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(_toggle(running: false, onTap: () {}));
    await tester.pump(const Duration(milliseconds: 100));
    final mid = _morphProgress(tester);
    expect(mid, isNotNull);
    expect(mid! > 0 && mid < 1, isTrue, reason: 'reversed morph was $mid');
    await tester.pumpAndSettle();
    expect(_morphProgress(tester), 0);
    expect(tester.takeException(), isNull);
  });
}
