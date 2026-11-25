import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:math' as math;
// ignore: unnecessary_import — widgets.dart only re-exports ScrollCacheExtent on newer SDKs.
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets.dart';
import '../providers/box_providers.dart';
import '../components/dashboard_editor.dart';

import 'about.dart' show showUpdateDialog;
import '../components/connected_buttons.dart';
import '../components/status_panel.dart';
import '../components/connections_panel.dart';
import '../components/memory_panel.dart';
import '../components/speed_gauge.dart';
import '../components/intranet_panel.dart';
import '../components/profile_panel.dart';
import '../components/proxy_groups_panel.dart';
import '../components/system_proxy_panel.dart';
import '../components/connectivity/connectivity_panel.dart';

export '../components/dashboard_editor.dart' show DashboardEditor;

const dashboardCards = ['Status', 'Network speed', 'Connectivity', 'Outbound mode', 'Current profile', 'Proxy groups', 'Memory', 'Intranet IP', 'Network takeover', 'Connections'];
const defaultDashboardCards = ['Status', 'Network speed', 'Connectivity', 'Outbound mode', 'Current profile', 'Proxy groups'];
const defaultHiddenCards = ['Memory', 'Intranet IP', 'Connections'];

List<String> dashboardOrder(Json prefs) {
  final saved = (prefs['dashboardCards'] as List? ?? defaultDashboardCards).whereType<String>().where(dashboardCards.contains).toList();
  return {...saved, ...dashboardCards}.toList();
}

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});
  @override ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  final _cardKeys = <String, GlobalKey>{};
  final _editor = GlobalKey<DashboardEditorState>();
  late final _scroll = sheetScrollController(context);
  bool _editing = false, _saving = false;
  GlobalKey _keyOf(String card) => _cardKeys.putIfAbsent(card, GlobalKey.new);

  @override void dispose() { _scroll.dispose(); super.dispose(); }

  Map<String, Widget> _cards(List<String> modes, {required bool systemProxy}) {
    final prefs = ref.read(preferencesProvider), caps = ref.read(capabilitiesProvider);
    // "Service status" used to be a second exit-IP card here, and it ran its own
    // RoutedIpProbe.egress() + ipQualities.lookup alongside StatusPanel's — two
    // probe sessions and duplicate lookups for the same data on every dashboard
    // build. StatusPanel already shows the address, region and quality, so the
    // duplicate card is gone rather than made to share state.
    return <String, Widget>{
      'Status': const StatusPanel(),
      if (caps.of('lanProxy')) 'Intranet IP': const IntranetPanel(),
      'Network speed': const _SpeedPanel(),
      if (prefs['connectivityCard'] != false) 'Connectivity': const ConnectivityPanel(),
      if (modes.isNotEmpty) 'Outbound mode': const _ModePanel(),
      'Current profile': const ProfilePanel(),
      // Throne keeps groups in its own list, there is no Clash-mode selector to render here.
      if (caps.of('proxyGroups')) 'Proxy groups': const ProxyGroupsPanel(),
      if (caps.of('memory')) 'Memory': const MemoryPanel(),
      if (systemProxy) 'Network takeover': const SystemProxyPanel(),
      if (caps.of('connections')) 'Connections': const ConnectionsPanel(),
    };
  }

  Future<bool> _saveLayout(List<String> shown) async {
    final layout = ref.read(dashboardLayoutProvider);
    final modes = layout.modes.isEmpty ? const <String>[] : layout.modes.split('\u0000');
    final box = ref.read(boxControllerProvider);
    final available = _cards(modes, systemProxy: layout.systemProxy).keys.toSet();
    final prefs = ref.read(preferencesProvider);
    final order = dashboardOrder(prefs), result = List<String>.of(shown);
    final hidden = (prefs['hiddenCards'] as List? ?? defaultHiddenCards)
      .whereType<String>().where(dashboardCards.contains).toSet();
    var at = 0;
    for (final card in order) {
      if (available.contains(card)) {
        final index = result.indexOf(card);
        if (index >= 0) at = index + 1;
      } else { result.insert(at++, card); }
    }
    for (final card in order) { if (!result.contains(card)) result.add(card); }
    for (final card in available) {
      shown.contains(card) ? hidden.remove(card) : hidden.add(card);
    }
    hidden.remove('Status');
    return box.setPreferences({'dashboardCards': result, 'hiddenCards': hidden.toList()});
  }

  @override Widget build(BuildContext context) {
    final box = ref.read(boxControllerProvider);
    // Watch the fields that decide which cards appear and how they are laid out.
    final layout = ref.watch(dashboardLayoutProvider);
    final modes = layout.modes.isEmpty ? const <String>[] : layout.modes.split('\u0000');
    final cards = _cards(modes, systemProxy: layout.systemProxy);
    final prefs = ref.watch(preferencesProvider);
    final hidden = prefs['hiddenCards'] as List? ?? defaultHiddenCards;
    final shown = [for (final card in dashboardOrder(prefs))
      if (cards.containsKey(card) && (card == 'Status' || !hidden.contains(card))) card];
    return _UpdateChecker(child: Scaffold(title: context.tr(_editing ? 'Edit dashboard' : 'Dashboard'),
      isLoading: _saving, backgroundColor: SurfaceLevel.page.colorOf(context.colorScheme),
      confirmationAction: _editing ? IconButtonData(glyph: AppGlyphs.check, tooltip: context.tr('Done'),
        onPressed: _saving ? null : () { _editor.currentState?.finish(); }) : null,
      iconActions: [if (!_editing) IconButtonData(glyph: AppGlyphs.edit, tooltip: context.tr('Dashboard cards'),
        onPressed: () => setState(() => _editing = true))],
      body: LayoutBuilder(builder: (context, constraints) {
        final side = math.max(16.0, (constraints.maxWidth - 560) / 2), gap = context.isMobileView ? 8.0 : 12.0;
        final padding = EdgeInsets.fromLTRB(side, context.contentTopPadding, side, 16 + context.bottomInset);
        return CustomScrollView(key: const PageStorageKey('dashboard'), controller: _scroll,
          scrollCacheExtent: _editing ? ScrollCacheExtent.viewport(dashboardCards.length.toDouble()) : null,
          slivers: [
            if (_editing) DashboardEditor(key: _editor, shown: shown,
              available: [for (final card in dashboardCards) if (cards.containsKey(card)) card],
              cardKeyOf: _keyOf, cardBuilder: (card) => cards[card]!, padding: padding, gap: gap,
              onChanged: _saveLayout, onBusyChanged: (busy) { if (mounted) setState(() => _saving = busy); },
              onDone: () { if (mounted) setState(() => _editing = false); })
            else SliverPadding(padding: padding, sliver: SliverToBoxAdapter(child: Column(children: [
              _DashboardNotices(gap: gap),
              Column(spacing: gap, children: [
                for (final card in shown) RepaintBoundary(key: _keyOf(card), child: cards[card]),
                for (final note in _deprecatedNotes(layout.deprecated))
                  ListItem(title: Text(note.$1), onTap: note.$2.isEmpty ? null : () => box.openUrl(note.$2)),
              ]),
            ]))),
          ],
        );
      }),
    ));
  }

  /// The `deprecated` dashboard rows encoded by [dashboardLayoutProvider].
  List<(String, String)> _deprecatedNotes(String encoded) {
    if (encoded.isEmpty) return const [];
    return [
      for (final item in encoded.split('\u0000'))
        (item.substring(0, item.indexOf('|')),
            item.substring(item.indexOf('|') + 1)),
    ];
  }
}

