// S6 new-subscription create path (pure Dart). The create service shares the
// refresh fetch/parse/reconcile/apply plan, so these tests pin the parts that
// differ: validation happens BEFORE a group exists, the name fallback ladder,
// one apply edit for the nodes, and the metadata/group columns written to the
// new group.

import 'dart:convert';

import 'package:flrone/data/configuration_store.dart'
    show ConfigurationRow, ConfigurationStore, MemoryConfigurationStoreFs, NodeRow;
import 'package:flrone/services/subscription_refresh.dart';
import 'package:flrone/services/subscription_transport.dart'
    show
        SubscriptionFetchResult,
        SubscriptionMetadata,
        SubscriptionTransportException;
import 'package:flutter_test/flutter_test.dart';

void main() {
  const aJson = '{"server":"1.1.1.1","server_port":1080,"tag":"A","type":"socks"}';
  const bJson = '{"server":"2.2.2.2","server_port":1080,"tag":"B","type":"socks"}';
  const aIdentity = '{"server":"1.1.1.1","server_port":1080}';
  const bIdentity = '{"server":"2.2.2.2","server_port":1080}';

  ProfileImportNode arrival(String json, String identity, String tag) =>
      ProfileImportNode(type: 'socks', name: tag, json: json, identity: identity);

  SubscriptionFetchResult fetched(
    String body, {
    SubscriptionMetadata metadata = const SubscriptionMetadata(),
    String fileName = '',
    String finalUrl = 'https://provider.example/sub',
  }) =>
      SubscriptionFetchResult(
        body: body,
        headers: const <String, String>{},
        metadata: metadata,
        fileName: fileName,
        statusCode: 200,
        finalUrl: finalUrl,
      );

  SubscriptionRefreshService serviceFor(
    CreateRecordingGateway gateway, {
    required SubscriptionFetchResult Function(String url) fetch,
    required ProfileImportResult Function(String body) parse,
    int Function()? nowSeconds,
    List<String>? reports,
  }) =>
      SubscriptionRefreshService(
        gateway: gateway,
        nowSeconds: nowSeconds,
        fetcher: (url, {headers = const <String, String>{}}) async => fetch(url),
        parser: (body) async => parse(body),
        onReport: (gid, title, text, popup) =>
            reports?.add('$gid|$title|$text|$popup'),
      );

  group('success', () {
    test('creates one group and inserts nodes in one apply, with metadata', () async {
      final gateway = CreateRecordingGateway();
      final now = 1_700_000_000;
      final service = serviceFor(
        gateway,
        fetch: (_) => fetched('$aJson\n$bJson', metadata: const SubscriptionMetadata(
          title: 'Panel',
          valid: true,
          total: 1000,
        )),
        parse: (_) => ProfileImportResult(nodes: [
          arrival(aJson, aIdentity, 'A'),
          arrival(bJson, bIdentity, 'B'),
        ]),
        nowSeconds: () => now,
      );

      final result = await service.create(
        name: 'My Sub',
        url: ' https://provider.example/sub ',
        subOptionsJson: '{"user_agent":"Flrone/1"}',
      );

      expect(result.applied, isTrue);
      expect(result.gid, 101);
      expect(result.name, 'My Sub');
      expect(result.added, 2);
      expect(result.metadata, contains('"total":1000'));
      expect(result.reportText, contains('[+]'));
      // One combined edit carries all inserts and the group patch.
      expect(gateway.applyCalls, 1);
      expect(gateway.group!.id, 101);
      expect(gateway.group!.name, 'My Sub');
      expect(gateway.group!.url, 'https://provider.example/sub');
      expect(gateway.group!.subOptionsJson, '{"user_agent":"Flrone/1"}');
      expect(gateway.group!.subLastUpdate, now);
      expect(gateway.group!.subMetadataJson, result.metadata);
      expect(gateway.rows.map((r) => r.gid), <int>[101, 101]);
      expect(gateway.rows.map((r) => r.userOrder), <int>[0, 1]);
      expect(gateway.rows.map((r) => r.outboundJson), <String>[aJson, bJson]);
      expect(gateway.groupPatches!.toList(), <int>[101]);
    });

    test('the user agent comes from subOptionsJson', () async {
      final gateway = CreateRecordingGateway();
      Map<String, String>? seen;
      final service = SubscriptionRefreshService(
        gateway: gateway,
        fetcher: (url, {headers = const <String, String>{}}) async {
          seen = headers;
          return fetched(aJson);
        },
        parser: (_) async => ProfileImportResult(nodes: [arrival(aJson, aIdentity, 'A')]),
      );
      await service.create(
        name: 'S',
        url: 'https://provider.example/sub',
        subOptionsJson: '{"user_agent":"UA/9"}',
      );
      expect(seen, <String, String>{'user-agent': 'UA/9'});
    });
  });

  group('name fallbacks', () {
    Future<String> resolvedName({
      required String supplied,
      SubscriptionMetadata metadata = const SubscriptionMetadata(),
      String fileName = '',
      String finalUrl = 'https://provider.example/sub',
    }) async {
      final gateway = CreateRecordingGateway();
      final service = serviceFor(
        gateway,
        fetch: (_) => fetched(aJson, metadata: metadata, fileName: fileName, finalUrl: finalUrl),
        parse: (_) => ProfileImportResult(nodes: [arrival(aJson, aIdentity, 'A')]),
      );
      final result = await service.create(
        name: supplied,
        url: finalUrl,
        subOptionsJson: '{}',
      );
      return result.name;
    }

    test('supplied name wins', () async {
      expect(await resolvedName(supplied: ' Mine ', metadata: const SubscriptionMetadata(title: 'Panel')), 'Mine');
    });

    test('metadata title then filename then URL host', () async {
      expect(
        await resolvedName(
          supplied: '  ',
          metadata: const SubscriptionMetadata(title: 'Panel', valid: true),
          fileName: 'panel.yaml',
        ),
        'Panel',
      );
      expect(
        await resolvedName(supplied: '', fileName: 'panel.yaml'),
        'panel.yaml',
      );
      expect(
        await resolvedName(supplied: '', finalUrl: 'https://www.provider.example/sub'),
        'provider.example',
      );
      expect(
        await resolvedName(supplied: '', finalUrl: 'https://provider.example/sub'),
        'provider.example',
      );
    });
  });

  group('validation leaves no group', () {
    Future<void> expectRefusal(
      SubscriptionFetchResult Function(String url) fetch,
      ProfileImportResult Function(String body) parse, {
      String url = 'https://provider.example/sub',
      String message = '',
    }) async {
      final gateway = CreateRecordingGateway();
      final service = serviceFor(gateway, fetch: fetch, parse: parse);
      try {
        await service.create(name: 'S', url: url, subOptionsJson: '{}');
        fail('create should have refused the subscription');
      } on SubscriptionCreateException catch (error) {
        if (message.isNotEmpty) expect(error.message, contains(message));
      }
      expect(gateway.createdNames, isEmpty, reason: 'no group may be created');
      expect(gateway.applyCalls, 0);
      expect(gateway.rows, isEmpty);
    }

    test('fetch failure', () async {
      await expectRefusal(
        (_) => throw SubscriptionTransportException('HTTP 503'),
        (_) => throw StateError('parser must not run'),
        message: 'HTTP 503',
      );
    });

    test('parse refusal (unsupported)', () async {
      await expectRefusal(
        (_) => fetched(aJson),
        (_) => const ProfileImportResult(supported: false, text: 'unsupported TLS'),
        message: 'unsupported TLS',
      );
    });

    test('parser throw', () async {
      await expectRefusal(
        (_) => fetched(aJson),
        (_) => throw StateError('bad bridge'),
        message: 'Subscription parse failed',
      );
    });

    test('empty body', () async {
      await expectRefusal(
        (_) => fetched(''),
        (_) => const ProfileImportResult(),
        message: 'Subscription is empty',
      );
    });

    test('web page body', () async {
      await expectRefusal(
        (_) => fetched('<!DOCTYPE html><html>blocked</html>'),
        (_) => const ProfileImportResult(),
        message: 'web page',
      );
    });

    test('non-HTTP schemes refuse before a fetch', () async {
      await expectRefusal(
        (_) => throw StateError('fetch must not run'),
        (_) => throw StateError('parser must not run'),
        url: 'content://com.example/file',
        message: 'host import path',
      );
    });

    test('empty URL refuses before a fetch', () async {
      await expectRefusal(
        (_) => throw StateError('fetch must not run'),
        (_) => throw StateError('parser must not run'),
        url: '  ',
        message: 'URL is required',
      );
    });
  });

  test('duplicate nodes are deduped before the single apply', () async {
    final gateway = CreateRecordingGateway();
    final reports = <String>[];
    final service = serviceFor(
      gateway,
      fetch: (_) => fetched(aJson),
      parse: (_) => ProfileImportResult(nodes: [
        arrival(aJson, aIdentity, 'A'),
        arrival(aJson, aIdentity, 'A2'),
      ]),
      reports: reports,
    );
    final result = await service.create(
      name: 'S', url: 'https://provider.example/sub', subOptionsJson: '{}',
    );
    expect(result.added, 1);
    expect(gateway.rows, hasLength(1));
    expect(gateway.applyCalls, 1);
    expect(result.reportText, contains('1 repeated nodes dropped'));
    expect(reports.single, contains('New subscription: S'));
  });

  test('the real ConfigurationStore gateway allocates the group and nodes', () async {
    const path = '/app/files/documents/profiles.json';
    final fs = MemoryConfigurationStoreFs()
      ..externalWrite(path, jsonEncode(<String, dynamic>{
        'version': 1,
        'name': 'profiles',
        'nextProfileId': 1,
        'nextGroupId': 1,
        'profiles': <dynamic>[],
        'groups': <dynamic>[],
      }));
    final store = ConfigurationStore(path: path, fs: fs);
    final service = SubscriptionRefreshService(
      gateway: ConfigurationStoreSubscriptionGateway(store),
      nowSeconds: () => 42,
      fetcher: (url, {headers = const <String, String>{}}) async => fetched(aJson),
      parser: (body) async => ProfileImportResult(nodes: [arrival(aJson, aIdentity, 'A')]),
    );
    final result = await service.create(
      name: 'Real', url: 'https://provider.example/sub', subOptionsJson: '{}',
    );
    final doc = await store.document;
    expect(result.gid, 1);
    expect(doc.groups, hasLength(1));
    expect(doc.groups.single.name, 'Real');
    expect(doc.groups.single.subLastUpdate, 42);
    expect(doc.profiles, hasLength(1));
    expect(doc.profiles.single.gid, 1);
    expect(doc.profiles.single.outboundJson, aJson);
  });
}

