import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../components/connectivity/connectivity_page.dart';
import '../components/tool_icon.dart';
import '../providers/box_providers.dart';
import '../services/traffic_stats.dart';
import '../widgets.dart';
import 'traffic_stats.dart';

// The network tools and their parameters, in one page. The cards are Bettbox's
// toolbox grid: a fixed 92dp unit, an 8dp gutter and small/wide/tall tiles,
// with the knobs each tool uses behind a sheet instead of a settings list. The
// display vocabulary (tool colours, press-tinted icons, prism cards) is the
// app's own, so no external package is involved.
//
// The speed-test modes belong to the control built here; test_panel.dart reaches
// them through widgets.dart -> settings_pages.dart.

const exitLookupProviders = ['auto', 'ip-api', 'ipwho', 'ipinfo', 'ipapi-co', 'freeipapi'];

/// ip-api's free endpoint is plain HTTP: name that in the picker instead of letting the choice
/// look like it did nothing (it falls back to the default order).
String exitLookupProviderName(String value) => value == 'ip-api' ? 'Lookup provider cleartext' : value;

enum _TileSize { small, wide, tall }

class NetworkToolboxPage extends ConsumerWidget {
  const NetworkToolboxPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the box state so a setting changed inside a sheet rebuilds the page
    // (the speed-settings card's Simple download URL visibility follows mode 3).
    ref.watchBoxState();
    final store = TrafficStatsStore.instance;

    void openSheet(String title, List<Widget> items) => showSheet<void>(
      context: context,
      builder: (_) => ListView(
        shrinkWrap: true,
        padding: EdgeInsets.fromLTRB(16, context.sectionsTopPadding, 16, 24 + context.bottomInset),
        children: [generateSection(title: context.tr(title), items: items)],
      ),
    );

    void openRetention() => showAppDialog<void>(
      context,
      child: Builder(builder: (dialogContext) => _RetentionDialog(store: store)),
    );

    void openTrafficSettings() => showSheet<void>(
      context: context,
      builder: (_) => _TrafficSettingsSheet(store: store, openRetention: openRetention),
    );

    // A tool card taps to a page or opens a sheet of settings. The card widgets
    // own their press feedback; the settings rows write straight through the
    // shared controls and the traffic store.
    final cards = <Widget>[
      _ToolCard(
        title: 'Speed test',
        description: 'Measure download, upload speed and latency',
        glyph: AppGlyphs.speed,
        color: ToolColors.blue,
        size: _TileSize.wide,
        onTap: () => openPage(context, const SpeedTestPage()),
      ),
      _ToolCard(
        title: 'Connectivity test',
        description: 'Check whether common services are reachable',
        glyph: AppGlyphs.link,
        color: ToolColors.cyan,
        size: _TileSize.tall,
        onTap: () => openPage(context, const ConnectivityPage()),
      ),
      _ToolCard(
        title: 'Traffic statistics',
        description: 'View traffic by day, week or month',
        glyph: AppGlyphs.dataUsage,
        color: ToolColors.green,
        onTap: () => openPage(context, const TrafficStatsPage()),
      ),
      _ToolCard(
        title: 'Node tests',
        description: 'Test URL, timeout and concurrency',
        glyph: AppGlyphs.bolt,
        color: ToolColors.orange,
        onTap: () => openSheet('Node tests', [
          SettingText('Test URL', 'testUrl'),
          SettingNumber('Test timeout', 'urlTestTimeoutMs', min: 1, unit: 'ms'),
          SettingNumber('Concurrent tests', 'testConcurrent', min: 1, max: 499),
          SettingText('Direct test URL', 'directTestUrl'),
        ]),
      ),
      _ToolCard(
        title: 'Speed test settings',
        description: 'Mode, timeout and simple download URL',
        glyph: AppGlyphs.settings,
        color: ToolColors.purple,
        onTap: () => openSheet('Speed test settings', [
          SettingChoice<int>('Speed test mode', 'speedTestMode', options: speedTestModes, text: speedTestModeName),
          SettingNumber('Speed test timeout', 'speedTestTimeoutMs', min: 1, unit: 'ms'),
          // This sheet is Consumer-aware, so the row appears the moment mode 3
          // is picked without closing and reopening it.
          const _SimpleDownloadRow(),
        ]),
      ),
      _ToolCard(
        title: 'Traffic statistics settings',
        description: 'Recording switches, retention and clearing',
        glyph: AppGlyphs.sliders,
        color: ToolColors.teal,
        onTap: openTrafficSettings,
      ),
      _ToolCard(
        title: 'Exit detection',
        description: 'Country lookup and provider',
        glyph: AppGlyphs.locate,
        color: ToolColors.blueDeep,
        onTap: () => openSheet('Exit detection', [
          SettingToggle('Look up exit country', 'exitCountryLookup'),
          SettingChoice<String>('Lookup provider', 'exitLookupProvider', options: exitLookupProviders, text: exitLookupProviderName),
        ]),
      ),
    ];

