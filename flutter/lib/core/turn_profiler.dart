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
    return profiler;
  }

  final String label;
  final void Function(String) _report;

  Ticker? _ticker;
  Duration? _last;
  int _frames = 0;
  int _slow = 0;
  int _bad = 0;
  double _maxGapMs = 0;
  double _sumGapMs = 0;
  bool _stopped = false;
  Timer? _pending;

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
    if (last == null) return;
    final gapMs = (elapsed - last).inMicroseconds / 1000;
    _frames++;
    _sumGapMs += gapMs;
    if (gapMs > _maxGapMs) _maxGapMs = gapMs;
    if (gapMs > _slowMs) _slow++;
    if (gapMs > _badMs) _bad++;
  }

  /// Stops and reports. The report waits a few frames so the turn's last
  /// ticks (scheduled before the controller settled) still land in the sum.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _pending = Timer(const Duration(milliseconds: 250), () {
      _pending = null;
      _ticker?.stop(canceled: true);
      _ticker = null;
      final avg = _frames == 0 ? 0.0 : _sumGapMs / _frames;
      _report(
        '$label turn: $_frames frames @${_refreshRate.toStringAsFixed(0)}Hz, '
        'max gap ${_maxGapMs.toStringAsFixed(1)}ms, '
        'avg gap ${avg.toStringAsFixed(1)}ms, '
        'slow>${_slowMs.toStringAsFixed(0)}ms=$_slow, '
        'bad>${_badMs.toStringAsFixed(0)}ms=$_bad',
      );
    });
  }

  /// Stops without reporting, for a card disposed mid-turn (a pending timer
  /// would also trip the widget tests' "no timers left" invariant).
  void cancel() {
    _stopped = true;
    _pending?.cancel();
    _pending = null;
    _ticker?.stop(canceled: true);
    _ticker = null;
  }
}
