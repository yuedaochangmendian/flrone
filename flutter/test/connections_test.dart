import 'dart:async';
import 'package:flrone/components/record.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flrone/pages/connections.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// One mounted connections page with a unique channel; records every channel call so tests can
/// assert the process lookup is per-path and cached, and can feed in `apps.process` replies.
class _Harness {
  final MethodChannel channel;
  final StreamController<dynamic> events;
  final List<MethodCall> calls = [];
  final Map<String, dynamic> processReplies = {};
  Json stateReply = const {};
  ({bool changed, Json state})? enableReply;
  _Harness._(this.channel, this.events);

  static Future<_Harness> mount(
    WidgetTester tester, {
    String name = 'test.connections.info',
    Json state = const {},
    ({bool changed, Json state})? enable,
  }) async {
    final events = StreamController<dynamic>.broadcast();
    final channel = MethodChannel(name);
    final harness = _Harness._(channel, events);
    harness.stateReply = state;
    harness.enableReply = enable;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      harness.calls.add(call);
      if (call.method == 'ready') {
        return {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Started'}};
      }
      if (call.method == 'apps.process') {
        return harness.processReplies[(call.arguments as Map)['path']];
      }
      if (call.method == 'connections.state') return harness.stateReply;
      if (call.method == 'connections.enableApi') {
        final reply = harness.enableReply ?? (changed: false, state: harness.stateReply);
        return {'changed': reply.changed, 'state': reply.state};
      }
      return null;
    });
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(360, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const ConnectionsPage());
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });
    return harness;
  }

  Future<void> push(WidgetTester tester, List<dynamic> rows) async {
    events.add({'type': 'connections', 'value': rows});
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
  }
}

Json _row(Object id, {
  String processPath = '', String protocol = '', int closedAt = 0,
  int createdAt = 1700000000000, String rule = 'geosite', String outbound = 'proxy',
  String destination = 'example.com', String reason = '',
}) => {
  'id': id, 'createdAt': createdAt, 'closedAt': closedAt,
  'network': 'tcp', 'protocol': protocol,
  'destination': '1.2.3.4:443', 'displayDestination': destination,
  'outbound': outbound, 'rule': rule, 'source': '10.0.0.2:5',
  'chain': [outbound],
  'upload': 0, 'download': 0, 'uploadTotal': 0, 'downloadTotal': 0,
  if (processPath.isNotEmpty) 'process': {'path': processPath},
  if (reason.isNotEmpty) 'error': reason,
};

/// The Requests page's status selector labels as rendered (`All N`, `Active N`, `Failed N`).
String _statusLabel(WidgetTester tester, String base) {
  final segments = tester.widgetList<SegmentedControl<RequestStatus>>(
    find.byType(SegmentedControl<RequestStatus>),
  ).single;
  final match = segments.segments.where((s) => s.$2.startsWith(base)).toList();
  return match.single.$2;
}

const _apk = '/data/app/~~AbC/com.example.app-XyZ/base.apk';

/// A real 1x1 PNG: Image.memory decodes during pump, so a truncated header throws.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x04, 0x00, 0x00, 0x00, 0xb5, 0x1c, 0x0c, 0x02, 0x00, 0x00, 0x00,
  0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xfc, 0xff, 0x1f, 0x00,
  0x03, 0x03, 0x02, 0x00, 0xef, 0xbf, 0x97, 0xd9, 0x00, 0x00, 0x00, 0x00,
  0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]);

