// Opening the app bar's search must take the focus away from any field the page
// already has focused and ask for the keyboard. `autofocus: true` alone is not
// enough: EditableText's autofocus goes through FocusScope.autofocus, which
// deliberately yields to an existing focused child. A page with its own text
// field focused (Cmd-F on a form, for example) therefore opened a visible
// search field that did not own the keyboard, and typing went into the old
// field. These tests pin that the shared scaffold hands focus over explicitly.

import 'package:flrone/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

void main() {
  void wideView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('app bar search takes focus and keyboard from a page field',
      (tester) async {
    wideView(tester);
    final otherFocus = FocusNode(debugLabel: 'page-field');
    addTearDown(otherFocus.dispose);
    final searched = <String>[];

    await tester.pumpWidget(TestApp(
      child: Scaffold(
        title: 'Proxies',
        searchState: AppBarSearchState(onSearch: searched.add),
        body: Center(
          child: SizedBox(
            width: 240,
            child: EditableText(
              controller: TextEditingController(text: 'page'),
              focusNode: otherFocus,
              style: const TextStyle(),
              cursorColor: const Color(0xFF000000),
              backgroundCursorColor: const Color(0xFF000000),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Another field on the page holds the focus before search is opened.
    otherFocus.requestFocus();
    await tester.pumpAndSettle();
    expect(otherFocus.hasFocus, isTrue, reason: 'precondition: the page field is focused');

    // Open the app bar search.
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();

    // The focused editable is now the search field, not the page's field.
    final fields = tester.widgetList<EditableText>(find.byType(EditableText)).toList();
    expect(fields.length, 2, reason: 'the page field and the search field are both mounted');
    final searchEditable = fields.firstWhere((f) => f.focusNode != otherFocus);
    expect(otherFocus.hasFocus, isFalse, reason: 'the page field must give up focus');
    expect(searchEditable.focusNode.hasFocus, isTrue,
        reason: 'the search field must own the primary focus');
    expect(tester.testTextInput.isVisible, isTrue,
        reason: 'the search field must request the soft keyboard');

    // Typing goes into the search field and reaches the page's search callback.
    await tester.enterText(find.byWidget(searchEditable), 'hello');
    await tester.pumpAndSettle();
    expect(searched, contains('hello'));
    expect(otherFocus.hasFocus, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('app bar search focuses even when nothing else is focused',
      (tester) async {
    wideView(tester);
    final searched = <String>[];

    await tester.pumpWidget(TestApp(
      child: Scaffold(
        title: 'Logs',
        searchState: AppBarSearchState(onSearch: searched.add),
        body: const SizedBox.expand(),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();

    final fields = tester.widgetList<EditableText>(find.byType(EditableText)).toList();
    expect(fields, isNotEmpty);
    expect(fields.single.focusNode.hasFocus, isTrue,
        reason: 'the search field must be focused with no competing field');
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.enterText(find.byType(EditableText), 'abc');
    await tester.pumpAndSettle();
    expect(searched, contains('abc'));
    expect(tester.takeException(), isNull);
  });
}
