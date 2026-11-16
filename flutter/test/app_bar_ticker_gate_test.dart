// The reported bug: an inactive tab is kept alive by PageSwitcher's Offstage
// and shares the root ModalRoute (whose isCurrent stays true), so a lifted
// app-bar item could stay painted in the root overlay over the active tab.
// The only per-tab signal is TickerMode(enabled: i == index) in main.dart.
// These tests assert that an inactive tab contributes NO painted action to the
// root overlay, and that the active tab's own actions still work.

import 'package:flrone/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

Widget _actionsPage() => Scaffold(
      title: 'Routing',
      body: const SizedBox.expand(),
      iconActions: [
        IconButtonData(glyph: AppGlyphs.add, tooltip: 'New', onPressed: () {}),
        IconButtonData(
            glyph: AppGlyphs.refresh, tooltip: 'Refresh', onPressed: () {}),
      ],
    );

/// A page's action exists once in its own slot. If a lifted overlay copy is
/// also being painted over another page, the same tooltip appears twice.
int _copies(WidgetTester tester, String tooltip) =>
    find.byWidgetPredicate(
      (w) => w is AppBarActionButton && w.data.tooltip == tooltip,
      skipOffstage: false,
    ).evaluate().length;

void main() {
  void sizePhone(WidgetTester tester) {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('an inactive tab paints no lifted action in the root overlay',
      (tester) async {
    sizePhone(tester);
    await tester.pumpWidget(TestApp(
      child: Stack(children: [
        TickerMode(enabled: false, child: _actionsPage()),
        const Scaffold(title: 'Tools', body: SizedBox.expand()),
      ]),
    ));
    await tester.pumpAndSettle();

    // The inactive tab's actions may exist in its own (offstage) slot, but
    // none of them may be painted through a root-overlay lift.
    expect(_copies(tester, 'New'), lessThanOrEqualTo(1),
        reason: 'an inactive tab must not paint a lifted copy over the active page');
    expect(_copies(tester, 'Refresh'), lessThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the active tab still shows its own actions', (tester) async {
    sizePhone(tester);
    await tester.pumpWidget(TestApp(child: _actionsPage()));
    await tester.pumpAndSettle();
    expect(find.byTooltip('New'), findsOneWidget);
    expect(find.byTooltip('Refresh'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching tabs does not leave the old tab painted',
      (tester) async {
    sizePhone(tester);
    Widget tree(bool routingActive) => TestApp(
          child: Stack(children: [
            TickerMode(enabled: routingActive, child: _actionsPage()),
            TickerMode(
              enabled: !routingActive,
              child: const Scaffold(title: 'Tools', body: SizedBox.expand()),
            ),
          ]),
        );
    await tester.pumpWidget(tree(true));
    await tester.pumpAndSettle();
    expect(find.byTooltip('New'), findsOneWidget);

    await tester.pumpWidget(tree(false));
    await tester.pumpAndSettle();
    expect(_copies(tester, 'New'), lessThanOrEqualTo(1));
    expect(_copies(tester, 'Refresh'), lessThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });
}
