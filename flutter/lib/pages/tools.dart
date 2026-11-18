import '../widgets.dart';
import '../components/tool_icon.dart';
import 'connections.dart';
import 'requests.dart';
import 'logs.dart';
import 'route_test.dart';
import '../components/connectivity/connectivity_page.dart';
import 'settings.dart';
import 'endpoints.dart';
import 'reports.dart';
import 'terminal.dart';

/// Throne answers nothing behind these entries, so they only exist when the host advertises that it
/// can: see [BoxCapabilities] and `Capabilities.map()` on the Android side.
///
/// The monitors section (requests, connections, logs, terminal, remote control), diagnostics,
/// reports and endpoints are all B-box or libbox-private features with no Throne counterpart.
class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});
  @override Widget build(BuildContext context) {
    final box = context.box, caps = box.capabilities;
    return BoxPage(title: 'Tools', children: [
      _section(<Widget>[
        if (caps.of('capture'))
          ToolEntry(glyph: AppGlyphs.filter, color: ToolColors.blue,
            title: context.tr('Requests'), page: const RequestsPage()),
        if (caps.of('connections'))
          ToolEntry(glyph: AppGlyphs.connections, color: ToolColors.purple,
            title: context.tr('Connections'), page: const ConnectionsPage()),
        if (caps.of('logs'))
          ToolEntry(glyph: AppGlyphs.logs, color: ToolColors.teal,
            title: context.tr('Logs'), page: const LogsPage()),
        ToolEntry(glyph: AppGlyphs.target, color: ToolColors.cyan,
          title: context.tr('Route test'), page: const RouteTestPage()),
        ToolEntry(glyph: AppGlyphs.link, color: ToolColors.blue,
          title: context.tr('Connectivity test'), page: const ConnectivityPage()),
        if (caps.of('terminal'))
          ToolEntry(glyph: AppGlyphs.code, color: ToolColors.green,
            title: context.tr('Terminal'), page: const TerminalPage()),
        if (caps.of('remote'))
          ToolEntry(glyph: AppGlyphs.proxies, color: ToolColors.orange,
            title: context.tr('Remote control'), page: const RemotePage()),
      ]),
      // The settings entries sit on this page, in Throne's order: no Settings page in between.
      _section(settingsEntries(context), title: context.tr('Settings')),
      _section(<Widget>[
        if (caps.of('reports'))
          for (final kind in ['crash', 'oom', 'power'])
            ToolEntry(
              glyph: AppGlyphs.profiles,
              color: switch (kind) {
                'crash' => ToolColors.pink,
                'oom' => ToolColors.burntOrange,
                _ => ToolColors.orange,
              },
              title: context.tr(reportTitle(kind)),
              page: ReportsPage(kind: kind),
            ),
      ], title: context.tr('Reports')),
      _section(<Widget>[
        if (caps.of('endpoints') && box.running)
          for (final kind in ['tailscale', 'openvpn', 'openconnect', 'usbip'])
            if (rows(box.toolState[kind]).isNotEmpty)
              ToolEntry(
                glyph: AppGlyphs.devices,
                color: switch (kind) {
                  'tailscale' => ToolColors.blue,
                  'openvpn' => ToolColors.green,
                  'openconnect' => ToolColors.purple,
                  _ => ToolColors.teal,
                },
                title: endpointName(kind),
                page: EndpointsPage(kind: kind),
              ),
      ], title: context.tr('Endpoints')),
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
