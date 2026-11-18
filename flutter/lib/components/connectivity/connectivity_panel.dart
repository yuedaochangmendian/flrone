import '../../widgets.dart';
import 'connectivity_avatar.dart';
import 'connectivity_page.dart';
import 'connectivity_store.dart';

/// The dashboard's compact connectivity card: the first pinned services with
/// their latest latency and a one-tap refresh. The full page is one tap away.
class ConnectivityPanel extends StatefulWidget {
  const ConnectivityPanel({super.key});
  @override State<ConnectivityPanel> createState() => _ConnectivityPanelState();
}

class _ConnectivityPanelState extends State<ConnectivityPanel> {
  static const _defaultPinned = ['openai', 'cloudflare', 'ehentai'];

  List<ConnectivityService> _pinned() {
    final saved = (context.box.preferences['connectivityPinned'] as List?)
        ?.whereType<String>()
        .map(connectivityService)
        .whereType<ConnectivityService>()
        .toList();
    final list = (saved == null || saved.isEmpty)
        ? _defaultPinned.map(connectivityService).whereType<ConnectivityService>().toList()
        : saved;
    return list.take(3).toList();
  }

  @override
  Widget build(BuildContext context) {
    final store = ConnectivityStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => BoxPanel(
        onTap: () => openPage(context, const ConnectivityPage()),
        radius: AppCorner.lg,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Column(children: [
          PanelTitle(
            'Connectivity test',
            AppGlyphs.link,
            trailing: SizedBox(
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
              onPressed: store.running ? null : store.runAll,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            height: 1,
            color: context.colorScheme.outlineVariant.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 4),
          for (final service in _pinned())
            _CompactRow(service: service, result: store.results[service.id]),
        ]),
      ),
    );
  }
}

class _CompactRow extends StatelessWidget {
  const _CompactRow({required this.service, required this.result});

  final ConnectivityService service;
  final ConnectivityResult? result;

  @override
  Widget build(BuildContext context) {
    final value = result ?? const ConnectivityResult();
    final active = value.status == ConnectivityStatus.testing;
    final progress = value.latencyMs <= 0 ? 0.0 : (value.latencyMs / 1500).clamp(0.04, 1.0);
    return SizedBox(
      height: 26,
      child: Row(children: [
        ConnectivityAvatar(service: service, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            service.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyle.caption1.of(context).copyWith(color: context.colorScheme.onSurface),
          ),
        ),
        const SizedBox(width: 8),
        _StatusDot(status: value.status),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              height: 5,
              color: context.colorScheme.primary.withValues(alpha: 0.12),
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: active ? 1 : progress,
                child: ColoredBox(color: context.colorScheme.primary),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 48,
          child: Text(
            active ? '…' : (value.latencyMs > 0 ? '${value.latencyMs}ms' : '—'),
            textAlign: TextAlign.right,
            style: AppTextStyle.caption1.of(context, emphasized: true).copyWith(color: context.colorScheme.onSurface),
          ),
        ),
      ]),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});
  final ConnectivityStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      ConnectivityStatus.completed => const Color(0xFF10B981),
      ConnectivityStatus.limited => const Color(0xFFF59E0B),
      ConnectivityStatus.blocked || ConnectivityStatus.failed => context.colorScheme.error,
      _ => context.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
    };
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
