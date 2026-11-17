import '../widgets.dart';
import '../components/tool_icon.dart';
import 'connections.dart';
import 'requests.dart';
import 'logs.dart';
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
          ToolEntry(glyph: AppGlyphs.filter, title: context.tr('Requests'), page: const RequestsPage()),
        if (caps.of('connections'))
          ToolEntry(glyph: AppGlyphs.connections, title: context.tr('Connections'), page: const ConnectionsPage()),
        if (caps.of('logs'))
          ToolEntry(
            glyph: AppGlyphs.logs,
            title: context.tr('Logs'),
            // One screen, two tails: the core's own log (rule matches, outbounds, DNS) and
            // this app process's logcat (VPN service, Go runtime, JNI). The screen's switch
            // picks between them; the subtitle says both are in there.
            subtitle: context.tr('Kernel log and Android logcat'),
            page: const LogsPage(),
          ),
        if (caps.of('terminal'))
          ToolEntry(glyph: AppGlyphs.code, title: context.tr('Terminal'), page: const TerminalPage()),
        if (caps.of('remote'))
          ToolEntry(glyph: AppGlyphs.proxies, title: context.tr('Remote control'), page: const RemotePage()),
      ]),
      // The settings entries sit on this page, in Throne's order: no Settings page in between.
      _section(settingsEntries(context), title: context.tr('Settings')),
      _section(<Widget>[
        if (caps.of('reports'))
          for (final kind in ['crash', 'oom', 'power'])
            ToolEntry(glyph: AppGlyphs.profiles, title: context.tr(reportTitle(kind)), page: ReportsPage(kind: kind)),
      ], title: context.tr('Reports')),
      _section(<Widget>[
        if (caps.of('endpoints') && box.running)
          for (final kind in ['tailscale', 'openvpn', 'openconnect', 'usbip'])
            if (rows(box.toolState[kind]).isNotEmpty)
              ToolEntry(glyph: AppGlyphs.devices, title: endpointName(kind), page: EndpointsPage(kind: kind)),
      ], title: context.tr('Endpoints')),
      _section(<Widget>[
        ToolEntry(glyph: AppGlyphs.info, title: context.tr('About'), page: const AboutPage()),
      ], title: context.tr('Other')),
    ]);
  }
}

/// Sections whose every entry was pruned must not leave an empty card behind.
Widget _section(List<Widget> items, {String? title}) =>
  items.isEmpty ? const SizedBox.shrink() : generateSection(title: title, items: items);
