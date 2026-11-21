import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/scheduler.dart';

/// Accumulates the frame cadence of one start-toggle turn and reports a single
/// summary line when it ends.
///
/// Sampled from a [Ticker] created by the owning widget's [TickerProvider],
/// not from `addTimingsCallback`: that pipeline reported zero frames for both
/// turn directions on a release device (stop was visually smooth), so its
/// numbers never arrived. A provider-owned ticker is muted with its
/// `TickerMode`, so a page pushed over the card neither measures nor keeps
/// scheduling frames (a bare ticker hangs every `pumpAndSettle` whose page
/// holds a panel in transition). The ticker's `elapsed` is the engine's vsync
/// timestamp: the delta between ticks is the real frame interval — a skipped
/// frame doubles it, a stalled UI thread turns it into one large gap.
class TurnProfiler {
  TurnProfiler._(this.label, this._report);

  /// Enables measurement immediately; every tick up to [stop] is counted.
  static TurnProfiler start(
    String label,
    void Function(String) report, {
    required TickerProvider vsync,
  }) {
    final profiler = TurnProfiler._(label, report);
    profiler._ticker = vsync.createTicker(profiler._onTick)..start();
    profiler._driftMark = DateTime.now();
    profiler._driftTimer = Timer.periodic(
      _driftPeriod,
      (_) => profiler._onDriftTick(),
    );
    return profiler;
  }

  final String label;
  final void Function(String) _report;

  Ticker? _ticker;
  Duration? _last;
  Duration? _firstTick;
  int _frames = 0;
  int _slow = 0;
  int _bad = 0;
  double _maxGapMs = 0;
  double _maxGapAtMs = 0;
  double _sumGapMs = 0;
  bool _stopped = false;

  /// A 25 ms wall-clock timer next to the vsync ticker. The ticker only says
  /// *that* frames stopped; this says *where* the stop was: a Dart timer that
  /// fires late means the UI isolate's event loop was busy (a synchronous task
  /// or a GC pause), while a punctual timer next to a large gap means the
  /// frame never arrived from outside it — a blocked platform thread (vsync
  /// comes from it) or a raster thread that never finished the previous frame.
  /// Both callbacks share the UI isolate, so this is a heuristic, not an
  /// independent clock; the turn window is cut at [stop] to keep it honest.
  Timer? _driftTimer;
  DateTime? _driftMark;
  double _maxDriftMs = 0;

  static const _driftPeriod = Duration(milliseconds: 25);

  /// 1.5 and 3 frames at 60 Hz; the reported refresh rate makes the reading
  /// meaningful on 90/120 Hz panels too.
  static const _slowMs = 25.0;
  static const _badMs = 50.0;

  double get _refreshRate {
    try {
      return PlatformDispatcher.instance.views.first.display.refreshRate;
    } catch (_) {
      return 60;
    }
  }

  void _onTick(Duration elapsed) {
    final last = _last;
    _last = elapsed;
    _firstTick ??= elapsed;
    if (last == null) return;
    final gapMs = (elapsed - last).inMicroseconds / 1000;
    _frames++;
    _sumGapMs += gapMs;
    if (gapMs > _maxGapMs) {
      _maxGapMs = gapMs;
      _maxGapAtMs = (elapsed - _firstTick!).inMicroseconds / 1000;
    }
    if (gapMs > _slowMs) _slow++;
    if (gapMs > _badMs) _bad++;
  }

  void _onDriftTick() {
    final now = DateTime.now();
    final mark = _driftMark;
    _driftMark = now;
    if (mark == null) return;
    final driftMs = now.difference(mark).inMilliseconds - _driftPeriod.inMilliseconds;
    if (driftMs > _maxDriftMs) _maxDriftMs = driftMs.toDouble();
  }

  /// Stops and reports immediately. Waiting after the animation settled used
  /// to fold the next 250 ms of idle/GC time into this turn's frame count,
  /// average gap and drift, which made the reported position misleading.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _ticker?.stop(canceled: true);
    _ticker = null;
    _driftTimer?.cancel();
    _driftTimer = null;
    final avg = _frames == 0 ? 0.0 : _sumGapMs / _frames;
    _report(
      '$label turn: $_frames frames @${_refreshRate.toStringAsFixed(0)}Hz, '
      'max gap ${_maxGapMs.toStringAsFixed(1)}ms'
      '${_maxGapMs > _slowMs ? ' at ${_maxGapAtMs.toStringAsFixed(0)}ms' : ''}, '
      'avg gap ${avg.toStringAsFixed(1)}ms, '
      'slow>${_slowMs.toStringAsFixed(0)}ms=$_slow, '
      'bad>${_badMs.toStringAsFixed(0)}ms=$_bad, '
      'ui drift ${_maxDriftMs.toStringAsFixed(0)}ms',
    );
  }

  /// Stops without reporting, for a card disposed mid-turn.
  void cancel() {
    _stopped = true;
    _ticker?.stop(canceled: true);
    _ticker = null;
    _driftTimer?.cancel();
    _driftTimer = null;
  }
}
