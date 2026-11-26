import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';
import '../widgets.dart';

/// Shares native sampling between visible consumers of the same data.
class BoxDataSubscription extends ConsumerStatefulWidget {
  const BoxDataSubscription({super.key, required this.data, required this.child});
  final BoxData data;
  final Widget child;
  @override ConsumerState<BoxDataSubscription> createState() => _BoxDataSubscriptionState();
}

class _BoxDataSubscriptionState extends ConsumerState<BoxDataSubscription> with WidgetsBindingObserver {
  BoxController? _box;
  bool _pageActive = false;
  /// Every route carrying this page (its own, plus any sheets wrapping it).
  /// A page pushed over the tab still has an active PageActivityScope, so we
  /// also check that all carrier routes are current — the same rule the
  /// connections feed uses — to stop sampling while the page is covered.
  List<ModalRoute<Object?>> _carriers = const [];

  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override void didChangeDependencies() {
    super.didChangeDependencies();
    final box = ref.read(boxControllerProvider);
    if (!identical(_box, box)) {
      _box?.setDataVisible(widget.data, this, false);
      _box = box;
    }
    _pageActive = PageActivityScope.isActiveOf(context) && TickerMode.valuesOf(context).enabled;
    _watchRoutes();
    _sync();
  }

  /// Follows the routes carrying this page. A push over any carrier starts its
  /// `secondaryAnimation`; a pop reverses it. Refreshed in didChangeDependencies
  /// because a sheet appearing changes the list while ModalRoute.of stays the same.
  void _watchRoutes() {
    final carriers = routesCarrying(context).toList(growable: false);
    if (_sameRoutes(carriers, _carriers)) return;
    for (final route in _carriers) {
      route.secondaryAnimation?.removeStatusListener(_routeMoved);
    }
    _carriers = carriers;
    for (final route in carriers) {
      route.secondaryAnimation?.addStatusListener(_routeMoved);
    }
  }

  static bool _sameRoutes(List<ModalRoute<Object?>> a, List<ModalRoute<Object?>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  void _routeMoved(AnimationStatus _) => _sync();

  @override void didUpdateWidget(BoxDataSubscription oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _box?.setDataVisible(oldWidget.data, this, false);
      _sync();
    }
  }

  /// Whether the page is actually on screen: active tab, tickers enabled, no
  /// route pushed above any carrier, and the app resumed.
  bool get _onScreen {
    if (!_pageActive) return false;
    for (final route in _carriers) {
      if (!route.isCurrent) return false;
    }
    return true;
  }

  void _sync() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _box?.setDataVisible(widget.data, this,
      _onScreen && (lifecycle == null || lifecycle == AppLifecycleState.resumed));
  }

  @override void didChangeAppLifecycleState(AppLifecycleState state) => _sync();

  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final route in _carriers) {
      route.secondaryAnimation?.removeStatusListener(_routeMoved);
    }
    _carriers = const [];
    _box?.setDataVisible(widget.data, this, false);
    super.dispose();
  }

  @override Widget build(BuildContext context) => widget.child;
}