/// Notices that depend on live state. Keeping them out of [DashboardPage.build]
/// prevents a `Started` event from rebuilding the whole scroll view and every
/// card in the same frame.
class _DashboardNotices extends ConsumerWidget {
  const _DashboardNotices({required this.gap});

  final double gap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(runningProvider);
    final applyRequired = ref.watch(applyRequiredProvider);
    final update = ref.watch(_updateOfferProvider);
    if (!(running && applyRequired != null) && update == null) {
      return const SizedBox.shrink();
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: gap, children: [
      if (update != null) _UpdateNotice(offer: update),
      if (running && applyRequired != null) _RestartHint(key: ValueKey(applyRequired)),
    ]);
  }
}

const _updateCacheMs = 'updateCheckedAt';
const _updateOfferKey = 'updateOffer';
const _updateCheckInterval = Duration(hours: 24);

/// The last offered update, replayed from preferences so the badge survives a
/// rebuild/restart without a second check. A cleared offer (dismissal) is null.
final _updateOfferProvider = Provider<Json?>((ref) {
  final prefs = ref.watch(preferencesProvider);
  final encoded = prefs[_updateOfferKey] as String?;
  if (encoded == null || encoded.isEmpty) return null;
  try {
    final offer = json(jsonDecode(encoded));
    return offer['version'] is String ? offer : null;
  } catch (_) { return null; }
});

