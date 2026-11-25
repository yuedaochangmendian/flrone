import 'dart:async';
import 'package:flutter/services.dart';
import '../widgets.dart';
import '../components/form.dart';
import '../components/configuration_card.dart';
import 'configuration_editor.dart';
import 'configuration_details.dart';
import 'protocol_form.dart';
import 'nodes.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

// libbox remote_profile.go stores the display name in the URL fragment.
String remoteConfigurationLink(Json profile) => Uri(
  scheme: 'sing-box', host: 'import-remote-profile',
  queryParameters: {'url': profile['url'].toString()},
  fragment: profile['name'].toString(),
).toString();

// The typed-form protocols the manual "New node" flow can start from, in the native editor's order.
const manualProtocols = <(String, String)>[
  ('chain', 'Chain Proxy'),
  ('shadowsocks', 'Shadowsocks'), ('vmess', 'VMess'), ('vless', 'VLESS'),
  ('trojan', 'Trojan'), ('hysteria', 'Hysteria'),
  ('tuic', 'TUIC'), ('juicity', 'Juicity'), ('anytls', 'AnyTLS'), ('shadowtls', 'ShadowTLS'),
  ('socks', 'Socks'), ('http', 'HTTP'), ('wireguard', 'WireGuard'), ('masque', 'MASQUE'),
  ('ssh', 'SSH'), ('snell', 'Snell'), ('naive', 'Naive'), ('mieru', 'Mieru'),
  ('trusttunnel', 'TrustTunnel'), ('openconnect', 'OpenConnect'), ('openvpn', 'OpenVPN'),
  ('direct', 'Direct'),
];

class ConfigurationsPage extends ConsumerStatefulWidget {
  const ConfigurationsPage({super.key, this.picker = false});
  final bool picker;
  @override ConsumerState<ConfigurationsPage> createState() => _ConfigurationsPageState();
}
class _ConfigurationsPageState extends ConsumerState<ConfigurationsPage> {
  final _updating = <int>{};
  bool _updatingAll = false;

  /// A profile card's `id` is its subscription group id (FlroneCatalog.profileOf), so the
  /// live queue state pushed by `subscriptionState` maps straight onto it. OR-ing this
  /// into `_updating` keeps the spinner up for the whole download: `configurationUpdate` only
  /// awaits the enqueue, which returns in milliseconds.
  bool _isUpdating(BoxController box, dynamic id) =>
      _updating.contains(id) || (box.subscriptionStates[(id as num).toInt()] ?? 0) != 0;

  /// Whether any remote group is currently queued/running. Used by the "Update all"
  /// guard so a second tap cannot be dispatched while downloads are still in flight.
  bool _anyUpdating(BoxController box) =>
      _updating.isNotEmpty || box.subscriptionStates.values.any((state) => state != 0);

  /// The menu's single refresh: one profile, so a refusal is one snackbar.
  /// "Update all" uses [BoxController.configurationUpdateOutcome] instead — N
  /// snackbars for one tap is exactly what its aggregate replaces.
  Future<void> _update(Json profile) async {
    final id = (profile['id'] as num).toInt();
    if (_updating.contains(id)) return;
    setState(() => _updating.add(id));
    try { await ref.read(boxControllerProvider).configurationUpdate(id); }
    finally { if (mounted) setState(() => _updating.remove(id)); }
  }

  /// How long a run waits for the host's first queue-state event before it
  /// accepts "nothing is queued" as the truth. The enqueue returns before the
  /// state event lands, and a summary printed then would call a profile that
  /// has not downloaded yet a success.
  static const _stateGrace = Duration(milliseconds: 600);

  /// A hung download must not pin the summary forever: the run reports the
  /// failures it has collected by this point.
  static const _runTimeout = Duration(minutes: 5);

  /// The settle window's beat.
  static const _pollInterval = Duration(milliseconds: 200);

  /// The profile name a report's `groupName` is matched against. Group display
  /// names are profile names (`FlroneCatalog.profileOf`), so one lookup serves
  /// both the enqueue failures and the download reports.
  static String _nameOf(Json profile) => profile['name']?.toString() ?? '';

  /// Every remote profile in one run, ending in **one** result surface: the
  /// failures are collected per profile (name + error) instead of arriving as
  /// one snackbar each, and the successes are counted. FlClash's update-all
  /// ends the same way (`profiles.dart` updateAll).
  Future<void> _updateAll() async {
    final box = ref.read(boxControllerProvider);
    if (_updatingAll || _anyUpdating(box)) return;
    final profiles = List<Json>.of(box.configurations).where((p) => p['remote'] == true).toList();
    if (profiles.isEmpty) return;
    // Quiets the per-item report surfaces for the span of the run: the queue's
    // own errors land in the collector, not in one snackbar per subscription.
    final collector = SubscriptionReportCollector();
    box.subscriptionCollector = collector;
    setState(() => _updatingAll = true);
    final attempted = <String>[];
    final failures = <String>[];
    final failedNames = <String>{};
    // Unnamed error reports cannot be pinned to a profile and must not be
    // counted as a failed profile (the success count is attempted - failures).
    // They are still shown, beside the named failures.
    final otherErrors = <String>[];
    final targets = <int>{};
    try {
      // Native profile writes share a mutex; keep updates serialized.
      for (final profile in profiles) {
        // A stop mid-run (remote session, page gone) reports what it has.
        if (!mounted || box.remote) break;
        final name = _nameOf(profile);
        final id = (profile['id'] as num?)?.toInt() ?? 0;
        if (id > 0) targets.add(id);
        attempted.add(name);
        final error = await _enqueue(box, profile);
        if (error != null) {
          failedNames.add(name);
          failures.add('$name: $error');
        }
      }
      // The enqueues alone say nothing about the downloads: wait for the queue
      // to let them go before the summary claims a result.
      if (mounted && !box.remote) await _awaitRun(box, targets);
    } finally {
      // One-shot seam: a leftover collector would silence every later report.
      if (identical(box.subscriptionCollector, collector)) box.subscriptionCollector = null;
      if (mounted) setState(() => _updatingAll = false);
    }
    _foldReports(collector, failedNames, failures, otherErrors);
    if (!mounted) return;
    _showUpdateResult(attempted, failures, otherErrors);
  }

