// A page's app-bar actions must not outlive it. `BarItemPresence` lifts an
// action out of its page into the root overlay while a card route moves the
// page, so a bug there paints the previous page's icons (refresh / overflow /
// add) over an unrelated bar — reported as "buttons appear on the Appearance
// page" and as a clipped arc at the edge of a neighbouring button group.
// These tests drive the real card-route push/pop paths and assert the covered
// or popped page's actions are gone; `dispose` also hides the overlay
// explicitly as a safety net.

import 'package:flrone/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

Widget _withActions({bool confirmation = true}) => Scaffold(
      title: 'Route profile',
      body: const SizedBox.expand(),
      confirmationAction: confirmation
          ? IconButtonData(
              glyph: AppGlyphs.check, tooltip: 'Save', onPressed: () {})
          : null,
      iconActions: [
        IconButtonData(glyph: AppGlyphs.add, tooltip: 'New', onPressed: () {}),
        IconButtonData(glyph: AppGlyphs.refresh, tooltip: 'Refresh', onPressed: () {}),
      ],
    );

Widget _plain() => const Scaffold(title: 'Appearance', body: SizedBox.expand());

void main() {
  void sizePhone(WidgetTester tester) {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('push: covered actions do not leak forward', (tester) async {
    sizePhone(tester);
    await tester.pumpWidget(HostApp(
      home: Builder(
        builder: (context) => Scaffold(
          title: 'Home',
          body: Center(
            child: TextButton(
              onPressed: () => openPage(context, _withActions()),
              child: const Text('open-form'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-form'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('New'), findsOneWidget);

    openPage(tester.element(find.byTooltip('New')), _plain());
    await tester.pumpAndSettle();
    expect(find.byTooltip('New'), findsNothing);
    expect(find.byTooltip('Save'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pop: dismissed actions do not leak backward', (tester) async {
    sizePhone(tester);
    await tester.pumpWidget(HostApp(
      home: Builder(
        builder: (context) => Scaffold(
          title: 'Home',
          body: Center(
            child: TextButton(
              onPressed: () => openPage(context, _withActions()),
              child: const Text('open-form'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-form'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('New'), findsOneWidget);

    // Pop back to the action-less home page.
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.pop();
    await tester.pumpAndSettle();

    expect(find.byTooltip('New'), findsNothing,
        reason: 'a popped page\'s buttons must not remain on the page below');
    expect(find.byTooltip('Refresh'), findsNothing);
    expect(find.byTooltip('Save'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('push then push a third page', (tester) async {
    sizePhone(tester);
    await tester.pumpWidget(HostApp(
      home: Builder(
        builder: (context) => Scaffold(
          title: 'Home',
          body: Center(
            child: TextButton(
              onPressed: () => openPage(context, _withActions()),
              child: const Text('open-form'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-form'));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byTooltip('New')), _plain());
    await tester.pumpAndSettle();
    openPage(tester.element(find.text('Appearance')), _plain());
    await tester.pumpAndSettle();
    expect(find.byTooltip('New'), findsNothing);
    expect(find.byTooltip('Save'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pop back then open another child page', (tester) async {
    // The reported path: from a tools child page, go back to the tools page,
    // then open a different child. The first child's buttons must not still be
    // painted at the top of the second one (a lifted overlay item that never
    // settled).
    sizePhone(tester);
    await tester.pumpWidget(HostApp(
      home: Builder(
        builder: (context) => Scaffold(
          title: 'Home',
          body: Center(
            child: TextButton(
              onPressed: () => openPage(context, _withActions()),
              child: const Text('open-form'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-form'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('New'), findsOneWidget);

    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.pop();
    await tester.pumpAndSettle();

    // Re-enter from the same home, but with a different action-less page.
    await tester.tap(find.text('open-form'));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byTooltip('New')), _plain());
    await tester.pumpAndSettle();

    expect(find.byTooltip('New'), findsNothing);
    expect(find.byTooltip('Save'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
