import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../app/l10n.dart';
import '../app/navigation.dart';
import '../app/settings_catalog.dart';
import '../box.dart';
import '../providers/box_providers.dart';
import '../ui/icons/icons.dart';
import '../ui/list_item.dart';
import '../ui/scaffold/scaffold.dart';
import 'access.dart';
import 'backup.dart';
import 'connectivity.dart';
import 'dashboard.dart';
import 'endpoints.dart';
import 'routes.dart';
import 'settings_pages.dart';
import 'speed_test.dart';
import 'terminal.dart';

class ToolsPage extends ConsumerWidget {
  const ToolsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(boxStateProvider);
    final settings = box.settings;
    final prefs = box.preferences;
    return Scaffold(
      title: context.tr('Tools'),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          24 + context.bottomInset,
        ),
        children: [
          _Section(
            title: context.tr('General'),
            children: [
              ListItem<String>.options(
                leading: const GlyphIcon(AppGlyphs.settings),
                title: Text(context.tr('Service mode')),
                options: const ['vpn', 'proxy'],
                value: settings['serviceMode'] == 'proxy' ? 'proxy' : 'vpn',
                textBuilder: (value) => value == 'vpn' ? 'VPN' : 'Proxy only',
                onChanged: (value) =>
                    box.setSetting('serviceMode', value, autoRestart: true),
              ),
              ListItem.toggle(
                leading: const GlyphIcon(AppGlyphs.connections),
                title: Text('Reset connections on network change'),
                value: settings['networkChangeResetConnections'] == true,
                onChanged: (value) => box.setSetting(
                  'networkChangeResetConnections',
                  value,
                  restart: false,
                ),
              ),
              ListItem.toggle(
                leading: const GlyphIcon(AppGlyphs.refresh),
                title: Text('Reset connections on wake'),
                value: settings['wakeResetConnections'] == true,
                onChanged: (value) => box.setSetting(
                  'wakeResetConnections',
                  value,
                  restart: false,
                ),
              ),
              ListItem.toggle(
                leading: const GlyphIcon(AppGlyphs.vpn),
                title: Text('Connect after reboot'),
                value: settings['rememberEnable'] == true,
                onChanged: (value) =>
                    box.setSetting('rememberEnable', value, restart: false),
              ),
              ListItem.toggle(
                leading: const GlyphIcon(AppGlyphs.warning),
                title: Text('Start without rule sets'),
                value: settings['startWithoutRuleSets'] == true,
                onChanged: (value) => box.setSetting(
                  'startWithoutRuleSets',
                  value,
                  restart: false,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _Section(
            title: context.tr('Appearance'),
            children: [
              ListItem<String>.options(
                leading: const GlyphIcon(AppGlyphs.sun),
                title: Text(context.tr('Theme')),
                options: const ['system', 'light', 'dark'],
                value: prefs['theme']?.toString() ?? 'system',
                textBuilder: (value) => context.tr(
                  value == 'system'
                      ? 'System'
                      : value == 'light'
                      ? 'Light'
                      : 'Dark',
                ),
                onChanged: (value) => box.setPreference('theme', value),
              ),
              ListItem<String>.options(
                leading: const GlyphIcon(AppGlyphs.liquidGlass),
                title: Text(context.tr('Liquid Glass')),
                options: const ['none', 'standard'],
                value: prefs['liquidGlass']?.toString() ?? 'none',
                textBuilder: (value) => value == 'none' ? 'Off' : 'Standard',
                onChanged: (value) => box.setPreference('liquidGlass', value),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.palette),
                title: Text('Accent'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 8,
                  children: [
                    for (final color in const [
                      Color(0xFF4C8DFF),
                      Color(0xFF8B5CF6),
                      Color(0xFF10B981),
                      Color(0xFFF59E0B),
                      Color(0xFFEF4444),
                    ])
                      PressSurface(
                        shape: AppShape.circle,
                        fill: color,
                        onPressed: () =>
                            box.setPreference('accent', color.toARGB32()),
                        child: const SizedBox.square(dimension: 24),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _Section(
            title: 'Network',
            children: [
              ListItem.toggle(
                leading: const GlyphIcon(AppGlyphs.vpn),
                title: Text('TUN routing'),
                subtitle: Text(
                  settings['enableTunRouting'] == true ? 'Enabled' : 'Disabled',
                ),
                value: settings['enableTunRouting'] == true,
                onChanged: (value) =>
                    box.setSetting('enableTunRouting', value, restart: true),
              ),
              ListItem.toggle(
                leading: const GlyphIcon(AppGlyphs.link),
                title: Text('System proxy'),
                value: box.dashboard['systemProxy'] == true,
                onChanged: (value) => box.systemProxySet(value),
              ),
              ListItem.toggle(
                leading: const GlyphIcon(AppGlyphs.dns),
                title: Text('DNS object'),
                subtitle: Text('Use a custom DNS object'),
                value: settings['useDnsObject'] == true,
                onChanged: (value) =>
                    box.setSetting('useDnsObject', value, restart: true),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.rules),
                title: Text('Routing'),
                subtitle: const Text('Route profiles and rules'),
                onTap: () => openPage<void>(context, const RoutesPage()),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.appsList),
                title: const Text('Access control'),
                subtitle: const Text('Per-app proxy or bypass'),
                onTap: () => openPage<void>(context, const AccessPage()),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.speed),
                title: const Text('Speed test'),
                subtitle: const Text('Measure the running outbound'),
                onTap: () => openPage<void>(context, const SpeedTestPage()),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.link),
                title: const Text('Connectivity'),
                subtitle: const Text('Probe common endpoints'),
                onTap: () => openPage<void>(context, const ConnectivityPage()),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.devices),
                title: const Text('Tailscale'),
                subtitle: const Text('Peers, exit nodes and Taildrop'),
                onTap: () => openPage<void>(
                  context,
                  const EndpointsPage(kind: 'tailscale'),
                ),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.devices),
                title: const Text('USB/IP'),
                subtitle: const Text('Shared USB devices'),
                onTap: () =>
                    openPage<void>(context, const EndpointsPage(kind: 'usbip')),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.send),
                title: const Text('Transfers'),
                subtitle: const Text('Taildrop transfers'),
                onTap: () => openPage<void>(context, const TransfersPage()),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.code),
                title: const Text('Terminal'),
                subtitle: const Text('Tailscale SSH sessions'),
                onTap: () => openPage<void>(context, const TerminalPage()),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _Section(
            title: 'Advanced settings',
            children: [
              for (final section in settingsSections)
                ListItem(
                  leading: GlyphIcon(_settingsGlyph(section.title)),
                  title: Text(section.title),
                  onTap: () => openPage<void>(
                    context,
                    SettingsSectionPage(section: section),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          _Section(
            title: 'Diagnostics',
            children: [
              ListItem(
                leading: const GlyphIcon(AppGlyphs.logs),
                title: Text(context.tr('Logs')),
                subtitle: Text('${box.logs.length} lines'),
                onTap: () => showLogs(context),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.connections),
                title: Text(context.tr('Connections')),
                subtitle: Text('${box.connections.length} active'),
                onTap: () => ref.read(tabIndexProvider.notifier).state = 3,
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.info),
                title: Text(context.tr('About')),
                subtitle: Text(
                  'Flrone ${box.version} · core ${box.coreVersion}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _about(context),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.cloudSync),
                title: Text(context.tr('Backup and restore')),
                subtitle: const Text('Local and WebDAV backups'),
                onTap: () => openPage<void>(context, const BackupPage()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _about(BuildContext context) {
    return showFloatingDialog<void>(
      context: context,
      child: AlertDialog(
        title: 'Flrone',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Text('Flutter interface rebuilt on prism_ui.'),
            Text('Core: ${boxVersion(context)}'),
            Text('License: GPL-3.0'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('Close')),
          ),
        ],
      ),
    );
  }
}

Glyph _settingsGlyph(String title) => switch (title) {
  'General' => AppGlyphs.settings,
  'Inbound' => AppGlyphs.link,
  'TUN' => AppGlyphs.vpn,
  'DNS' => AppGlyphs.dns,
  'Core' => AppGlyphs.cpu,
  'Notification' => AppGlyphs.status,
  'WARP' => AppGlyphs.shuffle,
  'Testing' => AppGlyphs.speed,
  'Node presets' => AppGlyphs.nodeGroup,
  _ => AppGlyphs.sliders,
};

String boxVersion(BuildContext context) {
  final box = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(boxControllerProvider);
  return '${box.version} (${box.coreRefShort})';
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            title,
            style: AppTextStyle.caption1
                .of(context)
                .copyWith(
                  color: context.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
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
              for (final (index, child) in children.indexed) ...[
                child,
                if (index != children.length - 1) const Divider(height: 1),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