  /// Enqueues one refresh and answers the host's refusal, without a snackbar.
  Future<String?> _enqueue(BoxController box, Json profile) async {
    final id = (profile['id'] as num).toInt();
    setState(() => _updating.add(id));
    try {
      return (await box.configurationUpdateOutcome(id)).error;
    } finally { if (mounted) setState(() => _updating.remove(id)); }
  }

  /// Waits until no target group is queued or running, so the aggregate can
  /// tell a finished download from a queued one. Bounded by [_runTimeout].
  ///
  /// The window is counted in polls, not wall-clock time: the delay is what
  /// drives it (a widget test's fake clock advances `Future.delayed` but not
  /// `DateTime.now()`, which would make the loop spin for real minutes).
  Future<void> _awaitRun(BoxController box, Set<int> targets) async {
    if (targets.isEmpty) return;
    final gracePolls = _stateGrace.inMilliseconds ~/ _pollInterval.inMilliseconds;
    final maxPolls = _runTimeout.inMilliseconds ~/ _pollInterval.inMilliseconds;
    var queued = false;
    for (var poll = 0; poll < maxPolls; poll++) {
      if (!mounted || box.remote) return;
      final busy = targets.any(box.subscriptionStates.containsKey);
      queued = queued || busy;
      if (!busy && (queued || poll >= gracePolls)) return;
      await Future<void>.delayed(_pollInterval);
    }
  }

  /// Folds the run's held reports into the same failure list as the enqueue
  /// refusals. Only `error` reports are failures; a popup/status line belongs to
  /// a profile that did download, and its change window was traded for this
  /// surface on purpose.
  void _foldReports(SubscriptionReportCollector collector, Set<String> failedNames, List<String> failures, List<String> otherErrors) {
    for (final report in collector.reports) {
      if (report['kind'] != 'error') continue;
      final text = report['text']?.toString() ?? '';
      final name = report['groupName']?.toString() ?? '';
      // An unnamed report cannot be pinned on a profile, so it must not count
      // as a failed profile. Its text is still surfaced through `otherErrors`.
      if (name.isEmpty) {
        otherErrors.add(text);
      } else if (failedNames.add(name)) {
        failures.add('$name: $text');
      }
    }
  }

