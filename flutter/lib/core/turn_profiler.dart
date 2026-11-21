import 'dart:async';

import 'package:flutter/scheduler.dart';

/// Accumulates frame timings across one start-toggle turn and reports a single
/// summary line when it ends.
///
/// The turn lasts ~450 ms, so this costs a handful of float comparisons per
/// frame — small enough to stay always-on — and it is the only way to tell a
/// build-side stall from a raster-side one on a device we cannot profile.
/// Timings start at vsync, so `max vsync` separates both from a blocked
/// platform thread: a large value means the frame never reached its build in
/// time, which points at native work on the Android main thread rather than at
/// anything the widget tree paints.
class TurnProfiler {
  TurnProfiler._(this.label, this._report);

  /// Enables measurement immediately; every frame up to [stop] is counted.
  static TurnProfiler start(String label, void Function(String) report) {
    final profiler = TurnProfiler._(label, report);
    SchedulerBinding.instance.addTimingsCallback(profiler._onTimings);
    return profiler;
  }

  final String label;
  final void Function(String) _report;

  int _frames = 0;
  int _slow = 0;
  int _bad = 0;
  double _maxBuild = 0;
  double _maxRaster = 0;
  double _maxVsync = 0;
  bool _stopped = false;
  Timer? _pending;

  static const _slowMs = 16.7;
  static const _badMs = 33.4;

  void _onTimings(List<FrameTiming> timings) {
    for (final frame in timings) {
      final build = frame.buildDuration.inMicroseconds / 1000;
      final raster = frame.rasterDuration.inMicroseconds / 1000;
      final vsync = frame.vsyncOverhead.inMicroseconds / 1000;
      _frames++;
      if (build > _maxBuild) _maxBuild = build;
      if (raster > _maxRaster) _maxRaster = raster;
      if (vsync > _maxVsync) _maxVsync = vsync;
      final total = build + raster;
      if (total > _slowMs) _slow++;
      if (total > _badMs) _bad++;
    }
  }

  /// Stops and reports. The removal and the report are delayed a few frames:
  /// timings are delivered after their frame rasterises, so a turn's last two
  /// frames would otherwise be missing from the summary.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _pending = Timer(const Duration(milliseconds: 250), () {
      _pending = null;
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _report(
        '$label turn: $_frames frames, '
        'max build ${_maxBuild.toStringAsFixed(1)}ms, '
        'max raster ${_maxRaster.toStringAsFixed(1)}ms, '
        'max vsync ${_maxVsync.toStringAsFixed(1)}ms, '
        'slow>16.7ms=$_slow, bad>33.4ms=$_bad',
      );
    });
  }

  /// Stops without reporting, for a card disposed mid-turn (a pending timer
  /// would also trip the widget tests' "no timers left" invariant).
  void cancel() {
    _stopped = true;
    _pending?.cancel();
    _pending = null;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }
}
