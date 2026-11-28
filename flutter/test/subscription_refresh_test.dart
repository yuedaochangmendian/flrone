// Unit tests for the first S6 production slice: the pure-Dart subscription
// refresh data path. The in-memory gateway applies requests with the same
// rules as ConfigurationStore.applyCombined (allocate, patch, delete, reorder,
// group patch), so a wrong apply plan cannot hide behind a no-op fake.

import 'dart:convert';

import 'package:flrone/data/configuration_store.dart'
    show ConfigurationRow, NodeRow;
import 'package:flrone/data/subscription_reconcile.dart'
    show subscriptionContentKey, subscriptionIdentityKey;
import 'package:flrone/services/subscription_refresh.dart';
import 'package:flrone/services/subscription_transport.dart'
    show
        SubscriptionFetchResult,
        SubscriptionHttpTransport,
        SubscriptionMetadata,
        SubscriptionTransportException;
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Canonical stored JSON: sorted keys, no whitespace (the Go exporter's shape).
  const aJson = '{"server":"1.1.1.1","server_port":1080,"tag":"A","type":"socks"}';
  const bJson = '{"server":"2.2.2.2","server_port":1080,"tag":"B","type":"socks"}';
  const bChangedJson = '{"server":"2.2.2.3","server_port":1080,"tag":"B2","type":"socks"}';
  const cJson = '{"server":"3.3.3.3","server_port":1080,"tag":"C","type":"socks"}';
  const dJson = '{"server":"4.4.4.4","server_port":1080,"tag":"D","type":"socks"}';

  String identityOf(String server) => '{"server":"$server","server_port":1080}';
  final aIdentity = identityOf('1.1.1.1');
  final bIdentity = identityOf('2.2.2.2');
  final cIdentity = identityOf('3.3.3.3');
  final dIdentity = identityOf('4.4.4.4');

  ProfileImportNode arrival(String json, String identity, String tag) =>
      ProfileImportNode(type: 'socks', name: tag, json: json, identity: identity);

  SubscriptionFetchResult fetched(String body, {SubscriptionMetadata? metadata}) =>
      SubscriptionFetchResult(
        body: body,
        headers: const <String, String>{},
        metadata: metadata ?? const SubscriptionMetadata(),
        fileName: '',
        statusCode: 200,
        finalUrl: 'https://example.com/sub',
      );

  NodeRow oldRow(int id, String json) => NodeRow(
        id: id,
        type: 'socks',
        name: 'old-$id',
        gid: 7,
        userOrder: id,
        outboundJson: json,
      );

  group('entry guards', () {
    test('missing, archived and url-less groups are no-ops', () async {
      for (final group in <ConfigurationRow?>[
        null,
        const ConfigurationRow(id: 7, archive: true, url: 'https://x'),
        const ConfigurationRow(id: 7, url: '   '),
      ]) {
        final gateway = MemorySubscriptionGateway(group: group);
        final service = SubscriptionRefreshService(
          gateway: gateway,
          fetcher: (url, {headers = const <String, String>{}}) async => fetched(aJson),
          parser: (body) async => ProfileImportResult(nodes: [arrival(aJson, aIdentity, 'A')]),
        );
        final result = await service.refresh(7);
        expect(result.outcome, SubscriptionRefreshOutcome.noop);
        expect(result.applied, isFalse);
        expect(gateway.applyCalls, 0);
      }
    });

    test('emits running/idle around the refresh', () async {
      final gateway = MemorySubscriptionGateway(group: const ConfigurationRow(id: 7, url: 'https://x'));
      final states = <int>[];
      final service = SubscriptionRefreshService(
        gateway: gateway,
        onState: (gid, state) => states.add(state),
        fetcher: (url, {headers = const <String, String>{}}) async => fetched(aJson),
        parser: (body) async => ProfileImportResult(nodes: [arrival(aJson, aIdentity, 'A')]),
      );
      await service.refresh(7);
      expect(states, <int>[
        SubscriptionRefreshStates.running,
        SubscriptionRefreshStates.idle,
      ]);
    });
  });

  group('fetch and parse refusals', () {
    test('fetch failure leaves the document untouched and reports an error', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(id: 7, url: 'https://x', name: 'G'),
        rows: [oldRow(1, aJson)],
      );
      final errors = <String>[];
      final service = SubscriptionRefreshService(
        gateway: gateway,
        fetcher: (url, {headers = const <String, String>{}}) async =>
            throw SubscriptionTransportException('HTTP 503'),
        parser: (body) async => throw StateError('parser must not run'),
        onError: (gid, message) => errors.add(message),
      );
      final before = gateway.group;
      final result = await service.refresh(7, notifyErrors: true);
      expect(result.outcome, SubscriptionRefreshOutcome.fetchFailed);
      expect(result.error, 'HTTP 503');
      expect(errors, <String>['HTTP 503']);
      expect(gateway.applyCalls, 0);
      expect(gateway.group, same(before));
      expect(gateway.rows.map((r) => r.id), <int>[1]);
      expect(gateway.rows.single.outboundJson, aJson);
    });

    test('import refusal (supported:false) leaves the document untouched', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(id: 7, url: 'https://x'),
        rows: [oldRow(1, aJson)],
      );
      final service = SubscriptionRefreshService(
        gateway: gateway,
        fetcher: (url, {headers = const <String, String>{}}) async => fetched(aJson),
        parser: (body) async => const ProfileImportResult(
          nodes: [],
          supported: false,
          text: 'unsupported TLS fingerprint',
        ),
      );
      final result = await service.refresh(7);
      expect(result.outcome, SubscriptionRefreshOutcome.parseRefused);
      expect(result.error, 'unsupported TLS fingerprint');
      expect(gateway.applyCalls, 0);
      expect(gateway.rows.single.outboundJson, aJson);
    });

    test('parser throw leaves the document untouched', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(id: 7, url: 'https://x'),
      );
      final service = SubscriptionRefreshService(
        gateway: gateway,
        fetcher: (url, {headers = const <String, String>{}}) async => fetched(aJson),
        parser: (body) async => throw StateError('bad bridge'),
      );
      final result = await service.refresh(7);
      expect(result.outcome, SubscriptionRefreshOutcome.parseRefused);
      expect(gateway.applyCalls, 0);
    });

    test('empty body and web-page body are rejected without an edit', () async {
      for (final entry in <MapEntry<String, SubscriptionRefreshOutcome>>[
        MapEntry('', SubscriptionRefreshOutcome.empty),
        MapEntry(' \uFEFF\n', SubscriptionRefreshOutcome.empty),
        MapEntry('<!DOCTYPE html><html>login</html>', SubscriptionRefreshOutcome.webPage),
        MapEntry('\uFEFF  <HTML>blocked</HTML>', SubscriptionRefreshOutcome.webPage),
      ]) {
        final body = entry.key;
        final outcome = entry.value;
        final gateway = MemorySubscriptionGateway(
          group: const ConfigurationRow(id: 7, url: 'https://x'),
        );
        final service = SubscriptionRefreshService(
          gateway: gateway,
          fetcher: (url, {headers = const <String, String>{}}) async => fetched(body),
          parser: (body) async => const ProfileImportResult(),
        );
        final result = await service.refresh(7);
        expect(result.outcome, outcome, reason: 'body=$body');
        expect(gateway.applyCalls, 0);
      }
    });

    test('duplicate arrivals collapse to one (distinctNodes) and report it', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(id: 7, url: 'https://x'),
      );
      final service = SubscriptionRefreshService(
        gateway: gateway,
        fetcher: (url, {headers = const <String, String>{}}) async => fetched(aJson),
        parser: (body) async => ProfileImportResult(nodes: [
          arrival(aJson, aIdentity, 'A'),
          arrival(aJson, aIdentity, 'A2'), // same identity -> deduped
        ]),
      );
      final result = await service.refresh(7);
      expect(result.outcome, SubscriptionRefreshOutcome.applied);
      expect(result.added, 1);
      expect(result.storedIds, <int>[1]);
      expect(result.reportText, contains('1 repeated nodes dropped'));
      expect(gateway.applyCalls, 1);
    });
  });

  group('apply path', () {
    test('fresh update inserts nodes in order and patches group metadata', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(id: 7, url: 'https://x', name: 'G'),
      );
      var now = 1_700_000_000;
      final service = SubscriptionRefreshService(
        gateway: gateway,
        nowSeconds: () => now,
        fetcher: (url, {headers = const <String, String>{}}) async => fetched('$aJson\n$bJson'),
        parser: (body) async => ProfileImportResult(nodes: [
          arrival(aJson, aIdentity, 'A'),
          arrival(bJson, bIdentity, 'B'),
        ]),
      );
      final result = await service.refresh(7, surface: SubscriptionRefreshSurface.diff);
      expect(result.outcome, SubscriptionRefreshOutcome.applied);
      expect(result.applied, isTrue);
      expect(result.changed, isTrue);
      expect(result.added, 2);
      expect(result.addedNames, <String>['[socks] A', '[socks] B']);
      expect(result.storedIds, <int>[1, 2]);
      expect(gateway.rows.map((r) => r.gid), <int>[7, 7]);
      expect(gateway.rows.map((r) => r.userOrder), <int>[0, 1]);
      expect(gateway.rows.map((r) => r.outboundJson), <String>[aJson, bJson]);
      expect(gateway.group!.subLastUpdate, now);
      expect(gateway.group!.info, '');
      expect(gateway.group!.subMetadataJson, '{}');
      expect(gateway.applyCalls, 1);
      expect(result.reportText, contains('[+]'));
    });

    test('metadata headers map into sub_metadata_json with sorted keys', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(id: 7, url: 'https://x'),
      );
      final metadata = SubscriptionHttpTransport.parseMetadata(
        <String, String>{
          'subscription-userinfo': 'upload=11; download=22; total=100; expire=1900000000',
          'profile-title': 'base64:8J+Yig==', // 😊
          'profile-update-interval': '12',
          'profile-web-page-url': 'https://provider.example',
        },
        aJson,
      );
      final service = SubscriptionRefreshService(
        gateway: gateway,
        nowSeconds: () => 1_700_000_123,
        fetcher: (url, {headers = const <String, String>{}}) async => fetched(aJson, metadata: metadata),
        parser: (body) async => ProfileImportResult(nodes: [arrival(aJson, aIdentity, 'A')]),
      );
      final result = await service.refresh(7);
      expect(result.applied, isTrue);
      final decoded = jsonDecode(gateway.group!.subMetadataJson) as Map<String, dynamic>;
      expect(decoded, <String, dynamic>{
        'valid': true,
        'has_quota': true,
        'upload': 11,
        'download': 22,
        'total': 100,
        'expire': 1900000000,
        'title': '😊',
        'web_url': 'https://provider.example',
        'server_interval': 12,
      });
      // Keys sorted like Kotlin's compact JsonWriter output.
      expect(gateway.group!.subMetadataJson.startsWith('{"announce"'), isFalse);
      expect(jsonDecode(result.metadata), decoded);
      expect(gateway.group!.subLastUpdate, 1_700_000_123);
    });

    test('same content reuses ids, changed identity supersedes, stale deleted, order kept', () async {
      // Old row 2 holds bJson with identity bIdentity; the B2 arrival has new
      // content but the SAME identity, so it supersedes row 2 in place.
      // Row 3 (3.3.3.3) has no matching arrival and is stale/deleted.
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(id: 7, url: 'https://x'),
        rows: [
          oldRow(1, aJson),
          oldRow(2, bJson),
          oldRow(3, cJson),
        ],
        identities: <int, String>{1: aIdentity, 2: bIdentity, 3: cIdentity},
      );
      final service = SubscriptionRefreshService(
        gateway: gateway,
        fetcher: (url, {headers = const <String, String>{}}) async => fetched('body'),
        parser: (body) async => ProfileImportResult(nodes: [
          arrival(aJson, aIdentity, 'A'), // content reuse -> id 1
          arrival(bChangedJson, bIdentity, 'B2'), // same identity -> supersede row 2
          arrival(dJson, dIdentity, 'D'), // new row
        ]),
      );
      final result = await service.refresh(7);
      expect(result.applied, isTrue);
      expect(result.added, 1);
      expect(result.updated, 1);
      expect(result.deleted, 1);
      expect(result.addedNames, <String>['[socks] D']);
      expect(result.updatedNames, <String>['[socks] B2']);
      expect(result.deletedNames, <String>['[socks] old-3']);
      expect(result.storedIds, <int>[1, 2, 4]);
      expect(gateway.rows.map((r) => r.id), <int>[1, 2, 4]);
      expect(gateway.rows.map((r) => r.userOrder), <int>[0, 1, 2]);
      expect(gateway.rows.firstWhere((r) => r.id == 2).outboundJson, bChangedJson);
      expect(gateway.applyCalls, 1);
      final request = gateway.requests.single;
      expect(request.deleteNodeIds, <int>[3]);
      expect(request.reorderNodeIds, <int>[1, 2, subscriptionPlaceholderIdBase]);
    });

    test('changed identity supersedes the old row in place', () async {
      // Old row 2 holds bJson with identity bIdentity; the arrival has new
      // content but the SAME identity, so identity pairing updates row 2.
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(id: 7, url: 'https://x'),
        rows: [oldRow(2, bJson)],
        identities: <int, String>{2: bIdentity},
      );
      final service = SubscriptionRefreshService(
        gateway: gateway,
        fetcher: (url, {headers = const <String, String>{}}) async => fetched('body'),
        parser: (body) async => ProfileImportResult(nodes: [
          arrival(bChangedJson, bIdentity, 'B2'),
        ]),
      );
      final result = await service.refresh(7);
      expect(result.applied, isTrue);
      expect(result.updated, 1);
      expect(result.added, 0);
      expect(result.deleted, 0);
      expect(result.storedIds, <int>[2]);
      expect(result.updatedNames, <String>['[socks] B2']);
      expect(gateway.rows.single.id, 2);
      expect(gateway.rows.single.outboundJson, bChangedJson);
      expect(gateway.rows.single.name, 'B2');
      expect(gateway.applyCalls, 1);
    });

    test('duplicate content claims FIFO exactly once per old row', () async {
      // Two old rows hold identical content; two arrivals with DIFFERENT
      // identities but identical stored content must claim both in group order.
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(id: 7, url: 'https://x'),
        rows: [oldRow(10, aJson), oldRow(20, aJson)],
        identities: <int, String>{10: aIdentity, 20: aIdentity},
      );
      final service = SubscriptionRefreshService(
        gateway: gateway,
        fetcher: (url, {headers = const <String, String>{}}) async => fetched('body'),
        parser: (body) async => ProfileImportResult(nodes: [
          arrival(aJson, aIdentity, 'copy-1'),
          arrival(aJson, identityOf('5.5.5.5'), 'copy-2'),
        ]),
      );
      final result = await service.refresh(7);
      expect(result.storedIds, <int>[10, 20]);
      expect(result.added, 0);
      expect(result.deleted, 0);
      expect(gateway.rows.map((r) => r.id), <int>[10, 20]);
      expect(gateway.applyCalls, 1);
    });

    test('identity pairing is FIFO when two old rows share an identity', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(id: 7, url: 'https://x'),
        rows: [oldRow(10, aJson), oldRow(20, bJson)],
        identities: <int, String>{10: aIdentity, 20: aIdentity},
      );
      final service = SubscriptionRefreshService(
        gateway: gateway,
        fetcher: (url, {headers = const <String, String>{}}) async => fetched('body'),
        parser: (body) async => ProfileImportResult(nodes: [
          arrival(bChangedJson, aIdentity, 'new-1'),
          arrival(dJson, dIdentity, 'new-2'),
        ]),
      );
      // First arrival pairs with the first unmatched old row (10); second is
      // new; row 20 (same identity, not matched FIFO) is stale/deleted.
      final result = await service.refresh(7);
      expect(result.storedIds, <int>[10, 21]);
      expect(result.updatedNames, <String>['[socks] new-1']);
      expect(result.addedNames, <String>['[socks] new-2']);
      expect(result.deletedNames, <String>['[socks] old-20']);
      expect(gateway.rows.map((r) => r.id), <int>[10, 21]);
      expect(gateway.rows.first.outboundJson, bChangedJson);
    });

    test('all content identical: no changes, but metadata and order still applied once', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(id: 7, url: 'https://x', info: 'stale'),
        rows: [oldRow(4, aJson)],
        identities: <int, String>{4: aIdentity},
      );
      final service = SubscriptionRefreshService(
        gateway: gateway,
        nowSeconds: () => 9_999,
        fetcher: (url, {headers = const <String, String>{}}) async => fetched('body'),
        parser: (body) async => ProfileImportResult(nodes: [
          arrival(aJson, aIdentity, 'same-1'),
        ]),
      );
      final result = await service.refresh(7);
      expect(result.applied, isTrue);
      expect(result.changed, isFalse);
      expect(result.storedIds, <int>[4]);
      expect(result.reportText, contains('Nothing changed'));
      expect(gateway.group!.info, '');
      expect(gateway.group!.subLastUpdate, 9_999);
      expect(gateway.applyCalls, 1);
    });
  });

  group('staleness and unsupported extras', () {
    test('a stale answer is discarded after the download', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(id: 7, url: 'https://x'),
      );
      var current = true;
      final service = SubscriptionRefreshService(
        gateway: gateway,
        isCurrentIntent: () async => current,
        fetcher: (url, {headers = const <String, String>{}}) async {
          current = false;
          return fetched(aJson);
        },
        parser: (body) async => ProfileImportResult(nodes: [arrival(aJson, aIdentity, 'A')]),
      );
      final result = await service.refresh(7);
      expect(result.outcome, SubscriptionRefreshOutcome.stale);
      expect(gateway.applyCalls, 0);
    });

    test('a URL change during the download discards the answer', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(id: 7, url: 'https://x'),
      );
      final service = SubscriptionRefreshService(
        gateway: gateway,
        fetcher: (url, {headers = const <String, String>{}}) async {
          gateway.group = const ConfigurationRow(id: 7, url: 'https://edited');
          return fetched(aJson);
        },
        parser: (body) async => ProfileImportResult(nodes: [arrival(aJson, aIdentity, 'A')]),
      );
      final result = await service.refresh(7);
      expect(result.outcome, SubscriptionRefreshOutcome.stale);
      expect(gateway.applyCalls, 0);
    });

    test('Kotlin-only extras are flagged, not approximated', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(
          id: 7,
          url: 'https://x',
          subOptionsJson: '{"url_test":true,"tls_version":4}',
          frontProxyId: 3,
        ),
      );
      final flagged = <String>[];
      final service = SubscriptionRefreshService(
        gateway: gateway,
        fetcher: (url, {headers = const <String, String>{}}) async => fetched(aJson),
        parser: (body) async => ProfileImportResult(nodes: [arrival(aJson, aIdentity, 'A')]),
        onUnsupportedFeature: (gid, feature) => flagged.add(feature),
      );
      final result = await service.refresh(7);
      expect(result.applied, isTrue);
      expect(
        result.skippedFeatures,
        containsAll(<String>[
          'urlTestFollowUp',
          'http2TlsPinning',
          'frontLandingProxy',
        ]),
      );
      expect(flagged, result.skippedFeatures);
      // Name filters are ported; the unmatched node still lands only because
      // this group sets no include/exclude rules.
      expect(gateway.rows.single.name, 'A');
    });

    test('name include/exclude filters nodes before reconciliation', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(
          id: 7,
          url: 'https://x',
          subOptionsJson: r'{"name_include":"^A$","name_exclude":"B"}',
        ),
      );
      final service = SubscriptionRefreshService(
        gateway: gateway,
        fetcher: (url, {headers = const <String, String>{}}) async => fetched('body'),
        parser: (body) async => ProfileImportResult(nodes: [
          arrival(aJson, aIdentity, 'A'),
          arrival(bJson, bIdentity, 'B'),
          arrival(cJson, cIdentity, 'C'),
        ]),
      );
      final result = await service.refresh(7);
      expect(result.applied, isTrue);
      expect(result.added, 1);
      expect(gateway.rows.single.name, 'A');
    });

    test('an invalid name pattern is ignored, not fatal', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(
          id: 7,
          url: 'https://x',
          subOptionsJson: '{"name_include":"["}',
        ),
      );
      final service = SubscriptionRefreshService(
        gateway: gateway,
        fetcher: (url, {headers = const <String, String>{}}) async => fetched(aJson),
        parser: (body) async => ProfileImportResult(nodes: [arrival(aJson, aIdentity, 'A')]),
      );
      final result = await service.refresh(7);
      expect(result.applied, isTrue);
      expect(gateway.rows.single.name, 'A');
    });

    test('request headers carry the stored user agent', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(
          id: 7,
          url: 'https://x',
          subOptionsJson: '{"user_agent":"Flrone/1.0"}',
        ),
      );
      Map<String, String>? seen;
      final service = SubscriptionRefreshService(
        gateway: gateway,
        fetcher: (url, {headers = const <String, String>{}}) async {
          seen = headers;
          return fetched(aJson);
        },
        parser: (body) async => ProfileImportResult(nodes: [arrival(aJson, aIdentity, 'A')]),
      );
      await service.refresh(7);
      expect(seen, <String, String>{'user-agent': 'Flrone/1.0'});
    });
  });

  group('host fetch routing', () {
    test('content:// goes to the host seam, not a Dart socket', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(
          id: 7,
          url: 'content://com.example/sub',
          name: 'G',
        ),
      );
      final directCalls = <String>[];
      final hostCalls = <String>[];
      final service = SubscriptionRefreshService(
        gateway: gateway,
        transport: _RecordingTransport(directCalls, fetched(aJson)),
        hostFetcher: (url, {required subOptionsJson, gid = 0}) async {
          hostCalls.add('$gid|$subOptionsJson|$url');
          return fetched(aJson);
        },
        parser: (body) async => ProfileImportResult(nodes: [arrival(aJson, aIdentity, 'A')]),
      );
      final result = await service.refresh(7);
      expect(result.applied, isTrue);
      expect(directCalls, isEmpty);
      expect(hostCalls.single, '7|{}|content://com.example/sub');
      expect(result.skippedFeatures, isNot(contains('contentUrlInput')));
    });

    test('a front/landing proxy group goes to the host seam', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(
          id: 7,
          url: 'https://provider.example/sub',
          frontProxyId: 3,
        ),
      );
      final directCalls = <String>[];
      final hostCalls = <String>[];
      final service = SubscriptionRefreshService(
        gateway: gateway,
        transport: _RecordingTransport(directCalls, fetched(aJson)),
        hostFetcher: (url, {required subOptionsJson, gid = 0}) async {
          hostCalls.add(url);
          return fetched(aJson);
        },
        parser: (body) async => ProfileImportResult(nodes: [arrival(aJson, aIdentity, 'A')]),
      );
      final result = await service.refresh(7);
      expect(result.applied, isTrue);
      expect(directCalls, isEmpty);
      expect(hostCalls, <String>['https://provider.example/sub']);
      expect(result.skippedFeatures, isNot(contains('frontLandingProxy')));
    });

    test('a plain HTTPS group stays on the Dart transport', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(id: 7, url: 'https://provider.example/sub'),
      );
      final directCalls = <String>[];
      final hostCalls = <String>[];
      final service = SubscriptionRefreshService(
        gateway: gateway,
        transport: _RecordingTransport(directCalls, fetched(aJson)),
        hostFetcher: (url, {required subOptionsJson, gid = 0}) async {
          hostCalls.add(url);
          return fetched(aJson);
        },
        parser: (body) async => ProfileImportResult(nodes: [arrival(aJson, aIdentity, 'A')]),
      );
      final result = await service.refresh(7);
      expect(result.applied, isTrue);
      expect(directCalls, <String>['https://provider.example/sub']);
      expect(hostCalls, isEmpty);
    });

    test('without the host seam the Kotlin-only flags still surface', () async {
      final gateway = MemorySubscriptionGateway(
        group: const ConfigurationRow(
          id: 7,
          url: 'https://provider.example/sub',
          frontProxyId: 3,
        ),
      );
      final service = SubscriptionRefreshService(
        gateway: gateway,
        transport: _RecordingTransport(<String>[], fetched(aJson)),
        parser: (body) async => ProfileImportResult(nodes: [arrival(aJson, aIdentity, 'A')]),
      );
      final result = await service.refresh(7);
      expect(result.skippedFeatures, contains('frontLandingProxy'));
    });
  });

  group('helpers', () {
    test('content and identity digests are delegated to the pure reconcile port', () {
      expect(subscriptionContentKey(aJson), isNot(subscriptionContentKey(bJson)));
      expect(
        subscriptionIdentityKey('socks', aIdentity),
        isNot(subscriptionIdentityKey('socks', bIdentity)),
      );
    });

    test('notice collapses at 1000 names', () {
      final many = List<String>.filled(1000, 'x');
      expect(notice(many, '[+]', 'added'), '[+] added 1000\n');
      expect(notice(<String>['A'], '[+]', 'added'), '[+] A\n');
    });
  });
}

