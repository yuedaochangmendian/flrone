import '../../widgets.dart';
import 'connectivity_avatar.dart';
import 'connectivity_settings_page.dart';
import 'connectivity_store.dart';

/// The Bettbox-style connectivity page: a summary, category chips and the
/// services grouped by whether the current exit can reach them.
class ConnectivityPage extends StatefulWidget {
  const ConnectivityPage({super.key});
  @override State<ConnectivityPage> createState() => _ConnectivityPageState();
}

class _ConnectivityPageState extends State<ConnectivityPage> {
  ConnectivityCategory? _category;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final prefs = context.box.preferences;
    ConnectivityStore.instance
        .setIncludeMoreStreaming(prefs['connectivityMoreStreaming'] == true);
    final saved = (prefs['connectivityCategories'] as List?)?.whereType<String>().toSet();
    if (saved != null && saved.isNotEmpty) {
      ConnectivityStore.instance.setCategories({
        for (final category in ConnectivityCategory.values)
          if (saved.contains(category.name)) category,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = ConnectivityStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final isChinese = Localizations.localeOf(context).languageCode == 'zh';
        final services = connectivityServices
            .where((service) => store.categories.contains(service.category))
            .where((service) =>
                store.includeMoreStreaming || !connectivityMoreStreaming.contains(service.id))
            .where((service) => isChinese || service.category != ConnectivityCategory.china)
            .where((service) => _category == null || service.category == _category)
            .toList();
        ConnectivityResult resultOf(ConnectivityService service) =>
            store.results[service.id] ?? const ConnectivityResult();
        // Bettbox's buckets exactly: unlocked; blocked + failed; everything else
        // (limited, flagged, testing, unknown).
        final completed = services
            .where((service) => resultOf(service).status == ConnectivityStatus.completed)
            .toList();
        final blocked = services
            .where((service) {
              final status = resultOf(service).status;
              return status == ConnectivityStatus.blocked || status == ConnectivityStatus.failed;
            })
            .toList();
        final other = services
            .where((service) {
              final status = resultOf(service).status;
              return status != ConnectivityStatus.completed &&
                  status != ConnectivityStatus.blocked &&
                  status != ConnectivityStatus.failed;
            })
            .toList();
        final streamingGroup = _category == ConnectivityCategory.streaming;
        return BoxPage(
          title: 'Connectivity test',
          actions: [
            IconButtonData(
              glyph: AppGlyphs.settings,
              tooltip: context.tr('Connectivity settings'),
              onPressed: () => openPage(context, const ConnectivitySettingsPage()),
            ),
            IconButtonData(
              glyph: AppGlyphs.refresh,
              tooltip: context.tr('Refresh'),
              onPressed: store.running
                  ? null
                  : () => store.runAll(ids: services.map((service) => service.id).toList()),
            ),
          ],
          children: [
            _SummaryPanel(
              completed: completed.length,
              blocked: blocked.length,
              other: other.length,
              streamingGroup: streamingGroup,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(spacing: 8, children: [
                  _categoryChip(null, context.tr('All')),
                  for (final category in ConnectivityCategory.values)
                    _categoryChip(category, context.tr(_categoryLabel(category))),
                ]),
              ),
            ),
            if (services.isEmpty)
              const EmptyState('No services selected')
            else ...[
              if (completed.isNotEmpty)
                _group(
                  context.tr(streamingGroup ? 'Unlocked' : 'Completed'),
                  AppGlyphs.checkCircle,
                  const Color(0xFF10B981),
                  completed,
                  resultOf,
                ),
              if (blocked.isNotEmpty)
                _group(context.tr('Not unlocked'), AppGlyphs.close, context.colorScheme.error,
                  blocked, resultOf),
              if (other.isNotEmpty)
                _group(context.tr('Other'), AppGlyphs.info, const Color(0xFFF59E0B),
                  other, resultOf),
            ],
          ],
        );
      },
    );
  }

  Widget _categoryChip(ConnectivityCategory? category, String label) {
    final selected = _category == category;
    return FilterChip(
      selected: selected,
      showCheckmark: false,
      label: Text(label),
      labelStyle: TextStyle(
        color: selected ? context.colorScheme.onPrimary : context.colorScheme.onSurfaceVariant,
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
      ),
      selectedColor: context.colorScheme.primary,
      backgroundColor: context.colorScheme.surfaceContainerHigh,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onSelected: (_) => setState(() => _category = category),
    );
  }

  Widget _group(
    String title,
    Glyph glyph,
    Color accent,
    List<ConnectivityService> services,
    ConnectivityResult Function(ConnectivityService) resultOf,
  ) {
    final count = services.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Row(children: [
            GlyphIcon(glyph, size: 16, color: accent),
            const SizedBox(width: 6),
            Text(
              '$title ($count)',
              style: AppTextStyle.subheadline.of(context, emphasized: true).copyWith(color: accent),
            ),
          ]),
        ),
        for (final service in services)
          _ServiceRow(service: service, result: resultOf(service)),
        const SizedBox(height: 6),
      ],
    );
  }

  static String _categoryLabel(ConnectivityCategory category) => switch (category) {
    ConnectivityCategory.ai => 'AI',
    ConnectivityCategory.streaming => 'Streaming',
    ConnectivityCategory.china => 'China direct',
    ConnectivityCategory.social => 'Social',
    ConnectivityCategory.developer => 'Developer',
    ConnectivityCategory.gaming => 'Gaming',
    ConnectivityCategory.crypto => 'Crypto',
  };
}

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({
    required this.completed,
    required this.blocked,
    required this.other,
    required this.streamingGroup,
  });
  final int completed;
  final int blocked;
  final int other;
  final bool streamingGroup;

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    final line = context.colorScheme.outlineVariant.withValues(alpha: light ? 0.45 : 0.25);
    return Container(
      margin: const EdgeInsets.only(top: 12, bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: light ? context.colorScheme.surfaceContainerLowest : context.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: line),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
        Expanded(child: _stat(
          context,
          context.tr(streamingGroup ? 'Unlocked' : 'Completed'),
          completed,
          const Color(0xFF10B981),
        )),
        Container(width: 1, height: 24, color: line),
        Expanded(child: _stat(context, context.tr('Not unlocked'), blocked, context.colorScheme.error)),
        Container(width: 1, height: 24, color: line),
        Expanded(child: _stat(context, context.tr('Other'), other, const Color(0xFFF59E0B))),
      ]),
    );
  }

  Widget _stat(BuildContext context, String label, int value, Color color) => Column(children: [
    Text(
      '$value',
      style: AppTextStyle.title3.of(context).copyWith(
        color: color,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
    const SizedBox(height: 2),
    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
      style: AppTextStyle.caption2.of(context).copyWith(color: context.colorScheme.onSurfaceVariant)),
  ]);
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({required this.service, required this.result});
  final ConnectivityService service;
  final ConnectivityResult result;

  @override
  Widget build(BuildContext context) {
    final testing = ConnectivityStore.instance.isTesting(service.id);
    final latency = result.latencyMs > 0 ? '${result.latencyMs}ms' : '';
    final flag = connectivityFlag(result.region);
    final detail = [
      if (testing) context.tr('Testing…') else if (latency.isNotEmpty) latency else result.error,
    ].where((part) => part.isNotEmpty).join(' · ');
    final light = Theme.of(context).brightness == Brightness.light;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: light ? context.colorScheme.surfaceContainerLowest : context.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: light ? context.colorScheme.surfaceContainer : context.colorScheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: ConnectivityAvatar(service: service, size: 25),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(
                service.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.callout.of(context, emphasized: true),
              ),
              if (flag.isNotEmpty || detail.isNotEmpty) ...[
                const SizedBox(height: 2),
                Row(children: [
                  if (flag.isNotEmpty) ...[
                    Text(flag, style: const TextStyle(fontSize: 11)),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.caption2
                          .of(context)
                          .copyWith(color: context.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ]),
              ],
            ]),
          ),
          _StatusBadge(status: result.status),
          const SizedBox(width: 8),
          SizedBox(
            width: 32,
            height: 32,
            child: IconButton(
              tooltip: context.tr('Retry'),
              padding: EdgeInsets.zero,
              icon: testing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const GlyphIcon(AppGlyphs.refresh, size: 18),
              onPressed: testing ? null : () => ConnectivityStore.instance.runOne(service.id),
            ),
          ),
        ]),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final ConnectivityStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ConnectivityStatus.completed => ('Completed', const Color(0xFF10B981)),
      ConnectivityStatus.limited => ('Limited', const Color(0xFFF59E0B)),
      ConnectivityStatus.flagged => ('Flagged', const Color(0xFFF59E0B)),
      ConnectivityStatus.blocked => ('Not unlocked', const Color(0xFFEF4444)),
      ConnectivityStatus.failed => ('Failed', context.colorScheme.error),
      ConnectivityStatus.testing => ('Testing…', context.colorScheme.primary),
      ConnectivityStatus.unknown => ('—', context.colorScheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(
          context.tr(label),
          style: AppTextStyle.caption2.of(context).copyWith(color: color, fontWeight: FontWeight.w700),
        ),
      ]),
    );
  }
}
