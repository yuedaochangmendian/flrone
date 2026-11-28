// The profile duty boundary (ADR 0005 final stage).
//
// What still needs Kotlin — parsing, validation, the subscription queue, the
// selection settings, the auto-selector runtime, and the narrow side effects
// (`sort.reposition`, `revision.edit`, `subscription.schedule`) — goes through
// ONE channel method, `profiles.platform` with `{op, payload}`.
// The old per-operation channel arms and the Go action-bus arms are gone; these
// tests pin the shape and the single path (an attached kernel is never
// consulted). The document-only ops (stats and the configuration
// config/read/write) are Dart-owned now and are covered here for their cache
// and write semantics only: their data comes from the profiles document, not
// the channel.

import 'dart:io';

import 'package:flrone/box.dart';
import 'package:flrone/core/action.dart';
import 'package:flrone/data/configuration_store.dart';
import 'package:flrone/data/configuration_store_source.dart';
import 'package:flrone/data/profile_document_service.dart'
    show ProfileDocumentService;
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
  // keeps painting '—' with no error branch to show. The read itself is
  // Dart-owned now: it comes from the profiles document, never the channel.
  group('profileStats', () {
    test('reads the Dart document and caches the reply', () async {
      final harness = _documentBox();
      await harness.store.replaceAll(ProfilesDocument(profiles: [
        NodeRow(id: 1, type: 'vmess', gid: 7),
      ]));

      final first = harness.box.profileStats(7);
      final second = harness.box.profileStats(7);
      expect(identical(first, second), isTrue,
          reason: 'the controller answers a repeat read from its single flight');
      expect(await first, {
        'groups': 1,
        'outbounds': 1,
        'rules': 0,
      });
      await second;
      expect(calls, isEmpty, reason: 'stats no longer crosses profiles.platform');
    });

    test('a failure is evicted so the next read retries', () async {
      final harness = _documentBox();
      harness.fs.fail = true;

      await expectLater(
        harness.box.profileStats(7),
        throwsA(isA<FileSystemException>()),
      );
      harness.fs.fail = false;
      expect(await harness.box.profileStats(7), {
        'groups': 1,
        'outbounds': 0,
        'rules': 0,
      });
      expect(harness.fs.existsCalls, 2,
          reason: 'a buried failure would answer every retry with the same stale error');
    });
  });

  test('clearTestResults is a Dart write plus the narrow sort duty', () async {
    final harness = _documentBox(port: channel);
    await harness.store.replaceAll(ProfilesDocument(
      groups: const [ConfigurationRow(id: 1)],
      profiles: [
        NodeRow(id: 1, type: 'vmess', gid: 1, latency: 120, latencyAt: 9),
      ],
    ));

    expect(await harness.box.configurationClearTestResults(1), isTrue);

    final cleared = (await harness.store.profile(1))!;
    expect(cleared.latency, 0);
    expect(cleared.latencyAt, 0);
    expect(calls.map((call) => call.method == 'profiles.platform' ? dutyOp(call) : call.method),
        ['data.refresh', 'sort.reposition']);
    expect(dutyPayload(calls.last), {'id': 1});
  });

  test('the configuration write is a Dart edit plus the narrow intent bump', () async {
    final harness = _documentBox(port: channel);
    await harness.store.replaceAll(ProfilesDocument(
      groups: const [ConfigurationRow(id: 1, name: 'Sub')],
      profiles: [NodeRow(id: 1, type: 'vmess', name: 'node-a', gid: 1)],
    ));

    final answer = await harness.box.configurationWrite(1, '{"name":"Renamed"}', '0');

    expect((await harness.store.group(1))!.name, 'Renamed',
        reason: 'the document write is local');
    expect(answer['revision'], '0');
    expect(_methods(calls), ['revision.edit', 'data.refresh'],
        reason: 'the newest-intent bump precedes the edit, then the catalog push');
    expect(dutyPayload(calls.first), {'id': 1});
  });

  test('a URL edit re-plans the subscription poller through the narrow duty', () async {
    final harness = _documentBox(port: channel);
    await harness.store.replaceAll(ProfilesDocument(
      groups: const [ConfigurationRow(id: 1, name: 'Sub')],
    ));

    await harness.box.configurationWrite(1, '{"url":"https://example.test/sub"}', '0');

    // The host's poller reads its cached catalog, so the document push has to
    // land before the re-plan: refresh, then schedule.
    expect(_methods(calls),
        ['revision.edit', 'data.refresh', 'subscription.schedule']);
    expect(dutyPayload(calls.last), isEmpty,
        reason: 'the re-plan takes no arguments — it reads the document');
  });

  test('a failed catalog push does not fail the committed write', () async {
    final harness = _documentBox(port: channel);
    await harness.store.replaceAll(ProfilesDocument(
      groups: const [ConfigurationRow(id: 1, name: 'Sub')],
    ));
    reply = (call) async {
      if (call.method == 'data.refresh') {
        throw PlatformException(code: 'refresh-failed');
      }
      return <String, dynamic>{'source': 'channel', 'op': dutyOp(call)};
    };

    final answer = await harness.box.configurationWrite(1, '{"name":"Renamed"}', '0');

    expect(answer['revision'], '0');
    expect((await harness.store.group(1))!.name, 'Renamed',
        reason: 'the edit is durable even when the host cannot reload the catalog');
  });
}