  /// The run's one result: a banner when every profile made it, a dialog that
  /// lists the failures beside the success count when some did not.
  void _showUpdateResult(List<String> attempted, List<String> failures, List<String> otherErrors) {
    // The successes are the attempted profiles no failure names, so the count
    // can never claim more than the run actually started. Unnamed errors are
    // not profiles and are deliberately excluded from `failures`.
    final updated = (attempted.length - failures.length).clamp(0, attempted.length);
    final details = [...failures, ...otherErrors];
    if (details.isEmpty) {
      showAppBanner(context, context.tr('Updated {count} profiles').replaceAll('{count}', '$updated'));
      return;
    }
    showAppDialog<void>(context, child: Builder(builder: (dialogContext) => AlertDialog(
      title: dialogContext.tr('Some profiles were not updated'),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, spacing: 12, children: [
          Text(dialogContext.tr('Updated: {updated} · Failed: {failed}')
            .replaceAll('{updated}', '$updated').replaceAll('{failed}', '${failures.length}')),
          // A long list scrolls inside the alert; the summary and the retry
          // hint stay put, so neither can be scrolled out of the message.
          ConstrainedBox(constraints: const BoxConstraints(maxHeight: 280), child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, spacing: 8,
              children: [for (final failure in details) SelectableText(failure)]),
          )),
          Text(dialogContext.tr('Tap update all again to retry the failed profiles.')),
        ],
      )),
      actions: [
        TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: details.join('\n'))),
          child: Text(dialogContext.tr('Copy'))),
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(dialogContext.tr('OK'))),
      ],
    )));
  }

  Future<void> _export(Json profile) async {
    final box = ref.read(boxControllerProvider);
    try {
      final content = await box.configurationRead(profile['id']);
      await box.documentSave('${profile['name']}.json', content);
    } catch (error) { box.report(error); }
  }
  Future<void> _share(Json profile) async {
    final box = ref.read(boxControllerProvider);
    try {
      final content = profile['remote'] == true ? remoteConfigurationLink(profile) : await box.configurationRead(profile['id']);
      await box.shareText(content);
    } catch (error) { box.report(error); }
  }
  List<PopupMenuItem> _menu(Json profile) => [
    PopupMenuItem(glyph: AppGlyphs.edit, label: context.tr('Edit'), onPressed: () => openForm(context, ConfigurationDetailsPage(profile: profile))),
    if (profile['remote'] == true)
      PopupMenuItem(glyph: AppGlyphs.sync, label: context.tr('Update'), onPressed: () => _update(profile)),
    if (profile['remote'] == true) ...[
      PopupMenuItem(glyph: AppGlyphs.copy, label: context.tr('Copy link'), onPressed: () async {
        await Clipboard.setData(ClipboardData(text: profile['url'].toString()));
        if (mounted) showAppBanner(context, context.tr('Copied'));
      }),
      PopupMenuItem(glyph: AppGlyphs.qrCode, label: context.tr('QR code'), onPressed: () => openForm(context, BoxPage(title: 'QR code', children: [
        Center(child: QrCodeView(data: remoteConfigurationLink(profile))),
      ]))),
    ],
    PopupMenuItem(glyph: AppGlyphs.upload, label: context.tr('Share'), onPressed: () => _share(profile)),
    PopupMenuItem(glyph: AppGlyphs.export, label: context.tr('Export'), onPressed: () => _export(profile)),
    PopupMenuItem(danger: true, glyph: AppGlyphs.delete, label: context.tr('Delete'), onPressed: () async {
      final box = ref.read(boxControllerProvider);
      // The General page offers "Skip delete confirmation"; honour it here, or
      // the toggle promised something the delete path never did.
      if (box.settings['skipDeleteConfirmation'] != true &&
          !await confirm(context, 'Delete this profile?', message: 'This cannot be undone.')) {
        return;
      }
      await box.configurationDelete(profile['id']);
    }),
  ];

  /// The two pages this screen hosts: the profile grid and the selected
  /// profile's nodes. The switch is the screen's own header; a picker and a
  /// remote session keep the single-page layout, because neither has a node
  /// page to switch to.
  int _page = 0;

  /// The page the user left this screen on, persisted so reopening the app does
  /// not reset the mode to the profile grid. The selection itself is the host's
  /// (`DataStore.selectedProxy`), so the node page comes back on the container
  /// that was current.
  static const _modeKey = 'profilesMode';
  final _nodes = GlobalKey<NodesViewState>();

  /// The node page is built on first open: a profile screen that never visits it
  /// must not ask the host for a node list (or hold its scroll state).
  bool _nodesBuilt = false;

  Future<int> _reloadNodes() async => await _nodes.currentState?.reload() ?? 0;

  /// The configuration the user was on before entering the single-node mode, so
  /// leaving it restores that subscription. Session-scoped: a cold start that
  /// reopened in node mode falls back to the profile the user last picked.
  int? _previousGroupId;

  @override
  void initState() {
    super.initState();
    // Reopen on the page the user left: the mode is part of the screen's state,
    // and resetting to the grid on every launch was the "closes and starts over"
    // behaviour. The host selection already persists, so the node page comes
    // back on the container it was showing.
    final saved = (ref
                .read(boxControllerProvider)
                .preferences[_modeKey] as num?)
            ?.toInt() ??
        0;
    if (saved == 1) {
      _page = 1;
      _nodesBuilt = true;
      final box = ref.read(boxControllerProvider);
      WidgetsBinding.instance.addPostFrameCallback((_) => _enterNodeMode(box));
    }
  }

  /// Makes the single-node container the current configuration and loads its
  /// rows. Shared by the mode switch and the persisted-mode restore.
  Future<void> _enterNodeMode(BoxController box) async {
    final groupId = await _reloadNodes();
    if (!mounted || _page != 1 || groupId <= 0) return;
    if (box.selectedConfigurationId != groupId) await box.configurationSelect(groupId);
  }

  /// The bar's page button: profiles ⇄ nodes.
  ///
  /// It switches the configuration too, which is what makes the two pages two
  /// modes: entering the node page makes the single-node container the current
  /// configuration, and going back restores the subscription the user was on.
  /// The node list follows the same switch — its container is the current
  /// configuration while it is on screen. The mode is persisted, so the next
  /// launch opens on the same page.
  void _showPage(int page) {
    if (_page == page || !mounted) return;
    final box = ref.read(boxControllerProvider);
    unawaited(box.setPreference(_modeKey, page));
    if (page == 1) {
      final previous = box.selectedConfigurationId;
      if (previous > 0) _previousGroupId = previous;
      setState(() {
        _page = 1;
        _nodesBuilt = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _enterNodeMode(box));
      return;
    }
    setState(() => _page = 0);
    // A cold start in node mode has no session-scoped previous id: fall back to
    // the profile the user last picked on the grid, so leaving the node page
    // does not strand the selection on the hidden container.
    final previous = _previousGroupId ??
        (box.preferences[BoxController.lastConfigurationKey] as num?)?.toInt();
    _previousGroupId = null;
    if (previous != null && previous > 0) {
      unawaited(box.configurationSelect(previous));
    }
  }

  /// Imports single nodes from the clipboard: one link opens the editor on it,
  /// a list (a subscription body included) is added row by row with the
  /// importer's own refusals reported instead of failing the whole paste.
  Future<void> _importNodes() async {
    final box = ref.read(boxControllerProvider);
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
      if (!mounted) return;
      if (text.isEmpty) throw StateError(context.tr('Empty clipboard'));
      final data = await box.nodeParse(text);
      if (!mounted) return;
      final parsed = [
        for (final node in (data['nodes'] as List? ?? const [])) json(node),
      ];
      if (parsed.isEmpty) throw StateError(context.tr('No supported node found'));
      if (parsed.length == 1) {
        // One node is a review, not a bulk write: open the typed form on it. The
        // host puts it in the single-node container, not in a profile.
        await openForm(context, ProtocolFormPage(id: 0, draft: {
          'id': 0, ...parsed.single,
        }));
        return;
      }
      final failures = <String>[];
      for (final node in parsed) {
        try {
          await box.nodeCreate({
            'name': node['name'],
            'content': node['json'],
          });
        } catch (error) {
          failures.add('${node['name']}: ${BoxController.describe(error)}');
        }
      }
      if (!mounted) return;
      final skipped = (data['skipped'] as num?)?.toInt() ?? 0;
      showAppBanner(
        context,
        failures.isNotEmpty
            ? failures.first
            : context.tr(skipped > 0 ? 'Nodes imported, some skipped' : 'Nodes imported'),
        level: failures.isNotEmpty ? BannerLevel.warning : BannerLevel.info,
      );
    } catch (error) {
      box.report(error);
    } finally {
      await _reloadNodes();
    }
  }

  /// A typed node of [type] in the selected profile, opened in the form.
  Future<void> _createNode(String type) async {
    final box = ref.read(boxControllerProvider);
    try {
      final info = json(await box.createNode(type));
      if (mounted) await openForm(context, ProtocolFormPage(id: 0, draft: info));
    } catch (error) {
      box.report(error);
    } finally {
      await _reloadNodes();
    }
  }

  /// A horizontal swipe moves between the profile grid and the node page,
  /// mirroring the bar's mode switch. The gesture only participates when the
  /// node page exists; vertical list scrolling keeps the arena.
  Widget _swipePages(bool enabled, Widget child) {
    if (!enabled) return child;
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity <= -300 && _page == 0) {
          _showPage(1);
        } else if (velocity >= 300 && _page == 1) {
          _showPage(0);
        }
      },
      child: child,
    );
  }

  @override Widget build(BuildContext context) {
    final box = ref.watchBoxState();
    // The two modes: this grid is the profile list (subscriptions and local
    // configs); manually imported single nodes live in their own container and
    // have the node page. `single` marks that container so it never shows here.
    final profiles = [
      for (final profile in box.configurations)
        if (profile['single'] != true) profile,
    ];
    // A picker and a remote session have no node page; otherwise the node page is reachable as soon as
    // there is something to attach nodes to — a profile card, or the single-node container itself (an
    // install whose only content is imported nodes has no card, and the node page must still open).
    final hasNodeContainer = box.configurations.any((profile) => profile['single'] == true);
    final twoPages = !widget.picker && !box.remote && (profiles.isNotEmpty || hasNodeContainer);
    final showNodes = twoPages && _page == 1;
    final grid = NullStatusSwitcher(
      isEmpty: profiles.isEmpty,
      nullStatus: NullStatus(
        label: context.tr('No profiles yet'), illustration: NullStatusIllustration.profile,
        description: context.tr('Import a sing-box JSON configuration to get started.'),
        action: AddConfigurationMenu(builder: (open) => TonalButton(size: TonalButtonSize.bar, glyph: AppGlyphs.addCircle,
          label: context.tr('Add profile'), onPressed: open), onNodeImported: () => _showPage(1)),
      ),
      child: _ConfigurationsGrid(profiles: profiles, selectedId: box.selectedConfigurationId, picker: widget.picker,
        itemBuilder: (context, profile) => ConfigurationCard(
          key: ValueKey(profile['id']), profile: profile,
          selected: profile['id'] == box.selectedConfigurationId,
          updating: _isUpdating(box, profile['id']),
          menuItems: _menu(profile),
          onPressed: box.remote ? null : () async {
            // FlClash never disables its profile cards on a transition —
            // a swallowed tap used to leave the whole grid dead for seconds.
            // New requests win; the selection epoch discards stale rebuilds
            // (KernelService.onSelectionChanged).
            if (box.remote) return;
            final id = profile['id'];
            if (await box.configurationSelect(id)) {
              // Remember the choice across restarts; restoring it is
              // BoxController._restoreSelectionOnce. The node page's container
              // selection never comes through this path, so a visit to it
              // cannot overwrite what the user actually picked here.
              unawaited(box.setPreference(BoxController.lastConfigurationKey, id));
              if (widget.picker && context.mounted) context.safeNestedPop();
            }
          },
        ),
      ),
    );
    final actions = <Widget>[
      // Bettbox keeps the sibling pages on one control: this bar button flips
      // between the configuration grid and its node page, and the add action
      // follows it.
      if (twoPages) IconButton(
        key: const ValueKey('profiles-mode-switch'),
        tooltip: context.tr(showNodes ? 'Profiles' : 'Nodes'),
        icon: GlyphIcon(showNodes ? AppGlyphs.profiles : AppGlyphs.devices),
        onPressed: () => _showPage(showNodes ? 0 : 1),
      ),
      if (showNodes)
        AddNodeMenu(
          builder: (open) => IconButton(
            tooltip: context.tr('Add node'), icon: const GlyphIcon(AppGlyphs.addCircle),
            onPressed: open,
          ),
          onImport: _importNodes,
          onCreate: _createNode,
        )
      else if (!box.remote && !widget.picker)
        AddConfigurationMenu(builder: (open) => IconButton(
          tooltip: context.tr('Add profile'), icon: const GlyphIcon(AppGlyphs.addCircle),
          onPressed: open,
        ), onNodeImported: () => _showPage(1)),
    ];
    return Scaffold(
      title: context.tr(showNodes ? 'Nodes' : 'Profiles'),
      actions: actions.isEmpty ? null : actions,
      iconActions: box.capabilities.of('tv') && twoPages && profiles.length > 1 ? [
        // The television has no notification shade, so the profiles toolbar carries the
        // previous / next server pair (TvControls.addServerSwitch gated on isTv there).
        IconButtonData(glyph: AppGlyphs.chevronBack, tooltip: context.tr('Previous server'),
          onPressed: () => box.configurationSwitchRelative(-1)),
        IconButtonData(glyph: AppGlyphs.chevronForward, tooltip: context.tr('Next server'),
          onPressed: () => box.configurationSwitchRelative(1)),
      ] : const [],
      // Update all and Reorder live in the overflow menu: the bar keeps the
      // mode switch, add, and (on TV) the sibling-server pair.
      menuItems: [
        PopupMenuItem(glyph: AppGlyphs.sync, label: context.tr('Update all'),
          onPressed: _updatingAll || _anyUpdating(box) || !profiles.any((p) => p['remote'] == true) ? null : _updateAll),
        PopupMenuItem(glyph: AppGlyphs.sort, label: context.tr('Reorder'),
          onPressed: profiles.length < 2 ? null : () => openForm(context, const ConfigurationOrderPage())),
      ],
      body: box.remote
          ? NullStatus(label: context.tr('Disconnect remote session to edit local profiles'), illustration: NullStatusIllustration.profile)
          : _swipePages(
              twoPages,
              twoPages
                  ? IndexedStack(index: _page, children: [
                      grid,
                      if (_nodesBuilt) NodesView(key: _nodes) else const SizedBox.shrink(),
                    ])
                  : grid,
            ),
    );
  }
}

