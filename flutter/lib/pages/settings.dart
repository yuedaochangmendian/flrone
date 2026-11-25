import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/box_providers.dart';
import '../components/tool_icon.dart';
import '../common/log_level.dart';
import '../widgets.dart';
import 'access.dart';
import 'appearance.dart';
import 'backup.dart';

export 'appearance.dart';
export 'access.dart';
export 'about.dart';
export 'backup.dart';

/// The settings entries in Throne's `global_preferences.xml` order. The Tools page lists them
/// directly, so every setting is one tap from the drawer and there is no Settings page in between.
///
/// Inbound, TUN, routing, DNS and the rest are pages of their own rather than items behind a
/// "General" container; General is the connection/behaviour page upstream calls General.
///
/// Inbound, Node presets and Subscriptions are configuration surfaces a user touches once, not
/// on the way to anything else. They sat in this flat list among the common entries and made
/// them harder to scan, so they moved behind one "Advanced settings" row.
List<Widget> settingsEntries(BuildContext context) {
  return [
    ToolEntry(glyph: AppGlyphs.settings, color: ToolColors.blue,
      title: context.tr('General'), page: const GeneralPage()),
    ToolEntry(glyph: AppGlyphs.status, color: ToolColors.orange,
      title: context.tr('Notification'), page: const NotificationPage()),
    ToolEntry(glyph: AppGlyphs.paintbrush, color: ToolColors.pink,
      title: context.tr('Appearance'), page: const AppearancePage()),
    ToolEntry(glyph: AppGlyphs.split, color: ToolColors.purple,
      title: context.tr('TUN'), page: const TunPage()),
    ToolEntry(glyph: AppGlyphs.rules, color: ToolColors.teal,
      title: context.tr('Routing'), page: const RoutingPage()),
    ToolEntry(glyph: AppGlyphs.dns, color: ToolColors.green,
      title: context.tr('DNS'), page: const DnsPage()),
    ToolEntry(glyph: AppGlyphs.cpu, color: ToolColors.burntOrange,
      title: context.tr('Core'), page: const CorePage()),
    ToolEntry(glyph: AppGlyphs.appsList, color: ToolColors.indigo,
      title: context.tr('Access control'), page: const AccessPage()),
    ToolEntry(glyph: AppGlyphs.cloudSync, color: ToolColors.blueDeep,
      title: context.tr('Backup and restore'), page: const BackupPage()),
    ToolEntry(glyph: AppGlyphs.sliders, color: ToolColors.orchid,
      title: context.tr('Advanced settings'), page: const AdvancedSettingsPage()),
  ];
}