/// In-memory gateway with `applyCombined` semantics.
class MemorySubscriptionGateway implements SubscriptionDocumentGateway {
  MemorySubscriptionGateway({
    this.group,
    List<NodeRow> rows = const <NodeRow>[],
    Map<int, String> identities = const <int, String>{},
  })  : rows = List<NodeRow>.of(rows),
        _identities = Map<int, String>.from(identities);

  ConfigurationRow? group;
  final List<NodeRow> rows;
  final Map<int, String> _identities;
  late int _nextId = rows.fold<int>(0, (max, r) => r.id > max ? r.id : max) + 1;
  int applyCalls = 0;
  final List<SubscriptionGatewayApply> requests = <SubscriptionGatewayApply>[];

  @override
  Future<ConfigurationRow?> groupByGid(int gid) async => group;

  @override
  Future<List<NodeRow>> membersOfGroup(int gid) async =>
      List<NodeRow>.of(rows)..sort((a, b) => a.userOrder.compareTo(b.userOrder));

  @override
  Future<String> identityJsonOf(NodeRow row) async => _identities[row.id] ?? '';

  int _nextGroupId = 100;

  @override
  Future<int> createSubscriptionGroup({
    required String name,
    required String url,
    required String subOptionsJson,
    bool autoUpdate = true,
  }) async {
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
      final realId = _nextId++;
      allocated[row.id] = realId;
      rows.add(row.copyWith(id: realId));
    }
    for (final entry in request.nodePatches.entries) {
      final index = rows.indexWhere((r) => r.id == entry.key);
      if (index >= 0) rows[index] = rows[index].applyPatch(entry.value);
    }
    final doomed = request.deleteNodeIds.toSet();
    rows.removeWhere((r) => doomed.contains(r.id));
    final order = request.reorderNodeIds;
    if (order != null) {
      for (var i = 0; i < order.length; i++) {
        final id = allocated[order[i]] ?? order[i];
        final index = rows.indexWhere((r) => r.id == id);
        if (index >= 0) rows[index] = rows[index].copyWith(userOrder: i);
      }
    }
    if (group != null) {
      final patch = request.groupPatches[group!.id];
      if (patch != null) group = group!.applyPatch(patch);
    }
    return SubscriptionGatewayApplyResult(insertedIds: allocated);
  }

  @override
  Future<void> deleteSubscriptionGroup(int gid) async {
    if (group?.id == gid) group = null;
    rows.removeWhere((row) => row.gid == gid);
  }
}

/// A direct transport that never opens a socket: proves which URL the service
/// sent where without a loopback server.
class _RecordingTransport extends SubscriptionHttpTransport {
  _RecordingTransport(this.calls, this.result);

  final List<String> calls;
  final SubscriptionFetchResult result;

  @override
  Future<SubscriptionFetchResult> fetch(
    String url, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    calls.add(url);
    return result;
  }
}
