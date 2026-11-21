import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../app/l10n.dart';
import '../box.dart';
import '../providers/box_providers.dart';
import '../ui/icons/icons.dart';
import 'dashboard_common.dart';

Future<void> showProfilePicker(BuildContext context) {
  return showSheet<void>(
    context: context,
    builder: (_) => const _ProfilePicker(),
  );
}

class _ProfilePicker extends ConsumerWidget {
  const _ProfilePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(boxStateProvider);
    final scheme = context.colorScheme;
    return Surface(
      color: SurfaceLevel.page.colorOf(scheme),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('Profiles'),
                      style: AppTextStyle.title3.of(context, emphasized: true),
                    ),
                  ),
                  DashboardIconButton(
                    glyph: AppGlyphs.add,
                    tooltip: context.tr('Add profile'),
                    onPressed: () => _addProfile(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (box.profiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    context.tr('No profile'),
                    style: AppTextStyle.body
                        .of(context)
                        .copyWith(color: scheme.onSurfaceVariant),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final profile in box.profiles)
                        _ProfileRow(
                          profile: profile,
                          selected:
                              (profile['id'] as num?)?.toInt() ==
                              box.selectedProfileId,
                          onTap: () async {
                            await box.profileSelect(profile['id']);
                            if (context.mounted) Navigator.pop(context);
                          },
                          onUpdate: profile['remote'] == true
                              ? () => box.profileUpdate(profile['id'])
                              : null,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.profile,
    required this.selected,
    required this.onTap,
    this.onUpdate,
  });

  final Json profile;
  final bool selected;
  final VoidCallback onTap;
  final Future<bool> Function()? onUpdate;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: PressSurface(
        fill: selected
            ? Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.1),
                SurfaceLevel.card.colorOf(scheme),
              )
            : SurfaceLevel.card.colorOf(scheme),
        shape: AppShape.all(AppCorner.md),
        onPressed: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            spacing: 12,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(
                      profile['name']?.toString() ??
                          profile['label']?.toString() ??
                          '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.subheadline.of(
                        context,
                        emphasized: true,
                      ),
                    ),
                    Text(
                      [
                        profile['type']?.toString() ?? 'local',
                        if (profile['remote'] == true) 'remote',
                        if (profile['nodeCount'] case final count?)
                          '$count nodes',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.caption1
                          .of(context)
                          .copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (onUpdate != null)
                DashboardIconButton(
                  glyph: AppGlyphs.sync,
                  tooltip: context.tr('Update'),
                  onPressed: () => onUpdate!(),
                ),
              if (selected)
                GlyphIcon(AppGlyphs.check, size: 18, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _addProfile(BuildContext context) async {
  final name = TextEditingController();
  final url = TextEditingController();
  final box = ProviderScope.containerOf(context, listen: false);
  await showFormSheet<void>(
    context: context,
    builder: (context) => Surface(
      color: SurfaceLevel.page.colorOf(context.colorScheme),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Text(
                context.tr('Add profile'),
                style: AppTextStyle.title3.of(context, emphasized: true),
              ),
              TextField(
                controller: name,
                decoration: const InputDecoration(hintText: 'Name'),
              ),
              TextField(
                controller: url,
                decoration: const InputDecoration(
                  hintText: 'https://example.com/config.json',
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TonalButton(
                    onPressed: () => Navigator.pop(context),
                    label: context.tr('Cancel'),
                  ),
                  TonalButton(
                    onPressed: () async {
                      try {
                        await box.read(boxControllerProvider).profileSave({
                          'name': name.text.trim(),
                          'url': url.text.trim(),
                          'autoUpdate': false,
                          'interval': 60,
                        });
                        if (context.mounted) Navigator.pop(context);
                      } catch (error) {
                        box.read(boxControllerProvider).report(error);
                      }
                    },
                    label: context.tr('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> showGroupsSheet(BuildContext context) {
  return showSheet<void>(
    context: context,
    builder: (_) => const _GroupsSheet(),
  );
}

class _GroupsSheet extends ConsumerWidget {
  const _GroupsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(boxStateProvider);
    final groups = box.groups;
    final scheme = context.colorScheme;
    return Surface(
      color: SurfaceLevel.page.colorOf(scheme),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.tr('Proxy groups'),
                style: AppTextStyle.title3.of(context, emphasized: true),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final group in groups) _GroupRow(group: group),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupRow extends ConsumerWidget {
  const _GroupRow({required this.group});

  final Json group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.colorScheme;
    final selected = group['selected']?.toString() ?? '—';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: PressSurface(
        fill: SurfaceLevel.card.colorOf(scheme),
        shape: AppShape.all(AppCorner.md),
        onPressed: () => showSheet<void>(
          context: context,
          builder: (_) => _GroupNodesSheet(group: group),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            spacing: 12,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(
                      group['tag']?.toString() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.subheadline.of(
                        context,
                        emphasized: true,
                      ),
                    ),
                    Text(
                      selected,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.caption1
                          .of(context)
                          .copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              DashboardIconButton(
                glyph: AppGlyphs.speed,
                tooltip: context.tr('Test'),
                onPressed: () =>
                    ref.read(boxControllerProvider).groupTest(group['tag']),
              ),
              GlyphIcon(
                AppGlyphs.chevronForward,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupNodesSheet extends ConsumerWidget {
  const _GroupNodesSheet({required this.group});

  final Json group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(boxStateProvider);
    final live = box.groups.firstWhere(
      (item) => item['tag'] == group['tag'],
      orElse: () => group,
    );
    final nodes = rows(live['items']);
    final selectedId = (live['selectedId'] as num?)?.toInt();
    final scheme = context.colorScheme;
    return Surface(
      color: SurfaceLevel.page.colorOf(scheme),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      live['tag']?.toString() ?? '',
                      style: AppTextStyle.title3.of(context, emphasized: true),
                    ),
                  ),
                  DashboardIconButton(
                    glyph: AppGlyphs.speed,
                    tooltip: context.tr('Test all'),
                    onPressed: () => box.groupTest(live['tag']),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final node in nodes)
                      _NodeRow(
                        group: live,
                        node: node,
                        selected:
                            (node['id'] as num?)?.toInt() == selectedId ||
                            node['tag'] == live['selected'],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NodeRow extends ConsumerWidget {
  const _NodeRow({
    required this.group,
    required this.node,
    required this.selected,
  });

  final Json group;
  final Json node;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.colorScheme;
    final delay = (node['delay'] as num?)?.toInt();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: PressSurface(
        fill: selected
            ? Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.1),
                SurfaceLevel.card.colorOf(scheme),
              )
            : SurfaceLevel.card.colorOf(scheme),
        shape: AppShape.all(AppCorner.md),
        onPressed: group['selectable'] == false
            ? null
            : () async {
                await ref
                    .read(boxControllerProvider)
                    .groupSelect(
                      group['tag'],
                      node['tag'],
                      nodeId: (node['id'] as num?)?.toInt(),
                    );
                if (context.mounted) Navigator.pop(context);
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            spacing: 10,
            children: [
              Expanded(
                child: Text(
                  node['tag']?.toString() ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.footnote
                      .of(context)
                      .copyWith(color: scheme.onSurface),
                ),
              ),
              Text(
                delay == null
                    ? '—'
                    : delay < 0
                    ? context.tr('Timeout')
                    : '$delay ms',
                style: AppTextStyle.caption1
                    .of(context)
                    .copyWith(
                      color: delay != null && delay < 0
                          ? scheme.error
                          : scheme.onSurfaceVariant,
                    ),
              ),
              if (selected)
                GlyphIcon(AppGlyphs.check, size: 16, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}
