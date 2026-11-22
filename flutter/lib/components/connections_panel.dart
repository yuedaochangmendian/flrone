import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../pages/connections.dart';
import '../providers/box_providers.dart';
import '../widgets.dart';
import 'speed_gauge.dart';

/// A cheap connection summary: the rows already live in [connectionsProvider],
/// so the two figures cost one pass over that list per rebuild. The host samples
/// connections only while the page is visible, so the figures hold the last
/// sample while it is closed — no extra polling from the dashboard.
class ConnectionsPanel extends ConsumerWidget {
  const ConnectionsPanel({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) {
    final connections = ref.watch(connectionsProvider);
    var active = 0;
    for (final connection in connections) {
      if ((connection['closedAt'] as num? ?? 0) <= 0) active++;
    }
    return BoxPanel(
      onTap: () => openPage(context, const ConnectionsPage()),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PanelTitle('Connections', AppGlyphs.connections, trailing: const GlyphIcon(AppGlyphs.chevronForward, size: 18)),
        const SizedBox(height: 12),
        Row(spacing: 16, children: [
          _Count(label: context.tr('Active'), value: active, color: context.colorScheme.primary),
          _Count(label: context.tr('Known'), value: connections.length, color: secondSeriesColor(context)),
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
