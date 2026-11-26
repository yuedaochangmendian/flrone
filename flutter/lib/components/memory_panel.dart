import 'dart:async';
import 'dart:io' show Platform, ProcessInfo;
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/kernel_memory.dart';
import '../providers/box_providers.dart';
import '../widgets.dart';
import 'data_subscription.dart';
import 'form.dart';
import 'speed_gauge.dart';

/// Whether the Go runtime's own accounting is reachable on this platform.
/// On Android the core is in-process behind the service engine's action bus;
/// elsewhere only the host's memory wire exists.
bool get _kernelMemoryAvailable => !kIsWeb && Platform.isAndroid;

/// Process RSS from Dart when it reports a usable number. `currentRss` throws
/// on unsupported platforms and can report 0 on some Android builds; both
/// cases fall back to the host's own `rss` wire value.
int _processRss(int hostRss) {
  if (!_kernelMemoryAvailable) return hostRss;
  try {
    final rss = ProcessInfo.currentRss;
    if (rss > 0) return rss;
  } catch (_) {
    // Unsupported platform or a restricted runtime: the host wire still knows.
  }
  return hostRss;
}

/// Shared 2 s poll for the Go runtime stats. Ref-counted: the card and the
/// detail sheet each hold one lease, so opening the sheet does not start a
/// second timer and closing it leaves the card's timer running.
class KernelMemoryMonitor extends ChangeNotifier {
  KernelMemoryMonitor(this._box);

  final BoxController _box;
  Timer? _timer;
  int _leases = 0;
  bool _inFlight = false;
  bool _disposed = false;

  KernelMemoryStats? _stats;
  bool _available = false;
  bool _active = false;

  /// The controller this monitor polls. Exposed so a provider test can assert
  /// a replacement controller gets a fresh monitor (not a second one sharing
  /// the old controller's proxy).
  @visibleForTesting
  BoxController get box => _box;

  /// Whether a visibility lease has started the 2 s poll. Exposed for the same
  /// reason: disposing the provider must stop it.
  @visibleForTesting
  bool get polling => _timer != null;

  KernelMemoryStats? get stats => _stats;
  bool get available => _available;

