// ADR 0005 phase 3 acceptance: the route list and the current-route selection
// live on the action bus (Go is the sole document writer), and switching the
// current route must be followed by a config build that reads the new set.
// With no FFI driver the error must be visible, never a stale channel answer.
//
// The fake kernel stands in for the Go dispatcher; the fake method channel
// stands in for the host's `state.setCurrentRoute` / `config.build` arms.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/box.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_route_kernel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('route list and current route come from the action bus', (tester) async {
    const channel = MethodChannel('test.routes-bus');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final hostCalls = <String>[];
    int hostSelected = 0;

    messenger.setMockMethodCallHandler(channel, (call) async {
      hostCalls.add(call.method);
      switch (call.method) {
        case 'ready':
          return {
            'version': 'test',
            'coreVersion': 'test',
            'preferences': {'locale': 'en'},
            'dashboard': {'status': 'Stopped'},
          };
        case 'data.documents':
          // The one-time Room -> JSON seed still runs on attach (ADR 0002
          // phase 3c upgrade path); it is not a route read.
          return {'seeded': true};
        case 'state.setCurrentRoute':
          hostSelected = ((call.arguments as Map?)?['id'] as num?)?.toInt() ?? 0;
          return {'id': hostSelected};
        case 'config.build':
          // The host resolves the selected route itself; no id is sent.
          expect(((call.arguments as Map?) ?? const {})['id'], isNull);
          return {'coreConfig': '{}'};
        case 'service.reload':
          return null;
        default:
          return null;
      }
    });

    final busCalls = <ActionMethod>[];
    Map<String, Object?> currentWire() => {
          'currentId': hostSelected == 0 ? 1 : hostSelected,
          'profiles': [
            {'id': 1, 'name': 'Default', 'current': hostSelected == 0},
            {'id': 2, 'name': 'Alternate', 'current': hostSelected == 2},
          ],
        };

    final box = BoxController(channel: channel, events: Stream<dynamic>.empty());
    addTearDown(box.dispose);
    box.debugAttach(
      FakeRouteKernel((method, data) {
        busCalls.add(method);
        switch (method) {
          case ActionMethod.getRouteProfiles:
            return currentWire();
          case ActionMethod.setCurrentRoute:
            // The bare Go action only moves the document marker; a UI tap goes
            // through the host pair instead, so this must not be reached.
            fail('the bare setCurrentRoute action must not be used by the UI');
          default:
            return null;
        }
      }),
      NoopKernelWorker(),
    );

    // The bus answers the list; no routes.list channel arm is consulted.
    final list = await box.routeList();
    expect(busCalls, contains(ActionMethod.getRouteProfiles));
    expect(hostCalls, isNot(contains('routes.list')));
    expect((list as Map)['profiles'], hasLength(2));

    // A UI selection takes the host path, then a config build reads the new set.
    await box.routeSetCurrentHost(2);
    expect(hostSelected, 2, reason: 'the host writes the settings row the build reads');
    await box.call('config.build');
    expect(hostCalls, contains('config.build'));
    expect(hostCalls, contains('state.setCurrentRoute'));
    expect(busCalls, isNot(contains(ActionMethod.setCurrentRoute)),
        reason: 'the bare action would leave the authoritative Room row stale');
  });

  test('no FFI driver: routeList surfaces a clear error, never a channel fallback', () async {
    const channel = MethodChannel('test.routes-noffi');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'routes.list') {
        fail('routes.list channel fallback must be gone');
      }
      return null;
    });

    final box = BoxController(channel: channel, events: Stream<dynamic>.empty());
    addTearDown(box.dispose);
    // No debugAttach: kernel.attached is null, so the bus call must throw.

    expect(
      () => box.routeList(),
      throwsA(isA<StateError>().having(
        (error) => error.toString(),
        'message',
        contains('FFI driver'),
      )),
    );
    expect(calls, isNot(contains('routes.list')));
  });
}
