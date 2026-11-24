// FlClash's ProxiesSetting sheet: every display choice in one place.
//
// FlClash's settings pages use the full-width `SegmentedControl` for exclusive
// choices; the old sheet was wrapped chips inside a bare sheet that still
// reserved a sheet bar it never drew. This is the same shape as the other Prism
// form sheets: a titled `BoxPage`, one segmented row per choice, and the
// behaviour switches as ordinary list rows.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';
import '../widgets.dart';

/// One exclusive choice: a label and a full-width segmented control.
class _SegmentedRow extends StatelessWidget {
  const _SegmentedRow({
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String title;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: context.listCaptionStyle),
          const SizedBox(height: 8),
          SegmentedControl<String>(
            segments: [for (final option in options) (option, context.tr(option))],
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// Shows the display settings; every tap writes through `box.setPreference` so
/// the page behind re-renders live, which is how FlClash's sheet behaves.
Future<void> showProxiesSetting(BuildContext context) =>
    openForm<void>(context, const ProxiesSettingSheet());

class ProxiesSettingSheet extends ConsumerWidget {
  const ProxiesSettingSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.read(boxControllerProvider);
    final prefs = ref.watch(preferencesProvider);
    String read(String key, String fallback) =>
        (prefs[key] ?? fallback).toString();
    void write(String key, String value) => box.setPreference(key, value);

    final list = read('proxyLayout', 'Tabs') == 'List';

    return BoxPage(
      title: 'Proxies settings',
      children: [
        generateSection(title: context.tr('Appearance'), items: [
          _SegmentedRow(
            title: context.tr('Style'),
            value: read('proxyLayout', 'Tabs'),
            options: const ['Tabs', 'List'],
            onChanged: (value) => write('proxyLayout', value),
          ),
          _SegmentedRow(
            title: context.tr('Sort'),
            value: read('proxySort', 'Default'),
            options: const ['Default', 'Latency', 'Name'],
            onChanged: (value) => write('proxySort', value),
          ),
          _SegmentedRow(
            title: context.tr('Layout'),
            value: read('proxyDensity', 'Standard'),
            options: const ['Tight', 'Standard', 'Loose'],
            onChanged: (value) => write('proxyDensity', value),
          ),
          _SegmentedRow(
            title: context.tr('Size'),
            value: read('proxyCardSize', 'Standard'),
            options: const ['Compact', 'Standard', 'Loose'],
            onChanged: (value) => write('proxyCardSize', value),
          ),
          if (list)
            _SegmentedRow(
              title: context.tr('Icon style'),
              value: read('proxyIconStyle', 'Filled'),
              options: const ['Filled', 'Plain', 'Hidden'],
              onChanged: (value) => write('proxyIconStyle', value),
            ),
        ]),
        generateSection(title: context.tr('Behaviour'), items: [
          ListItem(
            title: Text(context.tr('Hide timeout proxies')),
            trailing: Switch(
              value: prefs['hideTimeoutProxies'] == true,
              onChanged: (value) => box.setPreference('hideTimeoutProxies', value),
            ),
          ),
          ListItem(
            title: Text(context.tr('Close connections after switching')),
            trailing: Switch(
              value: prefs['closeConnectionsOnSelect'] == true,
              onChanged: (value) =>
                  box.setPreference('closeConnectionsOnSelect', value),
            ),
          ),
        ]),
      ],
    );
  }
}
