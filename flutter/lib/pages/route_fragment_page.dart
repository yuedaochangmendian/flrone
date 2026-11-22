// The Routing screen, rebuilt to Throne for Android's RouteFragment (the
// desktop Routes dialog): one card per route profile, the active one marked,
// with a toolbar of the actions the kernel can actually back.
//
// What a card does
// ----------------
// Tap makes the profile current (its rules are what the core builds) and reloads
// the service. The pencil opens the editor; the ⋮ menu carries the per-profile
// actions — clone, share, update (remote only), delete. A raw profile is the
// desktop's read-only carrier: it opens the same page without the editing half,
// and it is never made current.
//
// Honesty rule
// ------------
// Every entry in both menus has a real call behind it. "Download profiles" reads
// the bundled snapshot through the host's `routes.presets` arm; the upstream
// toolbar's "Update rule-sets" (Instance.updateRuleSets over the running
// service) and "Refresh repository" (RouteRepo.refresh) have no bridge arm in
// this build, so they are not drawn: a button that fails on a press is worse
// than a missing one.

import 'dart:convert';

import 'package:flutter/services.dart';

import '../widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

/// The routing screen. `settings.dart` and `configuration.dart` open it, so the
/// name and the no-argument constructor stay as they were.
class RoutingPage extends ConsumerStatefulWidget {
  const RoutingPage({super.key});

  @override
  ConsumerState<RoutingPage> createState() => _RoutingPageState();
}

class _RoutingPageState extends ConsumerState<RoutingPage> {
  List<Json> _profiles = const [];
  Json _details = const {};
  int _currentId = 0;
  bool _loading = true;
  String? _error;

