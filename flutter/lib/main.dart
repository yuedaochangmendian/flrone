import 'dart:async';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/foundation.dart' show FlutterError, LicenseRegistry, LicenseEntryWithLineBreaks, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/kernel_proxy.dart';
import 'common/refresh_gate.dart';
import 'providers/box_providers.dart';
import 'widgets.dart';
import 'pages/dashboard.dart';
import 'pages/backup.dart';
import 'pages/proxies.dart';
import 'pages/configurations.dart';
import 'pages/tools.dart';
import 'pages/vpn_auth.dart';
import 'theme_settings.dart';
import 'components/page_switcher.dart';
import 'service_entry.dart' as service;
import 'services/boot_guard.dart';
import 'services/traffic_stats.dart';

/// The second Flutter engine (`ServiceEngineManager.ensureStarted`) runs this
/// by name. It must live in the root library: a library only imported by an
/// unreachable file is not part of the AOT snapshot, so the entrypoint would
/// be missing at runtime. The `vm:entry-point` pragma keeps it past tree-shaking.
@pragma('vm:entry-point')
Future<void> serviceMain(List<String> args) => service.serviceMain(args);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  LicenseRegistry.addLicense(() async* {
    for (final entry in const {'FlClash': 'LICENSE', 'cilium/ebpf': 'cilium-ebpf-LICENSE', 'ulikunitz/xz': 'xz-LICENSE', 'JetBrains Mono': 'JetBrainsMono-OFL.txt'}.entries) {
      yield LicenseEntryWithLineBreaks([entry.key], await rootBundle.loadString('assets/licenses/${entry.value}'));
    }
  });
  // Cap the decoded-image cache so a long session cannot grow it without bound.
  imageCache.maximumSizeBytes = 50 << 20;
  // Attach to the service engine without blocking the first frame: an already
  // running tunnel is found immediately, and a cold start with no engine simply
  // stays on the channel until the user connects (serviceStart waits for the port).
  final proxy = KernelProxy();
  final controller = BoxController(kernelControl: proxy);
  // Transport lag (send stamp to receive): the only window that covers the
  // receiving isolate's deserialization of a service-engine message.
  proxy.diagnose = (text) => unawaited(
    controller.call('log.note', {'text': text}).then((_) {}, onError: (_) {}),
  );
  // Framework and engine errors reach the same banner the bridge uses, instead
  // of only going to logcat where the user never sees them.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    controller.report(details.exception);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    controller.report(error);
    return true;
  };
  // One ProviderScope overrides the box controller with the very same instance
  // BoxScope hands out. It lives inside BoxApp (not only in main) so every page
  // that pumps a BoxApp in tests inherits the same scope, and the root never
  // becomes a second source of truth: nothing writes back to Riverpod.
  runApp(BoxApp(controller: controller));
}

class BoxApp extends StatefulWidget {
  const BoxApp({super.key, required this.controller});
  final BoxController controller;
  @override State<BoxApp> createState() => _BoxAppState();
}

class _BoxAppState extends State<BoxApp> with WidgetsBindingObserver {
  final _banner = GlobalKey<BannerHostState>();
  StreamSubscription<String>? _messages;
  StreamSubscription<Json>? _reports;
  bool _vpnWatchArmed = false;

  /// The one queue of pushed VPN sign-in challenges. It presents a challenge
  /// sheet from the app shell (so one arriving over another screen is queued),
  /// and publishes the current pending challenge so the dashboard hint can be
  /// tapped as a manual fallback. Never holds answers.
  late final VpnAuthHost _vpnAuthHost = VpnAuthHost(
    VpnAuthCoordinator(present: _presentVpnChallenge),
    ValueNotifier<VpnChallenge?>(null),
  );

  /// Last screen-off value actually sent to the core. `inactive` is still on
  /// screen (a shade/dialog), so it must not flip this: only a hidden app makes
  /// the auto-selectors probe less often. This is a UI-lifecycle backgrounding
  /// hint only — device doze is driven by the Android host via setDoze.
  /// Tracked here so a burst of lifecycle callbacks cannot spam the action bus
  /// with repeated identical writes.
  bool _screenOffSent = false;

