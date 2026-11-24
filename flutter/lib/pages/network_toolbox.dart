import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../components/connectivity/connectivity_page.dart';
import '../components/tool_icon.dart';
import '../providers/box_providers.dart';
import '../services/traffic_stats.dart';
import '../widgets.dart';
import 'traffic_stats.dart';

// The network tools and their parameters, in one page. The three screens used to sit on the Tools
// list while the parameters behind them were a Testing settings entry of their own; keeping the
// two together puts a tool and the numbers it uses in one place, and the traffic ledger's switches
// beside the page that reads them.
//
// The speed-test modes belong to the control built here; test_panel.dart reaches them through
// widgets.dart -> settings_pages.dart.

const exitLookupProviders = ['auto', 'ip-api', 'ipwho', 'ipinfo', 'ipapi-co', 'freeipapi'];

/// ip-api's free endpoint is plain HTTP: name that in the picker instead of letting the choice
/// look like it did nothing (it falls back to the default order).
String exitLookupProviderName(String value) => value == 'ip-api' ? 'Lookup provider cleartext' : value;

class NetworkToolboxPage extends ConsumerWidget {
  const NetworkToolboxPage({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watchBoxState();
    final store = TrafficStatsStore.instance;
    return BoxPage(title: 'Network toolbox', actions: [
      restoreDefaultsAction(context, const [
        'testUrl', 'urlTestTimeoutMs', 'testConcurrent', 'directTestUrl', 'speedTestMode',
        'speedTestTimeoutMs', 'simpleDlUrl', 'exitCountryLookup', 'exitLookupProvider',
      ]),
    ], children: [
      generateSection(title: context.tr('Tools'), items: [
        ToolEntry(glyph: AppGlyphs.link, color: ToolColors.blue,
          title: context.tr('Connectivity test'), page: const ConnectivityPage()),
        ToolEntry(glyph: AppGlyphs.dataUsage, color: ToolColors.green,
          title: context.tr('Traffic statistics'), page: const TrafficStatsPage()),
        ToolEntry(glyph: AppGlyphs.speed, color: ToolColors.cyan,
          title: context.tr('Speed test'), page: const SpeedTestPage()),
      ]),
      generateSection(title: context.tr('Node tests'), items: [
        SettingText('Test URL', 'testUrl'),
        SettingNumber('Test timeout', 'urlTestTimeoutMs', min: 1, unit: 'ms'),
        SettingNumber('Concurrent tests', 'testConcurrent', min: 1, max: 499),
        SettingText('Direct test URL', 'directTestUrl'),
      ]),
      generateSection(title: context.tr('Speed test'), items: [
        SettingChoice<int>('Speed test mode', 'speedTestMode', options: speedTestModes, text: speedTestModeName),
        SettingNumber('Speed test timeout', 'speedTestTimeoutMs', min: 1, unit: 'ms'),
        // The conditional row must rebuild when the mode changes; the page watches the box state.
        if (box.settings['speedTestMode'] == 3)
          SettingText('Simple download URL', 'simpleDlUrl', hint: 'A file of known size used to measure throughput'),
      ]),
      AnimatedBuilder(
        animation: store,
        builder: (context, _) => generateSection(title: context.tr('Traffic statistics'), items: [
          ListItem.toggle(
            title: Text(context.tr('Enable traffic statistics')),
            subtitle: Text(context.tr('Off by default; recording starts when enabled and stays on this device')),
            value: store.enabled,
            onChanged: store.setEnabled,
          ),
          ListItem.toggle(
            title: Text(context.tr('Record details')),
            subtitle: Text(context.tr('Record the destination, app, node and rule of the traffic; off records totals only')),
            value: store.details,
            onChanged: store.enabled ? store.setDetails : null,
          ),
          ListItem.toggle(
            title: Text(context.tr('Show website icons')),
            subtitle: Text(context.tr('Fetch the site icon first, fall back to the Google icon service and cache it locally')),
            value: store.webIcons,
            onChanged: store.setWebIcons,
          ),
          ListItem(
            title: Text(context.tr('Data retention')),
            subtitle: Text('${store.retentionDays} ${context.tr('days')}'),
            onTap: () => showAppDialog<void>(context, child: _RetentionDialog(store: store)),
          ),
          ListItem(
            title: Text(context.tr('Clear data'), style: TextStyle(color: context.colorScheme.error)),
            onTap: () async {
              if (await confirm(context, 'Clear all traffic statistics?', action: 'Clear') && context.mounted) {
                await store.clear();
              }
            },
          ),
        ]),
      ),
      generateSection(title: context.tr('Exit detection'), items: [
        SettingToggle('Look up exit country', 'exitCountryLookup'),
        SettingChoice<String>('Lookup provider', 'exitLookupProvider', options: exitLookupProviders, text: exitLookupProviderName),
      ]),
    ]);
  }
}

class _RetentionDialog extends StatelessWidget {
  const _RetentionDialog({required this.store});
  final TrafficStatsStore store;

  @override Widget build(BuildContext context) => AlertDialog(
        title: context.tr('Data retention'),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final days in [7, 30, 90])
            ListItem(
              title: Text('$days ${context.tr('days')}'),
              trailing: store.retentionDays == days ? const GlyphIcon(AppGlyphs.check, size: 18) : null,
              onTap: () {
                store.setRetention(days);
                Navigator.pop(context);
              },
            ),
        ]),
      );
}