  /// The profiles whose remote rule list is being fetched right now.
  final Set<int> _updating = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // ADR 0005 phase 3: Go is the single writer/authority for the route
      // documents. The list comes off the action bus (getRouteProfiles), which
      // reads those documents. There is no channel fallback and no Room SQLite
      // read here: without the FFI driver `routeList()` throws a clear error
      // rather than showing a stale snapshot.
      final data = json(await ref.read(boxControllerProvider).routeList());
      if (!mounted) return;
      final profiles = rows(data['profiles']);
      final currentId = (data['currentId'] as num?)?.toInt() ?? 0;
      setState(() {
        _profiles = profiles;
        _currentId = currentId;
        _loading = false;
      });
      await _loadDetails(profiles);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = BoxController.describe(error);
        _loading = false;
      });
    }
  }

  /// The remote bookkeeping is not in the list wire: one `routeGetProfile` per
  /// remote profile fills the URL, the auto-update flag and the last update. A
  /// failed read only leaves the line out; the cards stay usable.
  Future<void> _loadDetails(List<Json> profiles) async {
    // The controller is captured before the first await: `ref.read(boxControllerProvider)` on a
    // deactivated context throws, and this loop can outlive the page.
    final box = ref.read(boxControllerProvider);
    final details = <String, dynamic>{};
    for (final profile in profiles) {
      if (profile['isRemote'] != true) continue;
      final id = (profile['id'] as num?)?.toInt() ?? 0;
      try {
        final answer = json(await box.routeGetProfile(id));
        if (answer.isNotEmpty) details['$id'] = answer;
      } catch (_) {
        // A profile the kernel cannot seed is shown from the list wire alone.
      }
      if (!mounted) return;
    }
    // Replaced, not merged: a profile deleted or made local since the previous load
    // used to keep its old detail line, and the map only ever grew.
    if (mounted) setState(() => _details = details);
  }

  Future<void> _reloadService() async {
    try {
      await ref.read(boxControllerProvider).serviceReload();
    } catch (_) {
      // A reload without a running service has nothing to do; the selection is
      // already saved and the next start builds from it.
    }
  }

  // --- toolbar -----------------------------------------------------------------

  Future<void> _newProfile({required bool remote}) async {
    final saved = await openPage<bool>(context, RouteProfileEditorPage(id: 0, remote: remote));
    if (saved == true) await _load();
  }

  Future<void> _importProfile() async {
    final saved = await openPage<bool>(context, const RouteImportPage());
    if (saved == true) await _load();
  }

  /// "Download profiles": the official snapshot's `Profile_<Country>` files,
  /// listed by the host's `routes.presets` arm. Picking one saves a remote
  /// profile through `routeSaveProfile`, so the kernel stays the only writer.
  Future<void> _downloadProfiles() async {
    final box = ref.read(boxControllerProvider);
    final List<Map<String, dynamic>> bundles;
    try {
      final answer = json(await box.call('routes.presets'));
      bundles = [
        for (final bundle in rows(answer['bundles']))
          {
            'country': bundle['country']?.toString() ?? '',
            'entries': rows(bundle['entries']),
          },
      ].where((bundle) => (bundle['entries'] as List).isNotEmpty).toList();
    } catch (error) {
      if (mounted) box.report(error);
      return;
    }
    if (!mounted) return;
    if (bundles.isEmpty) {
      showAppBanner(context, context.tr('The bundled snapshot has no profiles'));
      return;
    }
    final country = await showOptionSheet<String>(
      context: context,
      title: context.tr('Download profiles'),
      options: [
        for (final bundle in bundles)
          (bundle['country'] as String, '${bundle['country']} · ${(bundle['entries'] as List).length}'),
      ],
    );
    if (country == null || !mounted) return;
    final entries = bundles.firstWhere((bundle) => bundle['country'] == country)['entries'] as List;
    final picked = await showOptionSheet<String>(
      context: context,
      title: country,
      options: [for (final entry in entries) (entry['name']?.toString() ?? '', entry['name']?.toString() ?? '')],
    );
    if (picked == null || !mounted) return;
    final url = entries.firstWhere((entry) => entry['name'] == picked)['url']?.toString() ?? '';
    if (!isSafeRemoteRouteUrl(url)) {
      showAppBanner(context, context.tr('Only a public http(s) URL is accepted'), level: BannerLevel.warning);
      return;
    }
    try {
      final saved = await box.routeSaveProfile(
        id: 0,
        name: picked,
        defaultOutbound: 'proxy',
        isRemote: true,
        remoteUrl: url,
        autoUpdate: true,
      );
      final id = _savedId(saved);
      // Fetch it once, so the card starts with real rules instead of none.
      if (id > 0) {
        try {
          await updateRemoteProfile(box, id);
        } catch (error) {
          box.report(error);
        }
      }
      if (!mounted) return;
      showAppBanner(context, '${context.tr('Imported profile')}: $picked');
      await _load();
    } catch (error) {
      if (mounted) box.report(error);
    }
  }

  Future<void> _openSettings() => openPage<void>(context, const RouteEngineSettingsPage());

  Future<void> _updateAll() async {
    final remotes = [
      for (final profile in _profiles)
        if (profile['isRemote'] == true) (profile['id'] as num?)?.toInt() ?? 0,
    ].where((id) => id > 0).toList();
    if (remotes.isEmpty) {
      showAppBanner(context, context.tr('No remote route profiles'));
      return;
    }
    var updated = 0;
    final failures = <String>[];
    for (final id in remotes) {
      if (!mounted) return;
      setState(() => _updating.add(id));
      final name = _nameOf(id);
      try {
        await updateRemoteProfile(ref.read(boxControllerProvider), id);
        updated++;
      } catch (error) {
        failures.add('$name: ${BoxController.describe(error)}');
      } finally {
        if (mounted) setState(() => _updating.remove(id));
      }
    }
    if (!mounted) return;
    if (failures.isEmpty) {
      showAppBanner(context, '${context.tr('Remote profiles updated')}: $updated');
    } else {
      showAppBanner(
        context,
        '${context.tr('Updated')}: $updated · ${context.tr('Failed')}: ${failures.length}\n${failures.join('\n')}',
        level: BannerLevel.warning,
      );
    }
    await _load();
  }

  // --- card actions -------------------------------------------------------------

  String _nameOf(int id) {
    for (final profile in _profiles) {
      if ((profile['id'] as num?)?.toInt() == id) return profile['name']?.toString() ?? '';
    }
    return '#$id';
  }

  Future<void> _select(Json profile) async {
    final id = (profile['id'] as num?)?.toInt() ?? 0;
    if (profile['isRaw'] == true) {
      showAppBanner(context, context.tr('A raw profile cannot be current'), level: BannerLevel.warning);
      return;
    }
    if (id == _currentId) return;
    try {
      // The host wraps the selection on purpose: it writes Room's
      // `settings.current_route_id` (the row the config build reads) and then
      // the kernel's document marker. The Go action alone would move only the
      // marker, and the kernel writing that settings row itself is what caused
      // SQLITE_IOERR_SHORT_READ (522) at VPN start.
      await ref.read(boxControllerProvider).routeSetCurrentHost(id);
      if (!mounted) return;
      setState(() => _currentId = id);
      await _reloadService();
    } catch (error) {
      if (mounted) ref.read(boxControllerProvider).report(error);
    }
  }

  Future<void> _edit(Json profile) async {
    final id = (profile['id'] as num?)?.toInt() ?? 0;
    final saved = await openPage<bool>(context, RouteProfileEditorPage(id: id));
    if (!mounted) return;
    if (saved == true) {
      await _load();
      if (id == _currentId) await _reloadService();
    }
  }

  Future<void> _clone(Json profile) async {
    final id = (profile['id'] as num?)?.toInt() ?? 0;
    final name = profile['name']?.toString() ?? '';
    final box = ref.read(boxControllerProvider);
    final cloneSuffix = context.tr('clone');
    try {
      final rules = rows(json(await box.routeRules(id))['rules']);
      final saved = await box.routeSaveProfile(
        id: 0,
        name: '$name $cloneSuffix',
        defaultOutbound: profile['defaultOutbound']?.toString() ?? 'direct',
        isRemote: false,
        remoteUrl: '',
        autoUpdate: false,
      );
      final newId = _savedId(saved);
      if (newId > 0 && rules.isNotEmpty) {
        await box.routeSaveRules(newId, rules);
      }
      if (!mounted) return;
      showAppBanner(context, '${context.tr('Cloned')}: ${_nameAfterSave(saved, name, cloneSuffix)}');
      await _load();
    } catch (error) {
      if (mounted) box.report(error);
    }
  }

  String _nameAfterSave(dynamic saved, String fallback, String suffix) {
    final answer = saved is Map ? saved : const {};
    return answer['name']?.toString() ?? '$fallback $suffix';
  }

  Future<void> _share(Json profile) async {
    final id = (profile['id'] as num?)?.toInt() ?? 0;
    try {
      final rules = rows(json(await ref.read(boxControllerProvider).routeRules(id))['rules']);
      final detail = json(_details['$id'] ?? const {});
      final link = routeShareLink(
        name: profile['name']?.toString() ?? '',
        defaultOutbound: profile['defaultOutbound']?.toString() ?? 'direct',
        rules: rules,
        dns: detail['dns'] is Map ? Map<String, dynamic>.from(detail['dns'] as Map) : null,
        customDns: detail['customDns'] == true || detail['custom_dns'] == true,
      );
      await Clipboard.setData(ClipboardData(text: link));
      if (mounted) showAppBanner(context, context.tr('Route link copied'));
    } catch (error) {
      if (mounted) ref.read(boxControllerProvider).report(error);
    }
  }

  Future<void> _updateOne(Json profile) async {
    final id = (profile['id'] as num?)?.toInt() ?? 0;
    setState(() => _updating.add(id));
    try {
      final count = await updateRemoteProfile(ref.read(boxControllerProvider), id);
      if (!mounted) return;
      showAppBanner(context, '${context.tr('Rules updated')}: $count');
      await _load();
      if (id == _currentId) await _reloadService();
    } catch (error) {
      if (mounted) ref.read(boxControllerProvider).report(error);
    } finally {
      if (mounted) setState(() => _updating.remove(id));
    }
  }

  Future<void> _delete(Json profile) async {
    final id = (profile['id'] as num?)?.toInt() ?? 0;
    if (_profiles.length <= 1) {
      showAppBanner(context, context.tr('The last route profile cannot be deleted'), level: BannerLevel.warning);
      return;
    }
    final name = profile['name']?.toString() ?? '';
    final ok = await confirm(context, 'Delete this route profile?', message: name);
    if (!ok || !mounted) return;
    try {
      await ref.read(boxControllerProvider).routeDeleteProfile(id);
      if (!mounted) return;
      await _load();
      if (id == _currentId) await _reloadService();
    } catch (error) {
      if (mounted) ref.read(boxControllerProvider).report(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: context.tr('Routing'),
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.add,
          tooltip: context.tr('New'),
          onPressed: () => _newProfile(remote: false),
        ),
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: context.tr('Refresh'),
          onPressed: _loading ? null : _load,
        ),
      ],
      menuItems: [
        PopupMenuItem(
          glyph: AppGlyphs.rules,
          label: context.tr('Structured profile'),
          onPressed: () => _newProfile(remote: false),
        ),
        PopupMenuItem(
          glyph: AppGlyphs.cloudDownload,
          label: context.tr('Remote profile'),
          onPressed: () => _newProfile(remote: true),
        ),
        PopupMenuItem(
          glyph: AppGlyphs.importFile,
          label: context.tr('Import'),
          onPressed: _importProfile,
        ),
        PopupMenuItem(
          glyph: AppGlyphs.cloudSync,
          label: context.tr('Download profiles'),
          onPressed: _downloadProfiles,
        ),
        PopupMenuItem(
          glyph: AppGlyphs.sync,
          label: context.tr('Update all remote profiles'),
          onPressed: _updating.isEmpty ? _updateAll : null,
        ),
        PopupMenuItem(
          glyph: AppGlyphs.sliders,
          label: context.tr('Routing settings'),
          onPressed: _openSettings,
        ),
      ],
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: ActivityIndicator.page());
    if (_error != null) return ErrorState(_error!, retry: _load);
    if (_profiles.isEmpty) {
      return NullStatus(
        label: context.tr('No route profiles yet'),
        description: context.tr('A profile is the ordered rule list the core builds. Create one to start.'),
        illustration: NullStatusIllustration.rules,
        action: TonalButton(
          size: TonalButtonSize.bar,
          glyph: AppGlyphs.add,
          label: context.tr('New'),
          onPressed: () => _newProfile(remote: false),
        ),
      );
    }
    return ListView.separated(
      padding: boxPagePadding(context),
      itemCount: _profiles.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _RouteCard(
        profile: _profiles[index],
        detail: json(_details['${(_profiles[index]['id'] as num?)?.toInt() ?? 0}'] ?? const {}),
        current: (_profiles[index]['id'] as num?)?.toInt() == _currentId,
        updating: _updating.contains((_profiles[index]['id'] as num?)?.toInt()),
        onTap: () => _select(_profiles[index]),
        onEdit: () => _edit(_profiles[index]),
        onClone: () => _clone(_profiles[index]),
        onShare: () => _share(_profiles[index]),
        onUpdate: () => _updateOne(_profiles[index]),
        onDelete: () => _delete(_profiles[index]),
      ),
    );
  }
}

