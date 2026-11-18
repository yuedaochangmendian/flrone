// The node editor reads (config, tuning) go through the FFI action bus when the
// kernel is attached: Go opens the Room database itself, so a missing file, a
// WAL lock or a decode defect fails the read where the channel would have
// answered. These tests pin the fallback to the channel for the two pure reads,
// and that a kernel answer is used as-is (no unnecessary second round trip) and
// that writes stay fail-fast — a write re-applied through a second path would
// apply twice.

import 'package:flrone/box.dart';
import 'package:flrone/core/action.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_route_kernel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'test.node-editor-fallback';
  const channel = MethodChannel(channelName);

  late List<MethodCall> calls;
  late Future<dynamic> Function(MethodCall call) reply;

  setUp(() {
    calls = <MethodCall>[];
    reply = (call) async => <String, dynamic>{'source': 'channel', 'method': call.method};
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

  Object? refuseConfig(ActionMethod method, Object? data) {
    if (method == ActionMethod.profileNodeConfig) {
      throw const ActionException('profileNodeConfig', 'no proxy with id 70');
    }
    return null;
  }

  Object? refuseTuning(ActionMethod method, Object? data) {
    if (method == ActionMethod.profileNodeTuningInfo) {
      throw const ActionException('profileNodeTuningInfo', 'no proxy with id 70');
    }
    return null;
  }

  group('a kernel read that fails', () {
    test('node config falls back to the channel arm', () async {
      final box = withKernel(refuseConfig);

      final config = json(await box.profileNodeConfig(70));

      expect(calls.map((call) => call.method), ['profiles.nodeConfig']);
      expect(calls.single.arguments, {'id': 70});
      expect(config['source'], 'channel');
    });

    test('node tuning info falls back to the channel arm', () async {
      final box = withKernel(refuseTuning);

      final tuning = json(await box.profileNodeTuningInfo(70));

      expect(calls.map((call) => call.method), ['profiles.nodeTuningInfo']);
      expect(tuning['source'], 'channel');
    });

    test('a channel failure is surfaced, not swallowed into an empty answer', () async {
      reply = (call) async =>
          throw PlatformException(code: 'no_profile', message: 'no proxy with id 70');
      final box = withKernel(refuseConfig);

      await expectLater(
        box.profileNodeConfig(70),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.map((call) => call.method), ['profiles.nodeConfig']);
    });
  });

  group('a kernel read that answers', () {
    test('node config uses the kernel reply and does not call the channel', () async {
      final box = withKernel(
        (method, data) => <String, dynamic>{'source': 'kernel', 'method': method.name},
      );

      final config = json(await box.profileNodeConfig(70));

      expect(config['source'], 'kernel');
      expect(calls, isEmpty);
    });

    test('node tuning info uses the kernel reply and does not call the channel', () async {
      final box = withKernel(
        (method, data) => <String, dynamic>{'source': 'kernel', 'method': method.name},
      );

      final tuning = json(await box.profileNodeTuningInfo(70));

      expect(tuning['source'], 'kernel');
      expect(calls, isEmpty);
    });
  });

  test('without an attached kernel the channel answers directly', () async {
    final box = BoxController(channel: channel);
    addTearDown(box.dispose);

    final config = json(await box.profileNodeConfig(70));

    expect(config['source'], 'channel');
    expect(calls.map((call) => call.method), ['profiles.nodeConfig']);
  });

  test('writes never take a second path: a failed save surfaces once', () async {
    reply = (call) async =>
        throw PlatformException(code: 'write_failed', message: 'the row is locked');
    final box = withKernel(
      (method, data) => throw ActionException(method.name, 'a write must not reach the kernel'),
    );

    await expectLater(
      box.profileNodeTuningSave(70, {'muxState': 1}),
      throwsA(isA<PlatformException>()),
    );
    // One attempt on the channel path, and the kernel was never consulted: a
    // retried write is a double apply, which is why the fallback is reads only.
    expect(calls.map((call) => call.method), ['profiles.nodeTuningSave']);
  });

  // profileStats caches its future, and only a 'profiles' event clears that
  // cache: a cached failure therefore has to be evicted, or the dashboard card
  // keeps painting '—' with no error branch to show.
  group('profileStats', () {
    Object? refuseStats(ActionMethod method, Object? data) {
      if (method == ActionMethod.profileStats) {
        throw const ActionException('profileStats', 'Room database is not available');
      }
      return null;
    }

    test('a failed kernel read falls back to the channel', () async {
      final box = withKernel(refuseStats);

      final stats = await box.profileStats(7);

      expect(stats['source'], 'channel');
      expect(calls.map((call) => call.method), ['profiles.stats']);
      expect(calls.single.arguments, {'id': 7});
    });

    test('the failed kernel read leaves no error behind for the next call', () async {
      final box = withKernel(refuseStats);

      final first = await box.profileStats(7);
      // The kernel failed, the channel answered: the cached future resolves with
      // that reply. It must never resolve with the kernel's error — only a
      // 'profiles' event clears the cache, so a stored failure would stick.
      final second = await box.profileStats(7);

      expect(first, second);
      expect(second['source'], 'channel');
      expect(calls.map((call) => call.method), ['profiles.stats'],
          reason: 'a successful fallback is worth caching like any other read');
    });

    test('a successful kernel read is cached', () async {
      var reads = 0;
      final box = withKernel((method, data) {
        if (method == ActionMethod.profileStats) {
          reads++;
          return <String, dynamic>{'groups': 1, 'outbounds': 2, 'rules': 3};
        }
        return null;
      });

      expect(await box.profileStats(7), {'groups': 1, 'outbounds': 2, 'rules': 3});
      await box.profileStats(7);

      expect(reads, 1, reason: 'a working read is cached until the profiles event');
      expect(calls, isEmpty);
    });

    test('a channel failure on the fallback is evicted too', () async {
      reply = (call) async =>
          throw PlatformException(code: 'no_database', message: 'unable to open database file');
      final box = withKernel(refuseStats);

      await expectLater(box.profileStats(7), throwsA(isA<PlatformException>()));
      await expectLater(box.profileStats(7), throwsA(isA<PlatformException>()));

      expect(calls.map((call) => call.method), ['profiles.stats', 'profiles.stats'],
          reason: 'a buried failure would answer every retry with the same stale error');
    });
  });
}
