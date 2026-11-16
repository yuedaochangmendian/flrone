import '../widgets.dart';
import 'connections.dart';
import 'requests.dart';
import 'logs.dart';
import 'logcat.dart';
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
      _section(<ListItem>[
        if (caps.of('capture'))
          ListItem.open(leading: const GlyphIcon(AppGlyphs.filter), title: Text(context.tr('Requests')), widget: const RequestsPage()),
        if (caps.of('connections'))
          ListItem.open(leading: const GlyphIcon(AppGlyphs.connections), title: Text(context.tr('Connections')), widget: const ConnectionsPage()),
        if (caps.of('logs'))
          ListItem.open(
            leading: const GlyphIcon(AppGlyphs.logs),
            title: Text(context.tr('Logs')),
            // The two log screens sit next to each other and show different sources; the
            // subtitles are what tells them apart before either is opened.
            subtitle: Text(context.tr('sing-box core: rule matches, outbounds and DNS')),
            widget: const LogsPage(),
          ),
        // logcat is where the VPN service, gomobile's Go runtime and the JNI shim report;
        // none of that reaches sing-box's own log tail above. Gated on the same capability
        // because both come from the host's log subsystem.
        if (caps.of('logs'))
          ListItem.open(
            leading: const GlyphIcon(AppGlyphs.logs),
            title: Text(context.tr('Android logcat')),
            subtitle: Text(context.tr('This app process: VPN service, Go runtime and JNI')),
            widget: const LogcatPage(),
          ),
        if (caps.of('terminal'))
          ListItem.open(leading: const GlyphIcon(AppGlyphs.code), title: Text(context.tr('Terminal')), widget: const TerminalPage()),
        if (caps.of('remote'))
          ListItem.open(leading: const GlyphIcon(AppGlyphs.proxies), title: Text(context.tr('Remote control')), widget: const RemotePage()),
      ]),
      // The settings entries sit on this page, in Throne's order: no Settings page in between.
      _section(settingsEntries(context), title: context.tr('Settings')),
      _section(<ListItem>[
        if (caps.of('reports'))
          for (final kind in ['crash', 'oom', 'power'])
            ListItem.open(leading: const GlyphIcon(AppGlyphs.profiles), title: Text(context.tr(reportTitle(kind))), widget: ReportsPage(kind: kind)),
      ], title: context.tr('Reports')),
      _section(<ListItem>[
        if (caps.of('endpoints') && box.running)
          for (final kind in ['tailscale', 'openvpn', 'openconnect', 'usbip'])
            if (rows(box.toolState[kind]).isNotEmpty)
              ListItem.open(leading: const GlyphIcon(AppGlyphs.devices), title: Text(endpointName(kind)), widget: EndpointsPage(kind: kind)),
      ], title: context.tr('Endpoints')),
      _section(<ListItem>[
        ListItem.open(leading: const GlyphIcon(AppGlyphs.info), title: Text(context.tr('About')), widget: const AboutPage()),
      ], title: context.tr('Other')),
    ]);
  }
}

/// Sections whose every entry was pruned must not leave an empty card behind.
Widget _section(List<ListItem> items, {String? title}) =>
  items.isEmpty ? const SizedBox.shrink() : generateSection(title: title, items: items);
