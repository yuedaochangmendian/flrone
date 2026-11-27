import 'dart:math' as math;

import '../components/speed_gauge.dart';
import '../services/traffic_stats.dart';
import '../widgets.dart';
import 'network_toolbox.dart';

enum _Period { day, week, month }

/// Traffic statistics: the enable switch, day/week/month periods with date navigation, the
/// total ring with upload/download and the proxy/direct split, rule hits and the domain/node
/// ranking. The ledger is sampled from the core's totals and the host's attribution poller.
class TrafficStatsPage extends StatefulWidget {
  const TrafficStatsPage({super.key, this.ledger});

  /// Test seam; the app uses the store's live ledger.
  final TrafficLedger? ledger;

  @override State<TrafficStatsPage> createState() => _TrafficStatsPageState();
}

class _TrafficStatsPageState extends State<TrafficStatsPage> {
  _Period _period = _Period.day;
  DateTime _anchor = DateTime.now();
  bool _rankingNodes = false;

  TrafficStatsStore get _store => TrafficStatsStore.instance;
  TrafficLedger get _ledger => widget.ledger ?? _store.ledger;

  DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  (DateTime, DateTime) get _range {
    final anchor = DateTime(_anchor.year, _anchor.month, _anchor.day);
    return switch (_period) {
      _Period.day => (anchor, anchor),
      _Period.week => (
          anchor.subtract(Duration(days: anchor.weekday - 1)),
          anchor.add(Duration(days: 7 - anchor.weekday)),
        ),
      _Period.month => (
          DateTime(anchor.year, anchor.month, 1),
          DateTime(anchor.year, anchor.month + 1, 0),
        ),
    };
  }

  String get _title => switch (_period) {
        _Period.day => '${_anchor.year}-${_two(_anchor.month)}-${_two(_anchor.day)}',
        _Period.week => '${_two(_range.$1.month)}-${_two(_range.$1.day)} ~ ${_two(_range.$2.month)}-${_two(_range.$2.day)}',
        _Period.month => '${_anchor.year}-${_two(_anchor.month)}',
      };

  static String _two(int value) => value.toString().padLeft(2, '0');

  bool get _canGoForward => _range.$2.isBefore(_today);

  void _move(int direction) {
    setState(() {
      _anchor = switch (_period) {
        _Period.day => _anchor.add(Duration(days: direction)),
        _Period.week => _anchor.add(Duration(days: 7 * direction)),
        _Period.month => DateTime(_anchor.year, _anchor.month + direction, 1),
      };
    });
  }

  _Totals _totals() {
    final (from, to) = _range;
    final totals = _Totals();
    for (var day = from; !day.isAfter(to); day = day.add(const Duration(days: 1))) {
      final traffic = _ledger.day(day);
      if (traffic == null) continue;
      totals
        ..up += traffic.up
        ..down += traffic.down
        ..proxyUp += traffic.proxyUp
        ..proxyDown += traffic.proxyDown
        ..directUp += traffic.directUp
        ..directDown += traffic.directDown;
      totals.merge(totals.hosts, traffic.hosts);
      totals.merge(totals.nodes, traffic.nodes);
      totals.merge(totals.rules, traffic.rules);
    }
    return totals;
  }

