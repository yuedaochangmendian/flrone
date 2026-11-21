// A long, unbreakable trailing value must not squeeze the title into a
// vertical column. The node editor's encryption row hit exactly this: an
// Xray VLESS config can carry an `mlkem768x25519plus.native.0rtt...`
// encryption string that the form's `none`-only option list predates. The
// choice row now caps the value's width and offers the current value as a
// selectable option instead of silently overwriting it.

import 'dart:convert' as convert;

import 'package:flrone/pages/protocol_form.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

const _longEncryption =
    'kem768x25519plus.native.0rtt.rWg7hT9pLm3qX8vN2kZcF5sB6dJ1aYuE4oP0xQ';

// The editor seeds itself from a `nodeConfig` payload whose `json` field is the
// outbound as a JSON string.
Json _config(String encryption) => {
      'name': 'Vless',
      'json': convert.jsonEncode({
        'type': 'xrayvless',
        'name': 'Vless',
        'settings': {
          'address': '2607:fa98:4000:7:b0::1',
          'port': 443,
          'id': '822850d9-1c6d-47bc-9286-abcdef',
          'encryption': encryption,
          'flow': 'none',
        },
      }),
    };

void main() {
  testWidgets('a long encryption value keeps its label on one line',
      (tester) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(TestApp(
      child: ProtocolFormPage(id: 1, draft: _config(_longEncryption)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final title = find.text('Encryption');
    expect(title, findsOneWidget);
    final size = tester.getSize(title);
    // A normal one-line label, not four stacked CJK glyphs.
    expect(size.height, lessThan(size.width));
    // The value is present but ellipsized, never laid out at full length.
    final value = find.text(_longEncryption, skipOffstage: false);
    expect(value, findsOneWidget);
    expect(tester.getSize(value).width, lessThan(400 * .55 + 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the form keeps a value outside its option list', (tester) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(TestApp(
      child: ProtocolFormPage(id: 1, draft: _config(_longEncryption)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Opening the sheet offers the current (unknown) value as an option, so
    // the editor cannot silently replace it with "none".
    await tester.tap(find.text('Encryption'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(_longEncryption, skipOffstage: false), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