  void acquire() {
    _leases++;
    if (_leases != 1) return;
    _active = true;
    unawaited(refresh());
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(refresh()));
  }

  void release() {
    if (_leases == 0) return;
    _leases--;
    if (_leases == 0) {
      _active = false;
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> refresh() async {
    // Keep retrying while a panel is visible: a core that was not attached on
    // first sample may come up later, and the fallback is only for as long as
    // the action genuinely cannot be answered.
    if (!_active || _inFlight) return;
    _inFlight = true;
    try {
      _stats = await _box.runtimeMemory();
      _available = true;
    } catch (_) {
      // Core not attached / engine absent: keep the last good reading but mark
      // the source unavailable so the UI falls back to the host-only display.
      _available = false;
    } finally {
      _inFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// One monitor per BoxController, alive as long as the app's provider scope.
///
/// The provider **watches** [boxControllerProvider]: a replaced controller (a
/// scope override in tests, or a rebuilt app) disposes the old monitor — and
/// its 2 s polling timer — before creating one bound to the new controller.
/// Reading once with `ref.read` left a second KernelProxy polling the stale
/// controller for the life of the process after a replacement.
final kernelMemoryMonitorProvider = Provider<KernelMemoryMonitor>((ref) {
  final box = ref.watch(boxControllerProvider);
  final monitor = KernelMemoryMonitor(box);
  ref.onDispose(monitor.dispose);
  return monitor;
});

/// Adds a visibility-scoped lease on the kernel memory monitor.
class KernelMemorySubscription extends ConsumerStatefulWidget {
  const KernelMemorySubscription({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<KernelMemorySubscription> createState() =>
      _KernelMemorySubscriptionState();
}

class _KernelMemorySubscriptionState extends ConsumerState<KernelMemorySubscription>
    with WidgetsBindingObserver {
  KernelMemoryMonitor? _monitor;
  bool _pageActive = false;
  bool _leased = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final monitor = ref.read(kernelMemoryMonitorProvider);
    if (!identical(_monitor, monitor)) {
      if (_leased) _monitor?.release();
      _monitor = monitor;
      _leased = false;
    }
    _pageActive = PageActivityScope.isActiveOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _sync();
  }

  void _sync() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final wanted = _kernelMemoryAvailable &&
        _pageActive &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
    final monitor = _monitor;
    if (monitor == null) return;
    if (wanted && !_leased) {
      monitor.acquire();
      _leased = true;
    } else if (!wanted && _leased) {
      monitor.release();
      _leased = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _sync();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_leased) _monitor?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watching the monitor rebuilds descendants on each 2 s sample.
    final monitor = ref.watch(kernelMemoryMonitorProvider);
    return AnimatedBuilder(
      animation: monitor,
      builder: (context, child) => child!,
      child: widget.child,
    );
  }
}

class MemoryPanel extends ConsumerWidget {
  const MemoryPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => BoxDataSubscription(
        data: BoxData.memory,
        child: KernelMemorySubscription(
          child: BoxPanel(
            onTap: () => openForm(context, const MemoryDetails()),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const PanelTitle('Memory', AppGlyphs.memory,
                    trailing: GlyphIcon(AppGlyphs.chevronForward, size: 18)),
                const SizedBox(height: 12),
                MemorySummary(snapshot: ref.watch(memoryProvider)),
              ],
            ),
          ),
        ),
      );
}

/// The card's App/Core split. With the kernel action available, Core is the Go
/// runtime's own total and App is the rest of the process's resident memory.
/// Without it, the host-only wire is shown and labelled as such — no invented
/// core figure.
class MemorySummary extends ConsumerWidget {
  const MemorySummary({super.key, required this.snapshot});
  final Json snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = context.colorScheme;
    final remote = snapshot['remote'] == true;
    final hostRss = (snapshot['rss'] as num?)?.toInt() ?? 0;
    final monitor = _kernelMemoryAvailable
        ? ref.watch(kernelMemoryMonitorProvider)
        : null;
    final stats = monitor != null && monitor.available ? monitor.stats : null;

    final parts = <(String, num, Color)>[];
    late final int total;
    if (remote) {
      total = (snapshot['total'] as num?)?.toInt() ?? 0;
      parts.add(('Core', total, secondSeriesColor(context)));
    } else if (stats != null) {
      final split = KernelMemorySplit.from(stats, _processRss(hostRss));
      total = split.processRss;
      parts.add(('App', split.app, color.primary));
      parts.add(('Core (runtime)', split.coreTotal, secondSeriesColor(context)));
    } else {
      // Host-only fallback: `core` is native PSS and everything else in the
      // process's PSS is the app's. Both are PSS slices of `rss` — never mixed
      // with the RSS-based runtime split above.
      final hostCore = snapshot['core'] as num? ?? 0;
      total = hostRss;
      parts.add(('App', math.max(0, hostRss - hostCore), color.primary));
      parts.add(('Core (host)', hostCore, secondSeriesColor(context)));
    }
    final totalText = bytes(total).split(' ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text.rich(TextSpan(children: [
        TextSpan(
            text: snapshot.isEmpty && stats == null ? '—' : totalText.first,
            style: AppTextStyle.title1.of(context, emphasized: true).toTabular),
        if (snapshot.isNotEmpty || stats != null)
          TextSpan(
              text: ' ${totalText.last}',
              style: AppTextStyle.footnote.of(context)
                  .copyWith(color: color.onSurfaceVariant)),
      ]), maxLines: 1),
      const SizedBox(height: 14),
      MemoryBar(parts: parts),
      const SizedBox(height: 10),
      Wrap(spacing: 16, runSpacing: 4, children: [
        for (final part in parts)
          Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: [
            DecoratedBox(
                decoration: ShapeDecoration(
                    color: part.$3, shape: AppShape.circle),
                child: const SizedBox.square(dimension: 8)),
            Text(context.tr(part.$1), style: context.listCaptionStyle),
            Text(bytes(part.$2),
                style: AppTextStyle.footnote.of(context, emphasized: true).toTabular),
          ]),
      ]),
    ]);
  }
}