/// Gateway that behaves like ConfigurationStore.applyCombined and records the
/// create/apply split. Group ids start at 101 so they cannot collide with a
/// placeholder or with node ids.
class CreateRecordingGateway implements SubscriptionDocumentGateway {
  ConfigurationRow? group;
  final List<NodeRow> rows = <NodeRow>[];
  final List<String> createdNames = <String>[];
  final List<SubscriptionGatewayApply> requests = <SubscriptionGatewayApply>[];
  int applyCalls = 0;
  int _nextGroupId = 101;

  Iterable<int>? get groupPatches =>
      requests.isEmpty ? null : requests.single.groupPatches.keys;

  @override
  Future<ConfigurationRow?> groupByGid(int gid) async => group;

  @override
  Future<List<NodeRow>> membersOfGroup(int gid) async => List<NodeRow>.of(rows);

  @override
  Future<String> identityJsonOf(NodeRow row) async => '';

  @override
  Future<int> createSubscriptionGroup({
    required String name,
    required String url,
    required String subOptionsJson,
    bool autoUpdate = true,
  }) async {
    createdNames.add(name);
    final id = _nextGroupId++;
    group = ConfigurationRow(
      id: id,
      name: name,
      url: url,
      subOptionsJson: subOptionsJson,
      skipAutoUpdate: !autoUpdate,
    );
    return id;
  }

  @override
  Future<SubscriptionGatewayApplyResult> apply(SubscriptionGatewayApply request) async {
    applyCalls++;
    requests.add(request);
    final allocated = <int, int>{};
    for (final row in request.insertNodes) {
      final realId = rows.length + 1;
      allocated[row.id] = realId;
      rows.add(row.copyWith(id: realId));
    }
    final order = request.reorderNodeIds;
    if (order != null) {
      for (var i = 0; i < order.length; i++) {
        final id = allocated[order[i]] ?? order[i];
        final index = rows.indexWhere((r) => r.id == id);
        if (index >= 0) rows[index] = rows[index].copyWith(userOrder: i);
      }
    }
    final patch = request.groupPatches[group!.id];
    if (patch != null) group = group!.applyPatch(patch);
    return SubscriptionGatewayApplyResult(insertedIds: allocated);
  }
}
