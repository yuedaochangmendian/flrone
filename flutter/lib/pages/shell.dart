import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/l10n.dart';
import '../app/navigation.dart';
import '../ui/icons/icons.dart';
import 'dashboard.dart';
import 'profiles.dart';
import 'proxies.dart';
import 'requests.dart';
import 'tools.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  var _expanded = true;
  final _built = <int>{0};

  static const _destinations = [
    (AppGlyphs.dashboard, 'Dashboard'),
    (AppGlyphs.proxies, 'Proxies'),
    (AppGlyphs.profiles, 'Profiles'),
    (AppGlyphs.requests, 'Requests'),
    (AppGlyphs.tools, 'Tools'),
  ];

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(tabIndexProvider);
    final desktop = MediaQuery.sizeOf(context).width >= 900;
    final pages = <Widget>[
      const DashboardPage(),
      const ProxiesPage(),
      const ProfilesPage(),
      const RequestsPage(),
      const ToolsPage(),
    ];
    _built.add(index);
    final kept = [
      for (var index = 0; index < pages.length; index++)
        _built.contains(index) ? pages[index] : const SizedBox.shrink(),
    ];
    void select(int value) {
      setState(() => _built.add(value));
      ref.read(tabIndexProvider.notifier).state = value;
    }

    if (desktop) {
      return Surface(
        color: SurfaceLevel.page.colorOf(context.colorScheme),
        child: Row(
          children: [
            NavigationSidebar(
              destinations: [
                for (final destination in _destinations)
                  SidebarDestination(
                    glyph: destination.$1,
                    label: context.tr(destination.$2),
                  ),
              ],
              selectedIndex: index,
              expanded: _expanded,
              onSelected: select,
              onToggle: () => setState(() => _expanded = !_expanded),
            ),
            Expanded(
              child: IndexedStack(index: index, children: kept),
            ),
          ],
        ),
      );
    }
    final dockInset = NavigationDock.insetOf(context);
    return Surface(
      color: SurfaceLevel.page.colorOf(context.colorScheme),
      child: Stack(
        children: [
          Positioned.fill(
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: MediaQuery.paddingOf(context).copyWith(
                  bottom: MediaQuery.paddingOf(context).bottom + dockInset,
                ),
              ),
              child: IndexedStack(index: index, children: kept),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: NavigationDock(
              destinations: [
                for (final destination in _destinations)
                  NavigationDockDestination(
                    glyph: destination.$1,
                    label: context.tr(destination.$2),
                  ),
              ],
              selectedIndex: index,
              onSelected: select,
            ),
          ),
        ],
      ),
    );
  }
}
