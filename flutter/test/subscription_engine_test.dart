// S6 production queue wiring: the service-engine SubscriptionEngine turns the
// pure queue/client into the wire events and host command surface. The refresh
// data path itself is tested in subscription_refresh_test.dart; these tests pin
// the production wiring without HTTP or a document store.

import 'dart:async';
import 'dart:convert';

import 'package:flrone/data/configuration_store.dart'
    show ConfigurationStore, MemoryConfigurationStoreFs;
import 'package:flrone/services/subscription_engine.dart';
import 'package:flrone/services/subscription_refresh.dart';
import 'package:flrone/services/subscription_transport.dart'
    show SubscriptionFetchResult, SubscriptionMetadata;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the real ConfigurationStore gateway maps placeholder ids to allocated rows', () async {
    const path = '/app/files/documents/profiles.json';
    final fs = MemoryConfigurationStoreFs()
      ..externalWrite(path, jsonEncode(<String, dynamic>{
        'version': 1,
        'name': 'profiles',
        'nextProfileId': 2,
        'nextGroupId': 2,
        'profiles': <dynamic>[],
        'groups': <dynamic>[
          <String, dynamic>{'id': 7, 'name': 'Sub', 'url': 'https://x'},
        ],
      }));
    final store = ConfigurationStore(path: path, fs: fs);
    final service = SubscriptionRefreshService(
      gateway: ConfigurationStoreSubscriptionGateway(store),
      fetcher: (url, {headers = const <String, String>{}}) async => const SubscriptionFetchResult(
        body: 'body',
        headers: <String, String>{},
        metadata: SubscriptionMetadata(),
        fileName: '',
        statusCode: 200,
        finalUrl: 'https://x',
      ),
      parser: (body) async => ProfileImportResult(nodes: [
        const ProfileImportNode(
          type: 'socks',
          name: 'A',
          json: '{"server":"1.1.1.1","server_port":1080,"tag":"A","type":"socks"}',
          identity: '{"server":"1.1.1.1","server_port":1080}',
        ),
      ]),
    );

    final result = await service.refresh(7);
    expect(result.applied, isTrue);
    expect(result.added, 1);
    final doc = await store.document;
    expect(doc.profiles, hasLength(1));
    expect(doc.profiles.single.id, 2);
    expect(doc.profiles.single.name, 'A');
    expect(doc.groups.single.subLastUpdate, greaterThan(0));
  });

  test('refresh enqueues, runs once, and emits running/idle wire states', () async {
    final runs = <int>[];
    final events = <Map<String, dynamic>>[];
    final gate = Completer<void>();
    final engine = SubscriptionEngine(
      runRefresh: (gid, surface) async {
        runs.add(gid);
        await gate.future;
        return SubscriptionRefreshResult(
          gid: gid,
          outcome: SubscriptionRefreshOutcome.applied,
          applied: true,
        );
      },
      listGroups: () async => const [
        SubscriptionGroupRef(id: 7, name: 'Sub', url: 'https://example.test/sub'),
      ],
      emit: (type, value) => events.add(<String, dynamic>{'type': type, 'value': value}),
    )..start();

    expect(await engine.refresh(7), isTrue);
    expect(await engine.refresh(7), isFalse, reason: 'per-gid dedupe');
    gate.complete();
    await engine.awaitIdle();

    expect(runs, [7]);
    expect(
      events.where((event) => event['type'] == 'subscriptionState').map((event) => event['value']),
      containsAll(<Map<String, dynamic>>[
        <String, dynamic>{'gid': 7, 'state': 2},
        <String, dynamic>{'gid': 7, 'state': 0},
      ]),
    );
    await engine.dispose();
  });

  test('refreshAll skips archived, empty and (optionally) auto-update-off groups', () async {
    final runs = <int>[];
    final engine = SubscriptionEngine(
      runRefresh: (gid, surface) async {
        runs.add(gid);
        return SubscriptionRefreshResult(gid: gid, outcome: SubscriptionRefreshOutcome.applied);
      },
      listGroups: () async => const [
        SubscriptionGroupRef(id: 1, name: 'A', url: 'https://a.test'),
        SubscriptionGroupRef(id: 2, name: 'B', url: 'https://b.test', skipAutoUpdate: true),
        SubscriptionGroupRef(id: 3, name: 'C', url: ''),
        SubscriptionGroupRef(id: 4, name: 'D', url: 'https://d.test', archive: true),
      ],
      emit: (_, _) {},
    )..start();

    expect(await engine.refreshAll(onlyAllowed: true), isTrue);
    await engine.awaitIdle();
    expect(runs, [1]);
    await engine.dispose();
  });

  test('a missing group is not enqueued', () async {
    final engine = SubscriptionEngine(
      runRefresh: (gid, surface) async =>
          SubscriptionRefreshResult(gid: gid, outcome: SubscriptionRefreshOutcome.noop),
      listGroups: () async => const [],
      emit: (_, _) {},
    )..start();
    expect(await engine.refresh(99), isFalse);
    await engine.dispose();
  });
}
