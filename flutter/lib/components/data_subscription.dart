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
    _sync();
  }

  @override void didUpdateWidget(BoxDataSubscription oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _box?.setDataVisible(oldWidget.data, this, false);
      _sync();
    }
  }

  void _sync() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _box?.setDataVisible(widget.data, this,
      _pageActive && (lifecycle == null || lifecycle == AppLifecycleState.resumed));
  }

  @override void didChangeAppLifecycleState(AppLifecycleState state) => _sync();

  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _box?.setDataVisible(widget.data, this, false);
    super.dispose();
  }

  @override Widget build(BuildContext context) => widget.child;
}