class _ConfigurationsGrid extends StatefulWidget {
  const _ConfigurationsGrid({required this.profiles, required this.selectedId, required this.picker, required this.itemBuilder});
  final List<Json> profiles;
  final int selectedId;
  final bool picker;
  final Widget Function(BuildContext context, Json profile) itemBuilder;
  @override State<_ConfigurationsGrid> createState() => _ConfigurationsGridState();
}

class _ConfigurationsGridState extends State<_ConfigurationsGrid> {
  late final _scroll = sheetScrollController(context);
  bool _revealed = false;

  @override void dispose() { _scroll.dispose(); super.dispose(); }

  @override Widget build(BuildContext context) {
    final active = PageActivityScope.isActiveOf(context);
    final spacing = (context.isMobileView ? 8.0 : 12.0).mAp(context);
    final padding = EdgeInsets.fromLTRB(16, context.contentTopPadding, 16, 16 + context.bottomInset);
    final height = configurationCardHeight(context);
    return LayoutBuilder(builder: (context, constraints) {
      final columns = ((constraints.maxWidth - 32 + spacing) / (300.ap(context) + spacing)).floor().clamp(1, 3);
      if (!_revealed && !widget.picker && active && widget.profiles.isNotEmpty) {
        _revealed = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          final index = widget.profiles.indexWhere((p) => p['id'] == widget.selectedId);
          if (index < 0) return;
          final position = _scroll.position;
          final top = (index ~/ columns) * (height + spacing);
          final bottom = top + padding.vertical + height - position.viewportDimension;
          if (position.pixels >= bottom && position.pixels <= top) return;
          _scroll.jumpTo(((top + bottom) / 2).clamp(position.minScrollExtent, position.maxScrollExtent));
        });
      }
      return GridView.builder(
        key: PageStorageKey(widget.picker ? 'profile-picker' : 'profiles'),
        controller: _scroll, padding: padding,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns,
          mainAxisSpacing: spacing, crossAxisSpacing: spacing, mainAxisExtent: height),
        itemCount: widget.profiles.length,
        itemBuilder: (context, index) => widget.itemBuilder(context, widget.profiles[index]),
      );
    });
  }
}