/// On first mount, asks the host to check once a day (when the auto setting is
/// on) and remembers the offer in preferences. Failures are silent: a check is
/// a convenience, never a gate on the dashboard. The 24h cache keeps the
/// channel quiet when the page is rebuilt by a tab switch or a service event.
class _UpdateChecker extends ConsumerStatefulWidget {
  const _UpdateChecker({required this.child});
  final Widget child;
  @override ConsumerState<_UpdateChecker> createState() => _UpdateCheckerState();
}

class _UpdateCheckerState extends ConsumerState<_UpdateChecker> {
  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeCheck());
  }

  Future<void> _maybeCheck() async {
    if (!mounted) return;
    final box = ref.read(boxControllerProvider);
    if (box.settings['updateCheckAuto'] != true) return;
    final checkedAt = box.preferences[_updateCacheMs] as num? ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - checkedAt < _updateCheckInterval.inMilliseconds) return;
    try {
      final result = json(await box.updatesCheck());
      // Stamp only a completed round-trip: a failed check (no network) must not burn the
      // day's attempt, or the badge would stay absent until the next 24h window. The check
      // runs from initState, so a rebuild cannot start a second one in flight.
      if (!mounted) return;
      await box.setPreferences({_updateCacheMs: now});
      if (result['available'] != true) {
        // A later check reporting no update must retire an offer cached by an
        // earlier one — otherwise the badge outlives the release it announced.
        // '' is the same value a manual dismissal writes, so the provider reads
        // it as null and the notice goes away.
        await box.setPreferences({_updateOfferKey: ''});
        return;
      }
      final version = result['version']?.toString();
      if (version != null && version.isNotEmpty) {
        // Cache the whole payload so opening the badge does not need a second
        // network round-trip; only the version is shown, but the dialog wants
        // the notes and download link too.
        await box.setPreferences({_updateOfferKey: jsonEncode(result)});
      }
    } catch (_) { /* silent: no network, no metadata, no UI change */ }
  }

  @override Widget build(BuildContext context) => widget.child;
}

/// A dismissible "Update available" chip. Tapping it opens the same release
/// dialog the About page's manual check uses.
class _UpdateNotice extends ConsumerWidget {
  const _UpdateNotice({required this.offer});
  final Json offer;
  @override Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.read(boxControllerProvider);
    return ListItem(
      leading: const GlyphIcon(AppGlyphs.sync),
      title: Text('${context.tr('Update available')} ${offer['version']}'),
      trailing: IconButton(
        tooltip: context.tr('Dismiss'),
        icon: const GlyphIcon(AppGlyphs.close, size: 16),
        onPressed: () => box.setPreferences({_updateOfferKey: ''}),
      ),
      onTap: () => showUpdateDialog(context, box, offer),
    );
  }
}

/// Shows the "restart required" hint for three seconds when a config change is
/// applied while the service is running, then collapses away. The underlying
/// [BoxController.applyRequired] flag is left set so the configuration page
/// keeps an explicit Apply entry even after the hint disappears.
class _RestartHint extends ConsumerStatefulWidget {
  const _RestartHint({super.key});
  @override ConsumerState<_RestartHint> createState() => _RestartHintState();
}

class _RestartHintState extends ConsumerState<_RestartHint> {
  bool _visible = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = ref.read(boxControllerProvider);
    return AnimatedSize(
      duration: midDuration,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: _visible
          ? ListItem(
              title: Text(context.tr('Restart required')),
              trailing: TextButton(
                onPressed: () async {
                  // restartApp records the attempt in the boot guard before the host takes the
                  // process down, so the next launch (and any sticky service start) is gated.
                  if (await box.restartApp()) {
                    box.clearApplyRequired();
                  } else if (context.mounted) {
                    showAppBanner(context, context.tr('Restart failed'));
                  }
                },
                child: Text(context.tr('Apply')),
              ),
            )
          : const SizedBox(width: double.infinity, height: 0),
    );
  }
}

