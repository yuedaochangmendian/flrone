import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../pages/connections.dart';
import '../providers/box_providers.dart';
import '../widgets.dart';
import 'speed_gauge.dart';

/// A cheap connection summary. The live count comes from the core's own status
/// (`dashboard.connections`, refreshed once a second), so the card stays correct while the
/// full connections feed is off — the host samples that list only while the connections page
/// is open. A closed count is shown only when this session has a sampled list, because closed
/// rows exist nowhere else; an unsampled feed must not print a zero as if it were a count.
class ConnectionsPanel extends ConsumerWidget {
  const ConnectionsPanel({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) {
    final dashboard = ref.watch(dashboardProvider);
    final connections = ref.watch(connectionsProvider);
    var sampledActive = 0, closed = 0;
    for (final connection in connections) {
      if ((connection['closedAt'] as num? ?? 0) > 0) {
        closed++;
      } else {
        sampledActive++;
      }
    }
    // Two lower bounds on the same number: the core status and the last sample. Take the
    // larger so a stale/absent status (the channel path reports 0) cannot hide live rows.
    final active = math.max((dashboard['connections'] as num?)?.toInt() ?? 0, sampledActive);
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