void main() {
  testWidgets('connection subscriptions are released when their page closes', (tester) async {
    final visibility = <bool>[];
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.connections');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'connections.visible') visibility.add((call.arguments as Map)['visible'] == true);
      return call.method == 'ready' ? {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Started'}} : null;
    });
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(HomePage));
    openPage(context, const ConnectionsPage());
    await tester.pumpAndSettle();
    expect(visibility, [true]);
    final pageContext = tester.element(find.byType(ConnectionsPage));
    pageContext.safeNestedPop();
    await tester.pumpAndSettle();
    await tester.pump();
    expect(find.byType(ConnectionsPage), findsNothing);
    expect(visibility, [true, false]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  /// Every `connections.visible` the page asked for, in order and with its whole argument map
  /// (`pause` included), because the mode is the point of the activity gate.
  List<Json> feed(List<MethodCall> calls) => [
    for (final call in calls)
      if (call.method == 'connections.visible') json(call.arguments),
  ];

  /// Android's own sequence: the framework asserts it, and the shell's AppLifecycleListener
  /// rejects a direct paused → resumed jump.
  void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  testWidgets('the connections feed follows the app lifecycle', (tester) async {
    final h = await _Harness.mount(tester);
    addTearDown(() => lifecycle(tester, const [
      AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed,
    ]));
    expect(feed(h.calls), [{'visible': true}]);
    // Backgrounded: the full feed parks (the rows it emitted stay) instead of sampling every
    // 1.5 s behind a hidden app. The host's cheap count poll is visibility-gated on its own.
    lifecycle(tester, const [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);
    await tester.pump();
    expect(feed(h.calls).last, {'visible': false, 'pause': true});
    lifecycle(tester, const [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);
    await tester.pump();
    expect(feed(h.calls).last, {'visible': true});
    expect(tester.takeException(), isNull);
  });

  testWidgets('a route over the connections page parks the feed and resumes it on return', (tester) async {
    final h = await _Harness.mount(tester);
    await h.push(tester, [_row(1)]);
    expect(feed(h.calls).last, {'visible': true});
    final page = tester.element(find.byType(ConnectionsPage));
    unawaited(openPage(page, ConnectionDetail(initial: _row(1))));
    await tester.pumpAndSettle();
    // The page is covered: the feed stops but the host's rows are kept, so the list behind
    // the detail page is not blanked for a tick.
    expect(feed(h.calls).last, {'visible': false, 'pause': true});
    expect(find.byType(RecordListItem, skipOffstage: false), findsOneWidget);
    tester.element(find.byType(ConnectionDetail)).safeNestedPop();
    await tester.pumpAndSettle();
    // One full reload on return; the sampler's first sample is the whole page.
    expect(feed(h.calls).last, {'visible': true});
    page.safeNestedPop();
    await tester.pumpAndSettle();
    await tester.pump();
    // Closing the page still asks for the clearing mode, as before.
    expect(feed(h.calls).last, {'visible': false});
    expect(tester.takeException(), isNull);
  });

  testWidgets('a keyword chip does not leave a blank band above the list', (tester) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(360, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.connections.band');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready'
        ? {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Started'}}
        : null);
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const ConnectionsPage());
    await tester.pumpAndSettle();
    events.add({
      'type': 'connections',
      'value': [
        {
          'id': 1, 'createdAt': 1700000000000, 'network': 'tcp', 'destination': 'example.com:443',
          'outbound': 'proxy', 'rule': 'geosite', 'source': '10.0.0.2:5',
          'upload': 0, 'download': 0, 'uploadTotal': 0, 'downloadTotal': 0,
        },
      ],
    });
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    ListView verticalList() => tester.widgetList<ListView>(find.byType(ListView))
        .firstWhere((view) => view.scrollDirection == Axis.vertical);
    // Without a chip the body runs under the floating bar, so the list carries its height.
    expect((verticalList().padding! as EdgeInsets).top, greaterThan(0));
    tester.widget<RecordLabel>(find.widgetWithText(RecordLabel, 'TCP')).onPressed!();
    await tester.pumpAndSettle();
    // The strip now holds the bar's place, so the list must not add that gap again.
    expect((verticalList().padding! as EdgeInsets).top, 0);
    final listRect = tester.getRect(find.byWidget(verticalList()));
    final itemRect = tester.getRect(find.byType(RecordListItem).first);
    // The status selector is a fixed strip above the list (34dp) and a minute header
    // precedes the record. What must NOT appear is the old double-counted app-bar
    // band: the record stays close to the top of a filtered, short list.
    expect(itemRect.top - listRect.top, lessThan(80));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('resolves the process path into an app label, icon and tap-to-filter chip', (tester) async {
    final h = await _Harness.mount(tester);
    h.processReplies[_apk] = {
      'package': 'com.example.app', 'label': 'Example App', 'icon': _png,
    };
    await h.push(tester, [_row(1, processPath: _apk, protocol: 'TLS')]);
    expect(find.text('Example App'), findsOneWidget);
    // Protocol is filterable alongside the network label.
    expect(find.widgetWithText(RecordLabel, 'TLS'), findsOneWidget);

    final lookups = h.calls.where((call) => call.method == 'apps.process').toList();
    expect(lookups.length, 1);
    expect((lookups.first.arguments as Map)['path'], _apk);
    // A rebuild must not re-ask: the Future is cached per distinct path.
    await tester.pump();
    expect(h.calls.where((call) => call.method == 'apps.process').length, 1);

    // Tapping the label adds a keyword chip keyed by the package, labelled by the app name.
    await tester.tap(find.text('Example App'));
    await tester.pumpAndSettle();
    expect(find.text('Example App'), findsWidgets); // chip label + row label
    expect(find.widgetWithText(RecordLabel, 'TLS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unresolvable process falls back to the source line', (tester) async {
    final h = await _Harness.mount(tester, name: 'test.connections.fallback');
    await h.push(tester, [_row(2, processPath: '/data/local/tmp/tool')]);
    // The raw path is not an app name: keep the old source line instead of printing it.
    expect(find.text('/data/local/tmp/tool'), findsNothing);
    expect(find.text('10.0.0.2:5'), findsOneWidget);
    expect(h.calls.where((call) => call.method == 'apps.process').length, 1);
    // No chip is added by tapping the line (the host could not resolve a package).
    await tester.tap(find.text('10.0.0.2:5'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Active/Closed/All menu labels carry derived counts', (tester) async {
    final h = await _Harness.mount(tester, name: 'test.connections.counts');
    await h.push(tester, [
      _row(1), _row(2), _row(3, closedAt: 1700000001000),
    ]);
    final scaffold = tester.widget<Scaffold>(
      find.descendant(of: find.byType(ConnectionsPage), matching: find.byType(Scaffold)).first,
    );
    final labels = scaffold.menuItems.map((item) => item.label).toList();
    expect(labels, contains('Active 2'));
    expect(labels, contains('Closed 1'));
    expect(labels, contains('All 3'));
  });

  testWidgets('connection detail groups rows into Overview/Route/Process/Traffic sections', (tester) async {
    final h = await _Harness.mount(tester, name: 'test.connections.detail');
    await h.push(tester, [_row(4, processPath: _apk)]);
    await tester.tap(find.byType(RecordListItem).first);
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionDetail), findsOneWidget);
    // Section headers are ListHeaders; "Process" also names a DetailRow title inside its section.
    for (final section in ['Overview', 'Route', 'Process', 'Traffic']) {
      expect(find.descendant(of: find.byType(ListHeader), matching: find.text(section)), findsOneWidget);
    }
    // The original rows are still present under their sections (DetailRow titles).
    expect(find.descendant(of: find.byType(DetailRow), matching: find.text('Destination')), findsOneWidget);
    expect(find.descendant(of: find.byType(DetailRow), matching: find.text('Upload')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty list names a tunnel that is not running', (tester) async {
    await _Harness.mount(tester, name: 'test.connections.idle', state: {'running': false});
    expect(find.text('Tunnel is not running'), findsOneWidget);
    expect(find.text('Start the tunnel to see connections'), findsOneWidget);
  });

  testWidgets('an empty list with the Clash API off offers the one-tap enable', (tester) async {
    await _Harness.mount(tester, name: 'test.connections.api-off', state: {
      'running': true, 'apiEnabled': false, 'reachable': false, 'port': 9090, 'address': '127.0.0.1',
    });
    expect(find.text('Connection list is off'), findsOneWidget);
    expect(find.text('Enable'), findsOneWidget);
  });

  testWidgets('enabling the API asks for the core reload', (tester) async {
    final h = await _Harness.mount(tester, name: 'test.connections.api-enable', state: {
      'running': true, 'apiEnabled': false, 'reachable': false, 'port': 9090, 'address': '127.0.0.1',
    }, enable: (changed: true, state: {
      'running': true, 'apiEnabled': true, 'reachable': false, 'port': 9090, 'address': '127.0.0.1',
    }));
    await tester.tap(find.text('Enable'));
    await tester.pumpAndSettle();
    expect(h.calls.where((call) => call.method == 'connections.enableApi'), hasLength(1));
    expect(find.text('Restart the core to apply?'), findsOneWidget);
    // The dialog is declined here: the test asserts the ask, not the reload side effect.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Clash API is not answering'), findsOneWidget);
  });

  testWidgets('an enabled but unreachable API shows the address and retries', (tester) async {
    await _Harness.mount(tester, name: 'test.connections.api-dead', state: {
      'running': true, 'apiEnabled': true, 'reachable': false,
      'port': 9090, 'address': '127.0.0.1', 'error': 'HTTP 404',
    });
    expect(find.text('Clash API is not answering'), findsOneWidget);
    expect(find.textContaining('127.0.0.1:9090'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    // A config generated before the port was written needs a reload, not just a re-probe.
    expect(find.text('Reload'), findsOneWidget);
  });

  // ---- Requests redesign (v0.9.5 milestone 1) ------------------------------------------

  /// The minute header text for a given epoch-ms, as rendered on a bucket header.
  String minuteLabel(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  testWidgets('page is titled Requests and keeps the ConnectionsPage route', (tester) async {
    await _Harness.mount(tester, name: 'test.requests.title');
    expect(find.text('Requests'), findsWidgets);
    // The typedef keeps the old class name usable and pointing at the same type.
    expect(const RequestsPage(), isA<ConnectionsPage>());
  });

  testWidgets('requests are grouped into minute buckets, newest first', (tester) async {
    final h = await _Harness.mount(tester, name: 'test.requests.grouping');
    final older = 1700000000000;          // one minute boundary
    final newer = older + 60000;          // next minute
    await h.push(tester, [
      _row(1, createdAt: older, destination: 'old.example'),
      _row(2, createdAt: newer, destination: 'new.example'),
      _row(3, createdAt: newer + 5000, destination: 'new2.example'),
    ]);
    // The route and its buckets both use local time; read the rendered headers.
    final headers = find.text(minuteLabel(newer));
    expect(headers, findsOneWidget, reason: 'newest minute header missing');
    expect(find.text(minuteLabel(older)), findsOneWidget);
    // Newer bucket (2 rows) is above older bucket (1 row) in the header list.
    final newerHeader = tester.getRect(headers.first);
    final olderHeader = tester.getRect(find.text(minuteLabel(older)).first);
    expect(newerHeader.top, lessThan(olderHeader.top));
    // Compact counts: the newer bucket shows 2, older shows 1 (both next to a time).
    expect(find.text('2'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('status selector counts and filters All / Active / Failed', (tester) async {
    final h = await _Harness.mount(tester, name: 'test.requests.status');
    await h.push(tester, [
      _row(1, destination: 'live.example'),
      _row(2, destination: 'closed.example', closedAt: 1700000001000),
      _row(3, destination: 'rejected.example', closedAt: 1700000001000, rule: 'reject'),
    ]);
    // All 3, Active 1, Failed 2 (both closed rows, one with an explicit reason).
    expect(_statusLabel(tester, 'All'), 'All 3');
    expect(_statusLabel(tester, 'Active'), 'Active 1');
    expect(_statusLabel(tester, 'Failed'), 'Failed 2');
    expect(find.byType(RecordListItem), findsNWidgets(3));

    // Failed: only closed rows, their reason rendered on the card.
    final control = tester.widget<SegmentedControl<RequestStatus>>(
      find.byType(SegmentedControl<RequestStatus>),
    );
    control.onChanged(RequestStatus.failed);
    await tester.pumpAndSettle();
    expect(find.byType(RecordListItem), findsNWidgets(2));
    expect(find.text('live.example'), findsNothing);
    expect(find.text('rejected.example'), findsOneWidget);

    // Active: only the still-open row.
    tester.widget<SegmentedControl<RequestStatus>>(
      find.byType(SegmentedControl<RequestStatus>),
    ).onChanged(RequestStatus.active);
    await tester.pumpAndSettle();
    expect(find.byType(RecordListItem), findsOneWidget);
    expect(find.text('live.example'), findsOneWidget);

    // Back to All.
    tester.widget<SegmentedControl<RequestStatus>>(
      find.byType(SegmentedControl<RequestStatus>),
    ).onChanged(RequestStatus.all);
    await tester.pumpAndSettle();
    expect(find.byType(RecordListItem), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('search combines with the status filter', (tester) async {
    final h = await _Harness.mount(tester, name: 'test.requests.search-filter');
    await h.push(tester, [
      _row(1, destination: 'example.com', rule: 'geosite'),
      _row(2, destination: 'example.com', closedAt: 1700000001000, rule: 'reject'),
      _row(3, destination: 'other.net', closedAt: 1700000001000, rule: 'geosite'),
    ]);
    // Select Failed: two closed rows remain.
    tester.widget<SegmentedControl<RequestStatus>>(
      find.byType(SegmentedControl<RequestStatus>),
    ).onChanged(RequestStatus.failed);
    await tester.pumpAndSettle();
    expect(find.byType(RecordListItem), findsNWidgets(2));
    // Now search: counts and rows reflect search+status together.
    tester.widget<Scaffold>(
      find.descendant(of: find.byType(ConnectionsPage), matching: find.byType(Scaffold)).first,
    ).searchState!.onSearch('other');
    await tester.pumpAndSettle();
    expect(_statusLabel(tester, 'Failed'), 'Failed 1');
    expect(find.text('other.net'), findsOneWidget);
    expect(find.text('example.com'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed rows render the reason supplied by the payload', (tester) async {
    final h = await _Harness.mount(tester, name: 'test.requests.reason');
    await h.push(tester, [
      _row(1, closedAt: 1700000001000, destination: 'boom.example', reason: 'dial tcp: timeout'),
      _row(2, closedAt: 1700000001000, destination: 'drop.example', rule: 'reject'),
    ]);
    // Explicit error key is shown on the card; a reject rule is a reason too.
    expect(find.text('dial tcp: timeout'), findsOneWidget);
    expect(find.text('reject'), findsWidgets);
    // And the reason reaches the detail page.
    await tester.tap(find.text('boom.example'));
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionDetail), findsOneWidget);
    expect(find.descendant(of: find.byType(ListHeader), matching: find.text('Failure')), findsOneWidget);
    expect(find.descendant(of: find.byType(DetailRow), matching: find.text('dial tcp: timeout')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a healthy but empty feed distinguishes no requests / no active / no failed', (tester) async {
    await _Harness.mount(tester, name: 'test.requests.empty', state: {
      'running': true, 'apiEnabled': true, 'reachable': true, 'port': 9090, 'address': '127.0.0.1',
    });
    expect(find.text('No requests yet'), findsOneWidget);
    final control = tester.widget<SegmentedControl<RequestStatus>>(
      find.byType(SegmentedControl<RequestStatus>),
    );
    control.onChanged(RequestStatus.failed);
    await tester.pumpAndSettle();
    expect(find.text('No failed requests'), findsOneWidget);
    control.onChanged(RequestStatus.active);
    await tester.pumpAndSettle();
    expect(find.text('No active requests'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a search miss shows the no-results state, not "no requests yet"', (tester) async {
    final h = await _Harness.mount(tester, name: 'test.requests.no-match', state: {
      'running': true, 'apiEnabled': true, 'reachable': true, 'port': 9090, 'address': '127.0.0.1',
    });
    await h.push(tester, [_row(1, destination: 'match.example')]);
    tester.widget<Scaffold>(
      find.descendant(of: find.byType(ConnectionsPage), matching: find.byType(Scaffold)).first,
    ).searchState!.onSearch('zzzz-no-match');
    await tester.pumpAndSettle();
    expect(find.text('No search results'), findsOneWidget);
    expect(find.text('No requests yet'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