// The phone layout of FlClash's current dashboard/widgets/traffic.dart.
class _SpeedPanel extends ConsumerWidget {
  const _SpeedPanel();

  /// Long-press diagnostic: the card can only say "no sample" or a number, so
  /// this reports which stage of kernel → IPC → controller is silent.
  void _showDiagnostics(BuildContext context, BoxController box) {
    final d = box.speedDiagnostics;
    String attached(Object? value) =>
        value == true ? context.tr('attached') : context.tr('not attached');
    String available(Object? value) => value == null
        ? '-'
        : (value == 1 ? context.tr('Available') : context.tr('Unavailable'));
    final lines = [
      '${context.tr('Driver mode')}: ${d['driverActive']}'
          ' (${context.tr('kernel connected')}: ${d['kernelConnected']}, '
          '${context.tr('event subscription')}: ${attached(d['eventsAttached'])})',
      '${context.tr('Kernel phase')}: ${d['kernelPhase'] ?? '-'}',
      '${context.tr('Core status')}: ${d['status'] ?? '-'}, '
          '${context.tr('Connections')}: ${d['connections'] ?? '-'}',
      '${context.tr('Traffic counter')}: ${available(d['trafficAvailable'])}',
      '${context.tr('Status events')}: ${d['events']} ${context.tr('times')}, '
          '${context.tr('last')} ${d['lastEventAgo']} ${context.tr('seconds ago')}',
      '${context.tr('Rate events')}: ${d['rateEvents']} ${context.tr('times')}, '
          '${context.tr('last')} ${d['lastRateAgo']} ${context.tr('seconds ago')}',
      '${context.tr('Current rate')}: ${d['rates']}',
      '${context.tr('Totals')}: ${context.tr('Upload')} ${d['uploadTotal'] ?? '-'}'
          ' / ${context.tr('Download')} ${d['downloadTotal'] ?? '-'}',
      '${context.tr('Memory / goroutines')}: '
          '${d['memory'] ?? '-'} / ${d['goroutines'] ?? '-'}',
    ];
    showAppDialog<void>(
      context,
      child: Builder(
        builder: (dialogContext) => AlertDialog(
          title: dialogContext.tr('Network speed diagnostics'),
          child: Text(lines.join('\n'), style: AppTextStyle.footnote.of(dialogContext)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(dialogContext.tr('Close')),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(boxControllerProvider);
    return GestureDetector(
      onLongPress: () => _showDiagnostics(context, box),
      child: BoxPanel(
        onTap: () => openForm(context, const SpeedTestPage()),
        child: Column(children: [
          const PanelTitle('Network speed', AppGlyphs.speed),
          const SizedBox(height: 12),
          Row(spacing: 10, children: [for (final upload in [true, false]) Expanded(child: _SpeedTile(upload: upload))]),
        ]),
      ),
    );
  }
}

/// Keeps one shape at every width, growing only when the text needs more. The
/// chart fills the tile under the title row, behind the figure and the total.
class _SpeedTile extends ConsumerWidget {
  const _SpeedTile({required this.upload});
  final bool upload;

  static const _aspectRatio = 1.45;
  static const _padding = EdgeInsets.fromLTRB(16, 14, 16, 12);
  static const _titleGap = 4.0;
  static const _bleed = 2.0;

  @override Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colorScheme;
    final box = ref.watch(boxControllerProvider);
    final traffic = ref.watch(trafficProvider);
    // Download is the first chart series (primary); upload is the second,
    // primary at 45% over the card surface, not an unrelated tertiary hue.
    final color = upload ? secondSeriesColor(context) : colors.primary;
    // A missing rate is "no sample yet", not a measured zero: rendering 0 B/s
    // for an empty map made a dead feed look like an idle tunnel.
    final rate = traffic.rates[upload ? 'upload' : 'download'] as num?;
    final show = rate == null ? null : bytes(rate).split(' ');
    // The bridge sends the session total as a raw byte count; a pre-formatted string passes through.
    final raw = traffic.dashboard[upload ? 'uploadTotal' : 'downloadTotal'];
    final total = raw is num ? bytes(raw) : (raw?.toString() ?? '0 B');
    final scale = math.max(1.0, MediaQuery.textScalerOf(context).scale(1));
    final chartTop = _padding.top + _titleGap + AppTextStyle.footnote.leading * scale;
    return LayoutBuilder(builder: (context, constraints) {
      return Container(
        constraints: BoxConstraints(minHeight: constraints.maxWidth / _aspectRatio),
        clipBehavior: Clip.antiAlias,
        decoration: ShapeDecoration(color: SurfaceLevel.block.colorOf(colors), shape: AppShape.all(22)),
        child: Stack(children: [
          Positioned(
            left: -_bleed, right: -_bleed, top: chartTop, bottom: -_bleed,
            child: RepaintBoundary(child: LineChart(
              values: List.of(upload ? box.uploadHistory : box.downloadHistory), revision: box.sampleRevision,
              capacity: BoxController.trafficWindow, minScale: 8 * 1024, baselineRatio: 1,
              color: color,
            )),
          ),
          Padding(padding: _padding, child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(spacing: 4, children: [
                GlyphIcon(upload ? AppGlyphs.arrowUp : AppGlyphs.arrowDown, size: 16, color: color),
                Flexible(child: Text(context.tr(upload ? 'Upload' : 'Download'), maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.footnote.of(context, emphasized: true).copyWith(color: colors.onSurfaceVariant))),
              ]),
              const SizedBox(height: _titleGap),
              // Scale the figure down instead of clipping it: at the app's
              // largest text scale a value like `123.45 Mbps/s` is wider than
              // the phone's half-width tile, and a hard clip ate the last
              // digits (no ellipsis made it look like a rendering bug).
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: show?.first ?? '--', style: AppTextStyle.title1.of(context, emphasized: true).toTabular.copyWith(letterSpacing: -.02 * AppTextStyle.title1.size)),
                  if (show != null)
                    TextSpan(text: ' ${show.last}/s', style: AppTextStyle.footnote.of(context, emphasized: true).copyWith(color: colors.onSurfaceVariant)),
                ]), maxLines: 1),
              ),
              Text('${context.tr('Total')} $total',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTextStyle.caption1.of(context).toTabular.copyWith(color: colors.onSurfaceVariant)),
            ],
          )),
        ]),
      );
    });
  }
}

