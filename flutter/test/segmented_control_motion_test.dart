// A segmented control's selection pill and label transition are control
// transitions: under the system's reduce-motion setting they must collapse to
// zero, the way ConnectedButtonGroup and other connected controls do. They
// used to run on fixed durations and ignored the setting.

import 'package:flrone/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

Widget _control({required String value, required bool reduceMotion}) {
  Widget child = Center(
    child: SegmentedControl<String>(
      segments: const [('a', 'Alpha'), ('b', 'Beta')],
      value: value,
      onChanged: (_) {},
    ),
  );
  if (reduceMotion) {
    child = MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: child,
    );
  }
  return TestApp(child: child);
}

void main() {
  testWidgets('segmented selection animates with motion allowed', (tester) async {
    await tester.pumpWidget(_control(value: 'a', reduceMotion: false));
    await tester.pumpAndSettle();

    final pill = tester.widget<TweenAnimationBuilder<Rect?>>(
      find.byType(TweenAnimationBuilder<Rect?>),
    );
    final text = tester.widget<AnimatedDefaultTextStyle>(
      find.byType(AnimatedDefaultTextStyle).first,
    );
    expect(pill.duration, const Duration(milliseconds: 250));
    expect(text.duration, const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);
  });

  testWidgets('segmented selection collapses under reduce motion',
      (tester) async {
    await tester.pumpWidget(_control(value: 'a', reduceMotion: true));
    await tester.pumpAndSettle();

    final pill = tester.widget<TweenAnimationBuilder<Rect?>>(
      find.byType(TweenAnimationBuilder<Rect?>),
    );
    final text = tester.widget<AnimatedDefaultTextStyle>(
      find.byType(AnimatedDefaultTextStyle).first,
    );
    expect(pill.duration, Duration.zero);
    expect(text.duration, Duration.zero);
    expect(tester.takeException(), isNull);
  });
}