  /// The ledger's switches moved to the network toolbox; the action opens them there.
  void _openToolbox() => openPage(context, const NetworkToolboxPage());

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _store,
      builder: (context, _) {
        final totals = _totals();
        final rules = totals.sorted(totals.rules);
        final ranking = totals.sorted(_rankingNodes ? totals.nodes : totals.hosts);
        return BoxPage(
          title: 'Traffic statistics',
          actions: [
            IconButtonData(glyph: AppGlyphs.settings, tooltip: context.tr('Settings'), onPressed: _openToolbox),
          ],
          children: [
            const SizedBox(height: 8),
            if (!_store.enabled) ...[
              _DisabledCard(onOpen: _openToolbox),
              const SizedBox(height: 16),
            ],
            SegmentedControl<_Period>(
              segments: [
                (_Period.day, context.tr('Today')),
                (_Period.week, context.tr('This week')),
                (_Period.month, context.tr('This month')),
              ],
              value: _period,
              onChanged: (value) => setState(() {
                _period = value;
                _anchor = DateTime.now();
              }),
            ),
            const SizedBox(height: 12),
            _DateNav(
              title: _title,
              onPrevious: () => _move(-1),
              onNext: _canGoForward ? () => _move(1) : null,
            ),
            const SizedBox(height: 12),
            _SummaryCard(totals: totals),
            const SizedBox(height: 20),
            Text(context.tr('Rule hits'), style: context.listTitleStyle),
            const SizedBox(height: 8),
            _RankingCard(
              entries: rules,
              empty: context.tr('No data'),
              icon: (_) => GlyphIcon(AppGlyphs.rules, size: 22, color: context.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            Text(context.tr('Ranking'), style: context.listTitleStyle),
            const SizedBox(height: 8),
            SegmentedControl<bool>(
              segments: [
                (false, context.tr('Domain')),
                (true, context.tr('Node')),
              ],
              value: _rankingNodes,
              onChanged: (value) => setState(() => _rankingNodes = value),
            ),
            const SizedBox(height: 8),
            _RankingCard(
              entries: ranking,
              empty: context.tr('No data'),
              icon: (name) => _rankingNodes
                  ? GlyphIcon(AppGlyphs.proxies, size: 22, color: context.colorScheme.onSurfaceVariant)
                  : _DomainIcon(domain: name, enabled: _store.webIcons),
            ),
          ],
        );
      },
    );
  }
}

class _Totals {
  int up = 0;
  int down = 0;
  int proxyUp = 0;
  int proxyDown = 0;
  int directUp = 0;
  int directDown = 0;
  final Map<String, TrafficSlice> hosts = {};
  final Map<String, TrafficSlice> nodes = {};
  final Map<String, TrafficSlice> rules = {};

  int get total => up + down;
  int get proxy => proxyUp + proxyDown;
  int get direct => directUp + directDown;

  void merge(Map<String, TrafficSlice> target, Map<String, TrafficSlice> source) {
    for (final entry in source.entries) {
      target.putIfAbsent(entry.key, TrafficSlice.new).add(entry.value.up, entry.value.down);
    }
  }

  List<MapEntry<String, TrafficSlice>> sorted(Map<String, TrafficSlice> map) =>
      map.entries.toList()..sort((a, b) => b.value.total.compareTo(a.value.total));
}

/// Recording is off: there is nothing to chart yet, and the switch that turns it on (with the
/// rest of the ledger's settings) is on the network toolbox now.
class _DisabledCard extends StatelessWidget {
  const _DisabledCard({required this.onOpen});
  final VoidCallback onOpen;

  @override Widget build(BuildContext context) => BoxPanel(
        child: ListItem(
          leading: const GlyphIcon(AppGlyphs.dataUsage, size: 22),
          title: Text(context.tr('Traffic statistics is off')),
          subtitle: Text(context.tr('Off by default; recording starts when enabled and stays on this device')),
          trailing: Text(
            context.tr('Open network toolbox'),
            style: AppTextStyle.footnote.of(context).copyWith(color: context.colorScheme.primary),
          ),
          onTap: onOpen,
        ),
      );
}

class _DateNav extends StatelessWidget {
  const _DateNav({required this.title, required this.onPrevious, required this.onNext});
  final String title;
  final VoidCallback onPrevious;
  final VoidCallback? onNext;

  @override Widget build(BuildContext context) => Row(children: [
        IconButton(
          tooltip: context.tr('Previous'),
          icon: const GlyphIcon(AppGlyphs.chevronBack, size: 20),
          onPressed: onPrevious,
        ),
        Expanded(child: Text(title, textAlign: TextAlign.center, style: AppTextStyle.headline.of(context, emphasized: true).toTabular)),
        IconButton(
          tooltip: context.tr('Next'),
          icon: const GlyphIcon(AppGlyphs.chevronForward, size: 20),
          onPressed: onNext,
        ),
      ]);
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.totals});
  final _Totals totals;

  @override Widget build(BuildContext context) {
    return BoxPanel(child: Row(children: [
      _TotalRing(proxy: totals.proxy, direct: totals.direct),
      const SizedBox(width: 20),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _SummaryRow(label: context.tr('Upload'), value: totals.up, color: secondSeriesColor(context)),
          const SizedBox(height: 10),
          _SummaryRow(label: context.tr('Download'), value: totals.down, color: context.colorScheme.primary),
          const SizedBox(height: 14),
          Text(
            '${context.tr('Proxy')} ${bytes(totals.proxy)} · ${context.tr('Direct')} ${bytes(totals.direct)}',
            style: context.listCaptionStyle,
          ),
        ]),
      ),
    ]));
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value, required this.color});
  final String label;
  final int value;
  final Color color;

  @override Widget build(BuildContext context) => Row(children: [
        DecoratedBox(decoration: ShapeDecoration(color: color, shape: AppShape.circle), child: const SizedBox.square(dimension: 8)),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: context.listSubtitleStyle)),
        Text(bytes(value), style: AppTextStyle.footnote.of(context, emphasized: true).toTabular),
      ]);
}

