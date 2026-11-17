// What the speed screen's outbound card names when the core has no route to report.
//
// The card used to print the "core stopped" text for any running core whose route
// snapshot carried no chain and no pinned node, so a connected session read as
// "内核未启动" on the route row. The stopped wording belongs to a stopped core only.

import 'package:flrone/components/speed_outbound_card.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a stopped core says so', () {
    final rows = SpeedOutboundRows.of(
      const {},
      coreRunning: false,
      pinnedOutbound: '',
      unavailable: 'Core stopped',
    );
    expect(rows.node, '—');
    expect(rows.route, 'Core stopped');
  });

  test('a running core with no route yet shows a dash, not the stopped text', () {
    final rows = SpeedOutboundRows.of(
      const {},
      coreRunning: true,
      pinnedOutbound: '',
      unavailable: 'Core stopped',
    );
    expect(rows.node, '—');
    expect(rows.route, '—');
  });

  test('a running core names the pinned outbound when no chain is known', () {
    final rows = SpeedOutboundRows.of(
      const {},
      coreRunning: true,
      pinnedOutbound: 'Node A',
      unavailable: 'Core stopped',
    );
    expect(rows.node, 'Node A');
    expect(rows.route, 'Node A');
  });

  test('a route chain is shown in full while the pinned node names the node', () {
    final rows = SpeedOutboundRows.of(
      const {
        'route': {
          'chains': ['Group', 'Node B'],
        },
      },
      coreRunning: true,
      pinnedOutbound: 'Node A',
      unavailable: 'Core stopped',
    );
    expect(rows.node, 'Node A');
    expect(rows.route, 'Group › Node B');
  });
}
