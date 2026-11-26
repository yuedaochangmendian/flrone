import 'dart:async';

import 'package:flrone/components/connectivity/connectivity_page.dart';
import 'package:flrone/components/tool_icon.dart';
import 'package:flrone/main.dart';
import 'package:flrone/pages/network_toolbox.dart';
import 'package:flrone/pages/traffic_stats.dart';
import 'package:flrone/services/traffic_stats.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/errors.dart';

void main() {
  Future<void> mountApp(WidgetTester tester, String channelName,
      {Json settings = const {}, Locale locale = const Locale('en')}) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(420, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.platformDispatcher.localesTestValue = [locale];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    final events = StreamController<dynamic>.broadcast();
    addTearDown(events.close);
    final channel = MethodChannel(channelName);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'dashboard': {'status': 'Stopped'},
          'settings': settings,
          'preferences': {'locale': locale.languageCode},
        };
      }
      if (call.method == 'settings.set') return settings;
      if (call.method == 'preferences.set') return <String, dynamic>{};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pumpAndSettle();
  }

  Future<void> openToolbox(WidgetTester tester) async {
    openPage(tester.element(find.byType(HomePage)), const NetworkToolboxPage());
    await tester.pumpAndSettle();
  }

  testWidgets('the toolbox shows every card title and description', (tester) async {
    await mountApp(tester, 'test.toolbox-cards');
    await openToolbox(tester);

    for (final title in [
      'Speed test', 'Connectivity test', 'Traffic statistics', 'Tool settings',
    ]) {
      expect(find.text(title), findsOneWidget, reason: 'card title $title');
    }
    expect(find.text('Measure download, upload speed and latency'), findsOneWidget);
    expect(find.text('Check whether common services are reachable'), findsOneWidget);
    expect(find.text('View traffic by day, week or month'), findsOneWidget);
    expect(find.text('Test parameters, traffic retention and exit lookup'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the card titles are translated', (tester) async {
    await mountApp(tester, 'test.toolbox-zh', locale: const Locale('zh'));
    await openToolbox(tester);
    for (final title in [
      '测速', '连通性测试', '流量统计', '工具设置',
    ]) {
      expect(find.text(title), findsOneWidget, reason: 'card title $title');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the speed test card opens the SpeedTestPage', (tester) async {
    await mountApp(tester, 'test.toolbox-speed');
    await openToolbox(tester);

    await tester.tap(find.text('Speed test'));
    await tester.pumpAndSettle();
    expect(find.byType(SpeedTestPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the connectivity card opens the ConnectivityPage', (tester) async {
    await mountApp(tester, 'test.toolbox-connectivity');
    await openToolbox(tester);

    await tester.tap(find.text('Connectivity test'));
    await tester.pumpAndSettle();
    expect(find.byType(ConnectivityPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the traffic card opens the TrafficStatsPage', (tester) async {
    await mountApp(tester, 'test.toolbox-traffic-page');
    await openToolbox(tester);

    await tester.tap(find.text('Traffic statistics'));
    await tester.pumpAndSettle();
    expect(find.byType(TrafficStatsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<void> openToolSettings(WidgetTester tester) async {
    await tester.tap(find.text('Tool settings'));
    await tester.pumpAndSettle();
  }

  testWidgets('tool settings groups the four parameter sections', (tester) async {
    await mountApp(tester, 'test.toolbox-node-sheet');
    await openToolbox(tester);

    await openToolSettings(tester);
    expect(find.byType(ToolSettingsPage), findsOneWidget);
    expect(find.text('Node tests'), findsOneWidget);
    expect(find.text('Test URL'), findsOneWidget);
    expect(find.text('Concurrent tests'), findsOneWidget);
    expect(find.text('Direct test URL'), findsOneWidget);
    expect(find.text('Speed test settings'), findsOneWidget);
    expect(find.text('Traffic statistics settings'), findsWidgets);
    expect(find.text('Exit detection'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mode 3 shows Simple download URL in tool settings', (tester) async {
    await mountApp(tester, 'test.toolbox-speed-sheet-3', settings: {'speedTestMode': 3});
    await openToolbox(tester);

    await openToolSettings(tester);
    expect(find.text('Speed test mode'), findsOneWidget);
    expect(find.text('Speed test timeout'), findsOneWidget);
    expect(find.text('Simple download URL'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('other modes hide Simple download URL in tool settings', (tester) async {
    await mountApp(tester, 'test.toolbox-speed-sheet-0', settings: {'speedTestMode': 0});
    await openToolbox(tester);

    await openToolSettings(tester);
    expect(find.text('Simple download URL'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('the lookup provider options skip the ones the probe set cannot honour', () {
    expect(exitLookupProviders, contains('auto'));
    expect(exitLookupProviders, isNot(contains('ip2location')));
    expect(exitLookupProviders, isNot(contains('cloudflare')));
    expect(exitLookupProviderName('ip-api'), 'Lookup provider cleartext');
    expect(exitLookupProviderName('ipwho'), 'ipwho');
  });

  testWidgets('the traffic settings sheet toggles write through the store', (tester) async {
    await mountApp(tester, 'test.toolbox-traffic-sheet');
    addTearDown(() => TrafficStatsStore.instance.setEnabled(false));
    final store = TrafficStatsStore.instance;
    expect(store.enabled, isFalse);
    await openToolbox(tester);
    await tester.tap(find.text('Tool settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Traffic statistics settings').last);
    await tester.pumpAndSettle();

    // Detail recording is off the table until recording itself is on.
    await tester.tap(find.text('Record details'));
    await tester.pumpAndSettle();
    expect(store.details, isTrue);

    await tester.tap(find.text('Enable traffic statistics'));
    await tester.pumpAndSettle();
    expect(store.enabled, isTrue);

    await tester.tap(find.text('Record details'));
    await tester.pumpAndSettle();
    expect(store.details, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a toolbox glyph eases to the entry colour while pressed', (tester) async {
    await mountApp(tester, 'test.toolbox-press');
    await openToolbox(tester);

    // Each card draws the same glyph twice: the bare foreground icon and the
    // oversized background watermark mapped from it. Sizes tell them apart.
    GlyphIcon glyphOf(Glyph glyph) => tester.widget<GlyphIcon>(find.byWidgetPredicate(
        (widget) => widget is GlyphIcon && widget.glyph == glyph && (widget.size ?? 0) < 40));
    GlyphIcon watermarkOf(Glyph glyph) => tester.widget<GlyphIcon>(find.byWidgetPredicate(
        (widget) => widget is GlyphIcon && widget.glyph == glyph && (widget.size ?? 0) >= 40));

    final scheme = Theme.of(tester.element(find.byType(NetworkToolboxPage))).colorScheme;
    final idle = scheme.onSurfaceVariant;
    final accent = ToolColors.blue.resolve(Brightness.light);
    final idleWatermark = accent.withValues(alpha: 0.10);
    final pressedWatermark = accent.withValues(alpha: 0.24);
    Color? titleColor() => tester.widget<Text>(find.text('Speed test')).style?.color;

    expect(glyphOf(AppGlyphs.speed).color, idle);
    expect(watermarkOf(AppGlyphs.speed).color, idleWatermark,
        reason: 'the background icon is mapped from the tool glyph');
    expect(titleColor(), scheme.onSurface);

    // Press inside the wide speed-test card and hold: the foreground glyph, the
    // watermark and the title all ease to the entry's colour (Bettbox's 180 ms
    // transition), not just a box behind them.
    final gesture = await tester.startGesture(
        tester.getCenter(find.text('Measure download, upload speed and latency')));
    // One frame starts the 180 ms tween at its begin value; the next advances it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(glyphOf(AppGlyphs.speed).color, accent,
        reason: 'the pressed glyph wears the entry colour');
    expect(watermarkOf(AppGlyphs.speed).color, pressedWatermark,
        reason: 'the background icon deepens with the press');
    expect(titleColor(), accent, reason: 'the title wears the entry colour too');

    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(glyphOf(AppGlyphs.speed).color, idle, reason: 'releasing restores the idle tone');
    expect(watermarkOf(AppGlyphs.speed).color, idleWatermark);
    expect(titleColor(), scheme.onSurface);
    expect(tester.takeException(), isNull);
  });
}
