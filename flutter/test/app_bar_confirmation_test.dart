// A form's confirmation action is the bar's primary action. It used to be
// folded into TonalButtonGroup like any other icon, so with one confirmation
// and three icon actions the phone bar clipped "Save" and "Add rule" into a
// single half-capsule segment each — a segmented control's shape on a button
// that commits the whole form. These tests pin that the confirmation stands
// alone with its own filled shape, while the icon actions still group.

import 'package:flrone/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

Widget _bar({IconButtonData? confirmation, List<IconButtonData> icons = const []}) =>
    TestApp(
      child: Scaffold(
        title: 'Edit',
        body: const SizedBox.expand(),
        confirmationAction: confirmation,
        iconActions: icons,
      ),
    );

IconButtonData _action(String tooltip, Glyph glyph) => IconButtonData(
      glyph: glyph,
      tooltip: tooltip,
      onPressed: () {},
    );

void main() {
  testWidgets('a confirmation is not grouped with the icon actions',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final save = _action('Save', AppGlyphs.check);
    await tester.pumpWidget(_bar(
      confirmation: save,
      icons: [
        _action('Add rule', AppGlyphs.add),
        _action('Reset rules', AppGlyphs.reset),
        _action('Refresh', AppGlyphs.refresh),
      ],
    ));
    await tester.pump();

    // Save exists and is reachable.
    expect(find.byTooltip('Save'), findsOneWidget);
    // It is never inside the capsule group, so it cannot be clipped into a
    // half-capsule beside an unrelated icon. With this many actions only one
    // icon stays in the bar, so the group may be absent altogether.
    expect(
      find.descendant(
        of: find.byType(TonalButtonGroup),
        matching: find.byTooltip('Save'),
      ),
      findsNothing,
      reason: 'the confirmation must not be clipped into the icon group',
    );
    expect(
      find.ancestor(
        of: find.byTooltip('Save'),
        matching: find.byType(TonalButtonGroup),
      ),
      findsNothing,
      reason: 'no capsule group is an ancestor of the confirmation',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the confirmation is filled so it reads as the primary action',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final save = _action('Save', AppGlyphs.check);
    await tester.pumpWidget(_bar(confirmation: save, icons: [
      _action('Add rule', AppGlyphs.add),
      _action('Reset rules', AppGlyphs.reset),
      _action('Refresh', AppGlyphs.refresh),
    ]));
    await tester.pump();

    final button = tester.widget<AppBarActionButton>(find.ancestor(
      of: find.byTooltip('Save'),
      matching: find.byType(AppBarActionButton),
    ).first);
    expect(button.filled, isTrue);
    expect(button.data.tooltip, 'Save');
  });

  testWidgets('a bar with no confirmation still groups its icons',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_bar(icons: [
      _action('Add rule', AppGlyphs.add),
      _action('Reset rules', AppGlyphs.reset),
      _action('Refresh', AppGlyphs.refresh),
    ]));
    await tester.pump();

    expect(find.byType(TonalButtonGroup), findsOneWidget);
    expect(find.byTooltip('Add rule'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a lone confirmation is still an independent filled button',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_bar(
      confirmation: _action('Save', AppGlyphs.check),
    ));
    await tester.pump();

    // One button alone would have been wrapped in a group before; it must stay
    // a single filled action with no group container.
    expect(find.byType(TonalButtonGroup), findsNothing);
    final button = tester.widget<AppBarActionButton>(find.ancestor(
      of: find.byTooltip('Save'),
      matching: find.byType(AppBarActionButton),
    ).first);
    expect(button.filled, isTrue);
    expect(tester.takeException(), isNull);
  });
}
