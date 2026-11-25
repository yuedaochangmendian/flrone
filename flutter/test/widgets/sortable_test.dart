import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flrone/ui/prism_ui.dart';

import '../support/test_app.dart';

/// The handle reads `SliverReorderableList.maybeOf(context)` and only calls
/// `onReorderItem` when that ancestor is present. This file pins both halves
/// of that contract: with an ancestor the keyboard path reports a move, and
/// without one the same key sequence is a harmless no-op.
void main() {
  /// The innermost Focus is the one SortHandle builds; its node owns the
  /// onKeyEvent handler we want to drive.
  FocusNode handleNodeOf(WidgetTester tester) =>
      (tester.state<State>(find.byType(Focus).last) as dynamic).focusNode
          as FocusNode;

  Widget buildHandle({required int index}) => SortHandle(index: index);

  testWidgets('a lifted handle reports arrow-key moves to its list', (
    tester,
  ) async {
    final moves = <(int, int)>[];

    await tester.pumpWidget(
      TestApp(
        child: CustomScrollView(
          slivers: [
            SliverPrismReorderableList(
              itemCount: 5,
              onReorderItem: (from, to) => moves.add((from, to)),
              itemBuilder: (_, index) => SizedBox(
                key: ValueKey(index),
                height: 60,
                child: index == 1
                    ? buildHandle(index: index)
                    : Text('row $index'),
              ),
            ),
          ],
        ),
      ),
    );

    handleNodeOf(tester).requestFocus();
    await tester.pump();
    expect(handleNodeOf(tester).hasFocus, isTrue);
    expect(moves, isEmpty, reason: 'a focused but unlifted handle must not move');

    // Space lifts the row; arrow keys then move it until space or escape drops.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    // The widget keeps its own index; it only reports (from, to) to the list.
    expect(moves, [(1, 2), (1, 0)]);
  });

  testWidgets('a handle without a reorderable ancestor is a no-op', (
    tester,
  ) async {
    final moves = <(int, int)>[];
    // A plain Column has no SliverReorderableList above the handle. The
    // callback exists only to make a stray reorder visible to the assertion.
    await tester.pumpWidget(
      TestApp(
        child: Column(
          children: [
            buildHandle(index: 0),
            const Text('plain row'),
          ],
        ),
      ),
    );

    handleNodeOf(tester).requestFocus();
    await tester.pump();
    expect(handleNodeOf(tester).hasFocus, isTrue);

    // The whole key sequence must not throw even though there is no list.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(moves, isEmpty);
    expect(find.text('plain row'), findsOneWidget);
  });

  testWidgets('a lifted handle ignores arrow keys outside the list bounds', (
    tester,
  ) async {
    final moves = <(int, int)>[];

    await tester.pumpWidget(
      TestApp(
        child: CustomScrollView(
          slivers: [
            SliverPrismReorderableList(
              itemCount: 3,
              onReorderItem: (from, to) => moves.add((from, to)),
              itemBuilder: (_, index) => SizedBox(
                key: ValueKey(index),
                height: 60,
                child: index == 0
                    ? buildHandle(index: index)
                    : Text('row $index'),
              ),
            ),
          ],
        ),
      ),
    );

    handleNodeOf(tester).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    // index 0 with arrowUp targets -1, which the handle must reject.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    // Horizontal arrows are consumed (handled) but never reorder.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(moves, isEmpty, reason: 'out-of-range moves are ignored');
  });
}
