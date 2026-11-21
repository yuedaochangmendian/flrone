import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/main.dart';
import 'package:flrone/pages/route_test.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';
import 'support/fake_route_kernel.dart';

void main() {
  testWidgets('runs the kernel route test and renders its steps', (tester) async {
    reportFlutterErrors();
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.route-test');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready'
        ? {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': 'Started'},
            'preferences': {'locale': 'en'},
          }
        : null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final box = BoxController(channel: channel, events: events.stream);
    Map<String, Object?>? captured;
    box.debugAttach(
      FakeRouteKernel((method, data) {
        if (method != ActionMethod.routeTest) return null;
        captured = Map<String, Object?>.from(data as Map);
        return {
          'is_final': true,
          'action': 'route',
          'outbound': 'proxy',
          'destination': 'example.com:443',
          'domain': 'example.com',
          'inbound': 'mixed-in',
          'steps': [
            {
              'index': 0,
              'rule': 'domain-suffix example.com',
              'action': 'route',
              'action_detail': 'proxy',
              'matched': 'example.com',
            },
          ],
        };
      }),
      NoopKernelWorker(),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await events.close();
    });

    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const RouteTestPage());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'example.com');
    await tester.tap(find.text('Run test'));
    await tester.pumpAndSettle();

    expect(captured?['domain'], 'example.com');
    expect(captured?['port'], 443);
    expect(captured?['network'], 'tcp');
    expect(find.text('proxy'), findsOneWidget);
    expect(find.text('example.com:443'), findsOneWidget);
    expect(find.textContaining('domain-suffix'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
