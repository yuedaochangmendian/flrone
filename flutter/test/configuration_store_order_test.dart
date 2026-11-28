// Regression: a combined apply that inserts rows with client placeholder ids
// and asks for their order in the same edit must remap the placeholders to the
// allocated ids. Without this, `_setOrder` filters the negative ids out and
// subscription refreshs would append new rows in arbitrary order.

import 'package:flrone/data/configuration_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('applyCombined remaps placeholder ids in the same reorder request', () async {
    const path = '/app/files/documents/profiles.json';
    final fs = MemoryConfigurationStoreFs();
    final store = ConfigurationStore(path: path, fs: fs);
    await store.replaceAll(ProfilesDocument(
      groups: [const ConfigurationRow(id: 1, name: 'G', displayOrder: 0)],
      nextProfileId: 1,
      nextGroupId: 2,
    ));

    final allocated = await store.applyCombined(
      replaceAll: false,
      allocateIds: true,
      profiles: [
        const NodeRow(id: -1, type: 'socks', name: 'A', gid: 1, outboundJson: '{"a":1}'),
        const NodeRow(id: -2, type: 'socks', name: 'B', gid: 1, outboundJson: '{"b":1}'),
      ],
      reorderGroupId: 1,
      reorderNodeIds: const [-2, -1],
    );

    final a = allocated.profiles[-1]!;
    final b = allocated.profiles[-2]!;
    expect(a, isPositive);
    expect(b, isPositive);
    final members = await store.profilesOfGroup(1);
    expect(members.map((row) => row.id).toList(), [b, a]);
    expect(members.map((row) => row.userOrder).toList(), [0, 1]);
  });
}