/// One card, Throne's `layout_route_profile_item`: the name (bold when current),
/// the `Default: proxy · 4 rules` summary, the remote bookkeeping lines, and the
/// pencil + ⋮ pair. A raw profile keeps the pencil (as a plain view) and drops
/// the actions the kernel would refuse.
class _RouteCard extends ConsumerWidget {
  const _RouteCard({
    required this.profile,
    required this.detail,
    required this.current,
    required this.updating,
    required this.onTap,
    required this.onEdit,
    required this.onClone,
    required this.onShare,
    required this.onUpdate,
    required this.onDelete,
  });

  final Json profile;
  final Json detail;
  final bool current;
  final bool updating;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onClone;
  final VoidCallback onShare;
  final VoidCallback onUpdate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = profile['name']?.toString() ?? '';
    final raw = profile['isRaw'] == true;
    final remote = profile['isRemote'] == true;
    final outbound = profile['defaultOutbound']?.toString() ?? 'direct';
    final ruleCount = (profile['ruleCount'] as num?)?.toInt() ?? 0;
    final owner = _owner(ref);
    final notes = <String>[
      '${context.tr('Default')}: ${context.tr(outbound)} · $ruleCount ${context.tr('rules')}',
      if (remote) _remoteLine(context),
      if (raw) context.tr('Read-only'),
      if (owner != null) '${context.tr('From a subscription')}: $owner',
    ];
    return Card(
      radius: AppCorner.xl,
      onPressed: onTap,
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                child: Text(
                  name.isEmpty ? context.tr('Untitled') : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.headline
                      .of(context, emphasized: current)
                      .copyWith(color: context.colorScheme.onSurface),
                ),
              ),
              if (current) ...[const SizedBox(width: 8), const SelectionBadge(size: 22)],
            ]),
            const SizedBox(height: 4),
            for (final note in notes)
              Text(note, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.listSubtitleStyle),
            if (updating) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(minHeight: 3),
            ],
          ]),
        ),
        IconButton(
          tooltip: context.tr(raw ? 'View' : 'Edit'),
          icon: GlyphIcon(raw ? AppGlyphs.eye : AppGlyphs.edit),
          onPressed: onEdit,
        ),
        PopupAnchor(
          targetBuilder: (open) => IconButton(
            tooltip: context.tr('Action'),
            icon: const GlyphIcon(AppGlyphs.more),
            onPressed: open,
          ),
          popupBuilder: (_) => PopupMenu(items: [
            PopupMenuItem(
              glyph: raw ? AppGlyphs.eye : AppGlyphs.edit,
              label: context.tr(raw ? 'View' : 'Edit'),
              onPressed: onEdit,
            ),
            if (!raw) ...[
              PopupMenuItem(
                glyph: AppGlyphs.copy,
                label: context.tr('Clone'),
                onPressed: onClone,
              ),
              PopupMenuItem(
                glyph: AppGlyphs.link,
                label: context.tr('Share'),
                onPressed: onShare,
              ),
              if (remote)
                PopupMenuItem(
                  glyph: AppGlyphs.sync,
                  label: context.tr('Update'),
                  onPressed: updating ? null : onUpdate,
                ),
            ],
            PopupMenuItem(
              glyph: AppGlyphs.delete,
              label: context.tr('Delete'),
              danger: true,
              onPressed: onDelete,
            ),
          ]),
        ),
      ]),
    );
  }

  /// `Remote · updated <time>` and the auto-update flag. The last-update stamp is
  /// only on the wire when the host exposes it: with the key absent the time is
  /// unknown, so the line says "Remote" alone rather than claiming never.
  String _remoteLine(BuildContext context) {
    final auto = detail['autoUpdate'] == true || detail['auto_update'] == true;
    final hasStamp = detail.containsKey('remoteLastUpdate') || detail.containsKey('remote_last_update');
    final seconds = (detail['remoteLastUpdate'] as num? ?? detail['remote_last_update'] as num? ?? 0).toInt();
    final updated = !hasStamp
        ? context.tr('Remote')
        : seconds > 0
            ? '${context.tr('Remote')} · ${context.tr('updated')} ${routeDateTime(seconds)}'
            : '${context.tr('Remote')} · ${context.tr('not updated yet')}';
    return '$updated · ${context.tr(auto ? 'Auto update on' : 'Auto update off')}';
  }

  String? _owner(WidgetRef ref) {
    final gid = (detail['sourceGroupId'] as num? ?? detail['source_gid'] as num? ?? -1).toInt();
    if (gid <= 0) return null;
    for (final group in ref.watch(groupsProvider)) {
      if ((group['id'] as num?)?.toInt() == gid) return group['name']?.toString();
    }
    return null;
  }
}

