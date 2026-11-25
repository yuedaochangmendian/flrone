import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../pages/connections.dart';
import '../providers/box_providers.dart';
import '../widgets.dart';
import 'speed_gauge.dart';

/// A cheap connection summary backed by a real count.
///
/// `dashboard.connections` is the host's own count: a 2 s poll of the core's list length while
/// the UI is visible and the service is connected (the full ConnectionsSampler feed stays off
/// until the connections page opens). The sampled list is only the fresher value *while it is
/// live* — the page is open and rows keep arriving — so the larger of the two is shown; when
/// the feed is off the host clears the list, which keeps a stale sample from outbidding the wire.
/// A closed count exists only in the sampled list, so it is shown only when the list has rows.
class ConnectionsPanel extends ConsumerWidget {
  const ConnectionsPanel({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) {
    // Select only the two dashboard scalars this card paints. `dashboardProvider`
    // is replaced on every traffic tick; watching it whole rebuilt the card once
    // a second for counters it never reads.
    final summary = ref.watch(connectionSummaryProvider);
    final connections = ref.watch(connectionsProvider);
    var sampledActive = 0, closed = 0;
    for (final connection in connections) {
      if ((connection['closedAt'] as num? ?? 0) > 0) {
        closed++;
      } else {
        sampledActive++;
      }
    }
    final wire = summary.count;
    // The live feed's rows are fresher than the poll while the page is open, so the larger of
    // the two wins there. A stopped service has no connections, whatever a list from the last
    // session still says.
    final active = summary.started ? math.max(wire, sampledActive) : wire;
    return BoxPanel(
      onTap: () => openPage(context, const ConnectionsPage()),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PanelTitle('Connections', AppGlyphs.connections, trailing: const GlyphIcon(AppGlyphs.chevronForward, size: 18)),
        const SizedBox(height: 12),
        Row(spacing: 16, children: [
          _Count(label: context.tr('Active'), value: active, color: context.colorScheme.primary),
          if (connections.isNotEmpty) _Count(label: context.tr('Closed'), value: closed, color: secondSeriesColor(context)),
        ]),
      ]),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value, required this.color});
  final String label;
  final int value;
  final Color color;
  @override Widget build(BuildContext context) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('$value', maxLines: 1, style: AppTextStyle.title1.of(context, emphasized: true).toTabular.copyWith(color: color)),
    const SizedBox(height: 2),
    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.listCaptionStyle),
  ]));
}
