import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets.dart';
import '../providers/box_providers.dart';
import '../components/tool_icon.dart';
import 'connections.dart';
import 'logs.dart';
import 'network_toolbox.dart';
import 'settings.dart';

/// Connections and logs are gated the same way the rest of the navigation is: the host advertises
/// what it answers ([BoxCapabilities] / `Capabilities.map()`), and an entry whose backend does not
/// exist is not drawn at all. The B-box-only screens this page used to list (request capture, the
/// terminal, remote sessions, crash/oom/power reports, tailscale/openvpn/openconnect/usbip
/// endpoints, taildrop) are gone rather than hidden: nothing behind them had a host implementation.
class ToolsPage extends ConsumerWidget {
  const ToolsPage({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) {
    final caps = ref.watch(capabilitiesProvider);
    // FlClash's `openLogs`: the entry is hidden until log capture is enabled,
    // and no tail is sampled while it is off.
    final logsEnabled = ref.watch(preferencesProvider)['openLogs'] == true;
    return BoxPage(title: 'Tools', children: [
      _section(<Widget>[
        // The dashboard card is still titled Connections (it is a live count),
        // but the full page is Requests after the FlClash v0.9.5 redesign.
        if (caps.of('connections'))
          ToolEntry(glyph: AppGlyphs.connections, color: ToolColors.purple,
            title: context.tr('Requests'), page: const ConnectionsPage()),
        if (caps.of('logs') && logsEnabled)
          ToolEntry(glyph: AppGlyphs.logs, color: ToolColors.teal,
            title: context.tr('Logs'), page: const LogsPage()),
        // The three network tools and every parameter behind them are one page: a test screen
        // and the numbers it uses stay together, and the traffic ledger's switches sit beside
        // the page that reads them.
        ToolEntry(glyph: AppGlyphs.speed, color: ToolColors.cyan,
          title: context.tr('Network toolbox'), page: const NetworkToolboxPage()),
      ]),
      // The settings entries sit on this page, in Throne's order: no Settings page in between.
      _section(settingsEntries(context, caps), title: context.tr('Settings')),
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
