import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Logs UI-thread frame stalls as they happen, at any time — not only during a
/// start-toggle turn.
///
/// The turn profiler answers "how was this one animation"; this answers "where
/// else does the UI freeze", and it must also catch a freeze *inside* an
/// animation: the turn that reported one 188 ms gap produced a perfectly smooth
/// cadence otherwise, and a periodic probe can land between the stall and miss
/// it entirely. So this rides the frames that are already happening: a
/// persistent frame callback receives the engine's vsync timestamp for every
/// frame, and the interval between two consecutive frames is the real cadence.
///
/// A gap is only a stall when the frames were flowing: after an idle second the
/// next frame's interval is huge and harmless, so a gap is judged against the
/// previous one — animation-speed frames (well under [_animatingMs]) followed by
/// a long interval means something stopped the frames. A persistent callback
/// never schedules a frame itself, so it cannot keep a test's `pumpAndSettle`
/// awake (a bare [Ticker] does, and it also ignores `TickerMode`).
///
/// [TurnProfiler]'s `ui drift` proved a start freeze sits on the UI isolate;
/// [_measureFrameWork] attributes it: the work between the start of a frame and
/// its post-frame callback is build + layout + paint, all on that isolate, so a
/// heavy *rebuild* shows up here while the event handlers stay fast.
class FrameWatch {
  FrameWatch({required void Function(String) report, required String Function() context})
    : _report = report,
      _context = context;

  final void Function(String) _report;
  final String Function() _context;

  static const _animatingMs = 50.0;
  static const _stallMs = 100.0;
  static const _reportWindow = Duration(seconds: 2);

  /// Build + layout + paint beyond this is worth a line.
  static const _frameWorkMs = 12;

  Duration? _last;
  double? _lastGapMs;
  DateTime? _lastReport;
  DateTime? _lastWorkReport;

  void start() {
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
  }

  void _onFrame(Duration timeStamp) {
    _measureFrameWork();
    final last = _last;
    _last = timeStamp;
    if (last == null) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final gapMs = (timeStamp - last).inMicroseconds / 1000;
    final previous = _lastGapMs;
    _lastGapMs = gapMs;
    // Idle periods (and the first frames after a resume) are not stalls: only
    // a long interval that follows animation-speed frames describes a freeze
    // the user could see.
    if (previous == null || previous >= _animatingMs) return;
    if (gapMs < _stallMs) return;
    final now = DateTime.now();
    final reported = _lastReport;
    if (reported != null && now.difference(reported) < _reportWindow) return;
    _lastReport = now;
    _report('ui frame gap ~${gapMs.toStringAsFixed(0)}ms (${_context()})');
  }

  /// A persistent callback runs at the start of the frame; the post-frame
  /// callback runs after build, layout and paint, so the delta is the UI
  /// thread's frame work. Reported above [_frameWorkMs] and throttled like the
  /// gap lines, so a rebuild storm cannot flood the log.
  void _measureFrameWork() {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final began = DateTime.now();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final workMs = DateTime.now().difference(began).inMilliseconds;
      if (workMs < _frameWorkMs) return;
      final now = DateTime.now();
      final reported = _lastWorkReport;
      if (reported != null && now.difference(reported) < _reportWindow) return;
      _lastWorkReport = now;
      _report('frame work ${workMs}ms (${_context()})');
    });
  }
}