Future<void> _importProfile(BuildContext context, BoxController box, String source,
    {VoidCallback? onNodeImported}) async {
  final emptyClipboard = context.tr('Empty clipboard');
  try {
    Json? data;
    switch (source) {
      case 'File':
        final result = await box.configurationImportFile();
        if (result != null) data = json(result);
      case 'Clipboard':
        final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
        if (text == null || text.isEmpty) throw StateError(emptyClipboard);
        data = await decodeImport(box, text);
      case 'Scan QR code':
        data = await openPage<Json>(context, const ScanPage());
    }
    if (data != null && context.mounted) {
      await openForm(context, ConfigurationForm(initial: data, onNodeImported: onNodeImported));
    }
  } catch (error) { box.report(error); }
}

class AddConfigurationMenu extends ConsumerStatefulWidget {
  const AddConfigurationMenu({super.key, required this.builder, this.onNodeImported});
  final Widget Function(PopupOpen open) builder;

  /// A single node was imported from this menu; see [ConfigurationForm.onNodeImported].
  final VoidCallback? onNodeImported;

  @override ConsumerState<AddConfigurationMenu> createState() => _AddProfileMenuState();
}

class _AddProfileMenuState extends ConsumerState<AddConfigurationMenu> {
  bool _busy = false;
  Future<void> _import(String source) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _importProfile(context, ref.read(boxControllerProvider), source,
          onNodeImported: widget.onNodeImported);
    } finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _createSelector() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // The new selector tracks the group the user is looking at, not whichever group happens to be first.
      if (mounted) await openPage(context, const AutoSelectorPage(id: 0));
    } catch (error) { if (mounted) ref.read(boxControllerProvider).report(error); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _createNode(String type) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // A fresh node of the chosen protocol, opened straight into the typed form.
      final info = json(await ref.read(boxControllerProvider).createNode(type));
      if (mounted) await openForm(context, ProtocolFormPage(id: 0, draft: info));
    } catch (error) { if (mounted) ref.read(boxControllerProvider).report(error); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  @override Widget build(BuildContext context) => AbsorbPointer(absorbing: _busy, child: PopupAnchor(
    targetBuilder: widget.builder,
    popupBuilder: (_) => PopupMenu(items: [
      PopupMenuItem(glyph: AppGlyphs.qrCode, label: context.tr('Scan QR code'), onPressed: () => _import('Scan QR code')),
      PopupMenuItem(glyph: AppGlyphs.importFile, label: context.tr('File'), onPressed: () => _import('File')),
      PopupMenuItem(glyph: AppGlyphs.cloudDownload, label: context.tr('Import from URL'),
        onPressed: () => openForm(context, const ConfigurationForm(initial: {'url': '', 'remote': true}))),
      PopupMenuItem(glyph: AppGlyphs.copy, label: context.tr('Clipboard'), onPressed: () => _import('Clipboard')),
      PopupMenuItem(section: const PopupMenuSection(), glyph: AppGlyphs.add, label: context.tr('New node'), subItems: [
        for (final (type, label) in manualProtocols)
          PopupMenuItem(label: label, onPressed: () => _createNode(type)),
      ]),
      PopupMenuItem(glyph: AppGlyphs.customize,
        label: context.tr('New profile'), onPressed: () => openForm(context, const ConfigurationForm(initial: {'content': '{}'}))),
      PopupMenuItem(glyph: AppGlyphs.shuffle, label: context.tr('Auto selector'), onPressed: _createSelector),
    ]),
  ));
}

