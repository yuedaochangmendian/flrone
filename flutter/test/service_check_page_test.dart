import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/main.dart';
import 'package:flrone/pages/service_check.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';
import 'support/fake_route_kernel.dart';

void main() {
  testWidgets('runs the kernel serviceTest action and renders grouped results',
      (tester) async {
    reportFlutterErrors();
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.service-check');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
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
    ActionMethod? usedMethod;
    Object? sentData;
    box.kernel.debugAttach(
      FakeRouteKernel((method, data) {
        if (method != ActionMethod.serviceTest) return null;
        usedMethod = method;
        sentData = data;
        return {
          'results': [
            {
              'tag': 'proxy',
              'result': {
                'checks': [
                  {
                    'id': 'chatgpt',
                    'name': 'ChatGPT',
                    'category': 'ai',
                    'status': 'available',
                    'region': 'US',
                    'note': '',
                  },
                  {
                    'id': 'netflix',
                    'name': 'Netflix',
                    'category': 'streaming',
                    'status': 'blocked',
                    'region': 'CN',
                    'note': 'not available in region',
                  },
                ],
                'ip_info': [
                  {
                    'provider': 'ipinfo',
                    'ip': '1.2.3.4',
                    'country_code': 'US',
                    'asn': 'AS123',
                    'org': 'Example',
                    'type': 'proxy',
                    'risk_score': 3,
                    'flags': ['vpn'],
                    'error': '',
                  },
                ],
              },
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
    openPage(tester.element(find.byType(HomePage)), const ServiceCheckPage());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Run check'));
    await tester.pumpAndSettle();

    expect(usedMethod, ActionMethod.serviceTest);
    expect(sentData, isA<Map>());
    expect(find.text('ChatGPT'), findsOneWidget);
    expect(find.text('Netflix'), findsOneWidget);
    expect(find.text('Streaming'), findsOneWidget);
    expect(find.textContaining('not available in region'), findsOneWidget);
    expect(find.textContaining('1.2.3.4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reports a clear error when no core is attached', (tester) async {
    reportFlutterErrors();
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.service-check-stopped');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready'
        ? {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': 'Stopped'},
            'preferences': {'locale': 'en'},
          }
        : null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final box = BoxController(channel: channel, events: events.stream);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await events.close();
    });

    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const ServiceCheckPage());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Run check'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('service check needs the running core'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
