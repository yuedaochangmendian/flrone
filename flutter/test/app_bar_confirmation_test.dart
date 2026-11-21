// A form's confirmation action is the bar's primary action. It used to be
// folded into TonalButtonGroup like any other icon, so with one confirmation
// and three icon actions the phone bar clipped "Save" and "Add rule" into a
// single half-capsule segment each — a segmented control's shape on a button
// that commits the whole form. A later attempt to give it a filled accent
// button style then left a clipped blue arc at the group's edge on every
// settings page. These tests pin that the confirmation stands alone, is a
// whole button, and is kept out of both the capsule group and the bar's
// overlay materialization so nothing can paint over it.

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

Finder _saveButton(WidgetTester tester) => find.ancestor(
      of: find.byTooltip('Save'),
      matching: find.byType(AppBarActionButton),
    ).first;

void main() {
  testWidgets('a confirmation is an independent whole button', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_bar(
      confirmation: _action('Save', AppGlyphs.check),
      icons: [
        _action('Add rule', AppGlyphs.add),
        _action('Reset rules', AppGlyphs.reset),
        _action('Refresh', AppGlyphs.refresh),
      ],
    ));
    await tester.pump();

    expect(find.byTooltip('Save'), findsOneWidget);
    // Never clipped into the capsule group.
    expect(
      find.descendant(
        of: find.byType(TonalButtonGroup),
        matching: find.byTooltip('Save'),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.byTooltip('Save'),
        matching: find.byType(TonalButtonGroup),
      ),
      findsNothing,
    );
    // Kept out of the presence overlay that could paint a glass layer over it.
    expect(
      find.ancestor(
        of: find.byTooltip('Save'),
        matching: find.byType(BarItemPresence),
      ),
      findsNothing,
      reason: 'no overlay materialization may cover the confirmation',
    );
    // A normal AppBarActionButton, no special filled style.
    expect(tester.widget<AppBarActionButton>(_saveButton(tester)).data.tooltip,
        'Save');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the confirmation never overlaps a neighbouring group',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_bar(
      confirmation: _action('Save', AppGlyphs.check),
      icons: [
        _action('Add rule', AppGlyphs.add),
        _action('Reset rules', AppGlyphs.reset),
      ],
    ));
    await tester.pump();

    final save = tester.getRect(find.byTooltip('Save'));
    // The loop over groups used to be the whole assertion, so on a build with no group
    // it passed without checking anything (the sibling test above proves there is none).
    // Measure against the sibling actions themselves — that is what "clipped into the
    // group's edge" actually looked like.
    final siblings = find
        .byType(AppBarActionButton)
        .evaluate()
        .where((e) => (e.widget as AppBarActionButton).data.tooltip != 'Save')
        .toList();
    expect(siblings.length, 2, reason: 'both icon actions must be laid out in the bar');
    for (final element in siblings) {
      final rect = tester.getRect(find.byWidget(element.widget));
      expect(
        save.overlaps(rect),
        isFalse,
        reason: 'the confirmation ($save) must not sit under another action ($rect)',
      );
    }
    for (final group in find.byType(TonalButtonGroup).evaluate()) {
      final rect = tester.getRect(find.byWidget(group.widget));
      expect(
        save.overlaps(rect),
        isFalse,
        reason: 'the confirmation ($save) must not sit under a group ($rect)',
      );
    }
    // The loop above iterates whatever groups this build happens to render, so on a
    // build with none it asserted nothing (the same trap the sibling-actions check was
    // added to avoid). Pin the count explicitly: the layout deliberately produces no
    // TonalButtonGroup today, and a regression that reintroduces one must fail here.
    expect(
      find.byType(TonalButtonGroup),
      findsNothing,
      reason: 'the bar renders standalone buttons; a group would be the clipped shape '
          'this test exists to rule out',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('no action is wrapped in a capsule group', (tester) async {
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

    // Each action is its own round button; the old capsule group made the last
    // one read as a clipped half-capsule ("a covered button").
    expect(find.byType(TonalButtonGroup), findsNothing);
    expect(find.byTooltip('Add rule'), findsOneWidget);
    // The next icon stays reachable as a whole button rather than a segment.
    expect(find.byTooltip('Reset rules'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a lone confirmation stays a single independent button',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_bar(
      confirmation: _action('Save', AppGlyphs.check),
    ));
    await tester.pump();

    expect(find.byType(TonalButtonGroup), findsNothing);
    expect(
      find.ancestor(
        of: find.byTooltip('Save'),
        matching: find.byType(BarItemPresence),
      ),
      findsNothing,
    );
    expect(tester.widget<AppBarActionButton>(_saveButton(tester)).data.tooltip,
        'Save');
    expect(tester.takeException(), isNull);
  });
}