/// The node page's add menu: paste a link to import, or start a typed node in
/// the selected profile. Both paths end in the typed form (or the row list),
/// so nothing is written before the user has seen what was parsed.
class AddNodeMenu extends ConsumerStatefulWidget {
  const AddNodeMenu({super.key, required this.builder, required this.onImport, required this.onCreate});
  final Widget Function(PopupOpen open) builder;
  final Future<void> Function() onImport;
  final Future<void> Function(String type) onCreate;
  @override ConsumerState<AddNodeMenu> createState() => _AddNodeMenuState();
}

class _AddNodeMenuState extends ConsumerState<AddNodeMenu> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override Widget build(BuildContext context) => AbsorbPointer(absorbing: _busy, child: PopupAnchor(
    targetBuilder: widget.builder,
    popupBuilder: (_) => PopupMenu(items: [
      PopupMenuItem(glyph: AppGlyphs.paste, label: context.tr('Import from clipboard'),
        onPressed: () => _run(widget.onImport)),
      PopupMenuItem(section: const PopupMenuSection(), glyph: AppGlyphs.add, label: context.tr('New node'), subItems: [
        for (final (type, label) in manualProtocols)
          PopupMenuItem(label: label, onPressed: () => _run(() => widget.onCreate(type))),
      ]),
    ]),
  ));
}

class AddConfigurationPage extends ConsumerStatefulWidget {
  const AddConfigurationPage({super.key});
  @override ConsumerState<AddConfigurationPage> createState() => _AddProfilePageState();
}
class _AddProfilePageState extends ConsumerState<AddConfigurationPage> {
  bool _loading = false;
  Future<void> _import(String source) async {
    if (_loading) return;
    setState(() => _loading = true);
    try { await _importProfile(context, ref.read(boxControllerProvider), source); }
    finally { if (mounted) setState(() => _loading = false); }
  }
  Future<void> _createSelector() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      // The new selector tracks the group the user is looking at, not whichever group happens to be first.
      if (mounted) await openPage(context, const AutoSelectorPage(id: 0));
    } catch (error) { if (mounted) ref.read(boxControllerProvider).report(error); }
    finally { if (mounted) setState(() => _loading = false); }
  }
  Future<void> _createNode(String type) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final info = json(await ref.read(boxControllerProvider).createNode(type));
      if (mounted) await openForm(context, ProtocolFormPage(id: 0, draft: info));
    } catch (error) { if (mounted) ref.read(boxControllerProvider).report(error); }
    finally { if (mounted) setState(() => _loading = false); }
  }
  Future<void> _pickNode() async {
    if (_loading) return;
    final type = await showOptionSheet<String>(
      context: context,
      title: context.tr('New node'),
      options: [for (final (type, label) in manualProtocols) (type, label)],
    );
    if (type == null || !mounted) return;
    await _createNode(type);
  }
  @override Widget build(BuildContext context) => BoxPage(
    title: 'Add profile', loading: _loading,
    children: [
      generateSection(items: [
        ListItem.open(leading: const GlyphIcon(AppGlyphs.link), title: Text(context.tr('Import from URL')),
          widget: const ConfigurationForm(initial: {'url': '', 'remote': true}), forceFull: false),
        for (final item in [('File', AppGlyphs.profiles), ('Clipboard', AppGlyphs.copy), ('Scan QR code', AppGlyphs.qrCode)])
          ListItem(leading: GlyphIcon(item.$2), title: Text(context.tr(item.$1)), onTap: _loading ? null : () => _import(item.$1)),
        ListItem(leading: const GlyphIcon(AppGlyphs.add), title: Text(context.tr('New node')),
          onTap: _loading ? null : _pickNode),
        ListItem.open(leading: const GlyphIcon(AppGlyphs.add), title: Text(context.tr('New profile')),
          widget: const ConfigurationForm(initial: {'content': '{}'}), forceFull: false),
        ListItem(leading: const GlyphIcon(AppGlyphs.shuffle), title: Text(context.tr('Auto selector')),
          onTap: _loading ? null : _createSelector),
      ], footer: context.tr('This URL must serve a sing-box JSON configuration.')),
    ],
  );
}