class MemoryBar extends StatelessWidget {
  const MemoryBar({super.key, required this.parts});
  final List<(String, num, Color)> parts;

  @override
  Widget build(BuildContext context) {
    final total = parts.fold<num>(0, (sum, part) => sum + math.max(0, part.$2));
    final positive = parts.where((part) => part.$2 > 0).toList();
    return ClipRSuperellipse(
        borderRadius: AppRadius.full,
        child: SizedBox(height: 8, child: total == 0
            ? ColoredBox(color: SurfaceLevel.inset.colorOf(context.colorScheme))
            : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final (index, part) in positive.indexed) ...[
                  if (index > 0) const SizedBox(width: 2),
                  TweenAnimationBuilder<double>(
                      tween: Tween(
                          end: (part.$2 * 100 / total).roundToDouble()),
                      duration: context.motionDuration(commonDuration),
                      curve: Easing.standard,
                      builder: (_, percent, child) => Expanded(
                          flex: math.max(1, (percent * 100).round()),
                          child: child!),
                      child: ColoredBox(color: part.$3)),
                ]
              ])));
  }
}

class MemoryDetails extends ConsumerStatefulWidget {
  const MemoryDetails({super.key});
  @override
  ConsumerState<MemoryDetails> createState() => _MemoryDetailsState();
}

class _MemoryDetailsState extends ConsumerState<MemoryDetails> {
  bool _releasing = false;

  Future<void> _release() async {
    final box = ref.read(boxControllerProvider);
    final monitor = ref.read(kernelMemoryMonitorProvider);
    final before = monitor.stats?.runtimeTotal;
    // Capture the localized strings before any await: BuildContext must not be
    // used across an async gap.
    final releasedLabel = context.tr('Memory released');
    final coreLabel = context.tr('Core GC completed');
    final freedLabel = context.tr('Runtime freed');
    final failedLabel = context.tr('Memory release failed');
    if (mounted) setState(() => _releasing = true);

    // Both trims are independent: a failure of one must not hide the other or
    // crash the page.
    var hostOk = false;
    try {
      hostOk = await box.dashboardReleaseMemory();
    } catch (_) {
      hostOk = false;
    }
    var coreOk = false;
    try {
      // The user-facing release asks for the full trim (FreeOSMemory) so the
      // freed-bytes report has a meaningful before/after; host trims pass their
      // own level separately.
      coreOk = await box.forceGc(full: true);
    } catch (_) {
      coreOk = false;
    }
    try {
      await monitor.refresh();
    } catch (_) {
      // Already swallowed inside refresh.
    }
    final after = monitor.stats?.runtimeTotal;
    final freed = before != null && after != null
        ? math.max(0, before - after)
        : null;
    final report = switch ((hostOk, coreOk, freed)) {
      (true, true, final freed?) => '$releasedLabel · $freedLabel ${bytes(freed)}',
      (true, true, null) => releasedLabel,
      (true, false, _) => releasedLabel,
      (false, true, final freed?) => '$coreLabel · $freedLabel ${bytes(freed)}',
      (false, true, null) => coreLabel,
      (false, false, _) => failedLabel,
    };
    if (mounted) {
      setState(() => _releasing = false);
      showAppBanner(context, report);
    }
  }