/// The engine switches the Routing settings screen keeps (upstream
/// `settings_routing.xml`, the two "common" sections): the domain strategies,
/// the rule-set mirror and ad blocking, plus the remote route auto-update pair.
/// They are real settings keys with a real reload story, so they stay one tap
/// from the profile list instead of vanishing with the old routing page.
class RouteEngineSettingsPage extends ConsumerWidget {
  const RouteEngineSettingsPage({super.key});

  static const _domainStrategies = ['', 'ipv4_only', 'ipv6_only', 'prefer_ipv4', 'prefer_ipv6'];
  static const _mirrors = [0, 1, 2, 3, 4, 5];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watchBoxState();
    final autoUpdate = box.settings['routeAutoUpdateEnabled'] == true;
    return BoxPage(
      title: 'Routing settings',
      actions: [
        restoreDefaultsAction(context, const [
          'outboundDomainStrategy', 'domainStrategy', 'rulesetMirror', 'adblockEnable',
          'routeAutoUpdateEnabled', 'routeAutoUpdateMinutes',
        ]),
      ],
      children: [
        generateSection(items: [
          SettingChoice<String>('Outbound domain strategy', 'outboundDomainStrategy',
              options: _domainStrategies, text: _strategyName),
          SettingChoice<String>('Domain strategy', 'domainStrategy',
              options: _domainStrategies, text: _strategyName),
          SettingChoice<int>('Rule set mirror', 'rulesetMirror', options: _mirrors, text: _mirrorName),
          SettingToggle('Ad blocking', 'adblockEnable', autoRestart: true),
        ], footer: context.tr('These change how the rules resolve for every profile.')),
        generateSection(title: context.tr('Automatic updates'), items: [
          SettingToggle('Update remote route profiles', 'routeAutoUpdateEnabled'),
          if (autoUpdate) SettingNumber('Update interval', 'routeAutoUpdateMinutes', min: 30, unit: 'min'),
        ]),
        const _RuleSetsStatus(),
      ],
    );
  }
}