Future<Json> decodeImport(BoxController box, String text) async {
  // The host runs Throne's own importer: share links, base64 subscriptions and JSON/YAML documents
  // all come back as the same editor draft, and invalid text reports the importer's own reason.
  return json(await box.configurationDecodeIntent(text.trim()));
}

class ConfigurationForm extends ConsumerStatefulWidget {
  const ConfigurationForm({super.key, required this.initial, this.onNodeImported});
  final Json initial;

  /// A single node was imported into the node container. The screen hosting this
  /// form switches to its node page: the container is hidden from the profile
  /// grid, so without the switch the just-imported node would land nowhere the
  /// user can see.
  final VoidCallback? onNodeImported;
  @override ConsumerState<ConfigurationForm> createState() => _ConfigurationFormState();
}
class _ConfigurationFormState extends ConsumerState<ConfigurationForm> {
  late final _name = TextEditingController(text: widget.initial['name'] as String? ?? '');
  late final _url = TextEditingController(text: widget.initial['url'] as String? ?? '');
  late final _interval = TextEditingController(text: (widget.initial['interval'] ?? 60).toString());
  late bool _remote = widget.initial['remote'] == true || _url.text.isNotEmpty;
  late bool _auto = widget.initial['autoUpdate'] != false;
  bool _saving = false, _attempted = false;
  // Anything the user touched: the sheet's dismiss guard asks before throwing
  // the edits away.
  bool _dirty = false;
  String? _errorMessage;

  ({String field, String message})? get _issue {
    // A subscription names itself (Profile-Title, then the URL host), so its
    // name is optional; a local profile is named by the user.
    if (!_remote && _name.text.trim().isEmpty) {
      return (field: 'name', message: '${context.tr('Name')}: ${context.tr('Required')}');
    }
    if (!_remote) return null;
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
      return (field: 'url', message: context.tr('sing-box JSON URL'));
    }
    if (_auto && (int.tryParse(_interval.text) ?? 0) < 15) {
      return (field: 'interval', message: context.tr('At least 15 minutes'));
    }
    return null;
  }
  void _changed(String _) {
    _dirty = true;
    if (_attempted) setState(() { _errorMessage = null; });
  }

  @override void dispose() { _name.dispose(); _url.dispose(); _interval.dispose(); super.dispose(); }
  Future<void> _save() async {
    if (_saving) return;
    final imported = (widget.initial['nodeCount'] as num?)?.toInt();
    if (_issue != null) { setState(() => _attempted = true); return; }
    final box = ref.read(boxControllerProvider);
    setState(() => _saving = true);
    try {
      final interval = int.tryParse(_interval.text);
      final previousInterval = (widget.initial['interval'] as num?)?.toInt() ?? 60;
      await box.configurationSave({
        ...widget.initial, 'name': _name.text.trim(), 'url': _remote ? _url.text.trim() : '',
        'autoUpdate': _remote && _auto,
        'interval': interval != null && interval >= 15 ? interval : previousInterval >= 15 ? previousInterval : 60,
      });
      // A single node goes into the hidden node container, not into the grid: the host that opened this
      // form switches to its node page so the import ends where the node is visible. Switch before the
      // pop: the callback belongs to the page under this sheet, and popping first can unmount it.
      if (imported == 1 && !_remote) widget.onNodeImported?.call();
      if (mounted) context.safeNestedPop();
    } catch (error) {
      // A subscription is downloaded and validated before its row exists, so a failure comes back here with the
      // reason (an HTTP status, an empty body, a blocked web page) and leaves no group behind. Keep the sheet open
      // and show the reason on the form's error line, not only as a transient message.
      box.report(error);
      if (mounted) setState(() => _errorMessage = BoxController.describe(error));
    }
    if (mounted) setState(() => _saving = false);
  }
  @override Widget build(BuildContext context) {
    final issue = _attempted ? _issue : null;
    final imported = (widget.initial['nodeCount'] as num?)?.toInt();
    return BoxEditGuard(
      dirty: _dirty && !_saving,
      busy: _saving,
      child: BoxPage(
      title: widget.initial['id'] == null ? 'Add profile' : 'Edit',
      confirmationAction: IconButtonData(glyph: AppGlyphs.check, tooltip: context.tr('Save'), isLoading: _saving, onPressed: _saving ? null : _save),
      error: _errorMessage ?? issue?.message,
      loading: _saving,
      absorbing: _saving,
      children: [
        generateSection(items: [
          FormRow(title: context.tr('Name'), invalid: issue?.field == 'name',
            trailing: FormRowTextField(controller: _name, hintText: context.tr(_remote ? 'Optional' : 'Required'),
              textInputAction: TextInputAction.next, onChanged: _changed)),
          FormRow(title: context.tr('Remote'), onPressed: () => setState(() { _remote = !_remote; _dirty = true; }),
            trailing: Switch(value: _remote, onChanged: (value) => setState(() { _remote = value; _dirty = true; }))),
          if (_remote) FormRow(title: context.tr('URL'), invalid: issue?.field == 'url',
            trailing: FormRowTextField(controller: _url, hintText: context.tr('Required'),
              keyboardType: TextInputType.text, textInputAction: TextInputAction.next,
              autocorrect: false, onChanged: _changed)),
        ], footer: _remote
            ? context.tr('This URL must serve a sing-box JSON configuration.')
            : imported == null ? null : imported == 1
                ? context.tr('One node will be imported into the node list.')
                : '$imported ${context.tr('nodes will be imported.')}'),
        if (_remote) generateSection(items: [
          FormRow(title: context.tr('Auto update'), onPressed: () => setState(() { _auto = !_auto; _dirty = true; }),
            trailing: Switch(value: _auto, onChanged: (value) => setState(() { _auto = value; _dirty = true; }))),
          if (_auto) FormRow(title: context.tr('Update interval'), invalid: issue?.field == 'interval',
            trailing: Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: [
              Flexible(child: FormRowTextField(controller: _interval, hintText: context.tr('Required'),
                keyboardType: TextInputType.number, textInputAction: TextInputAction.done,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly], onChanged: _changed)),
              Text(context.tr('minutes'), style: AppTextStyle.subheadline.of(context)),
            ])),
        ], footer: _auto ? context.tr('At least 15 minutes') : null),
        if (widget.initial['id'] != null) generateSection(items: [
          ListItem.open(title: Text(context.tr('Open configuration')), leading: const GlyphIcon(AppGlyphs.code),
            widget: ConfigurationEditor(profile: widget.initial)),
          ListItem(title: Text(context.tr('Last updated')), subtitle: Text(
            (widget.initial['updatedAt'] as num? ?? 0) <= 0 ? context.tr('Unknown') : localDate(widget.initial['updatedAt']))),
        ]),
        ],
      ),
    );
  }
}

