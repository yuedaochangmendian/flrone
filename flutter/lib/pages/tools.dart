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
          _ToolEntry(glyph: AppGlyphs.filter, title: context.tr('Requests'), page: const RequestsPage()),
        if (caps.of('connections'))
          _ToolEntry(glyph: AppGlyphs.connections, title: context.tr('Connections'), page: const ConnectionsPage()),
        if (caps.of('logs'))
          _ToolEntry(
            glyph: AppGlyphs.logs,
            title: context.tr('Logs'),
            // One screen, two tails: the core's own log (rule matches, outbounds, DNS) and
            // this app process's logcat (VPN service, Go runtime, JNI). The screen's switch
            // picks between them; the subtitle says both are in there.
            subtitle: context.tr('Kernel log and Android logcat'),
            page: const LogsPage(),
          ),
        if (caps.of('terminal'))
          _ToolEntry(glyph: AppGlyphs.code, title: context.tr('Terminal'), page: const TerminalPage()),
        if (caps.of('remote'))
          _ToolEntry(glyph: AppGlyphs.proxies, title: context.tr('Remote control'), page: const RemotePage()),
      ]),
      // The settings entries sit on this page, in Throne's order: no Settings page in between.
      _section(settingsEntries(context), title: context.tr('Settings')),
      _section(<Widget>[
        if (caps.of('reports'))
          for (final kind in ['crash', 'oom', 'power'])
            _ToolEntry(glyph: AppGlyphs.profiles, title: context.tr(reportTitle(kind)), page: ReportsPage(kind: kind)),
      ], title: context.tr('Reports')),
      _section(<Widget>[
        if (caps.of('endpoints') && box.running)
          for (final kind in ['tailscale', 'openvpn', 'openconnect', 'usbip'])
            if (rows(box.toolState[kind]).isNotEmpty)
              _ToolEntry(glyph: AppGlyphs.devices, title: endpointName(kind), page: EndpointsPage(kind: kind)),
      ], title: context.tr('Endpoints')),
      _section(<Widget>[
        _ToolEntry(glyph: AppGlyphs.info, title: context.tr('About'), page: const AboutPage()),
      ], title: context.tr('Other')),
    ]);
  }
}

/// One toolbox row: the icon takes the theme colour while the row is pressed.
///
/// The entry mirrors its own pointer events into the icon's `WidgetStatesController`. A
/// `Listener` does not join the gesture arena, so the row keeps its tap and navigation;
/// `ListItem.open` hands its tap to an `OpenContainer`, whose recognizer would otherwise
/// win before the inner press surface ever sees a tap-down, which is why the state is
/// observed here rather than shared with the row.
class _ToolEntry extends StatefulWidget {
  const _ToolEntry({required this.glyph, required this.title, this.subtitle, required this.page});

  final Glyph glyph;
  final String title;
  final String? subtitle;
  final Widget page;
  @override State<_ToolEntry> createState() => _ToolEntryState();
}

class _ToolEntryState extends State<_ToolEntry> {
  final _states = WidgetStatesController();

  @override void dispose() {
    _states.dispose();
    super.dispose();
  }

  void _press(bool pressed) {
    if (mounted) _states.update(WidgetState.pressed, pressed);
  }

  @override Widget build(BuildContext context) {
    final subtitle = widget.subtitle;
    return Listener(
      onPointerDown: (_) => _press(true),
      onPointerUp: (_) => _press(false),
      onPointerCancel: (_) => _press(false),
      child: MouseRegion(
        onEnter: (_) => _states.update(WidgetState.hovered, true),
        onExit: (_) => _states.update(WidgetState.hovered, false),
        child: ListItem.open(
          leading: ToolIcon(glyph: widget.glyph, states: _states),
          title: Text(widget.title),
          subtitle: subtitle == null ? null : Text(subtitle),
          widget: widget.page,
        ),
      ),
    );
  }
}

/// Sections whose every entry was pruned must not leave an empty card behind.
Widget _section(List<Widget> items, {String? title}) =>
  items.isEmpty ? const SizedBox.shrink() : generateSection(title: title, items: items);