/// The last rule-set update the kernel worker reported. The core fetches these
/// automatically after start; there is no manual action in this build (see the
/// honesty rule at the top of the file), so this is a read-only caption. Hidden
/// while the kernel is not running — with no worker there is no status to show.
class _RuleSetsStatus extends ConsumerWidget {
  const _RuleSetsStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(runningProvider);
    final status = ref.watch(ruleSetsProvider);
    if (!running || status.isEmpty) return const SizedBox.shrink();
    final updated = (status['updated'] as num?)?.toInt() ?? 0;
    final error = status['error']?.toString() ?? '';
    final at = (status['at'] as num?)?.toInt() ?? 0;
    final time = at > 0 ? routeDateTime(at ~/ 1000) : '—';
    final caption = error.isEmpty
        ? '${context.tr('Rule sets updated')} · $updated · $time'
        : '${context.tr('Rule sets')}: $updated · $error';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Text(caption, style: context.listCaptionStyle),
    );
  }
}

String _strategyName(String value) => switch (value) {
      '' => 'Automatic', 'ipv4_only' => 'IPv4 only', 'ipv6_only' => 'IPv6 only',
      'prefer_ipv4' => 'Prefer IPv4', _ => 'Prefer IPv6',
    };

String _mirrorName(int value) => switch (value) {
      1 => 'jsDelivr · Cloudflare', 2 => 'jsDelivr', 3 => 'GitHub',
      4 => 'Cloudflare Pages', 5 => 'Throne mirror', _ => 'GitHub raw',
    };