class ConfigurationOrderPage extends ConsumerStatefulWidget {
  const ConfigurationOrderPage({super.key});
  @override ConsumerState<ConfigurationOrderPage> createState() => _ConfigurationOrderPageState();
}
class _ConfigurationOrderPageState extends ConsumerState<ConfigurationOrderPage> {
  List<Json>? _profiles;
  bool _saving = false;
  Widget _item(int index) => ReorderableDelayedDragStartListener(
    key: ValueKey(_profiles![index]['id']), index: index,
    child: ItemPositionProvider(position: ItemPosition.get(index, _profiles!.length),
      child: DecorationListItem(contentPadding: const EdgeInsets.only(left: 16),
        title: Text(_profiles![index]['name'].toString()), trailing: SortHandle(index: index))),
  );
  @override Widget build(BuildContext context) {
    final box = ref.watchBoxState();
    _profiles ??= List.of(box.configurations);
    return Scaffold(title: context.tr('Reorder'),
      confirmationAction: IconButtonData(glyph: AppGlyphs.check, tooltip: context.tr('Save'), isLoading: _saving, onPressed: _saving ? null : () async {
        setState(() => _saving = true);
        final saved = await box.configurationReorder(_profiles!.map((p) => p['id']).toList());
        if (!context.mounted) return;
        if (saved) {
          context.safeNestedPop();
        } else {
          setState(() => _saving = false);
        }
      }),
      body: AbsorbPointer(absorbing: _saving, child: ReorderableListView.builder(
        buildDefaultDragHandles: false,
        padding: EdgeInsets.fromLTRB(16, context.contentTopPadding, 16, 32 + context.bottomInset),
        itemCount: _profiles!.length,
        proxyDecorator: (child, index, animation) => commonProxyDecorator(_item(index), index, animation),
        onReorderItem: (old, next) => setState(() => _profiles!.insert(next, _profiles!.removeAt(old))),
        itemBuilder: (_, index) => _item(index),
      )),
    );
  }
}

class ScanPage extends ConsumerStatefulWidget {
  const ScanPage({super.key});
  @override ConsumerState<ScanPage> createState() => _ScanPageState();
}
class _ScanPageState extends ConsumerState<ScanPage> {
  BoxController? _box;
  bool _busy = false;
  String? _error;

  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScan());
  }

  @override void didChangeDependencies() { super.didChangeDependencies(); _box ??= ref.read(boxControllerProvider); }

  /// The camera now lives in the host's ZXing activity, not in a Flutter plugin:
  /// one channel call opens it and the decoded payload (multi-frame symbols are
  /// assembled on the host) comes back when it closes. A refused permission or a
  /// dismissed activity leaves a retry on screen instead of a black preview.
  Future<void> _startScan() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final granted = await _box!.ensureCameraPermission();
      if (!mounted) return;
      if (!granted) {
        setState(() => _error = 'The camera permission is denied. Grant it in the system settings, then try again.');
        return;
      }
      final text = await _box!.scanQrCode();
      if (!mounted) return;
      if (text == null || text.isEmpty) {
        setState(() => _error = 'Scanning was cancelled. Tap retry to open the camera again.');
        return;
      }
      final profile = await decodeImport(_box!, text);
      if (mounted) context.safeNestedPop(profile);
    } catch (error) {
      if (mounted) setState(() => _error = BoxController.describe(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
  @override Widget build(BuildContext context) => Scaffold(
    title: context.tr('Scan QR code'),
    body: Padding(padding: EdgeInsets.only(top: context.appBarInset), child: Center(child: Padding(
      padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, spacing: 16, children: [
        if (_error != null) ErrorState(context.tr(_error!), retry: _startScan)
        else ...[
          if (_busy) const ActivityIndicator(),
          Text(
            context.tr('The camera opens in the scanning screen. Point it at a configuration QR code.'),
            textAlign: TextAlign.center,
            style: AppTextStyle.subheadline.of(context),
          ),
          if (_busy) Text(context.tr('Waiting for a QR code…'),
              style: AppTextStyle.footnote.of(context).copyWith(color: context.colorScheme.onSurfaceVariant)),
        ],
      ]),
    ))),
  );
}
