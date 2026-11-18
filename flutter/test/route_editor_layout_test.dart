// The route profile editor's layout, pinned to the four defects a phone-sized
// screenshot showed: a long remote URL squeezing its label into a vertical
// column, a doubled gap above the first section, page text legible through the
// floating bar, and a progress pill left floating over that bar.
//
// The harness is `route_fragment_test.dart`'s: the fake kernel answers the
// frozen route API, so the screens run their real code path.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';
import 'support/fake_route_kernel.dart';

const longUrl =
    'https://raw.githubusercontent.com/throneproj/routepro/master/bypass-china/proxy/bypass-china.json';

Map<String, Object?> profile(
  String name, {
  int id = 1,
  bool current = false,
  bool isRemote = false,
  int ruleCount = 3,
}) => {
      'id': id,
      'name': name,
      'defaultOutbound': 'proxy',
      'current': current,
      'isRemote': isRemote,
      'isRaw': false,
      'ruleCount': ruleCount,
      'simpleRuleCount': 0,
    };

Map<String, Object?> rule(String name, {String? domainSuffix}) => {
      'name': name,
      'type': 'custom',
      'disabled': false,
      'action': 'route',
      'outbound_id': -2,
      'domain': <String>[],
      'domain_suffix': <String>[?domainSuffix],
      'ip_cidr': <String>[],
      'rule_set': <String>[],
      'port': <String>[],
      'invert': false,
      'no_drop': false,
      'sniff_override_dest': false,
      'network_is_expensive': false,
      'ip_is_private': false,
      'source_ip_is_private': false,
      'tls_fragment': false,
      'tls_record_fragment': false,
    };

void main() {
  late StreamController<dynamic> events;
  late List<Map<String, Object?>> profiles;
  late Map<int, List<Map<String, Object?>>> profileRules;

  Object? routeFixtures(ActionMethod method, Object? data) {
    final payload = data is Map ? data : const <String, dynamic>{};
    switch (method) {
      case ActionMethod.getRouteProfiles:
        return {'currentId': 1, 'profiles': profiles};
      case ActionMethod.getRouteProfile:
        final id = (payload['id'] as num?)?.toInt() ?? 0;
        final found = profiles.firstWhere((p) => (p['id'] as num?)?.toInt() == id,
            orElse: () => const <String, Object?>{});
        return {
          ...found,
          'remoteUrl': found['isRemote'] == true ? longUrl : '',
          'autoUpdate': false,
          'rules': '',
        };
      case ActionMethod.getRouteRules:
        final id = (payload['id'] as num?)?.toInt() ?? 0;
        return {'rules': profileRules[id] ?? const []};
      case ActionMethod.saveRouteRules:
        return {'rules': payload['rules'] ?? const []};
      case ActionMethod.saveRouteProfile:
        return (payload['id'] as num?)?.toInt() ?? 1;
      default:
        return null;
    }
  }

  Future<void> mount(WidgetTester tester) async {
    reportFlutterErrors();
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    // A phone, narrow enough that a 96-character URL cannot fit beside its
    // label on one line.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    profiles = [profile('Bypass China', isRemote: true, current: true)];
    profileRules = {
      1: [
        rule('Bypass China',
            domainSuffix:
                'a-very-long-domain-suffix-that-cannot-fit-in-a-single-line-of-the-rule-row.example'),
      ],
    };

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

  Future<void> openEditor(WidgetTester tester) async {
    openPage(tester.element(find.byType(HomePage)), const RoutingPage());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    expect(find.byType(RouteProfileEditorPage), findsOneWidget);
  }

  testWidgets('a long URL keeps its label on one line', (tester) async {
    await mount(tester);
    await openEditor(tester);

    final label = tester.getSize(find.text('URL'));
    final lineHeight = tester.getSize(find.text('Remote')).height;
    expect(label.height, lessThanOrEqualTo(lineHeight * 1.5 + 0.5),
        reason: 'the label is one line, not a vertical column');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the body starts below the bar once, not twice', (tester) async {
    await mount(tester);
    await openEditor(tester);

    final list = tester.widget<ListView>(
      find.descendant(of: find.byType(RouteProfileEditorPage), matching: find.byType(ListView)).first,
    );
    final top = (list.padding as EdgeInsets).top;
    // The first child is a titled section, so the page's clearance (the 72
    // toolbar plus 12) gives up the 24 the section header brings itself: 60.
    // Leaving contentTopPadding here put the first header at 84, and the
    // header's own gap then doubled the empty space above it.
    expect(top, closeTo(72 + 12 - 24, .5));

    // The bar floats over the body, and the header's box may reach under it;
    // its text must not. Left doubled, that text sat at 102.
    final headerTop = tester
        .getRect(find.descendant(
          of: find.byType(RouteProfileEditorPage),
          matching: find.text('Profile'),
        ).first)
        .top;
    expect(headerTop, greaterThanOrEqualTo(72 - .5), reason: 'clear of the bar');
    expect(headerTop, lessThan(90), reason: 'not the section gap on top of the clearance');
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling the editor neither overflows nor throws', (tester) async {
    await mount(tester);
    await openEditor(tester);

    final list = find
        .descendant(of: find.byType(RouteProfileEditorPage), matching: find.byType(ListView))
        .first;
    await tester.drag(list, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.drag(list, const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('an opaque strip keeps scrolled rows out of the bar', (tester) async {
    await mount(tester);
    await openEditor(tester);

    final backdrop = find.byKey(const ValueKey('route-editor-bar-backdrop'));
    expect(backdrop, findsOneWidget);
    final box = tester.widget<DecoratedBox>(backdrop);
    final gradient = (box.decoration as BoxDecoration).gradient! as LinearGradient;
    expect(gradient.colors.first.a, 1, reason: 'opaque where the bar sits');

    final rect = tester.getRect(backdrop);
    final page = tester.getRect(find.byType(RouteProfileEditorPage));
    expect(rect.top, page.top);
    expect(rect.height, greaterThan(0));

    await tester.drag(
      find.descendant(of: find.byType(RouteProfileEditorPage), matching: find.byType(ListView)).first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    // The strip stays over the bar whatever the list holds under it.
    expect(tester.getRect(backdrop), rect);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a save in flight paints no spinner over the bar', (tester) async {
    await mount(tester);
    await openEditor(tester);

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
    expect(scaffold.isLoading, isFalse,
        reason: 'the bar LoadingBar runs out of the bar box over the page');

    await tester.tap(find.byTooltip('Save'));
    await tester.pump();
    // The page reports its own progress in the body: an inline bar, never the
    // blue ring the app-bar action spinner drew against the title.
    expect(find.byType(LinearProgressIndicator), findsAny);
    final editor = tester.state<State<RouteProfileEditorPage>>(find.byType(RouteProfileEditorPage));
    expect(editor.mounted, isTrue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
