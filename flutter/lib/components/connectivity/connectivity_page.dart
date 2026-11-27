import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/box_providers.dart';
import '../../widgets.dart';
import 'connectivity_avatar.dart';
import 'connectivity_settings_page.dart';
import 'connectivity_store.dart';

/// The Bettbox-style connectivity page: a summary, category chips and the
/// services grouped by whether the current exit can reach them.
///
/// Riverpod pilot: a read-only consumer. [connectivityStoreProvider] exposes
/// the very [ConnectivityStore.instance] the store methods mutate; the page
/// reads it via `ref.watch` and rebuilds on the store's own notifications.
/// Writes still go through the store's methods, so Riverpod never becomes a
/// second writer.
class ConnectivityPage extends ConsumerStatefulWidget {
  const ConnectivityPage({super.key});
  @override ConsumerState<ConnectivityPage> createState() => _ConnectivityPageState();
}

class _ConnectivityPageState extends ConsumerState<ConnectivityPage> {
  ConnectivityCategory? _category;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final prefs = ref.read(preferencesProvider);
    // Read the same store instance the provider exposes, then call its own
    // mutators. This is a write through the store, never a write to Riverpod.
    final store = ref.read(connectivityStoreProvider);
    store.setIncludeMoreStreaming(prefs['connectivityMoreStreaming'] == true);
    final saved = (prefs['connectivityCategories'] as List?)?.whereType<String>().toSet();
    if (saved != null && saved.isNotEmpty) {
      store.setCategories({
        for (final category in ConnectivityCategory.values)
          if (saved.contains(category.name)) category,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Read the single store instance from the provider. Rebuilds come from the
    // store's own notifications (via AnimatedBuilder), so no state is duplicated
    // into Riverpod and nothing is ever written back to it.
    final store = ref.watch(connectivityStoreProvider);
    // Only the service mode decides whether the proxy-only notice is shown.
    // Watching the whole box state rebuilt this page on every unrelated state
    // event; the narrow provider rebuilds only when that one string changes.
    final proxyOnly = ref.watch(serviceModeProvider) == 'proxy';
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => _buildPage(context, store, proxyOnly),
    );
  }

  Widget _buildPage(BuildContext context, ConnectivityStore store, bool proxyOnly) {
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
          // A full page like every other settings screen, not the sheet
          // transition openPage uses: the sheet's floating back button did not
          // match the parent page's bar.
          onPressed: () => BaseNavigator.push(context, const ConnectivitySettingsPage()),
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
        // The probe process rides the tunnel only in VPN mode; in proxy-only
        // mode nothing routes it through the proxy, so say what the cards mean.
        if (proxyOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              context.tr(
                'In proxy-only mode the probes leave this device directly; the results do not reflect the tunnel exit.',
              ),
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
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
              context.colorScheme.success,
              completed,
              resultOf,
            ),
          if (blocked.isNotEmpty)
            _group(context.tr('Not unlocked'), AppGlyphs.close, context.colorScheme.error,
              blocked, resultOf),
          if (other.isNotEmpty)
            _group(context.tr('Other'), AppGlyphs.info, context.colorScheme.warning,
              other, resultOf),
        ],
      ],
    );
  }

  Widget _categoryChip(ConnectivityCategory? category, String label) {
    return Chip(
      label: label,
      selected: _category == category,
      onPressed: () => setState(() => _category = category),
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
        borderRadius: BorderRadius.circular(AppCorner.lg),
        border: Border.all(color: line),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
        Expanded(child: _stat(
          context,
          context.tr(streamingGroup ? 'Unlocked' : 'Completed'),
          completed,
          context.colorScheme.success,
        )),
        Container(width: 1, height: 24, color: line),
        Expanded(child: _stat(context, context.tr('Not unlocked'), blocked, context.colorScheme.error)),
        Container(width: 1, height: 24, color: line),
        Expanded(child: _stat(context, context.tr('Other'), other, context.colorScheme.warning)),
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

class _ServiceRow extends ConsumerWidget {
  const _ServiceRow({required this.service, required this.result});
  final ConnectivityService service;
  final ConnectivityResult result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final testing = ref.watch(connectivityStoreProvider).isTesting(service.id);
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
          borderRadius: BorderRadius.circular(AppCorner.md),
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
              onPressed: testing ? null : () => ref.read(connectivityStoreProvider).runOne(service.id),
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
      ConnectivityStatus.completed => ('Completed', context.colorScheme.success),
      ConnectivityStatus.limited => ('Limited', context.colorScheme.warning),
      ConnectivityStatus.flagged => ('Flagged', context.colorScheme.warning),
      ConnectivityStatus.blocked => ('Not unlocked', context.colorScheme.error),
      ConnectivityStatus.failed => ('Failed', context.colorScheme.error),
      ConnectivityStatus.testing => ('Testing…', context.colorScheme.primary),
      ConnectivityStatus.unknown => ('—', context.colorScheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppCorner.sm),
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
