import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/box_providers.dart';
import '../../widgets.dart';
import 'connectivity_avatar.dart';
import 'connectivity_page.dart';
import 'connectivity_store.dart';
import '../dashboard_chip.dart';

/// The dashboard's service-status card, in FlClash's layout: a header with the verdict and a
/// refresh button, then a two-column grid of the pinned services. Each cell carries the
/// service's own artwork, its name and its latest result (latency, or the limited/failed label).
class ConnectivityPanel extends ConsumerStatefulWidget {
  const ConnectivityPanel({super.key});
  @override ConsumerState<ConnectivityPanel> createState() => _ConnectivityPanelState();
}

class _ConnectivityPanelState extends ConsumerState<ConnectivityPanel> {
  static const _defaultPinned = ['openai', 'cloudflare', 'ehentai'];

  /// Two columns, two rows: what the card can show without turning into the full page.
  static const _maxPinned = 4;

  List<ConnectivityService> _pinned(Json prefs) {
    final saved = (prefs['connectivityPinned'] as List?)
        ?.whereType<String>()
        .map(connectivityService)
        .whereType<ConnectivityService>()
        .toList();
    final list = (saved == null || saved.isEmpty)
        ? _defaultPinned.map(connectivityService).whereType<ConnectivityService>().toList()
        : saved;
    return list.take(_maxPinned).toList();
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(connectivityStoreProvider);
    final prefs = ref.watch(preferencesProvider);
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final services = _pinned(prefs);
        final results = <String, ConnectivityResult?>{
          for (final service in services) service.id: store.results[service.id],
        };
        final ready = results.values
            .whereType<ConnectivityResult>()
            .where((result) =>
                result.status != ConnectivityStatus.unknown &&
                result.status != ConnectivityStatus.testing)
            .toList();
        final problems = ready.where((result) => result.status != ConnectivityStatus.completed).length;
        final verdict = problems > 0
            ? DashboardChip(
                label: '$problems ${context.tr('checks failed')}',
                tone: DashboardChipTone.warn,
              )
            : services.isNotEmpty && ready.length == services.length
                ? DashboardChip(label: context.tr('All available'), tone: DashboardChipTone.ok)
                : null;
        return BoxPanel(
          onTap: () => openPage(context, const ConnectivityPage()),
          radius: AppCorner.lg,
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PanelTitle(
              'Service status',
              AppGlyphs.verified,
              trailing: Row(mainAxisSize: MainAxisSize.min, spacing: 2, children: [
                ?verdict,
                SizedBox(
                  width: 30,
                  height: 26,
                  child: IconButton(
                    tooltip: context.tr('Refresh'),
                    padding: EdgeInsets.zero,
                    icon: store.running
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const GlyphIcon(AppGlyphs.refresh, size: 19),
                    onPressed: store.running
                        ? null
                        : () => store.runAll(
                              ids: services.map((service) => service.id).toList(),
                            ),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            _ServiceGrid(services: services, results: results),
          ]),
        );
      },
    );
  }
}

class _ServiceGrid extends StatelessWidget {
  const _ServiceGrid({required this.services, required this.results});

  final List<ConnectivityService> services;
  final Map<String, ConnectivityResult?> results;

  @override
  Widget build(BuildContext context) {
    const gap = 8.0;
    return Column(spacing: gap, children: [
      for (var start = 0; start < services.length; start += 2)
        Row(spacing: gap, children: [
          for (final service in services.skip(start).take(2))
            Expanded(child: _ServiceCell(service: service, result: results[service.id])),
          // An odd last row keeps its cell at half width, like the grid above it.
          if (start + 1 >= services.length) const Expanded(child: SizedBox.shrink()),
        ]),
    ]);
  }
}

class _ServiceCell extends StatelessWidget {
  const _ServiceCell({required this.service, required this.result});

  final ConnectivityService service;
  final ConnectivityResult? result;

  @override
  Widget build(BuildContext context) {
    final value = result ?? const ConnectivityResult();
    final (label, color) = switch (value.status) {
      ConnectivityStatus.completed => (
          value.latencyMs > 0 ? '${value.latencyMs} ms' : context.tr('Completed'),
          context.colorScheme.onSurfaceVariant,
        ),
      ConnectivityStatus.limited => (context.tr('Limited'), const Color(0xFFF59E0B)),
      ConnectivityStatus.flagged => (context.tr('Flagged'), const Color(0xFFF59E0B)),
      ConnectivityStatus.blocked => (context.tr('Not unlocked'), context.colorScheme.error),
      ConnectivityStatus.failed => (context.tr('Failed'), context.colorScheme.error),
      ConnectivityStatus.testing => ('…', context.colorScheme.primary),
      ConnectivityStatus.unknown => ('—', context.colorScheme.onSurfaceVariant),
    };
    return Tooltip(
      message: '${service.name}\n$label',
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: ShapeDecoration(
          color: SurfaceLevel.block.colorOf(context.colorScheme),
          shape: AppShape.all(AppCorner.md),
        ),
        child: Row(spacing: 8, children: [
          ConnectivityAvatar(service: service, size: 24),
          Expanded(
            child: Text(
              service.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.caption1.of(context).copyWith(color: context.colorScheme.onSurface),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            maxLines: 1,
            style: AppTextStyle.caption1.of(context, emphasized: true).toTabular.copyWith(color: color),
          ),
        ]),
      ),
    );
  }
}