class _TotalRing extends StatelessWidget {
  const _TotalRing({required this.proxy, required this.direct});
  final int proxy;
  final int direct;

  @override Widget build(BuildContext context) {
    final total = proxy + direct;
    final value = bytes(total).split(' ');
    final size = 132.0;
    return SizedBox.square(
      dimension: size,
      child: Stack(alignment: Alignment.center, children: [
        CustomPaint(
          size: Size.square(size),
          painter: _RingPainter(
            track: SurfaceLevel.inset.colorOf(context.colorScheme),
            primary: context.colorScheme.primary,
            secondary: secondSeriesColor(context),
            proxyFraction: total == 0 ? 0 : proxy / total,
            directFraction: total == 0 ? 0 : direct / total,
          ),
        ),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Text(value.first, style: AppTextStyle.title1.of(context, emphasized: true).toTabular),
          Text(value.last, style: AppTextStyle.footnote.of(context).copyWith(color: context.colorScheme.onSurfaceVariant)),
        ]),
      ]),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.track,
    required this.primary,
    required this.secondary,
    required this.proxyFraction,
    required this.directFraction,
  });

  final Color track;
  final Color primary;
  final Color secondary;
  final double proxyFraction;
  final double directFraction;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width / 16;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: size.width / 2 - stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint);
    if (proxyFraction <= 0 && directFraction <= 0) return;
    const start = -math.pi / 2;
    final proxySweep = math.pi * 2 * proxyFraction;
    final directSweep = math.pi * 2 * directFraction;
    canvas.drawArc(rect, start, proxySweep, false, paint..color = primary);
    canvas.drawArc(rect, start + proxySweep, directSweep, false, paint..color = secondary);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.proxyFraction != proxyFraction ||
      old.directFraction != directFraction ||
      old.track != track ||
      old.primary != primary ||
      old.secondary != secondary;
}

class _RankingCard extends StatelessWidget {
  const _RankingCard({required this.entries, required this.empty, required this.icon});
  final List<MapEntry<String, TrafficSlice>> entries;
  final String empty;
  final Widget Function(String name) icon;

  @override Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return BoxPanel(child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(child: Text(empty, style: context.listCaptionStyle)),
      ));
    }
    return generateSection(
      items: [
        for (final entry in entries.take(10))
          ListItem(
            leading: icon(entry.key),
            title: Text(entry.key, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Text(bytes(entry.value.total), style: context.listValueStyle.toTabular),
          ),
      ],
    );
  }
}

class _DomainIcon extends StatelessWidget {
  const _DomainIcon({required this.domain, required this.enabled});
  final String domain;
  final bool enabled;

  @override Widget build(BuildContext context) {
    // 6dp on a 24px favicon sits between AppCorner.xs/sm; kept so the icon and its
    // fallback stay visually matched, not an intended new token.
    final fallback = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: ColoredBox(
        color: SurfaceLevel.inset.colorOf(context.colorScheme),
        child: SizedBox.square(
          dimension: 24,
          child: Center(child: Text(domain.isEmpty ? '?' : domain.characters.first.toUpperCase(), style: context.listCaptionStyle)),
        ),
      ),
    );
    if (!enabled || !domain.contains('.')) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        'https://www.google.com/s2/favicons?domain=${Uri.encodeComponent(domain)}&sz=64',
        width: 24,
        height: 24,
        cacheWidth: 48,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}
