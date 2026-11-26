// The per-run VPN watch policy. The watcher lives on a Go Instance, so a
// stop/start or a config reload creates a new one; a one-shot latch leaves the
// new core with no listener. These tests pin the identity, retry and reset
// rules with an injected arm/sleep, without an engine or a Flutter binding.

import 'dart:async';

import 'package:flrone/common/vpn_watch_armer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one arm per run key; a stop clears the latch', () async {
    String? key = '100';
    final arms = <String>[];
    final armer = VpnWatchArmer(
      runKey: () => key,
      arm: () async {
        arms.add(key!);
        return true;
      },
    );

    await armer.onState();
    await armer.onState();
    expect(arms, ['100']);

    key = null; // stop
    await armer.onState();
    expect(arms, ['100']);

    key = '200'; // start again, new instance
    await armer.onState();
    expect(arms, ['100', '200']);

    key = null;
    await armer.onState();
    key = '100'; // the same key after a real stop must be armed again
    await armer.onState();
    expect(arms, ['100', '200', '100']);
    armer.dispose();
  });

  test('a changed key (config reload) arms again even while still running', () async {
    String? key = '100@1';
    final arms = <String>[];
    final armer = VpnWatchArmer(
      runKey: () => key,
      arm: () async {
        arms.add(key!);
        return true;
      },
    );
    await armer.onState();
    key = '100@2'; // same startedAt, different route/config version
    await armer.onState();
    expect(arms, ['100@1', '100@2']);
    armer.dispose();
  });

  test('false arms retry a bounded number of times then settle', () async {
    final arms = <int>[];
    final sleeps = <Duration>[];
    final armer = VpnWatchArmer(
      runKey: () => '100',
      arm: () async {
        arms.add(arms.length + 1);
        return false;
      },
      sleep: (delay) async => sleeps.add(delay),
    );

    for (var i = 0; i < 10; i++) {
      await armer.onState();
    }
    expect(arms, hasLength(3));
    expect(sleeps, hasLength(2));
    expect(sleeps.every((d) => d == const Duration(seconds: 5)), isTrue);
    armer.dispose();
  });

  test('a false arm that turns true on retry latches once', () async {
    final answers = [false, false, true];
    var calls = 0;
    var slept = 0;
    final armer = VpnWatchArmer(
      runKey: () => '100',
      arm: () async => answers[calls++],
      sleep: (_) async => slept++,
    );
    await armer.onState();
    expect(calls, 3);
    expect(slept, 2);
    await armer.onState(); // settled true: no extra arm
    expect(calls, 3);
    armer.dispose();
  });

  test('a throwing arm is retried and reported, never latched', () async {
    final errors = <Object>[];
    var calls = 0;
    var slept = 0;
    final armer = VpnWatchArmer(
      runKey: () => '100',
      arm: () async {
        calls++;
        throw StateError('kernel gone');
      },
      sleep: (_) async => slept++,
      onError: errors.add,
    );
    await armer.onState();
    expect(calls, 3);
    expect(slept, 2);
    expect(errors, hasLength(3));
    expect(errors.every((e) => e is StateError), isTrue);
    armer.dispose();
  });

  test('a stop during the retry window cancels the pending sequence', () async {
    String? key = '100';
    var calls = 0;
    final release = Completer<void>();
    final armer = VpnWatchArmer(
      runKey: () => key,
      arm: () async {
        calls++;
        return false;
      },
      sleep: (_) => release.future,
      maxAttempts: 1,
    );
    final pending = armer.onState();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);

    key = null; // stop while the retry sleep is in flight
    armer.onState(); // synchronous reset
    release.complete();
    await pending;
    expect(calls, 1); // no second arm after the stop

    key = '100';
    await armer.onState();
    expect(calls, 2);
    armer.dispose();
  });

  test('dispose cancels everything', () async {
    var calls = 0;
    final armer = VpnWatchArmer(
      runKey: () => '100',
      arm: () async {
        calls++;
        return false;
      },
      sleep: (_) => Future<void>.delayed(const Duration(seconds: 1)),
    );
    final pending = armer.onState();
    armer.dispose();
    await pending;
    expect(calls, 1);
    await armer.onState();
    expect(calls, 1);
  });
}