// FlClash Android's outbound_mode.dart, using sing-box's case-insensitive modes.
class _ModePanel extends ConsumerWidget {
  const _ModePanel();
  @override Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(boxControllerProvider);
    final layout = ref.watch(dashboardLayoutProvider);
    // The dashboard map comes off the channel: a half-written or hostile payload used to
    // throw on the cast and take the whole home screen down with it.
    final modes = layout.modes.isEmpty ? const <String>[] : layout.modes.split('\u0000');
    if (modes.isEmpty) return const SizedBox.shrink();
    final selected = layout.mode;
    return BoxPanel(child: Column(children: [
      const PanelTitle('Outbound', AppGlyphs.split),
      const SizedBox(height: 12),
      DashboardConnectedGroup(children: [
        for (final (index, mode) in modes.indexed) Expanded(key: ValueKey(mode), child: DashboardConnectedButton(
          selected: mode.toLowerCase() == selected, first: index == 0, last: index == modes.length - 1,
          outer: 26, inner: 12, background: SurfaceLevel.block.colorOf(context.colorScheme),
          semanticLabel: context.tr({'rule': 'Rule', 'global': 'Global', 'direct': 'Direct'}[mode.toLowerCase()] ?? mode),
          onTap: () { if (mode.toLowerCase() != selected) box.modeSet(mode); },
          builder: (foreground) => SizedBox(height: 52, child: Column(
            mainAxisAlignment: MainAxisAlignment.center, spacing: 2, children: [
              GlyphIcon({'rule': AppGlyphs.rules, 'global': AppGlyphs.proxies, 'direct': AppGlyphs.target}[mode.toLowerCase()] ?? AppGlyphs.split, size: 18, color: foreground),
              Text(context.tr({'rule': 'Rule', 'global': 'Global', 'direct': 'Direct'}[mode.toLowerCase()] ?? mode),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTextStyle.footnote.of(context, emphasized: true).copyWith(color: foreground)),
            ],
          )),
        )),
      ]),
    ]));
  }
}
