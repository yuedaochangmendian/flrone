// The profile editor's platform duty boundary (ADR 0005 final stage).
//
// Every Kotlin-only profile operation — parsing, validation, the subscription
// queue, the selection settings, the auto-selector runtime — goes through ONE
// channel method, `profiles.platform` with `{op, payload}`. The old per-operation
// channel arms and the Go action-bus arms are gone; these tests pin the shape,
// the single path (an attached kernel is never consulted) and profileStats'
// cache semantics.

import 'package:flrone/box.dart';
import 'package:flrone/core/action.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_route_kernel.dart';
import 'support/profile_duty.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'test.profile-duty';
  const channel = MethodChannel(channelName);

  late List<MethodCall> calls;
  late Future<dynamic> Function(MethodCall call) reply;

  setUp(() {
    calls = <MethodCall>[];
    reply = (call) async => <String, dynamic>{'source': 'channel', 'op': dutyOp(call)};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// A box with a kernel attached; [handler] answers (or throws for) each action.
  BoxController withKernel(Object? Function(ActionMethod method, Object? data) handler) {
    final box = BoxController(channel: channel);
    box.debugAttach(FakeRouteKernel(handler), NoopKernelWorker());
    addTearDown(box.dispose);
    return box;
  }

  test('node reads travel as ops with the id payload', () async {
    final box = BoxController(channel: channel);
    addTearDown(box.dispose);

    final config = json(await box.nodeConfig(70));
    final tuning = json(await box.nodeTuningInfo(70));

    expect(config['op'], 'nodeConfig');
    expect(tuning['op'], 'nodeTuningInfo');
    expect(calls.map(dutyOp), ['nodeConfig', 'nodeTuningInfo']);
    expect(calls.map(dutyPayload), [
      {'id': 70},
      {'id': 70},
    ]);
  });

  test('an attached kernel is never consulted: the read path stays single', () async {
    var actions = 0;
    final box = withKernel((method, data) {
      actions++;
      return <String, dynamic>{'source': 'kernel'};
    });

    final config = json(await box.nodeConfig(70));

    expect(config['source'], 'channel');
    expect(actions, 0,
        reason: 'the Go profile actions were deleted with the Room authority');
    expect(dutyOp(calls.single), 'nodeConfig');
  });

  test('a channel failure is surfaced, not swallowed into an empty answer', () async {
    reply = (call) async =>
        throw PlatformException(code: 'no_profile', message: 'no proxy with id 70');
    final box = BoxController(channel: channel);
    addTearDown(box.dispose);

    await expectLater(
      box.nodeConfig(70),
      throwsA(isA<PlatformException>()),
    );
    expect(calls.map(dutyOp), ['nodeConfig']);
  });

  test('writes take one path and surface their failure', () async {
    reply = (call) async =>
        throw PlatformException(code: 'write_failed', message: 'the row is locked');
    final box = BoxController(channel: channel);
    addTearDown(box.dispose);

    await expectLater(
      box.nodeTuningSave(70, {'muxState': 1}),
      throwsA(isA<PlatformException>()),
    );
    expect(calls.map(dutyOp), ['nodeTuningSave']);
    expect(dutyPayload(calls.single), {
      'id': 70,
      'value': {'muxState': 1},
    });
  });

  // profileStats caches its future, and only a 'profiles' event clears that
  // cache: a cached failure therefore has to be evicted, or the dashboard card
  // keeps painting '—' with no error branch to show.
  group('profileStats', () {
    test('reads through the duty and caches the reply', () async {
      final box = BoxController(channel: channel);
      addTearDown(box.dispose);

      expect(await box.profileStats(7), {'source': 'channel', 'op': 'stats'});
      await box.profileStats(7);

      expect(calls.map(dutyOp), ['stats']);
      expect(dutyPayload(calls.single), {'id': 7});
    });

    test('a failure is evicted so the next read retries', () async {
      var fail = true;
      reply = (call) async => fail
          ? throw PlatformException(code: 'no_database', message: 'unable to open database file')
          : <String, dynamic>{'source': 'channel', 'op': dutyOp(call)};
      final box = BoxController(channel: channel);
      addTearDown(box.dispose);

      await expectLater(box.profileStats(7), throwsA(isA<PlatformException>()));
      fail = false;
      expect((await box.profileStats(7))['op'], 'stats');
      expect(calls.map(dutyOp), ['stats', 'stats'],
          reason: 'a buried failure would answer every retry with the same stale error');
    });
  });
}
