import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../box.dart';
import '../pages/shell.dart';
import '../providers/box_providers.dart';
import 'theme.dart';
import 'ui_localizations.dart';

class BoxApp extends StatefulWidget {
  const BoxApp({super.key, required this.controller});

  final BoxController controller;

  @override
  State<BoxApp> createState() => _BoxAppState();
}

class _BoxAppState extends State<BoxApp> with WidgetsBindingObserver {
  late bool _ready;
  String? _startupError;
  late String _preferences;

  static String _preferenceKey(Json preferences) => [
    preferences['theme'],
    preferences['liquidGlass'],
    preferences['accent'],
    preferences['fontFamily'],
  ].join('|');

  @override
  void initState() {
    super.initState();
    _ready = widget.controller.ready;
    _startupError = widget.controller.startupError;
    _preferences = _preferenceKey(widget.controller.preferences);
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_handleController);
    widget.controller.initialize();
  }

  void _handleController() {
    final controller = widget.controller;
    if (_ready == controller.ready &&
        _startupError == controller.startupError &&
        _preferences == _preferenceKey(controller.preferences)) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _ready = controller.ready;
      _startupError = controller.startupError;
      _preferences = _preferenceKey(controller.preferences);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_handleController);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.controller.resumeRefreshes();
    } else {
      widget.controller.suspendRefreshes();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ProviderScope(
      overrides: [boxControllerProvider.overrideWithValue(controller)],
      child: Builder(
        builder: (context) {
          final prefs = controller.preferences;
          final glass = prefs['liquidGlass'];
          final mode = switch (prefs['theme']) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            _ => ThemeMode.system,
          };
          final seed = (prefs['accent'] as num?)?.toInt();
          return PrismApp(
            title: 'Flrone',
            debugShowCheckedModeBanner: false,
            theme: appTheme(
              Brightness.light,
              seed: seed == null ? null : Color(seed),
            ),
            darkTheme: appTheme(
              Brightness.dark,
              seed: seed == null ? null : Color(seed),
            ),
            themeMode: mode,
            supportedLocales: const [Locale('en'), Locale('zh')],
            localizationsDelegates: const [
              AppUiLocalizationsDelegate(),
              GlobalWidgetsLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            liquidGlass: glass == 'none' || glass == null
                ? null
                : LiquidGlassQuality.standard,
            builder: (context, child) {
              final size = MediaQuery.sizeOf(context);
              return ViewScope(
                size: size,
                isMobile: size.width < 900,
                child: child ?? const SizedBox.shrink(),
              );
            },
            stackedBanners: false,
            bannerTopInset: 56,
            home: _BannerBridge(
              controller: controller,
              child: controller.ready
                  ? const HomeShell()
                  : _StartupView(controller: controller),
            ),
          );
        },
      ),
    );
  }
}

class _BannerBridge extends StatefulWidget {
  const _BannerBridge({required this.controller, required this.child});

  final BoxController controller;
  final Widget child;

  @override
  State<_BannerBridge> createState() => _BannerBridgeState();
}

class _BannerBridgeState extends State<_BannerBridge> {
  StreamSubscription<String>? _messages;
  StreamSubscription<Json>? _reports;

  @override
  void initState() {
    super.initState();
    _messages = widget.controller.messages.listen((message) {
      if (mounted) BannerHost.maybeOf(context)?.show(message);
    });
    _reports = widget.controller.subscriptionReports.listen((report) {
      if (!mounted) return;
      final text = report['text']?.toString().trim() ?? '';
      BannerHost.maybeOf(context)
          ?.show(text.isEmpty ? 'Configuration updated' : text);
    });
  }

  @override
  void dispose() {
    _messages?.cancel();
    _reports?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _StartupView extends StatelessWidget {
  const _StartupView({required this.controller});

  final BoxController controller;

  @override
  Widget build(BuildContext context) {
    final error = controller.startupError;
    return Surface(
      color: context.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: error == null
              ? const ActivityIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 16,
                  children: [
                    Text(
                      error,
                      textAlign: TextAlign.center,
                      style: AppTextStyle.body.of(context),
                    ),
                    TonalButton(
                      onPressed: controller.initialize,
                      label: 'Retry',
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
