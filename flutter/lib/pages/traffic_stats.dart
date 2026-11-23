import 'dart:math' as math;

import '../components/form.dart';
import '../components/speed_gauge.dart';
import '../services/traffic_stats.dart';
import '../widgets.dart';

/// Daily traffic, its hourly shape and the per-profile split. The ledger is sampled from the
/// core's cumulative session totals while the app runs (see [TrafficStatsStore]).
class TrafficStatsPage extends StatelessWidget {
  const TrafficStatsPage({super.key, this.ledger});

  /// Test seam; the app uses the store's live ledger.
  final TrafficLedger? ledger;

  @override
  Widget build(BuildContext context) {
    final store = TrafficStatsStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final data = ledger ?? store.ledger;
        final now = DateTime.now();
        final today = data.day(now) ?? DayTraffic();
        final week = data.totalBetween(now.subtract(const Duration(days: 6)), now);
        final month = data.totalBetween(now.subtract(const Duration(days: 29)), now);
        final profiles = today.profiles.values.toList()
          ..sort((a, b) => b.total.compareTo(a.total));
        return BoxPage(title: 'Traffic statistics', children: [
          const SizedBox(height: 8),
          _Summary(day: today, week: week, month: month),
          const SizedBox(height: 16),
          Text(context.tr('Hourly'), style: context.listTitleStyle),
          const SizedBox(height: 8),
          _HourChart(day: today),
          if (profiles.isNotEmpty) ...[
            const SizedBox(height: 8),
            generateSection(
              title: context.tr('By profile'),
              items: [
                for (final profile in profiles.take(8))
                  ListItem(
                    title: Text(profile.name.isEmpty ? context.tr('Profile') : profile.name),
                    trailing: Text(
                      '${bytes(profile.up)} ↑ · ${bytes(profile.down)} ↓',
                      style: context.listValueStyle.toTabular,
                    ),
                  ),
              ],
            ),
          ],
          if (data.days.isEmpty)
            NullStatus(label: context.tr('No traffic recorded yet'), illustration: NullStatusIllustration.profile)
          else
            generateSection(
              title: context.tr('Last 30 days'),
              items: [
                for (var i = 0; i < 30; i++)
                  if (data.day(now.subtract(Duration(days: i))) case final day?)
                    ListItem(
                      title: Text(i == 0 ? context.tr('Today') : _label(now.subtract(Duration(days: i)))),
                      trailing: Text(
                        '${bytes(day.up)} ↑ · ${bytes(day.down)} ↓',
                        style: context.listValueStyle.toTabular,
                      ),
                    ),
              ],
            ),
        ]);
      },
    );
  }

  static String _label(DateTime at) =>
      '${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
}

class _Summary extends StatelessWidget {
  const _Summary({required this.day, required this.week, required this.month});
  final DayTraffic day;
  final int week;
  final int month;

  @override
  Widget build(BuildContext context) {
    final color = context.colorScheme;
    final total = bytes(day.total).split(' ');
    return BoxPanel(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PanelTitle('Today', AppGlyphs.dataUsage),
      const SizedBox(height: 14),
      Text.rich(TextSpan(children: [
        TextSpan(text: total.first, style: AppTextStyle.title1.of(context, emphasized: true).toTabular),
        TextSpan(text: ' ${total.last}', style: AppTextStyle.footnote.of(context).copyWith(color: color.onSurfaceVariant)),
      ]), maxLines: 1),
      const SizedBox(height: 10),
      Wrap(spacing: 16, runSpacing: 4, children: [
        _Figure(label: context.tr('Upload'), value: day.up, color: secondSeriesColor(context)),
        _Figure(label: context.tr('Download'), value: day.down, color: color.primary),
        _Figure(label: context.tr('Last 7 days'), value: week, color: color.onSurfaceVariant),
        _Figure(label: context.tr('Last 30 days'), value: month, color: color.onSurfaceVariant),
      ]),
    ]));
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, required this.color});
  final String label;
  final int value;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: [
        DecoratedBox(decoration: ShapeDecoration(color: color, shape: AppShape.circle), child: const SizedBox.square(dimension: 8)),
        Text(label, style: context.listCaptionStyle),
        Text(bytes(value), style: AppTextStyle.footnote.of(context, emphasized: true).toTabular),
      ]);
}

class _HourChart extends StatelessWidget {
  const _HourChart({required this.day});
  final DayTraffic day;

  @override
  Widget build(BuildContext context) {
    final max = math.max(1, [
      for (var hour = 0; hour < 24; hour++) day.hourUp[hour] + day.hourDown[hour],
    ].fold<int>(0, math.max));
    final primary = context.colorScheme.primary;
    final secondary = secondSeriesColor(context);
    return Column(children: [
      SizedBox(
        height: 90,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var hour = 0; hour < 24; hour++)
            Expanded(child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (day.hourUp[hour] > 0)
                  Container(height: math.max(1, day.hourUp[hour] / max * 44), color: secondary),
                if (day.hourDown[hour] > 0)
                  Container(height: math.max(1, day.hourDown[hour] / max * 44), color: primary),
              ]),
            )),
        ]),
      ),
      const SizedBox(height: 4),
      SizedBox(
        height: 14,
        child: Row(children: [
          for (var hour = 0; hour < 24; hour++)
            Expanded(child: Text(hour % 6 == 0 ? '$hour' : '', textAlign: TextAlign.center, style: context.listCaptionStyle)),
        ]),
      ),
    ]);
  }
}
