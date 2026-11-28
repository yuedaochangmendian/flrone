// Known-vector and semantic tests for the pure subscription reconcile port.
// The digests below were computed outside Dart (Python hashlib) so a mistake in
// the SHA-256 port cannot be hidden by computing expectations with the same
// implementation.

import 'dart:convert';

import 'package:flrone/data/subscription_reconcile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('keys', () {
    test('content key is lowercase hex SHA-256 of canonical stored JSON bytes', () {
      // NIST vectors through the same utf8 -> lowercase-hex path.
      expect(
        subscriptionContentKey(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        subscriptionContentKey('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        subscriptionContentKey('hello world'),
        'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
      );
      // A canonical stored JSON string (sorted keys, no whitespace) and a
      // non-ASCII tag: hashing is over UTF-8 bytes, not Dart UTF-16 units.
      expect(
        subscriptionContentKey('{"type":"socks","tag":"节点"}'),
        '8a2d2281db0b4189a8303103ce68a5fdb302aa223a9d6e48df1296ce387a8749',
      );
    });

    test('content key is byte-exact: whitespace and key order change the digest', () {
      const canonical = '{"server":"1.2.3.4","server_port":1080,"type":"socks"}';
      expect(
        subscriptionContentKey(canonical),
        '351e785a3b346d39e9504fcf515289116e6c5e08bf02381497c9a422b62641c4',
      );
      expect(subscriptionContentKey('$canonical '), isNot(subscriptionContentKey(canonical)));
      expect(
        subscriptionContentKey('{"type":"socks","server_port":1080,"server":"1.2.3.4"}'),
        isNot(subscriptionContentKey(canonical)),
      );
    });

    test('identity key digests the literal type|identityJson string', () {
      expect(
        subscriptionIdentityKey('socks', '{"server":"1.2.3.4","server_port":1080}'),
        '1525511186b6710c841d52c6c1677e1d77bbaaba738a0e245bf2758a042710e9',
      );
      expect(
        subscriptionIdentityKey('vless', '{"server":"example.com","server_port":443}'),
        '0d4bd6e6b94727f52b8aa29d44ff15112cad3a7712ec68802f00abf2f16a26b4',
      );
      // The separator is present even for empty parts: SHA-256 of "|" is not
      // SHA-256 of the empty string.
      expect(
        subscriptionIdentityKey('', ''),
        'cbe5cfdf7c2118a9c3d78ef1d684f3afa089201352886449a06a6511cfef74a7',
      );
      expect(
        subscriptionIdentityKey('x', ''),
        'a10629cfa782abfe970abb6e7517c772cc811ac2f3d0178c46fdae3e95959b4f',
      );
      // type is part of the key: same identity JSON under a different type.
      expect(
        subscriptionIdentityKey('http', '{"server":"1.2.3.4","server_port":1080}'),
        isNot(subscriptionIdentityKey('socks', '{"server":"1.2.3.4","server_port":1080}')),
      );
    });
  });

  group('content index', () {
    test('claims in group order, at most once per old row', () {
      const a = 'A', b = 'B';
      final index = SubscriptionContentIndex([
        const SubscriptionOldEntry(10, a, 'i-a', 'old-1'),
        const SubscriptionOldEntry(20, a, 'i-a', 'old-2'),
        const SubscriptionOldEntry(30, b, 'i-b', 'old-3'),
      ]);
      expect(index.knows(a), isTrue);
      expect(index.knows('C'), isFalse);
      expect(index.claim(a), 10);
      expect(index.claim(a), 20);
      expect(index.claim(a), isNull);
      expect(index.claim(b), 30);
      expect(index.claim('C'), isNull);
      expect(index.isClaimed(10), isTrue);
      expect(index.isClaimed(20), isTrue);
      expect(index.isClaimed(30), isTrue);
      expect(index.arrived(a), isFalse);
      index.noteArrival(b);
      expect(index.arrived(b), isTrue);
      expect(index.arrived(a), isFalse);
    });
  });

  group('arrival preparation', () {
    const aJson = '{"server":"1.2.3.4","server_port":1080,"type":"socks"}';
    const aIdent = '{"server":"1.2.3.4","server_port":1080}';
    const bIdent = '{"server":"1.2.3.5","server_port":1080}';

    SubscriptionOldEntry oldA(int id) => SubscriptionOldEntry(
          id,
          subscriptionContentKey(aJson),
          subscriptionIdentityKey('socks', aIdent),
          'old-$id',
        );

    test('identical content reuses the first old row and skips identity', () {
      final index = SubscriptionContentIndex([oldA(10), oldA(20)]);
      final entry = prepareSubscriptionArrival(
        index,
        display: 'new-A',
        storedJson: aJson,
        type: 'socks',
        identityJson: aIdent,
      );
      expect(entry.reused, isTrue);
      expect(entry.contentKnown, isTrue);
      expect(entry.id, 10);
      expect(entry.identity, isEmpty, reason: 'content-known arrivals never compute identity');
      expect(index.arrived(entry.content), isTrue);
      // Claim order: the second identical arrival gets the other row.
      final second = prepareSubscriptionArrival(
        index,
        display: 'new-A2',
        storedJson: aJson,
        type: 'socks',
        identityJson: aIdent,
      );
      expect(second.reused, isTrue);
      expect(second.id, 20);
    });

    test('new content computes identity; known-but-unclaimed content does not', () {
      final index = SubscriptionContentIndex([oldA(10)]);
      final fresh = prepareSubscriptionArrival(
        index,
        display: 'fresh',
        storedJson: '{"server":"1.2.3.5","server_port":1080,"type":"socks"}',
        type: 'socks',
        identityJson: bIdent,
      );
      expect(fresh.reused, isFalse);
      expect(fresh.contentKnown, isFalse);
      expect(fresh.identity, subscriptionIdentityKey('socks', bIdent));
      expect(fresh.supersedes, 0);
      expect(fresh.id, -1);

      // Old row 10 of content A was claimed by a different arrival; a later
      // arrival of the same content A is "known" but cannot claim it, and must
      // not compute identity either.
      prepareSubscriptionArrival(
        index,
        display: 'claim-A',
        storedJson: aJson,
        type: 'socks',
        identityJson: aIdent,
      );
      final late = prepareSubscriptionArrival(
        index,
        display: 'late-A',
        storedJson: aJson,
        type: 'socks',
        identityJson: aIdent,
      );
      expect(late.contentKnown, isTrue);
      expect(late.reused, isFalse);
      expect(late.identity, isEmpty);
    });
  });

  group('identity pairing', () {
    const aJson = '{"server":"1.2.3.4","server_port":1080,"type":"socks"}';
    const bJson = '{"server":"1.2.3.5","server_port":1080,"type":"socks"}';
    const identA = '{"server":"1.2.3.4","server_port":1080}';
    const identB = '{"server":"1.2.3.5","server_port":1080}';

    SubscriptionOldEntry old(int id, String json, String ident, String display) =>
        SubscriptionOldEntry(
          id,
          subscriptionContentKey(json),
          subscriptionIdentityKey('socks', ident),
          display,
        );

    test('pairs a renamed node by identity, ignoring the display name', () {
      // The stored JSON embeds the tag, so a rename changes the content key.
      final oldRows = [old(11, aJson, identA, 'Old name')];
      const renamed = '{"server":"1.2.3.4","server_port":1080,"tag":"New","type":"socks"}';
      final index = SubscriptionContentIndex(oldRows);
      final arrival = prepareSubscriptionArrival(
        index,
        display: 'New name',
        storedJson: renamed,
        type: 'socks',
        identityJson: identA,
      );
      // Different content (tag differs) -> no content claim, identity computed.
      expect(arrival.reused, isFalse);
      expect(arrival.contentKnown, isFalse);
      expect(arrival.identity, isNotEmpty);
      pairSubscriptionByIdentity(oldRows, [arrival], index);
      expect(arrival.supersedes, 11);
    });

    test('leftovers exclude claimed rows and arrived content', () {
      final oldA = old(11, aJson, identA, 'old-A');
      final oldB = old(22, bJson, identB, 'old-B');
      final index = SubscriptionContentIndex([oldA, oldB]);
      final reusedA = prepareSubscriptionArrival(
        index,
        display: 'reused-A',
        storedJson: aJson,
        type: 'socks',
        identityJson: identA,
      );
      // old-B's content arrives but is not claimed by this arrival because
      // the content pass already spent that key on old-B for a different
      // arrival below. Here we first note the arrival, then keep old-B out of
      // the leftover pool via `arrived(content)`.
      index.noteArrival(subscriptionContentKey(bJson));
      final changedB = prepareSubscriptionArrival(
        index,
        display: 'changed-B',
        // New content, so identity is computed and the arrival is pairable.
        storedJson: '{"server":"1.2.3.5","server_port":1081,"type":"socks"}',
        type: 'socks',
        identityJson: identB,
      );
      expect(reusedA.reused, isTrue);
      expect(changedB.contentKnown, isFalse);
      expect(changedB.reused, isFalse);
      // old-A was claimed, old-B's content was noted as arrived: neither is a
      // leftover, so a pairable arrival with either identity cannot supersede.
      final noLeftover = prepareSubscriptionArrival(
        index,
        display: 'no-leftover',
        storedJson: '{"tag":"unrelated","type":"direct"}',
        type: 'socks',
        identityJson: identB,
      );
      // The index used for pairing must be the one that saw arrivals.
      pairSubscriptionByIdentity([oldA, oldB], [reusedA, changedB, noLeftover], index);
      expect(reusedA.supersedes, 0, reason: 'reused arrivals are not paired');
      expect(changedB.supersedes, 0,
          reason: 'old-B is excluded from leftovers because its content arrived');
      expect(noLeftover.supersedes, 0, reason: 'the leftover pool is empty');
    });

    test('multiple leftovers with one identity are consumed FIFO, once each', () {
      final oldRows = [
        old(11, '{"server":"1.2.3.10","server_port":1080,"type":"socks"}', identB, 'old-1'),
        old(22, '{"server":"1.2.3.11","server_port":1080,"type":"socks"}', identB, 'old-2'),
      ];
      final index = SubscriptionContentIndex(oldRows);
      const changed = '{"server":"1.2.3.5","server_port":1081,"type":"socks"}';
      final first = prepareSubscriptionArrival(index,
          display: 'arrival-1', storedJson: changed, type: 'socks', identityJson: identB);
      final second = prepareSubscriptionArrival(index,
          display: 'arrival-2', storedJson: '{"tag":"x","type":"direct"}', type: 'socks', identityJson: identB);
      final third = prepareSubscriptionArrival(index,
          display: 'arrival-3', storedJson: '{"tag":"y","type":"direct"}', type: 'socks', identityJson: identB);
      pairSubscriptionByIdentity(oldRows, [first, second, third], index);
      expect([first.supersedes, second.supersedes, third.supersedes], [11, 22, 0]);
    });
  });

  group('reconcile plan', () {
    const aJson = '{"server":"1.2.3.4","server_port":1080,"tag":"Old","type":"socks"}';
    const aIdent = '{"server":"1.2.3.4","server_port":1080}';
    const bJson = '{"server":"1.2.3.5","server_port":1080,"tag":"B","type":"socks"}';
    const bIdent = '{"server":"1.2.3.5","server_port":1080}';
    const renamedA = '{"server":"1.2.3.4","server_port":1080,"tag":"New","type":"socks"}';

    SubscriptionOldEntry old(int id, String json, String ident, String display) =>
        SubscriptionOldEntry(
          id,
          subscriptionContentKey(json),
          subscriptionIdentityKey('socks', ident),
          display,
        );

    test('kept, updated, added and deleted with document order', () {
      final oldRows = [
        old(10, aJson, aIdent, 'old-A'), // kept by identical content
        old(20, bJson, bIdent, 'old-B'), // updated in place by renamed B
        old(30, '{"tag":"C","type":"direct"}', '{}', 'old-C'), // deleted
      ];
      final result = planSubscriptionRefresh(
        old: oldRows,
        storedJson: [
          aJson, // same content as old 10 -> reuse
          '{"server":"1.2.3.5","server_port":1080,"tag":"B v2","type":"socks"}', // same identity as old 20
          '{"server":"1.2.3.9","server_port":443,"type":"vless"}', // brand new
        ],
        types: ['socks', 'socks', 'vless'],
        identityJson: [
          aIdent,
          bIdent,
          '{"server":"1.2.3.9","server_port":443}',
        ],
        displays: ['kept-A', 'updated-B', 'brand-new'],
        // A future queue inserts first and supplies the assigned id; without
        // it the inserted arrival has no id and stays out of the order.
        assignedIds: {2: 40},
      );

      final plan = result.plan;
      expect(plan.updates, [20]);
      expect(plan.updated, ['updated-B']);
      expect(plan.stale, [30]);
      expect(plan.deleted, ['old-C']);
      expect(plan.added, ['brand-new'], reason: 'reused and updated arrivals are not adds');
      // Old positions keep their ids; the new insertion lands at the end.
      expect(plan.order, [10, 20, 40]);
      expect(result.entries[0].id, 10);
      expect(result.entries[1].id, 20, reason: 'an update keeps the old row id');
      expect(result.entries[2].id, 40);

      // Re-running the pure reconcile over the same entries is idempotent.
      final stored = reconcileSubscription(oldRows, result.entries, result.index);
      expect(stored.order, [10, 20, 40]);
      expect(stored.added, ['brand-new']);
      expect(stored.updates, [20]);
      expect(stored.stale, [30]);

      final apply = SubscriptionApplyPlan.from(stored, result.entries);
      expect(apply.order, [10, 20, 40]);
      expect(apply.deleteIds, [30]);
      expect(apply.patches, hasLength(1));
      expect(apply.patches.single.oldId, 20);
      expect(apply.patches.single.arrivalIndex, 1);
      expect(apply.insertArrivals, [2]);
    });

    test('all arrivals new: everything old is stale, order is storage order', () {
      final oldRows = [
        old(10, aJson, aIdent, 'old-A'),
        old(20, bJson, bIdent, 'old-B'),
      ];
      final index = SubscriptionContentIndex(oldRows);
      final arrivals = [
        prepareSubscriptionArrival(index,
            display: 'new-1', storedJson: '{"tag":"x","type":"direct"}',
            type: 'direct', identityJson: '{}'),
        prepareSubscriptionArrival(index,
            display: 'new-2', storedJson: '{"tag":"y","type":"direct"}',
            type: 'direct', identityJson: '{}'),
      ];
      pairSubscriptionByIdentity(oldRows, arrivals, index);
      // No stored ids: nothing enters the order or the added list yet.
      var plan = reconcileSubscription(oldRows, arrivals, index);
      expect(plan.order, isEmpty);
      expect(plan.added, isEmpty);
      expect(plan.stale, [10, 20]);
      expect(plan.deleted, ['old-A', 'old-B']);

      arrivals[0].id = 41;
      arrivals[1].id = 42;
      plan = reconcileSubscription(oldRows, arrivals, index);
      expect(plan.order, [41, 42]);
      expect(plan.added, ['new-1', 'new-2']);
    });

    test('claim-once: duplicate content beyond the old rows becomes an add', () {
      final oldRows = [old(10, aJson, aIdent, 'old-A')];
      final result = planSubscriptionRefresh(
        old: oldRows,
        storedJson: [aJson, aJson],
        types: ['socks', 'socks'],
        identityJson: [aIdent, aIdent],
        displays: ['first', 'second'],
      );
      expect(result.entries[0].reused, isTrue);
      expect(result.entries[0].id, 10);
      expect(result.entries[1].reused, isFalse);
      expect(result.entries[1].contentKnown, isTrue);
      expect(result.entries[1].identity, isEmpty);
      expect(result.entries[1].supersedes, 0);
      // Only one stored row: second needs a new id before it joins the order.
      expect(result.plan.order, [10]);
      result.entries[1].id = 50;
      final plan = reconcileSubscription(oldRows, result.entries, result.index);
      expect(plan.order, [10, 50]);
      expect(plan.added, ['second']);
      expect(plan.stale, isEmpty);
    });

    test('no old group: pure insertion and no updates or deletions', () {
      final result = planSubscriptionRefresh(
        old: const [],
        storedJson: [aJson],
        types: ['socks'],
        identityJson: [aIdent],
        displays: ['only'],
      );
      expect(result.plan.stale, isEmpty);
      expect(result.plan.updates, isEmpty);
      expect(result.entries.single.reused, isFalse);
      expect(result.entries.single.identity, subscriptionIdentityKey('socks', aIdent));
      result.entries.single.id = 60;
      final plan = reconcileSubscription(const [], result.entries, result.index);
      expect(plan.order, [60]);
      expect(plan.added, ['only']);
      final apply = SubscriptionApplyPlan.from(plan, result.entries);
      expect(apply.patches, isEmpty);
      expect(apply.deleteIds, isEmpty);
      expect(apply.insertArrivals, [0]);
    });

    test('renamed node updates in place instead of add + delete', () {
      final oldRows = [old(10, aJson, aIdent, 'old-A')];
      final result = planSubscriptionRefresh(
        old: oldRows,
        storedJson: [renamedA],
        types: ['socks'],
        identityJson: [aIdent],
        displays: ['renamed-A'],
      );
      expect(result.entries.single.supersedes, 10);
      expect(result.plan.updates, [10]);
      expect(result.plan.updated, ['renamed-A']);
      expect(result.plan.stale, isEmpty);
      expect(result.plan.deleted, isEmpty);
      expect(result.plan.added, isEmpty);
      expect(result.plan.order, [10]);
      // The update takes the old id: no insert row is needed.
      final apply = SubscriptionApplyPlan.from(result.plan, result.entries);
      expect(apply.insertArrivals, isEmpty);
      expect(apply.patches.single.oldId, 10);
      expect(jsonDecode(renamedA)['tag'], 'New');
    });
  });
}
