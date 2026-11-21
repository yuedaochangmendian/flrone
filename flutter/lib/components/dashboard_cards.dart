import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../app/l10n.dart';
import '../box.dart';
import '../providers/box_providers.dart';
import '../ui/icons/icons.dart';
import 'dashboard_common.dart';
import 'pickers.dart';

class TrafficCard extends ConsumerWidget {
  const TrafficCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final traffic = ref.watch(trafficProvider);
    final box = ref.read(boxControllerProvider);
    final scheme = context.colorScheme;
    final second = Color.alphaBlend(
      scheme.primary.withValues(alpha: 0.45),
      SurfaceLevel.card.colorOf(scheme),
    );
    final up = (traffic.rates['upload'] as num?)?.toDouble();
    final down = (traffic.rates['download'] as num?)?.toDouble();
    return DashboardCard(
      padding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      semanticLabel: context.tr('Network speed'),
      child: SizedBox(
        height: 196,
        child: Stack(
          children: [
            Positioned(
              left: -2,
              right: -2,
              bottom: -2,
              height: 86,
              child: RepaintBoundary(
                child: LineChart(
                  values: box.downloadHistory,
                  revision: traffic.revision,
                  capacity: BoxController.trafficWindow,
                  minScale: 8 * 1024,
                  baselineRatio: 1,
                  color: scheme.primary,
                ),
              ),
            ),
            Positioned(
              left: -2,
              right: -2,
              bottom: 76,
              height: 74,
              child: RepaintBoundary(
                child: LineChart(
                  values: box.uploadHistory,
                  revision: traffic.revision,
                  capacity: BoxController.trafficWindow,
                  minScale: 8 * 1024,
                  baselineRatio: 1,
                  color: second,
                ),
              ),
            ),
            Padding(
              padding: dashboardPadding(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DashboardHeader(
                    glyph: AppGlyphs.speed,
                    title: context.tr('Network speed'),
                    trailing: [
                      Text(
                        '${formatRate(box.downloadHistory.isEmpty ? 0 : box.downloadHistory.last)} ↓',
                        style: AppTextStyle.caption1
                            .of(context)
                            .copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: _Rate(
                          label: context.tr('Download'),
                          value: down,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _Rate(
                          label: context.tr('Upload'),
                          value: up,
                          color: second,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Rate extends StatelessWidget {
  const _Rate({required this.label, required this.value, required this.color});

  final String label;
  final double? value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: [
        Row(
          spacing: 5,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            Text(
              label,
              style: AppTextStyle.caption1
                  .of(context)
                  .copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        Text(
          value == null ? '—' : formatRate(value!),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyle.title2
              .of(context, emphasized: true)
              .copyWith(
                color: scheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
        ),
      ],
    );
  }
}

class ProfileCard extends ConsumerWidget {
  const ProfileCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(boxStateProvider);
    final profile = box.selectedProfile;
    final scheme = context.colorScheme;
    final remote = profile?['remote'] == true;
    return DashboardCard(
      semanticLabel: context.tr('Current profile'),
      onTap: () => showProfilePicker(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashboardHeader(
            glyph: AppGlyphs.profiles,
            title: context.tr('Current profile'),
            trailing: [
              DashboardIconButton(
                glyph: AppGlyphs.swap,
                tooltip: context.tr('Switch profile'),
                onPressed: () => showProfilePicker(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            profile?['name']?.toString() ??
                profile?['label']?.toString() ??
                context.tr('No profile'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyle.title3
                .of(context, emphasized: true)
                .copyWith(color: scheme.onSurface),
          ),
          const SizedBox(height: 4),
          Row(
            spacing: 8,
            children: [
              DashboardChip(
                label: remote
                    ? 'Remote'
                    : (profile?['type']?.toString() ?? 'Local'),
              ),
              if (profile?['lastUpdate'] case final update?)
                Expanded(
                  child: Text(
                    'Updated ${_ago(update)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.caption1
                        .of(context)
                        .copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _ago(Object update) {
  final value = update is num
      ? (update > 100000000000 ? update ~/ 1000 : update)
      : 0;
  final time = DateTime.fromMillisecondsSinceEpoch((value * 1000).toInt());
  final diff = DateTime.now().difference(time);
  if (diff.inDays > 0) return '${diff.inDays}d ago';
  if (diff.inHours > 0) return '${diff.inHours}h ago';
  return '${diff.inMinutes}m ago';
}

class ProxyGroupsCard extends ConsumerWidget {
  const ProxyGroupsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsProvider);
    final visible = groups.where((group) => group['items'] is List).toList();
    final scheme = context.colorScheme;
    return DashboardCard(
      semanticLabel: context.tr('Proxy groups'),
      onTap: visible.isEmpty ? null : () => showGroupsSheet(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashboardHeader(
            glyph: AppGlyphs.nodeGroup,
            title: context.tr('Proxy groups'),
            trailing: [
              DashboardChip(
                label: '${visible.length}',
                tone: visible.isEmpty
                    ? DashboardChipTone.idle
                    : DashboardChipTone.ok,
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (visible.isEmpty)
            Text(
              context.tr('No proxy groups'),
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: scheme.onSurfaceVariant),
            )
          else
            for (final group in visible.take(3))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        group['tag']?.toString() ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyle.footnote
                            .of(context)
                            .copyWith(color: scheme.onSurface),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      flex: 2,
                      child: Text(
                        group['selected']?.toString() ?? '—',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: AppTextStyle.caption1
                            .of(context)
                            .copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
          if (visible.length > 3)
            Text(
              '+${visible.length - 3}',
              style: AppTextStyle.caption1
                  .of(context)
                  .copyWith(color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

class ModeCard extends ConsumerWidget {
  const ModeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(boxStateProvider);
    final modes = (box.dashboard['modes'] as List? ?? const [])
        .whereType<String>()
        .toList();
    if (modes.isEmpty) return const SizedBox.shrink();
    final current = box.dashboard['mode']?.toString().toLowerCase() ?? '';
    return DashboardCard(
      semanticLabel: context.tr('Outbound mode'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashboardHeader(
            glyph: AppGlyphs.split,
            title: context.tr('Outbound mode'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final (index, mode) in modes.indexed)
                Expanded(
                  child: Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: index == 0 ? 0 : 4,
                      end: index == modes.length - 1 ? 0 : 4,
                    ),
                    child: _ModeButton(
                      label: _modeLabel(context, mode),
                      selected: mode.toLowerCase() == current,
                      onTap: () => box.modeSet(mode),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _modeLabel(BuildContext context, String mode) {
    return switch (mode.toLowerCase()) {
      'rule' => context.tr('Rule'),
      'global' => context.tr('Global'),
      'direct' => context.tr('Direct'),
      _ => mode,
    };
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return PressSurface(
      fill: selected ? scheme.primary : SurfaceLevel.block.colorOf(scheme),
      shape: AppShape.all(AppCorner.md),
      onPressed: onTap,
      child: SizedBox(
        height: 50,
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyle.footnote
                .of(context, emphasized: true)
                .copyWith(
                  color: selected ? scheme.onPrimary : scheme.onSurface,
                ),
          ),
        ),
      ),
    );
  }
}

class MemoryCard extends ConsumerWidget {
  const MemoryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memory = ref.watch(memoryProvider);
    final scheme = context.colorScheme;
    final rss = (memory['rss'] as num?) ?? 0;
    final app = (memory['app'] as num?) ?? 0;
    final core = (memory['core'] as num?) ?? 0;
    final other = (memory['other'] as num?) ?? 0;
    final total = math.max(rss, app + core + other);
    return DashboardCard(
      semanticLabel: context.tr('Memory'),
      onTap: () => boxRelease(context, ref),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashboardHeader(
            glyph: AppGlyphs.memory,
            title: context.tr('Memory'),
            trailing: [
              DashboardIconButton(
                glyph: AppGlyphs.broom,
                tooltip: 'Release memory',
                onPressed: () => boxRelease(context, ref),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            total == 0 ? '—' : formatBytes(total),
            style: AppTextStyle.title2
                .of(context, emphasized: true)
                .copyWith(color: scheme.onSurface),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: SizedBox(
              height: 8,
              child: Row(
                children: [
                  if (app > 0)
                    Expanded(
                      flex: math.max(1, (app * 100 ~/ math.max(1, total))),
                      child: ColoredBox(color: scheme.primary),
                    ),
                  if (core > 0)
                    Expanded(
                      flex: math.max(1, (core * 100 ~/ math.max(1, total))),
                      child: ColoredBox(
                        color: Color.alphaBlend(
                          scheme.primary.withValues(alpha: 0.45),
                          SurfaceLevel.card.colorOf(scheme),
                        ),
                      ),
                    ),
                  if (other > 0)
                    Expanded(
                      flex: math.max(1, (other * 100 ~/ math.max(1, total))),
                      child: ColoredBox(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            spacing: 14,
            children: [
              _Legend(
                label: 'App',
                value: formatBytes(app),
                color: scheme.primary,
              ),
              _Legend(
                label: 'Core',
                value: formatBytes(core),
                color: Color.alphaBlend(
                  scheme.primary.withValues(alpha: 0.45),
                  SurfaceLevel.card.colorOf(scheme),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> boxRelease(BuildContext context, WidgetRef ref) async {
    final box = ref.read(boxControllerProvider);
    if (await box.dashboardReleaseMemory()) {
      if (context.mounted) {
        BannerHost.maybeOf(context)?.show('Memory released');
      }
    }
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 5,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        Text(
          '$label $value',
          style: AppTextStyle.caption1
              .of(context)
              .copyWith(color: context.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class LanCard extends ConsumerWidget {
  const LanCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(boxStateProvider);
    final addresses = box.lanAddresses;
    final scheme = context.colorScheme;
    return DashboardCard(
      semanticLabel: 'LAN proxy',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashboardHeader(
            glyph: AppGlyphs.link,
            title: 'LAN proxy',
            trailing: [
              SizedBox(
                width: 52,
                height: 32,
                child: Switch(
                  value: box.lan['enabled'] == true,
                  onChanged: box.canSetLanProxy
                      ? (value) => box.setLanProxy(value)
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            addresses.isEmpty ? 'No network' : addresses.first,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyle.title2
                .of(context, emphasized: true)
                .copyWith(color: scheme.onSurface),
          ),
          if (box.lanCopyText case final text?) ...[
            const SizedBox(height: 8),
            PressRegion(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) {
                  BannerHost.maybeOf(context)?.show('Copied');
                }
              },
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.caption1
                    .of(context)
                    .copyWith(color: scheme.primary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