    return BoxPage(
      title: 'Network toolbox',
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, context.contentTopPadding, 16, 24 + context.bottomInset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Full-width speed test.
            _gridRow(_unitHeight, [cards[0]]),
            const SizedBox(height: _spacing),
            // Tall connectivity card on the left, two small cards stacked right.
            SizedBox(
              height: _unitHeight * 2 + _spacing,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: cards[1]),
                const SizedBox(width: _spacing),
                Expanded(child: Column(children: [
                  SizedBox(height: _unitHeight, child: cards[2]),
                  const SizedBox(height: _spacing),
                  SizedBox(height: _unitHeight, child: cards[3]),
                ])),
              ]),
            ),
            const SizedBox(height: _spacing),
            // Two settings cards.
            _gridRow(_unitHeight, [cards[4], cards[5]]),
            const SizedBox(height: _spacing),
            // Exit detection with an empty second column.
            _gridRow(_unitHeight, [cards[6], const SizedBox.shrink()]),
          ],
        ),
      ),
      actions: [
        restoreDefaultsAction(context, const [
          'testUrl', 'urlTestTimeoutMs', 'testConcurrent', 'directTestUrl', 'speedTestMode',
          'speedTestTimeoutMs', 'simpleDlUrl', 'exitCountryLookup', 'exitLookupProvider',
        ]),
      ],
    );
  }
}

/// The traffic sheet rebuilds its rows from the store so the details switch
/// follows the recording switch immediately. Building the toggles inside the
/// builder keeps each onChanged bound to the store's current state.
class _TrafficSettingsSheet extends StatelessWidget {
  const _TrafficSettingsSheet({required this.store, required this.openRetention});
  final TrafficStatsStore store;
  final VoidCallback openRetention;

  @override
  Widget build(BuildContext context) => ListView(
    shrinkWrap: true,
    padding: EdgeInsets.fromLTRB(16, context.sectionsTopPadding, 16, 24 + context.bottomInset),
    children: [
      AnimatedBuilder(
        animation: store,
        builder: (sheetContext, _) => generateSection(title: sheetContext.tr('Traffic statistics settings'), items: [
          ListItem.toggle(
            title: Text(sheetContext.tr('Enable traffic statistics')),
            subtitle: Text(sheetContext.tr('Off by default; recording starts when enabled and stays on this device')),
            value: store.enabled,
            onChanged: store.setEnabled,
          ),
          ListItem.toggle(
            title: Text(sheetContext.tr('Record details')),
            subtitle: Text(sheetContext.tr('Record the destination, app, node and rule of the traffic; off records totals only')),
            value: store.details,
            onChanged: store.enabled ? store.setDetails : null,
          ),
          ListItem.toggle(
            title: Text(sheetContext.tr('Show website icons')),
            subtitle: Text(sheetContext.tr('Fetch the site icon first, fall back to the Google icon service and cache it locally')),
            value: store.webIcons,
            onChanged: store.setWebIcons,
          ),
          ListItem(
            title: Text(sheetContext.tr('Data retention')),
            subtitle: Text('${store.retentionDays} ${sheetContext.tr('days')}'),
            onTap: openRetention,
          ),
          ListItem(
            title: Text(sheetContext.tr('Clear data'), style: TextStyle(color: sheetContext.colorScheme.error)),
            onTap: () async {
              if (await confirm(sheetContext, 'Clear all traffic statistics?', action: 'Clear') && sheetContext.mounted) {
                await store.clear();
              }
            },
          ),
        ]),
      ),
    ],
  );
}

/// The Simple download URL row lives in its own Consumer so it appears as soon
/// as the mode changes, without rebuilding the whole sheet's static rows.
class _SimpleDownloadRow extends ConsumerWidget {
  const _SimpleDownloadRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(settingsProvider.select((s) => s['speedTestMode']));
    return mode == 3
        ? SettingText('Simple download URL', 'simpleDlUrl', hint: 'A file of known size used to measure throughput')
        : const SizedBox.shrink();
  }
}

/// A grid row of `_unitHeight`-tall cells with Bettbox's 8dp gutter. The two
/// columns share the remaining width equally; a wide card takes the row alone.
const _unitHeight = 92.0;
const _spacing = 8.0;