  /// Startup-attempt bookkeeping (FlClash's boot guard): a launch that dies
  /// before the UI is up is recorded, and the next launch starts degraded
  /// instead of repeating whatever killed it.
  late final BootGuard _bootGuard = BootGuard(
    store: PreferencesBootRecordStore(
      readValue: () => widget.controller.preferences[BootGuard.preferenceKey],
      writeValue: (value) async {
        await widget.controller.setPreferences({BootGuard.preferenceKey: value});
      },
    ),
  );

  /// Presents one challenge as a dialog and routes its submit/cancel through
  /// the controller. The dialog itself never pops — it reports the outcome and
  /// this host decides: a successful submit/cancel closes it and clears the
  /// hint, a failed one throws back into the sheet so its fields stay put.
  Future<void> _presentVpnChallenge(VpnChallenge challenge) async {
    final outerContext = _banner.currentState?.context;
    if (outerContext == null) return;
    final box = widget.controller;
    // The hint tracks what is on screen so a tap can reopen it.
    _vpnAuthHost.pending.value = challenge;
    var settled = false;

    try {
      await showVpnChallengeDialog(
        // ignore: use_build_context_synchronously — captured synchronously above.
        outerContext,
        challenge: challenge,
        onSubmit: (answer) async {
          await box.vpnSubmitChallenge(challenge.endpointTag, challenge.id, answer);
          settled = true;
          // ignore: use_build_context_synchronously
          if (outerContext.mounted) Navigator.pop(outerContext);
        },
        onCancel: () async {
          await box.vpnCancelChallenge(challenge.endpointTag, challenge.id);
          settled = true;
          // ignore: use_build_context_synchronously
          if (outerContext.mounted) Navigator.pop(outerContext);
        },
        onOpenUrl: (url) => box.openUrl(url),
      );
    } finally {
      if (_vpnAuthHost.pending.value?.id == challenge.id && settled) {
        _vpnAuthHost.pending.value = null;
      }
    }
  }

  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The traffic ledger samples the core's cumulative totals; attaching before the controller
    // is ready is safe (it starts once `ready` flips) and keeps the first session covered.
    TrafficStatsStore.instance.attach(widget.controller);
    _messages = widget.controller.messages.listen((message) {
      _banner.currentState?.show(message);
    });    // A subscription update's change window (SubscriptionReportDialog): the report body selectable,
    // a copy action beside OK.
    _reports = widget.controller.subscriptionReports.listen((report) {
      final context = _banner.currentState?.context;
      if (context == null) return;
      final text = report['text']?.toString() ?? '';
      // The listener captures its context synchronously; the dialog owns the
      // context used by its deferred builder and actions.
      // ignore: use_build_context_synchronously
      showAppDialog<void>(context, child: Builder(builder: (dialogContext) => AlertDialog(
        title: report['title']?.toString() ?? dialogContext.tr('Change of configuration'),
        child: SelectableText(
          text.trim().isEmpty ? dialogContext.tr('Nothing changed') : text,
        ),
        actions: [
          TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: text.trim())),
            child: Text(dialogContext.tr('Copy'))),
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(dialogContext.tr('OK'))),
        ],
      )));
    });
    // A pushed challenge must be queued app-wide, not just on the dashboard.
    // The Go watcher is armed once the tunnel is up (see _maybeArmVpnWatch);
    // arming at startup would attach a kernel no core has started and leave a
    // retry loop spinning behind every screen.
    _vpnAuthHost.coordinator.start(widget.controller.vpnStatuses);
    widget.controller.addListener(_maybeArmVpnWatch);
    unawaited(_startup());
  }

  /// First attach, then the boot guard, then whatever this launch does by itself.
  ///
  /// `initialize()` is what loads `preferences`, so the guard cannot read its
  /// marker before it; everything after it runs in the same order for every
  /// launch, which is what makes a marker meaningful.
  Future<void> _startup() async {
    await widget.controller.initialize();
    if (!mounted) return;
    await _runBootGuard();
    if (!mounted) return;
    _markRunningWhenUp();
  }

  Future<void> _runBootGuard() async {
    final box = widget.controller;
    final profileId = box.selectedConfigurationId > 0 ? box.selectedConfigurationId : null;
    BootDecision decision;
    try {
      decision = await _bootGuard.evaluate(profileId: profileId);
    } catch (error) {
      // Bookkeeping must never be the reason a launch fails: without a marker
      // the app behaves as it always did.
      box.report(error);
      return;
    }
    if (decision.isDegraded) {
      _showBootNotice(decision);
      // FlClash's clearProfile: forget the selection so nothing re-arms the
      // profile that just crashed the launch. The host's `selectedProxy` is
      // Kotlin-owned and has no clear op yet; the pick this app restores at
      // startup is Dart-owned, so clearing it is the part the UI can honour.
      if (decision.recovery == BootRecovery.clearProfile) {
        unawaited(
          box
              .setPreference(BoxController.lastConfigurationKey, null)
              .then((_) {}, onError: (Object _) {}),
        );
      }
      return;
    }
    await _autoStartOnLaunch(decision);
  }

  /// The launch-time automatic start, gated by the guard.
  ///
  /// There is deliberately no start here today: when the Android service starts
  /// (a tap, the tile, a widget, the boot receiver) the service engine brings the
  /// core up by itself, and a launcher launch only attaches to what is already
  /// running. Keeping the decision in one place means the day an auto-connect
  /// lands it has this gate rather than its own private check.
  Future<void> _autoStartOnLaunch(BootDecision decision) async {
    // The guard's answer is final: a degraded launch does no automatic work.
    if (decision.isDegraded) return;
    final profileId = widget.controller.selectedConfigurationId;
    await _bootGuard.markAttempt(profileId: profileId > 0 ? profileId : null);
  }

  /// Arms the Go status watcher once the tunnel is running. Best effort: a
  /// failure leaves the dashboard hint as the manual fallback. Idempotent —
  /// the listener fires on every state change, but one box needs one watcher.
  void _maybeArmVpnWatch() {
    if (_vpnWatchArmed || !widget.controller.running) return;
    _vpnWatchArmed = true;
    unawaited(widget.controller.vpnWatchStatus().then((_) {}, onError: (Object _) {
      // A failed arm is not permanent: allow a later state change to retry.
      _vpnWatchArmed = false;
    }));
  }

  /// The UI is really up: `ready` (or the error screen that replaces it) has
  /// painted. Marking earlier would turn every slow start into a recorded crash.
  void _markRunningWhenUp() {
    if (!mounted) return;
    final box = widget.controller;
    if (!box.ready && box.startupError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _markRunningWhenUp());
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_bootGuard.markRunning().then((_) {}, onError: (Object _) {}));
    });
  }

  void _showBootNotice(BootDecision decision, [int attempt = 0]) {
    final state = _banner.currentState;
    final context = state?.context;
    if (state == null || context == null) {
      // The guard runs as soon as the host answers `ready`, which can be before
      // the shell has built its banner host. A few frames is enough; past that
      // the notice is dropped rather than held against a teardown.
      if (attempt < 30) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showBootNotice(decision, attempt + 1);
        });
      }
      return;
    }
    state.show(
      decision.recovery == BootRecovery.clearProfile
          ? context.tr('The previous launch kept failing, so the remembered profile was cleared. Start the tunnel when you are ready.')
          : context.tr('The previous launch was interrupted before the app was ready. Nothing was started automatically this time.'),
      level: decision.recovery == BootRecovery.clearProfile
          ? BannerLevel.error
          : BannerLevel.warning,
    );
  }
  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messages?.cancel();
    _reports?.cancel();
    widget.controller.removeListener(_maybeArmVpnWatch);
    unawaited(_vpnAuthHost.dispose());
    widget.controller.dispose();
    super.dispose();
  }

  final _themes = <String, ThemeData>{};

  @override void didChangeLocales(List<Locale>? locales) => setState(_themes.clear);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Keep ingesting bridge events either way; only a hidden app holds their
    // rebuilds. `inactive` is still on screen (split screen, the shade, a system
    // dialog), and FlClash keeps its dashboard live there — the speed card used
    // to freeze the moment another window took focus.
    final suspended = RefreshGate.suspendedFor(state);
    // The host keeps its 1 s ticker running either way; this only tells it
    // whether a snapshot is worth building (FlClash's UI-only dashboard poll).
    widget.controller.setUiVisible(!suspended);
    _syncScreenOff(state);
    if (suspended) {
      widget.controller.suspendRefreshes();
      // The app may not come back (a swipe from recents); write the ledger now.
      unawaited(TrafficStatsStore.instance.flush(force: true));
    } else {
      widget.controller.resumeRefreshes();
    }
  }

  /// Sends the screen-off hint only on a real transition. The kernel may not
  /// have attached yet (a cold start, or no VPN has ever run); that is not an
  /// error worth surfacing to the user, but the flag is still updated so a
  /// later resumed callback does not replay a stale "on" write.
  void _syncScreenOff(AppLifecycleState state) {
    final off = switch (state) {
      AppLifecycleState.paused ||
      AppLifecycleState.hidden ||
      AppLifecycleState.detached => true,
      AppLifecycleState.resumed => false,
      // `inactive` is visible: keep the last value.
      AppLifecycleState.inactive => _screenOffSent,
    };
    if (off == _screenOffSent) return;
    _screenOffSent = off;
    unawaited(
      widget.controller.setScreenOff(off).then((_) {}, onError: (_) {}),
    );
  }

  /// Prism's theme is the only one: every page, component and control in this
  /// app reads it, so there is no parallel Material scheme to keep in sync.
  ThemeData _theme(Brightness brightness) {
    final prefs = widget.controller.preferences;
    final scheme = appColorScheme(widget.controller, brightness);
    final family = prefs['fontFamily'] as String?;
    final key = "$brightness:${scheme.hashCode}:$family";
    final fallback = appFontFamilyFallback(platform: defaultTargetPlatform, locales: WidgetsBinding.instance.platformDispatcher.locales, fontFamily: family);
    return _themes.putIfAbsent(key, () => ThemeData(
      colorScheme: scheme,
      fontFamily: family,
      fontFamilyFallback: fallback,
      elevatedColorScheme: brightness == Brightness.dark ? scheme.elevated : null,
    ));
  }

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [
      boxControllerProvider.overrideWithValue(widget.controller),
      vpnAuthHostProvider.overrideWithValue(_vpnAuthHost),
    ],
    child: BoxScope(
      controller: widget.controller,
      child: Builder(
        builder: (context) {
          final prefs = BoxScope.of(context, aspect: BoxAspect.appearance).preferences;
          final media = MediaQuery.of(context);
          final scale = appTextScale(prefs, media.textScaler.scale(1)).clamp(.8, 1.4);
          final glass = (prefs['liquidGlass'] ?? 'none');
          return PrismApp(
            title: 'Flrone',
            debugShowCheckedModeBanner: false,
            theme: _theme(Brightness.light),
            darkTheme: _theme(Brightness.dark),
            themeMode: ThemeMode.values.firstWhere((mode) => mode.name == prefs['theme'], orElse: () => ThemeMode.system),
            supportedLocales: const [Locale('en'), Locale('zh')],
            localizationsDelegates: const [
              BoxUiDelegate(), ...GlobalMaterialLocalizations.delegates,
            ],
            textScale: scale,
            minTextScale: .8,
            maxTextScale: 1.4,
            liquidGlass: glass == 'none' ? null : (glass == 'ultra' ? LiquidGlassQuality.ultra : LiquidGlassQuality.standard),
            stackedBanners: media.size.width >= 600,
            // Banners hang below the page bar so they never cover its buttons.
            bannerTopInset: media.padding.top + pageToolbarHeight,
            bannerKey: _banner,
            home: widget.controller.ready ? const HomePage() : Surface(
              color: context.colorScheme.surface,
              child: SafeArea(child: Center(child: widget.controller.startupError == null
                  ? const ActivityIndicator()
                  : ErrorState(widget.controller.startupError!, retry: widget.controller.initialize))),
            ),
          );
        },
      ),
    ),
  );
}

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  int _index = 0;

  /// The desktop sidebar starts labelled — the app has no other textual
  /// navigation — and its toggle collapses it to icons.
  bool _sidebarExpanded = true;
  StreamSubscription<IntentAvailableEvent>? _intents;
  BoxController? _box;
  bool _handlingIntent = false;

  @override void didChangeDependencies() {
    super.didChangeDependencies();
    if (_box != null) return;
    _box = ref.read(boxControllerProvider);
    _intents = _box!.intents.listen((_) => _drainIntents());
    WidgetsBinding.instance.addPostFrameCallback((_) => _drainIntents());
  }

  Future<void> _drainIntents() async {
    if (_handlingIntent || !mounted) return;
    _handlingIntent = true;
    try {
      while (mounted && _box!.pendingIntents.isNotEmpty) {
        await _import(_box!.pendingIntents.removeAt(0));
      }
    } finally { _handlingIntent = false; }
  }

  Future<void> _import(String uri) async {
    try {
      // A file the platform handed us: the host reads it and says which it is, because a .thrbackup is a
      // binary container the config importer cannot parse and a document is text it can.
      if (uri.startsWith('content://') || uri.startsWith('file://')) {
        final data = json(await _box!.filesOpen(uri));
        final backup = json(data['backup']);
        if (backup.isNotEmpty) {
          if (mounted) await restoreBackupFile(context, backup, box: _box!);
        } else if (mounted) {
          await openForm(context, ConfigurationForm(initial: data));
        }
        return;
      }
      final data = json(await _box!.configurationDecodeIntent(uri));
      if (mounted) await openForm(context, ConfigurationForm(initial: data));
    } catch (error) { _box!.report(error); }
  }

  @override void dispose() { _intents?.cancel(); super.dispose(); }

  @override Widget build(BuildContext context) {
    final mobile = context.isMobileView;
    // Watch the two preference values the shell actually renders. Watching the
    // whole provider would rebuild the navigation and page host for unrelated
    // preferences (proxy selection, log level) as well as a start/stop.
    final floating = ref.watch(
      preferencesProvider.select((prefs) => prefs['floatingNavigation'] != false),
    );
    final tabAnimation = ref.watch(preferencesProvider.select(tabAnimationOf));
    // A tab exists only when the host answers for it; the Proxies tab needs selector groups.
    final caps = ref.watch(capabilitiesProvider);
    final items = <(String, Glyph)>[
      ('Dashboard', AppGlyphs.dashboard),
      if (caps.of('proxyGroups')) ('Proxies', AppGlyphs.proxies),
      ('Profiles', AppGlyphs.profiles),
      ('Tools', AppGlyphs.tools),
    ];
    final pages = <Widget>[
      const DashboardPage(),
      if (caps.of('proxyGroups')) const ProxiesPage(),
      const ConfigurationsPage(),
      const ToolsPage(),
    ];
    // Pruning a tab that the user was standing on must not leave the index past the end.
    final index = _index.clamp(0, pages.length - 1);
    final content = PageSwitcher(
      index: index,
      animation: tabAnimation,
      onSelected: (index) => setState(() => _index = index),
      children: [for (var i = 0; i < pages.length; i++)
        TickerMode(enabled: i == index, child: PageActivityScope(isActive: i == index, child: pages[i])),
      ],
    );
    // The shell is a bare surface: every page brings its own prism bar.
    return Surface(
      color: context.colorScheme.surface,
      child: Row(children: [
          if (!mobile) NavigationSidebar(
            selectedIndex: index,
            expanded: _sidebarExpanded,
            onSelected: (index) => setState(() => _index = index),
            onToggle: () => setState(() => _sidebarExpanded = !_sidebarExpanded),
            destinations: [for (final item in items) SidebarDestination(
              glyph: item.$2, label: context.tr(item.$1),
            )],
          ),
          Expanded(child: Column(children: [
            Expanded(child: Stack(children: [
              Positioned.fill(child: BottomInsetScope(
                inset: mobile && floating ? NavigationDock.insetOf(context) : 0,
                child: MediaQuery.removePadding(context: context, removeBottom: mobile, removeLeft: mobile, removeRight: mobile, child: content),
              )),
              if (mobile && floating) PositionedDirectional(
                start: 0, end: 0, bottom: 0,
                child: NavigationDock(
                  selectedIndex: index,
                  onSelected: (index) => setState(() => _index = index),
                  destinations: [for (final item in items) NavigationDockDestination(glyph: item.$2, label: context.tr(item.$1))],
                ),
              ),
            ])),
            if (mobile && !floating) NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (index) => setState(() => _index = index),
              destinations: [for (final (i, item) in items.indexed)
                NavigationDestination(icon: AnimatedGlyph(glyph: item.$2, filled: i == index), label: context.tr(item.$1)),
              ],
            ),
          ])),
      ]),
    );
  }
}
