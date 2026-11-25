import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flrone/ui/prism_ui.dart';

import '../support/test_app.dart';

/// BannerHost is driven through its public [BannerHostState.show] API; these
/// tests pin the queue rules the implementation actually follows in
/// banner.dart: repeated messages merge into the live banner, errors jump
/// ahead of buffered info, and tapping a banner runs its action.
void main() {
  late BannerHostState host;

  Widget buildHost({required bool stacked}) => TestApp(
    child: BannerHost(
      stacked: stacked,
      topInset: 0,
      child: Builder(
        builder: (context) {
          host = BannerHost.maybeOf(context)!;
          return const SizedBox.expand();
        },
      ),
    ),
  );

  testWidgets('a repeat merges into the live banner and replaces its tap', (
    tester,
  ) async {
    var firstTaps = 0;
    var secondTaps = 0;
    await tester.pumpWidget(buildHost(stacked: true));

    host.show('same message', onTap: () => firstTaps++);
    await tester.pumpAndSettle();
    expect(find.text('same message'), findsOneWidget);

    host.show('same message', onTap: () => secondTaps++);
    await tester.pumpAndSettle();
    expect(
      find.text('same message'),
      findsOneWidget,
      reason: 'a repeat must merge, not stack a second banner',
    );

    await tester.tap(find.text('same message'));
    await tester.pumpAndSettle();
    expect(firstTaps, 0);
    expect(secondTaps, 1, reason: 'the merged banner carries the newest tap');
  });

  testWidgets('a buffered error overtakes an earlier info banner', (
    tester,
  ) async {
    await tester.pumpWidget(buildHost(stacked: false));

    host.show('info first');
    host.show('error second', level: BannerLevel.error);
    await tester.pumpAndSettle();

    // Only one banner fits when not stacked, and the error waits in the buffer.
    expect(find.text('info first'), findsOneWidget);
    expect(find.text('error second'), findsNothing);

    // The info banner's three-second hide timer expires, then the error is
    // pulled out of the buffer ahead of anything else queued.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.text('error second'), findsOneWidget);
    expect(find.text('info first'), findsNothing);
  });

  testWidgets('distinct messages stack up to three banners', (tester) async {
    await tester.pumpWidget(buildHost(stacked: true));

    for (var i = 0; i < 4; i++) {
      host.show('banner $i');
    }
    await tester.pumpAndSettle();

    for (var i = 0; i < 4; i++) {
      expect(
        find.text('banner $i'),
        i < 3 ? findsOneWidget : findsNothing,
        reason: 'a stacked host holds at most three visible banners',
      );
    }
  });
}