Widget _gridRow(double height, List<Widget> children) => SizedBox(
  height: height,
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (index, child) in children.indexed) ...[
        if (index > 0) const SizedBox(width: _spacing),
        Expanded(child: child),
      ],
    ],
  ),
);

/// A single Bettbox toolbox card, built from the app's own prism primitives.
/// Small and wide cards occupy one unit, tall cards two. The icon box and its
/// oversized watermark own the accent; pressing tints only the icon and box,
/// never the whole card.
class _ToolCard extends StatefulWidget {
  const _ToolCard({
    required this.title,
    required this.description,
    required this.glyph,
    required this.color,
    required this.onTap,
    this.size = _TileSize.small,
  });

  final String title, description;
  final Glyph glyph;
  final ToolColor color;
  final VoidCallback onTap;
  final _TileSize size;

  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> {
  final _states = WidgetStatesController();

  @override
  void dispose() {
    _states.dispose();
    super.dispose();
  }

  bool get _active => _states.value.contains(WidgetState.pressed) ||
      _states.value.contains(WidgetState.hovered);

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final tall = widget.size == _TileSize.tall;
    final wide = widget.size == _TileSize.wide;
    final resolved = widget.color.resolve(scheme.brightness);

    Widget iconBox(double dimension, double iconSize) => AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      width: dimension,
      height: dimension,
      decoration: BoxDecoration(
        color: _active ? resolved.withValues(alpha: 0.14) : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(dimension * 0.3),
      ),
      child: Center(child: GlyphIcon(widget.glyph, size: iconSize)),
    );

    Widget watermark(double iconSize) => AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      child: GlyphIcon(
        widget.glyph,
        size: iconSize,
        color: _active ? resolved.withValues(alpha: 0.16) : scheme.onSurface.withValues(alpha: 0.05),
      ),
    );

    final titleStyle = (wide || tall ? AppTextStyle.subheadline : AppTextStyle.body)
        .of(context, emphasized: true)
        .copyWith(color: scheme.onSurface);
    final descStyle = (wide || tall ? AppTextStyle.footnote : AppTextStyle.caption1)
        .of(context)
        .copyWith(color: scheme.onSurfaceVariant, height: 1.3);

    Widget content;
    if (wide) {
      content = Stack(children: [
        PositionedDirectional(end: -14, bottom: -22, child: watermark(104)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            iconBox(46, 26),
            const SizedBox(width: 14),
            Expanded(child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
                const SizedBox(height: 4),
                Text(context.tr(widget.description), maxLines: 2, overflow: TextOverflow.ellipsis, style: descStyle),
              ],
            )),
            const SizedBox(width: 24),
          ]),
        ),
      ]);
    } else if (tall) {
      content = Stack(children: [
        PositionedDirectional(end: -18, top: -18, child: watermark(96)),
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            iconBox(42, 24),
            Expanded(child: Align(
              alignment: AlignmentDirectional.bottomStart,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
                const SizedBox(height: 6),
                Text(context.tr(widget.description), maxLines: 3, overflow: TextOverflow.ellipsis, style: descStyle),
              ]),
            )),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _active ? resolved.withValues(alpha: 0.14) : scheme.surfaceContainerHigh,
                ),
                child: Center(child: GlyphIcon(
                  AppGlyphs.chevronForward,
                  size: 15,
                  color: _active ? resolved : scheme.onSurfaceVariant,
                )),
              ),
            ),
          ]),
        ),
      ]);
    } else {
      content = Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            iconBox(30, 18),
            const SizedBox(width: 10),
            Expanded(child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle)),
          ]),
          const Spacer(),
          Text(context.tr(widget.description), maxLines: 2, overflow: TextOverflow.ellipsis, style: descStyle),
        ]),
      );
    }

    // Pointer/focus feedback is published to a private controller; the card
    // paints no wash or band of its own, so press tint stays on the icon.
    return Listener(
      onPointerDown: (_) => _states.update(WidgetState.pressed, true),
      onPointerUp: (_) => _states.update(WidgetState.pressed, false),
      onPointerCancel: (_) => _states.update(WidgetState.pressed, false),
      child: MouseRegion(
        onEnter: (_) => _states.update(WidgetState.hovered, true),
        onExit: (_) => _states.update(WidgetState.hovered, false),
        child: ListenableBuilder(
          listenable: _states,
          builder: (context, _) => Card(
            onPressed: widget.onTap,
            radius: AppCorner.lg,
            pressTint: const Color(0x00000000),
            statesController: _states,
            padding: EdgeInsets.zero,
            child: SizedBox.expand(child: content),
          ),
        ),
      ),
    );
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