/// The channel traffic as method/op names, without `data.path` (the default
/// group name lookup that any document manifest read makes).
List<String?> _methods(List<MethodCall> calls) => calls
    .map((call) => call.method == 'profiles.platform' ? dutyOp(call) : call.method)
    .where((method) => method != 'data.path')
    .toList();

/// A document store whose `exists` can be made to fail, with the read count
/// observable (the stats cache test needs both).
class _ToggleFs extends MemoryConfigurationStoreFs {
  bool fail = false;
  int existsCalls = 0;

  @override
  Future<bool> exists(String path) async {
    existsCalls++;
    if (fail) throw const FileSystemException('unreadable document');
    return super.exists(path);
  }
}

({BoxController box, ConfigurationStore store, _ToggleFs fs}) _documentBox({
  MethodChannel? port,
}) {
  final fs = _ToggleFs();
  final store = ConfigurationStore(path: '/doc/profiles.json', fs: fs);
  final source = ConfigurationStoreSource(
    resolvePath: () async => {'path': '/app/databases/sager_net.db'},
    store: store,
  );
  late final BoxController box;
  // S6 loopback: the UI relays document writes to the owner instead of editing
  // the store itself. This seam stands in for the service engine's
  // kernelWorker: it runs the same ProfileDocumentService ops against the local
  // store, and its host seams go back through the box channel so the existing
  // tests still observe data.refresh / revision.edit / sort.reposition /
  // subscription.schedule as bridge traffic.
  final owner = ProfileDocumentService(
    storeSource: source,
    refreshCatalog: () async {
      // The production refreshCatalog swallows a failed host push so a
      // committed write is never reported as failed (see box.dart).
      try {
        await box.call('data.refresh');
      } catch (_) {}
    },
    repositionTestResults: (groupId) async => box.configurationPlatform(
      'sort.reposition',
      {'id': groupId},
    ),
    beginGroupEdit: (groupId) async => box.configurationPlatform(
      'revision.edit',
      {'id': groupId},
    ),
    rescheduleSubscriptions: () async => box.configurationPlatform(
      'subscription.schedule',
    ),
    readDefaultGroupName: () async => 'Default',
  );
  Future<dynamic> relay(String method, Map<String, dynamic> args) async {
    switch (method) {
      case 'configurationWrite':
        return await owner.write(
          (args['id'] as num?)?.toInt() ?? 0,
          args['revision'] as String?,
          '${args['content'] ?? ''}',
        );
      case 'configurationClearTestResults':
        await owner.clearTestResults((args['id'] as num?)?.toInt() ?? 0);
        return true;
      case 'nodeReorder':
        await owner.reorderNodes(
          (args['groupId'] as num?)?.toInt() ?? 0,
          [for (final id in (args['ids'] as List? ?? const [])) (id as num).toInt()],
        );
        return true;
      case 'configurationReorder':
        await owner.reorderGroups([
          for (final id in (args['ids'] as List? ?? const [])) (id as num).toInt()
        ]);
        return true;
      case 'configurationNodeList':
        return await owner.nodeList();
      default:
        throw UnsupportedError('test relay has no op $method');
    }
  }

  box = BoxController(
    channel: port ?? const MethodChannel('test.profile-duty.doc'),
    configurationStoreSource: source,
    documentRelay: relay,
  );
  addTearDown(box.dispose);
  return (box: box, store: store, fs: fs);
}
