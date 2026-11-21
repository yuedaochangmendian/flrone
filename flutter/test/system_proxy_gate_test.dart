import 'dart:async';

import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _mount(WidgetTester tester, String name, {required bool available}) async {
  tester.view.physicalSize = const Size(360, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final events = StreamController<dynamic>.broadcast();
  final channel = MethodChannel(name);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready'
      ? {
          'version': 'test',
          'coreVersion': 'test',
          // The manifest knows the API level only; the dashboard carries the service mode.
          'capabilities': {'systemProxy': true},
          'dashboard': {'status': 'Stopped', 'systemProxyAvailable': available},
          'preferences': {'locale': 'en'},
        }
      : null);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
  await tester.pumpAndSettle();
  openPage(tester.element(find.byType(HomePage)), const InboundPage());
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}

void main() {
  testWidgets('the system proxy section follows the dashboard, not the API capability', (tester) async {
    await _mount(tester, 'test.system_proxy_off', available: false);
    expect(find.text('System proxy'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the system proxy section appears when the VPN mode can write it', (tester) async {
    await _mount(tester, 'test.system_proxy_on', available: true);
    expect(find.text('System proxy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
