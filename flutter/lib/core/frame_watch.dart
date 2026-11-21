import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Logs UI-thread stalls as they happen, at any time — not only during a
/// start-toggle turn.
///
/// The turn profiler answers "how was this one animation"; this answers "where
/// else does the UI freeze". It probes instead of ticking: every [_probePeriod]
/// it asks for a frame and measures how long the UI thread takes to reach the
/// end of that frame. A blocked UI or platform thread delays the frame, so the
/// latency is the stall. This schedules only four frames a second when idle —
/// a permanently running [Ticker] would force continuous rendering, and it
/// also ignores `TickerMode`, which hangs `pumpAndSettle` in tests.
class FrameWatch {
  FrameWatch({required void Function(String) report, required String Function() context})
    : _report = report,
      _context = context;

  final void Function(String) _report;
  final String Function() _context;

  static const _probePeriod = Duration(milliseconds: 250);
  static const _stallMs = 100;
  static const _reportWindow = Duration(seconds: 2);

  Timer? _timer;
  bool _probing = false;
  DateTime? _lastReport;

  void start() {
    _timer ??= Timer.periodic(_probePeriod, (_) => _probe());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _probe() {
    if (_probing) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _probing = true;
    final began = DateTime.now();
    // A frame is already on its way (an animation is running); measure that
    // one instead of asking for another.
    if (SchedulerBinding.instance.hasScheduledFrame) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _settle(began));
    } else {
      WidgetsBinding.instance.ensureVisualUpdate();
      WidgetsBinding.instance.addPostFrameCallback((_) => _settle(began));
    }
  }

  void _settle(DateTime began) {
    _probing = false;
    final latencyMs = DateTime.now().difference(began).inMilliseconds;
    if (latencyMs < _stallMs) return;
    final now = DateTime.now();
    final reported = _lastReport;
    if (reported != null && now.difference(reported) < _reportWindow) return;
    _lastReport = now;
    _report('ui stall ~${latencyMs}ms (${_context()})');
  }
}
