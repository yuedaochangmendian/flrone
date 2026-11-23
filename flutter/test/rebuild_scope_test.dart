import 'dart:async';

import 'package:flrone/box.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('one log batch rebuilds the list once, not once per row', (tester) async {
    const channel = MethodChannel('test.rebuild-scope');
    final events = StreamController<dynamic>.broadcast();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready'
        ? {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}}
        : null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
    await box.initialize();

    var builds = 0;
    await tester.pumpWidget(BoxScope(
      controller: box,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (context) {
          builds++;
          final logs = BoxScope.of(context, aspect: BoxAspect.logs).logs;
          return Text('${logs.length}', textDirection: TextDirection.ltr);
        }),
      ),
    ));
    expect(builds, 1);
    expect(find.text('0'), findsOneWidget);

    Json line(int id) => {'id': id, 'level': 'info', 'message': 'INFO[0000] core: line $id'};
    for (var id = 1; id <= 3; id++) {
      box.handleEvent({
        'type': 'logs',
        'value': {'reset': false, 'firstId': 1, 'entries': [line(id)]},
      });
    }
    // Reads are current immediately — the batched rebuild only delays the frame.
    expect(box.logs, hasLength(3));
    await tester.pump();
    expect(builds, 1, reason: 'the batch window holds the rebuild');

    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
    expect(builds, 2, reason: 'three events in one window are one rebuild, not three');
    expect(find.text('3'), findsOneWidget);

    // The snapshot identity the reader caches moves exactly once per batch, so a derived
    // row cache (`pages/logs.dart`) re-runs once too.
    final snapshot = box.logs;
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
    expect(identical(box.logs, snapshot), isTrue);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    box.dispose();
    await events.close();
  });
}
