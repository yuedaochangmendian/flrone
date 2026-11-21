import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../app/l10n.dart';
import '../app/settings_catalog.dart';
import '../providers/box_providers.dart';
import '../ui/list_item.dart';
import '../ui/scaffold/scaffold.dart';

class SettingsSectionPage extends ConsumerWidget {
  const SettingsSectionPage({super.key, required this.section});

  final SettingsSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(boxStateProvider);
    final settings = box.settings;
    return Scaffold(
      title: section.title,
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          24 + context.bottomInset,
        ),
        children: [
          if (section.note case final note?)
            Padding(
              padding: const EdgeInsets.only(bottom: 10, left: 4),
              child: Text(
                note,
                style: AppTextStyle.caption1
                    .of(context)
                    .copyWith(color: context.colorScheme.onSurfaceVariant),
              ),
            ),
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: ShapeDecoration(
              color: SurfaceLevel.card.colorOf(context.colorScheme),
              shape: AppShape.all(AppCorner.xl),
            ),
            child: Column(
              children: [
                for (final (index, entry) in section.entries.indexed) ...[
                  _SettingRow(entry: entry, value: settings[entry.key]),
                  if (index != section.entries.length - 1)
                    const Divider(height: 1),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingRow extends ConsumerWidget {
  const _SettingRow({required this.entry, required this.value});

  final SettingEntry entry;
  final dynamic value;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.read(boxControllerProvider);
    final label = entry.label;
    switch (entry.kind) {
      case SettingKind.toggle:
        return ListItem.toggle(
          title: Text(label),
          value: value == true,
          onChanged: (next) => box.setSetting(
            entry.key,
            next,
            restart: entry.restart,
            autoRestart: entry.autoRestart,
          ),
        );
      case SettingKind.options:
        return ListItem<String>.options(
          title: Text(label),
          options: [for (final (key, _) in entry.options) key],
          value: value?.toString() ?? entry.options.first.$1,
          textBuilder: (key) => entry.options
              .firstWhere(
                (option) => option.$1 == key,
                orElse: () => (key, key),
              )
              .$2,
          onChanged: (next) => box.setSetting(
            entry.key,
            next,
            restart: entry.restart,
            autoRestart: entry.autoRestart,
          ),
        );
      case SettingKind.text:
        return ListItem.input(
          title: Text(label),
          dialogTitle: label,
          value: value?.toString() ?? '',
          onChanged: (next) => box.setSetting(
            entry.key,
            next ?? '',
            restart: entry.restart,
            autoRestart: entry.autoRestart,
          ),
        );
      case SettingKind.integer:
        return ListItem.input(
          title: Text(label),
          dialogTitle: label,
          value: value?.toString() ?? '',
          keyboardType: TextInputType.number,
          onChanged: (next) {
            final parsed = int.tryParse(next ?? '');
            if (parsed != null) {
              box.setSetting(
                entry.key,
                parsed,
                restart: entry.restart,
                autoRestart: entry.autoRestart,
              );
            }
          },
        );
      case SettingKind.lines:
        final lines = value is List
            ? value.whereType<String>().toList()
            : value?.toString().split('\n') ?? const <String>[];
        return ListItem(
          title: Text(label),
          subtitle: Text(
            lines.isEmpty ? 'None' : '${lines.length} lines',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _editLines(context, ref, lines),
        );
    }
  }

  Future<void> _editLines(
    BuildContext context,
    WidgetRef ref,
    List<String> lines,
  ) async {
    final controller = TextEditingController(text: lines.join('\n'));
    final saved = await showFormSheet<bool>(
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
                  entry.label,
                  style: AppTextStyle.title3.of(context, emphasized: true),
                ),
                TextField(
                  controller: controller,
                  minLines: 5,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    hintText: 'One entry per line',
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  spacing: 8,
                  children: [
                    TonalButton(
                      label: context.tr('Cancel'),
                      onPressed: () => Navigator.pop(context, false),
                    ),
                    TonalButton(
                      label: context.tr('Save'),
                      onPressed: () => Navigator.pop(context, true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved == true) {
      final next = controller.text
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      await ref
          .read(boxControllerProvider)
          .setSetting(
            entry.key,
            next,
            restart: entry.restart,
            autoRestart: entry.autoRestart,
          );
    }
    controller.dispose();
  }
}
