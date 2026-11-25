// Build-counter proof that the narrow box providers isolate rebuilds from the
// 1 Hz traffic tick.
//
// `ConnectionsPanel` used to watch `dashboardProvider`, which re-evaluates on
// every aspect notification and returns a *new* map on every dashboard push
// (`box.dart` replaces `dashboard` wholesale). The panel renders only two
// scalars from that map, so a rate-only tick rebuilt it once a second for
// nothing. It now watches `connectionSummaryProvider`, a structural record of
// just those two scalars.
//
// This test mounts the two consumers as siblings over one injected controller
// and counts their own builds. A traffic-only dashboard update (status and
// connections unchanged, rates moved) must rebuild the broad consumer but NOT
// the narrow one. A real connection-count change must rebuild both, proving
// the narrow provider still delivers the update it exists for.

import 'dart:async';

import 'package:flrone/box.dart';
import 'package:flrone/providers/box_providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';

/// The old shape: watch the whole dashboard map, like `ConnectionsPanel` did.
/// Counts its *own* builds — a `ConsumerWidget` rebuilds itself in place, so a
/// counter in a parent wrapper would never see the provider-driven rebuild.
class _BroadDashboardConsumer extends ConsumerWidget {
  const _BroadDashboardConsumer({required this.stats});
  final Map<String, int> stats;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    stats['broad'] = (stats['broad'] ?? 0) + 1;
    final dash = ref.watch(dashboardProvider);
    return Text('broad:${dash['connections']}', textDirection: TextDirection.ltr);
  }
}

/// The new shape: watch only the two scalars the card renders.
class _NarrowSummaryConsumer extends ConsumerWidget {
  const _NarrowSummaryConsumer({required this.stats});
  final Map<String, int> stats;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    stats['narrow'] = (stats['narrow'] ?? 0) + 1;
    final summary = ref.watch(connectionSummaryProvider);
    return Text('narrow:${summary.count}/${summary.started}', textDirection: TextDirection.ltr);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<BoxController> makeBox() async {
    final events = StreamController<dynamic>.broadcast();
    addTearDown(events.close);
    const channel = MethodChannel('test.rebuild-isolation');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready'
        ? {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': 'Stopped', 'connections': 0},
          }
        : null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
    addTearDown(box.dispose);
    await box.initialize();
    return box;
  }

  Widget frame(BoxController box, Map<String, int> stats) => ProviderScope(
        overrides: [boxControllerProvider.overrideWithValue(box)],
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Column(children: [
            _BroadDashboardConsumer(stats: stats),
            _NarrowSummaryConsumer(stats: stats),
          ]),
        ),
      );

  testWidgets('a traffic-only tick rebuilds the broad consumer but not the narrow one', (tester) async {
    reportFlutterErrors();
    final box = await makeBox();
    final stats = <String, int>{};

    await tester.pumpWidget(frame(box, stats));
    expect(stats['broad'], 1);
    expect(stats['narrow'], 1);
    expect(find.text('broad:0'), findsOneWidget);
    expect(find.text('narrow:0/false'), findsOneWidget);

    // A 1 Hz traffic push: rates moved, but the two scalars the card reads did
    // not. `dashboard` is replaced wholesale, so the broad watcher rebuilds.
    box.handleEvent({
      'type': 'dashboard',
      'value': {
        'status': 'Stopped',
        'connections': 0,
        'rates': {'upload': 1024, 'download': 2048},
      },
    });
    await tester.pump();

    expect(stats['broad'], 2, reason: 'watching the whole map must see the tick');
    expect(stats['narrow'], 1,
        reason: 'the structural record is unchanged, so the card must not rebuild');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a real connection-count change still rebuilds the narrow consumer', (tester) async {
    reportFlutterErrors();
    final box = await makeBox();
    final stats = <String, int>{};

    await tester.pumpWidget(frame(box, stats));

    box.handleEvent({
      'type': 'dashboard',
      'value': {'status': 'Started', 'connections': 3},
    });
    await tester.pump();

    expect(stats['broad'], 2);
    expect(stats['narrow'], 2, reason: 'a real value change must reach the card');
    expect(find.text('narrow:3/true'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
