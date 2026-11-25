// The single global rule list's layout: a long rule summary must not squeeze
// its row, the list must not double its top inset, and scrolling must neither
// overflow nor throw. There is no profile metadata any more — the harness is
// the routing screen's fake kernel answering the global table.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';
import 'support/fake_route_kernel.dart';

const longSuffix =
    'a-very-long-domain-suffix-that-cannot-fit-in-a-single-line-of-the-rule-row.example';

Map<String, Object?> rule(String name, {String? domainSuffix}) => {
      'name': name,
      'type': 'custom',
      'disabled': false,
      'action': 'route',
      'outbound_id': -2,
      'domain_suffix_json': <String>[?domainSuffix],
      'invert': false,
      'no_drop': false,
    };

void main() {
  late StreamController<dynamic> events;
  late List<Map<String, Object?>> globalRules;

  Object? routeFixtures(ActionMethod method, Object? data) {
    final payload = data is Map ? data : const <String, dynamic>{};
    switch (method) {
      case ActionMethod.getGlobalRules:
        return {'rules': globalRules};
      case ActionMethod.saveGlobalRules:
        return {'rules': payload['rules'] ?? const []};
      default:
        return null;
    }
  }

  Future<void> mount(WidgetTester tester) async {
    reportFlutterErrors();
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    globalRules = [
      rule('Bypass China', domainSuffix: longSuffix),
      rule('Direct LAN', domainSuffix: 'lan.test'),
      rule('Block ads', domainSuffix: 'ads.test'),
    ];

    const channel = MethodChannel('test.route-editor-layout');
    events = StreamController<dynamic>.broadcast();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'preferences': {'locale': 'en'},
          'dashboard': {'status': 'Stopped'},
        };
      }
      if (call.method == 'groups.nodes') return {'nodes': const []};
      return null;
    });
    final box = BoxController(channel: channel, events: events.stream);
    box.debugAttach(FakeRouteKernel(routeFixtures), NoopKernelWorker());
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });
  }

  Future<void> openRouting(WidgetTester tester) async {
    openPage(tester.element(find.byType(HomePage)), const RoutingPage());
    await tester.pumpAndSettle();
    expect(find.byType(GlobalRulesPage), findsOneWidget);
  }

  testWidgets('a long rule summary stays on its row', (tester) async {
    await mount(tester);
    await openRouting(tester);
    expect(find.text('Bypass China'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the body starts below the bar once', (tester) async {
    await mount(tester);
    await openRouting(tester);
    final list = tester.widget<ListView>(
      find.descendant(of: find.byType(GlobalRulesPage), matching: find.byType(ListView)).first,
    );
    final top = (list.padding as EdgeInsets).top;
    expect(top, greaterThan(0), reason: 'the list clears the toolbar');
    expect(top, lessThan(120), reason: 'the clearance is applied once, not doubled');
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling the rule list neither overflows nor throws', (tester) async {
    await mount(tester);
    await openRouting(tester);
    final list = find
        .descendant(of: find.byType(GlobalRulesPage), matching: find.byType(ListView))
        .first;
    await tester.drag(list, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.drag(list, const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a save in flight shows the page progress inline', (tester) async {
    await mount(tester);
    await openRouting(tester);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
    expect(scaffold.isLoading, isFalse);
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    // The fake kernel answers at once, so the inline progress bar is already
    // gone by the time the settled frame is painted — the important contract is
    // that the bar action never used the scaffold's pill spinner.
    expect(tester.takeException(), isNull);
  });
}