/// Epoch seconds as a short local date and time, Throne's `RouteTexts.dateTime`.
String routeDateTime(int epochSeconds) {
  if (epochSeconds <= 0) return '—';
  final local = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

/// The id `routeSaveProfile` answered, whether the host replies with the bare id
/// or with `{id: …}`.
int _savedId(dynamic saved) {
  if (saved is num) return saved.toInt();
  if (saved is Map) return (saved['id'] as num?)?.toInt() ?? 0;
  return 0;
}

/// Keeps the share/import pair's base64 codec honest: the link is the profile
/// object, compact-keyed JSON, base64url without padding, as `RouteShare`.
String routeShareLink({
  required String name,
  required String defaultOutbound,
  required List<Json> rules,
  Map<String, dynamic>? dns,
  bool customDns = false,
}) {
  final object = <String, dynamic>{
    'kind': 'throne-route-profile',
    'v': 1,
    'name': name,
    'default_outbound': defaultOutbound,
    if (customDns && dns != null) 'dns': dns,
    'rules': [
      for (final rule in rules)
        {
          ...Map<String, dynamic>.from(rule),
          if ((rule['action']?.toString() ?? 'route') == 'reject' && (rule['reject_method']?.toString() ?? '').isNotEmpty)
            'method': rule['reject_method'],
        },
    ],
  };
  return 'throne://route/${base64Url.encode(utf8.encode(jsonEncode(object))).replaceAll('=', '')}';
}
