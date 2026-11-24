import 'dart:async';
import 'dart:convert';

import 'package:flrone/main.dart';
import 'package:flrone/pages/group_settings.dart';
import 'package:flrone/pages/profiles.dart';
import 'package:flrone/pages/protocol_form.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/errors.dart';
import 'support/profile_duty.dart';
import 'support/test_app.dart';

void main() {
  Future<void> mount(WidgetTester tester, Future<dynamic> Function(MethodCall) handler) async {
    reportFlutterErrors();
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('test.maintenance-pages');
    final events = StreamController<dynamic>.broadcast();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'preferences': {'locale': 'en'},
          'dashboard': {'status': 'Stopped'},
        };
      }
      return handler(call);
    });
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });
  }

  testWidgets('typed protocol form renders a loaded protocol document', (tester) async {
    await mount(tester, (call) async {
      if (dutyOp(call) == 'nodeConfig') {
        return {
          'name': 'Node A',
          'json': jsonEncode({
            'type': 'shadowsocks',
            'tag': 'Node A',
            'server': 'example.com',
            'server_port': 8388,
            'method': 'aes-256-gcm',
            'password': 'secret',
          }),
        };
      }
      return null;
    });
    openPage(tester.element(find.byType(HomePage)), const ProtocolFormPage(id: 1));
    await tester.pumpAndSettle();
    expect(find.text('Edit settings'), findsWidgets);
    expect(find.text('Node A'), findsWidgets);
    expect(find.byTooltip('Save'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('group settings renders a basic group and exposes save', (tester) async {
    await mount(tester, (call) async {
      if (call.method == 'groupSettings.get') {
        return {
          'id': 7,
          'name': 'Primary',
          'type': 'basic',
          'url': '',
          'skipAutoUpdate': false,
          'autoClearUnavailable': false,
          'importSubRoute': false,
          'frontProxyId': -1,
          'landingProxyId': -1,
          'routeId': '-1',
          'sortMethod': 0,
          'sortDescending': false,
          'testSortBy': 0,
          'trafficSortBy': 0,
          'testItemsToShow': 0,
          'options': <String, dynamic>{},
          'defaults': <String, dynamic>{},
          'groups': <dynamic>[],
        };
      }
      return null;
    });
    openPage(tester.element(find.byType(HomePage)), const GroupSettingsPage(id: 7));
    await tester.pumpAndSettle();
    expect(find.text('Group settings'), findsWidgets);
    expect(find.text('Basic'), findsOneWidget);
    expect(find.text('Primary'), findsWidgets);
    expect(find.byTooltip('Save'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('auto selector renders idle status and its filters', (tester) async {
    await mount(tester, (call) async {
      if (dutyOp(call) == 'autoSelectorInfo') {
        return {
          'id': 9,
          'name': 'Auto',
          'gids': [1],
          'groups': [{'id': 1, 'name': 'Source'}],
          'members': <dynamic>[],
          'balance': false,
        };
      }
      if (dutyOp(call) == 'autoSelectorStatus') {
        return {'phase': 'idle', 'driver': 'ffi'};
      }
      return null;
    });
    openPage(tester.element(find.byType(HomePage)), const AutoSelectorPage(id: 9));
    await tester.pumpAndSettle();
    expect(find.text('Auto selector'), findsWidgets);
    expect(find.text('Filters'), findsWidgets);
    expect(find.byTooltip('Save'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('typed protocol form shows the XHTTP transport fields', (tester) async {
    await mount(tester, (call) async {
      if (dutyOp(call) == 'nodeConfig') {
        return {
          'name': 'XHTTP node',
          'json': jsonEncode({
            'type': 'vless',
            'tag': 'XHTTP node',
            'server': 'example.com',
            'server_port': 443,
            'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811',
            'encryption': 'none',
            'packet_encoding': 'xudp',
            'transport': {
              'type': 'xhttp',
              'host': 'cdn.example.com',
              'path': '/x',
              'mode': 'packet-up',
              'x_padding_bytes': '100-1000',
              'xmux': {'maxConnections': '4-8'},
            },
          }),
        };
      }
      return null;
    });
    openPage(tester.element(find.byType(HomePage)), const ProtocolFormPage(id: 2));
    await tester.pumpAndSettle();
    expect(find.text('X-Padding bytes'), findsOneWidget);
    expect(find.text('No gRPC header'), findsOneWidget);
    expect(find.text('No SSE header'), findsOneWidget);
    expect(find.text('Congestion controller'), findsOneWidget);
    expect(find.text('XHTTP extra JSON (xmux)'), findsOneWidget);
    // The KCP block stays hidden for an XHTTP transport.
    expect(find.text('MTU'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('typed protocol form shows the mKCP transport fields', (tester) async {
    await mount(tester, (call) async {
      if (dutyOp(call) == 'nodeConfig') {
        return {
          'name': 'KCP node',
          'json': jsonEncode({
            'type': 'vless',
            'tag': 'KCP node',
            'server': 'example.com',
            'server_port': 443,
            'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811',
            'encryption': 'none',
            'packet_encoding': 'xudp',
            'transport': {
              'type': 'mkcp',
              'mtu': 1350,
              'tti': 50,
              'congestion': true,
              'header_type': 'srtp',
              'seed': 'abc',
            },
          }),
        };
      }
      return null;
    });
    openPage(tester.element(find.byType(HomePage)), const ProtocolFormPage(id: 3));
    await tester.pumpAndSettle();
    expect(find.text('MTU'), findsOneWidget);
    expect(find.text('TTI'), findsOneWidget);
    expect(find.text('Uplink capacity'), findsOneWidget);
    expect(find.text('Downlink capacity'), findsOneWidget);
    expect(find.text('Header type'), findsOneWidget);
    expect(find.text('Seed'), findsOneWidget);
    // The XHTTP block stays hidden for an mKCP transport.
    expect(find.text('X-Padding bytes'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('the manual protocol picker offers only the sing-box VLESS', () {
    final vless = manualProtocols
        .where((entry) => entry.$2.toLowerCase().contains('vless'))
        .toList();
    expect(vless, [('vless', 'VLESS')]);
    expect(manualProtocols.any((entry) => entry.$1 == 'xrayvless'), isFalse);
  });

  testWidgets('an Xray-shaped document has no typed form', (tester) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(TestApp(
      child: ProtocolFormPage(id: 4, draft: {
        'name': 'Xray',
        'json': jsonEncode({
          'protocol': 'vless',
          'settings': {'address': 'example.com', 'port': 443, 'id': 'uuid'},
          'streamSettings': {'network': 'xhttp'},
        }),
      }),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('No typed form for this protocol'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
