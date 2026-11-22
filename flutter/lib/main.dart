import 'dart:async';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/foundation.dart' show FlutterError, LicenseRegistry, LicenseEntryWithLineBreaks, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/frame_watch.dart';
import 'core/kernel_proxy.dart';
import 'common/refresh_gate.dart';
import 'providers/box_providers.dart';
import 'widgets.dart';
import 'pages/dashboard.dart';
import 'pages/backup.dart';
import 'pages/proxies.dart';
import 'pages/profiles.dart';
import 'pages/tools.dart';
import 'theme_settings.dart';
import 'components/page_switcher.dart';
import 'service_entry.dart' as service;

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
  // Record UI-thread stalls in the app log (one line per freeze above 100 ms,
  // throttled): the start-turn profiler only sees its own 450 ms, and the
  // surviving jank kept proving it lived somewhere else on the frame path.
  // `last=` names the event that preceded a stall the handler stopwatches did
  // not cover (message deserialization, a GC pause).
  FrameWatch(
    report: (text) => unawaited(
      controller.call('log.note', {'text': text}).then((_) {}, onError: (_) {}),
    ),
    context: () =>
        'status=${controller.dashboard['status']}, last=${controller.lastEventType}',
  ).start();
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
  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    widget.controller.initialize();
  }
  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messages?.cancel();
    _reports?.cancel();
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
    if (RefreshGate.suspendedFor(state)) {
      widget.controller.suspendRefreshes();
    } else {
      widget.controller.resumeRefreshes();
    }
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
    overrides: [boxControllerProvider.overrideWithValue(widget.controller)],
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
          await openForm(context, ProfileForm(initial: data));
        }
        return;
      }
      final data = json(await _box!.profileDecodeIntent(uri));
      if (mounted) await openForm(context, ProfileForm(initial: data));
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
      const ProfilesPage(),
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