  @override
  Widget build(BuildContext context) {
    final memory = ref.watch(memoryProvider);
    final remote = memory['remote'] == true;
    final hostRss = (memory['rss'] as num?)?.toInt() ?? 0;
    final monitor = _kernelMemoryAvailable
        ? ref.watch(kernelMemoryMonitorProvider)
        : null;
    final stats = monitor != null && monitor.available ? monitor.stats : null;
    final split =
        stats != null ? KernelMemorySplit.from(stats, _processRss(hostRss)) : null;
    return KernelMemorySubscription(
      child: BoxDataSubscription(
        data: BoxData.memory,
        child: BoxPage(
          title: 'Memory',
          loading: _releasing,
          actions: [
            if (!remote && memory['running'] == true)
              IconButtonData(
                  glyph: AppGlyphs.broom,
                  tooltip: context.tr('Release memory'),
                  onPressed: _releasing ? null : _release),
          ],
          children: [
            const SizedBox(height: 8),
            Text(context.tr('Total memory'), style: AppTextStyle.headline.of(context)),
            const SizedBox(height: 4),
            MemorySummary(snapshot: memory),
            const SizedBox(height: 12),
            Text(
              context.tr(remote
                  ? 'Memory reported by the remote core. Detailed accounting is unavailable.'
                  : stats != null
                      ? "The total is the process's resident memory (RSS). Core (runtime) is what the Go runtime holds; the rest of the process is the app's."
                      : "Host-only accounting: the total and both slices are Android's PSS figures. Go runtime accounting is unavailable."),
              style: context.listCaptionStyle,
            ),
            if (!remote)
              generateSection(title: context.tr('App'), items: [
                ListItem(
                    title: Text(context.tr('Process RSS')),
                    trailing: Text(bytes(split?.processRss ?? hostRss),
                        style: context.listValueStyle)),
                if (split != null)
                  ListItem(
                      title: Text(context.tr('App memory')),
                      trailing: Text(bytes(split.app), style: context.listValueStyle))
                else
                  ListItem(
                      title: Text(context.tr('ART heap')),
                      trailing: Text(bytes(memory['app'] as num? ?? 0),
                          style: context.listValueStyle)),
              ]),
            if (!remote && stats != null)
              generateSection(title: context.tr('Core (runtime)'), items: [
                ListItem(
                    title: Text(context.tr('Heap in use')),
                    trailing: Text(bytes(stats.heapInuse), style: context.listValueStyle)),
                ListItem(
                    title: Text(context.tr('Retained idle heap')),
                    trailing: Text(bytes(stats.heapIdle), style: context.listValueStyle)),
                ListItem(
                    title: Text(context.tr('Stack in use')),
                    trailing: Text(bytes(stats.stackInuse), style: context.listValueStyle)),
                ListItem(
                    title: Text(context.tr('Runtime other')),
                    trailing: Text(bytes(stats.runtimeOther), style: context.listValueStyle)),
                ListItem(
                    title: Text(context.tr('GC count')),
                    trailing: Text('${stats.numGC}', style: context.listValueStyle)),
                ListItem(
                    title: Text(context.tr('Goroutines')),
                    trailing: Text('${stats.goroutines}', style: context.listValueStyle)),
              ]),
            if (stats == null && !remote)
              generateSection(title: context.tr('Core (host)'), items: [
                if (memory['running'] != true)
                  ListItem(title: Text(context.tr('Not running'))),
                ListItem(
                    title: Text(context.tr('Core memory')),
                    trailing: Text(bytes(memory['core'] as num? ?? 0),
                        style: context.listValueStyle)),
                ListItem(
                    title: Text(context.tr('ART heap in use')),
                    trailing: Text(bytes(memory['heapInuse'] as num? ?? 0),
                        style: context.listValueStyle)),
                ListItem(
                    title: Text(context.tr('ART heap idle')),
                    trailing: Text(bytes(memory['heapIdle'] as num? ?? 0),
                        style: context.listValueStyle)),
              ]),
          ],
        ),
      ),
    );
  }
}
