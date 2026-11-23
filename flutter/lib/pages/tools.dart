import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets.dart';
import '../providers/box_providers.dart';
import '../components/tool_icon.dart';
import 'connections.dart';
import 'logs.dart';
import '../components/connectivity/connectivity_page.dart';
import 'settings.dart';
import 'traffic_stats.dart';

/// Connections and logs are gated the same way the rest of the navigation is: the host advertises
/// what it answers ([BoxCapabilities] / `Capabilities.map()`), and an entry whose backend does not
/// exist is not drawn at all. The B-box-only screens this page used to list (request capture, the
/// terminal, remote sessions, crash/oom/power reports, tailscale/openvpn/openconnect/usbip
/// endpoints, taildrop) are gone rather than hidden: nothing behind them had a host implementation.
class ToolsPage extends ConsumerWidget {
  const ToolsPage({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) {
    final caps = ref.watch(capabilitiesProvider);
    return BoxPage(title: 'Tools', children: [
      _section(<Widget>[
        if (caps.of('connections'))
          ToolEntry(glyph: AppGlyphs.connections, color: ToolColors.purple,
            title: context.tr('Connections'), page: const ConnectionsPage()),
        if (caps.of('logs'))
          ToolEntry(glyph: AppGlyphs.logs, color: ToolColors.teal,
            title: context.tr('Logs'), page: const LogsPage()),
        ToolEntry(glyph: AppGlyphs.link, color: ToolColors.blue,
          title: context.tr('Connectivity test'), page: const ConnectivityPage()),
        // Sampled in Dart from the core's totals, so it answers even when a host has no caps key
        // for it; the ledger lives in preferences.
        ToolEntry(glyph: AppGlyphs.dataUsage, color: ToolColors.green,
          title: context.tr('Traffic statistics'), page: const TrafficStatsPage()),
      ]),
      // The settings entries sit on this page, in Throne's order: no Settings page in between.
      _section(settingsEntries(context), title: context.tr('Settings')),
      _section(<Widget>[
        ToolEntry(glyph: AppGlyphs.info, color: ToolColors.indigo,
          title: context.tr('About'), page: const AboutPage()),
      ], title: context.tr('Other')),
    ]);
  }
}

/// Sections whose every entry was pruned must not leave an empty card behind.
Widget _section(List<Widget> items, {String? title}) =>
  items.isEmpty ? const SizedBox.shrink() : generateSection(title: title, items: items);
