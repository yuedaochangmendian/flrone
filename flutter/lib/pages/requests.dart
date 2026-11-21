import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../app/l10n.dart';
import '../box.dart';
import '../components/dashboard_common.dart';
import '../providers/box_providers.dart';
import '../ui/icons/icons.dart';
import '../ui/scaffold/scaffold.dart';

class RequestsPage extends ConsumerStatefulWidget {
  const RequestsPage({super.key});

  @override
  ConsumerState<RequestsPage> createState() => _RequestsPageState();
}

class _RequestsPageState extends ConsumerState<RequestsPage> {
  var _showClosed = false;
  BoxController? _box;

  @override
  void initState() {
    super.initState();
    _box = ref.read(boxControllerProvider);
    _box!.connectionsSetVisible(true);
  }

  @override
  void dispose() {
    _box?.connectionsSetVisible(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = ref.watch(boxStateProvider);
    final all = ref.watch(connectionsProvider);
    final list = all.where((connection) {
      final closed = ((connection['closedAt'] as num?)?.toInt() ?? 0) > 0;
      return _showClosed ? true : !closed;
    }).toList();
    return Scaffold(
      title: context.tr('Requests'),
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.clearAll,
          tooltip: context.tr('Close all'),
          onPressed: box.running ? box.connectionsCloseAll : null,
        ),
      ],
      menuItems: [
        PopupMenuItem(
          label: context.tr('Closed'),
          checked: _showClosed,
          onPressed: () => setState(() => _showClosed = !_showClosed),
        ),
      ],
      body: ListView.builder(
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          24 + context.bottomInset,
        ),
        itemCount: list.length,
        itemBuilder: (context, index) {
          final connection = list[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ConnectionCard(connection: connection),
          );
        },
      ),
    );
  }
}

class _ConnectionCard extends ConsumerWidget {
  const _ConnectionCard({required this.connection});

  final Json connection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.colorScheme;
    final closed = ((connection['closedAt'] as num?)?.toInt() ?? 0) > 0;
    return PressSurface(
      fill: SurfaceLevel.card.colorOf(scheme),
      shape: AppShape.all(AppCorner.lg),
      onPressed: () => _details(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Row(
              spacing: 8,
              children: [
                Expanded(
                  child: Text(
                    connection['displayDestination']?.toString() ??
                        connection['destination']?.toString() ??
                        '—',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.subheadline.of(
                      context,
                      emphasized: true,
                    ),
                  ),
                ),
                if (closed)
                  DashboardChip(label: context.tr('Closed'))
                else
                  DashboardChip(
                    label: connection['network']?.toString() ?? 'tcp',
                  ),
                if (!closed)
                  DashboardIconButton(
                    glyph: AppGlyphs.block,
                    tooltip: context.tr('Close'),
                    onPressed: () => ref
                        .read(boxControllerProvider)
                        .connectionsClose(connection['id']),
                  ),
              ],
            ),
            Row(
              spacing: 6,
              children: [
                if ((connection['rule']?.toString() ?? '').isNotEmpty) ...[
                  Flexible(
                    child: Text(
                      connection['rule'].toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.caption1
                          .of(context)
                          .copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  GlyphIcon(
                    AppGlyphs.chevronForward,
                    size: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
                Text(
                  connection['outbound']?.toString() ?? '—',
                  style: AppTextStyle.caption1
                      .of(context)
                      .copyWith(color: scheme.primary),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    connection['source']?.toString() ?? '—',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.caption2
                        .of(context)
                        .copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                Text(
                  '↑ ${formatBytes((connection['uploadTotal'] as num?) ?? 0)}  ↓ ${formatBytes((connection['downloadTotal'] as num?) ?? 0)}',
                  style: AppTextStyle.caption2
                      .of(context)
                      .copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _details(BuildContext context) {
    final values = <String, String>{
      'Host':
          connection['displayDestination']?.toString() ??
          connection['destination']?.toString() ??
          '—',
      'Source': connection['source']?.toString() ?? '—',
      'Network': connection['network']?.toString() ?? '—',
      'Protocol': connection['protocol']?.toString() ?? '—',
      'Rule': connection['rule']?.toString() ?? '—',
      'Outbound': connection['outbound']?.toString() ?? '—',
      'Upload': formatBytes((connection['uploadTotal'] as num?) ?? 0),
      'Download': formatBytes((connection['downloadTotal'] as num?) ?? 0),
    };
    return showSheet<void>(
      context: context,
      builder: (context) => Surface(
        color: SurfaceLevel.page.colorOf(context.colorScheme),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                Text(
                  values['Host']!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.title3.of(context, emphasized: true),
                ),
                const SizedBox(height: 4),
                for (final entry in values.entries.skip(1))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 96,
                          child: Text(
                            entry.key,
                            style: AppTextStyle.caption1
                                .of(context)
                                .copyWith(
                                  color: context.colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            entry.value,
                            style: AppTextStyle.footnote.of(context),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