/// The service notification's rows, one tap from the settings list. They used to
/// live on the General page, where they outgrew the section they were squeezed into.
/// Riverpod pilot: watches [settingsProvider] so the page rebuilds through the
/// one-way bridge when notification settings change. The shared controls still
/// write through `context.box.setSetting()`; Riverpod is never a second writer.
class NotificationPage extends ConsumerWidget {
  const NotificationPage({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(settingsProvider);
    return BoxPage(title: 'Notification', children: [
      generateSection(items: [
        // Both are read by the host on its next update, so they need no core restart.
        const SettingToggle('Show group name in the notification', 'showGroupInNotification', restart: false),
        const SettingToggle('Show proxy speed', 'showProxySpeed', restart: false),
        const SettingToggle('Show direct speed', 'showDirectSpeed', restart: false),
        const SettingToggle('Show traffic total', 'showTrafficTotal', restart: false),
        const SettingText('Notification title template', 'notificationTitleTemplate',
            hint: 'Use {title} for the profile name, for example 🚀 {title}', restart: false),
        const SettingText('Notification content template', 'notificationContentTemplate',
            hint: 'Leave empty for the built-in speed line; {up} {down} {totalUp} {totalDown}', restart: false),
        const NotificationActionsSetting(),
      ]),
    ]);
  }
}

/// Throne's General page: connection, behaviour, and the update entry upstream keeps here.
///
/// Removed here, because Throne has no equivalent: auto redirect, dynamic notification, deprecation
/// warnings, the core memory killer and its limit, and power reports.
/// Riverpod pilot: the settings rows read the merged map through
/// [settingsProvider], which rebuilds on the one-way `stateChanges` bridge.
/// Writes still go through `context.box.setSetting()` — Riverpod is never a
/// second writer. Capabilities and transient flags stay on [context.box].
class GeneralPage extends ConsumerWidget {
  const GeneralPage({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watchBoxState();
    final settings = ref.watch(settingsProvider);
    final caps = box.capabilities;
    return BoxPage(title: 'General', loading: box.serviceSettingsChanging, children: [
      generateSection(items: [
        ListItem<String>.options(
          title: Text(context.tr('Service mode')), options: const ['vpn', 'proxy'],
          value: settings['serviceMode'] == 'proxy' ? 'proxy' : 'vpn',
          textBuilder: (value) => context.tr(value == 'vpn' ? 'VPN' : 'Proxy only'),
          onChanged: (value) => box.setSetting('serviceMode', value, autoRestart: true),
        ),
        // "Allow bypass" lives on the Access screen as the per-app mode; the private-range switch is
        // under TUN, because upstream keeps them in two different stores.
        // "Always show the address" is gone: nothing in this fork renders a node
        // address from it (the status card always shows the egress IP), so the
        // switch promised a change that could never happen.
        // The notification rows are a page of their own on the settings list.
      ]),
      generateSection(title: context.tr('Connections'), items: [
        const SettingToggle('Reset connections on network change', 'networkChangeResetConnections', restart: false),
        const SettingToggle('Reset connections when waking up', 'wakeResetConnections', restart: false),
      ]),
      generateSection(title: context.tr('Behaviour'), items: [
        const SettingToggle('Connect after reboot', 'rememberEnable', restart: false),
        const SettingToggle('Hide from recent apps', 'hideFromRecentApps', restart: false),
        const SettingToggle('Treat the VPN as metered', 'meteredNetwork', autoRestart: true),
        const SettingToggle('Skip delete confirmation', 'skipDeleteConfirmation', restart: false),
        // A failed rule-set download normally blocks a start; this lets the core come up anyway.
        const SettingToggle('Start without rule sets', 'startWithoutRuleSets', restart: false),
        ListItem(title: Text(context.tr('Battery optimization')),
          subtitle: Text(context.tr(settings['batteryExempt'] == true ? 'Unrestricted' : 'Allow background operation')),
          onTap: () => box.batteryOpen()),
      ]),
      generateSection(title: context.tr('Logs'), items: [
        const _LogCaptureToggle(),
        // FlClash keeps the level here; the log screen's picker is a shortcut to the same
        // core setting, and both restart the service to apply it.
        SettingChoice<String>('Log level', 'logLevel', options: coreLogLevels, text: (value) => value, autoRestart: true),
      ]),
      // Upstream keeps the two update switches in a section of this page.
      if (caps.of('update')) generateSection(title: context.tr('Updates'), items: [
        ListItem.open(leading: const GlyphIcon(AppGlyphs.sync), title: Text(context.tr('Update settings')), widget: const UpdatePage()),
      ]),
    ]);
  }
}

/// FlClash's "Logcat" switch: off by default, it hides the Logs entry. Sources
/// are only sampled while a log screen is open, so this also means nothing is
/// recorded while the entry is hidden.
class _LogCaptureToggle extends ConsumerWidget {
  const _LogCaptureToggle();
  @override Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(preferencesProvider)['openLogs'] == true;
    // The page disables its switches while a service restart is in flight; this
    // preference does not touch the service, but staying consistent avoids a
    // write racing the restart's preference document.
    final changing = ref.watch(serviceSettingsChangingProvider);
    final box = ref.read(boxControllerProvider);
    return ListItem.toggle(
      title: Text(context.tr('Log capture')),
      subtitle: Text(context.tr('Record kernel and app logs; off hides the Logs entry')),
      value: enabled,
      onChanged: changing ? null : (value) => box.setPreference('openLogs', value),
    );
  }
}

/// The service notification's buttons. The host keeps a fixed order (stop, previous, next,
/// switch, reset) and shows the first three enabled ones, so the picker is a checkbox list
/// and whatever it saves is re-ordered and truncated by `ServiceNotification` itself.
///
/// An empty selection is valid and means "no buttons"; a missing key (older host) renders as
/// the built-in default set.
class NotificationActionsSetting extends ConsumerWidget {
  const NotificationActionsSetting({super.key});

  /// The host's button ids in its `ACTION_ORDER`, with the label the dialog shows.
  static const actions = <(String, String)>[
    ('stop', 'Stop'),
    ('previous', 'Previous'),
    ('next', 'Next'),
    ('switch', 'Switch…'),
    ('reset', 'Reset connections'),
  ];

  static const defaults = <String>['stop', 'next', 'switch'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watchBoxState();
    final raw = ref.watch(settingsProvider)['notificationActions'];
    final selected = raw is List ? raw.whereType<String>().toList() : defaults;
    return ListItem(
      title: Text(context.tr('Notification buttons')),
      subtitle: Text(_summary(context, selected), maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () async {
        final saved = await showAppDialog<List<String>>(
          context,
          child: _NotificationActionsEditor(initial: selected),
        );
        if (saved != null) await box.setSetting('notificationActions', saved, restart: false);
      },
    );
  }

  String _summary(BuildContext context, List<String> selected) {
    if (selected.isEmpty) return context.tr('None');
    final names = selected.map((id) => _label(context, id));
    return names.join(', ');
  }

  String _label(BuildContext context, String id) => context.tr(
      actions.firstWhere((action) => action.$1 == id, orElse: () => (id, id)).$2);
}

class _NotificationActionsEditor extends StatefulWidget {
  const _NotificationActionsEditor({required this.initial});

  final List<String> initial;

  @override
  State<_NotificationActionsEditor> createState() => _NotificationActionsEditorState();
}

class _NotificationActionsEditorState extends State<_NotificationActionsEditor> {
  late final Set<String> _selected = {...widget.initial};

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: context.tr('Notification buttons'),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
      TextButton(
        // Keep the host's order, not the dialog's: the save is what the service reads.
        onPressed: () => Navigator.pop(context,
            NotificationActionsSetting.actions.map((a) => a.$1).where(_selected.contains).toList()),
        child: Text(context.tr('Save')),
      ),
    ],
    // Prism's own checkbox row, consistent with the app's ListItem primitives.
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(context.tr('The first three of the enabled ones show, in a fixed order'),
            style: AppTextStyle.caption1.of(context)),
      ),
      for (final (id, label) in NotificationActionsSetting.actions)
        ListItem.checkbox(
          value: _selected.contains(id),
          title: Text(context.tr(label)),
          onChanged: (value) => setState(() {
            if (value == true) {
              _selected.add(id);
            } else {
              _selected.remove(id);
            }
          }),
        ),
    ]),
  );
}
