import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_color_utilities/hct/hct.dart' as hct;

import '../widgets.dart';

// The speed test's parts, shared by the screen (speed_test.dart) and the test
// panel (test_panel.dart), so the two render one animation instead of two
// lookalikes. Shapes and timing follow Bettbox's speed-test screen:
//
//   * a 270° gauge on a non-linear scale (0,5,10,50,100,250,500,750,1000 Mbps),
//     a gradient sweep arc, a needle, and a track that spins while it connects;
//   * three phase dots (latency → download → upload) whose current one grows;
//   * throughput curves for download and upload on one shared peak.
//
// The values come from the kernel's own snapshot (`SpeedTestState` in
// core/mobile/speedtest.go); nothing here computes a measurement.

/// The gauge's marked values in Mbps, as Bettbox spaces them.
const speedGaugeMarks = <double>[
  0,
  5,
  10,
  50,
  100,
  250,
  500,
  750,
  1000,
];

/// Where [bps] sits on [speedGaugeMarks], as 0..1. The marks are unevenly
/// spaced, so each segment interpolates on its own.
double speedGaugeFraction(double bps) {
  final mbps = bps / 1e6;
  if (mbps <= 0) return 0;
  final segments = speedGaugeMarks.length - 1;
  for (var i = 0; i < segments; i++) {
    final low = speedGaugeMarks[i];
    final high = speedGaugeMarks[i + 1];
    if (mbps <= high) return (i + (mbps - low) / (high - low)) / segments;
  }
  return 1;
}

/// The gauge's headline: two decimals and a unit that follows the magnitude.
String speedValueText(double bps) {
  final mbps = bps / 1e6;
  if (mbps >= 1000) return (mbps / 1000).toStringAsFixed(2);
  return mbps.toStringAsFixed(1);
}

String speedUnitText(double bps) => bps / 1e6 >= 1000 ? 'Gbps' : 'Mbps';

/// The second chart/legend series of a speed run: primary at 45% over the card
/// surface, not an unrelated tertiary hue (surfaces.md). The first series is
/// [ColorScheme.primary]; gauges, tiles and curves share this blend so the
/// download/upload palette reads as one accent at two strengths. Blending over
/// [SurfaceLevel.card] keeps the value identical in the page, the panel and the
/// chart regardless of the local surface scope.
Color secondSeriesColor(BuildContext context) {
  final scheme = context.colorScheme;
  return Color.alphaBlend(
    scheme.primary.withValues(alpha: .45),
    SurfaceLevel.card.colorOf(scheme),
  );
}

/// The two curve series of a speed run, kept apart by hue rather than by
/// strength so a download and an upload line are never mistaken for one another.
/// Download stays [ColorScheme.primary]; upload is its complement — primary's
/// hue rotated 180° at the same tone, so a blue theme reads blue/orange and the
/// pair keeps the same light/dark contrast as the accent it came from.
///
/// A theme's tertiary role sits only ~60° away on a blue seed (a pale lilac),
/// which two overlapping lines do not separate clearly enough. HCT builds the
/// complement instead: an achromatic primary has no hue to rotate, so it gets
/// a fixed warm hue (30°) and enough chroma to be visibly coloured. The tone is
/// clamped to a readable light/dark range. The gauge and the result tiles keep
/// using [secondSeriesColor], a single accent at two strengths, because they
/// show one value at a time.
({Color download, Color upload}) speedSeriesColors(BuildContext context) =>
    speedSeriesColorsOf(context.colorScheme);

/// [speedSeriesColors] over an explicit scheme, so tests and non-widget callers
/// can pin the palette without standing up a whole themed app.
({Color download, Color upload}) speedSeriesColorsOf(ColorScheme scheme) {
  final seed = hct.Hct.fromInt(scheme.primary.toARGB32());
  final dark = scheme.brightness == Brightness.dark;
  final hue = seed.chroma < 4 ? 30.0 : (seed.hue + 180) % 360;
  final tone = seed.tone
      .clamp(dark ? 55.0 : 40.0, dark ? 85.0 : 65.0)
      .toDouble();
  final upload = Color(hct.Hct.from(hue, 48, tone).toInt());
  return (download: scheme.primary, upload: upload);
}

/// `1.2 Mbps` / `340 kbps`, for the tiles and the curve legend.
String speedRateText(double bps) {
  if (bps >= 1e9) return '${(bps / 1e9).toStringAsFixed(2)} Gbps';
  if (bps >= 1e6) return '${(bps / 1e6).toStringAsFixed(2)} Mbps';
  if (bps >= 1e3) return '${(bps / 1e3).toStringAsFixed(1)} kbps';
  return '${bps.toStringAsFixed(0)} bps';
}

/// `↓12 ↑34` — the loaded round trips, blank when a phase did not run.
String speedLoadedText(double downloadLatency, double uploadLatency) {
  final parts = [
    if (downloadLatency > 0) '↓${downloadLatency.round()}',
    if (uploadLatency > 0) '↑${uploadLatency.round()}',
  ];
  return parts.isEmpty ? '' : '${parts.join(' ')} ms';
}

/// The Bettbox gauge. [fraction] is 0..1 on [speedGaugeMarks]; [spinning] turns
/// on the connecting sweep while no value is shown.
///
/// Both animations live on their own controllers here rather than being driven
/// by the page's rebuilds. The kernel pushes a sample every 200 ms and the host
/// relays its session wire every 400 ms; if the sweep read the caller's value at
/// build time it only moved on those irregular ticks, so the arc visibly sped up
/// and slowed down. A linear repeating controller repaints every frame instead.
/// The needle likewise chases the sample on its own controller rather than a
/// [TweenAnimationBuilder]: a builder restarts its tween from the current value
/// on every rebuild, so a 450 ms chase never finished a segment between 200 ms
/// samples and the arc stuttered.
class SpeedGauge extends StatefulWidget {
  const SpeedGauge({
    super.key,
    required this.size,
    required this.fraction,
    required this.color,
    this.accentColor,
    this.trackColor,
    this.needleColor,
    this.passedLabelColor,
    this.spinning = false,
    this.showNeedle = true,
    this.labelStyle,
  });

  final double size;
  final double fraction;
  final Color color;
  final Color? accentColor;
  final Color? trackColor;
  final Color? needleColor;
  final Color? passedLabelColor;
  final bool spinning;
  final bool showNeedle;
  final TextStyle? labelStyle;

  @override
  State<SpeedGauge> createState() => _SpeedGaugeState();
}

class _SpeedGaugeState extends State<SpeedGauge>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final AnimationController _spinController;
  late Animation<double> _chase;
  double _target = 0;

  @override
  void initState() {
    super.initState();
    _target = speedGaugeFraction(widget.fraction);
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
      value: 1,
    );
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _chase = AlwaysStoppedAnimation(_target);
    _syncSpin();
  }

  void _syncSpin() {
    if (widget.spinning) {
      // Ping-pong instead of wrapping: the blue sweep reaches the right end,
      // reverses back to the left, and repeats, so it never jumps across the gap.
      if (!_spinController.isAnimating) _spinController.repeat(reverse: true);
    } else {
      _spinController.stop();
    }
  }

  @override
  void didUpdateWidget(SpeedGauge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSpin();
    final next = speedGaugeFraction(widget.fraction);
    if (next == _target) return;
    // Retarget from wherever the needle is now: one continuous ease, no reset.
    // `drive(CurveTween(...))` rather than a fresh `CurvedAnimation`: the SDK
    // requires a CurvedAnimation be created once and disposed, and this runs on
    // every sample; a CurveTween needs no disposal.
    _chase = Tween(begin: _chase.value, end: next).animate(
      _controller.drive(CurveTween(curve: Curves.easeOutCubic)),
    );
    _target = next;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _spinController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final size = widget.size;
    return SizedBox(
      width: size,
      height: size * .92,
      child: AnimatedBuilder(
        // The needle and the connecting sweep are independent; either one ticking
        // must repaint the same gauge.
        animation: Listenable.merge([_controller, _spinController]),
        builder: (context, _) => CustomPaint(
          painter: SpeedGaugePainter(
            fraction: _chase.value,
            color: widget.color,
            accentColor: widget.accentColor ?? secondSeriesColor(context),
            trackColor: widget.trackColor ?? scheme.surfaceContainerHighest,
            needleColor: widget.needleColor ?? scheme.onSurface,
            passedLabelColor: widget.passedLabelColor ?? scheme.onSurface,
            labelStyle:
                widget.labelStyle ??
                AppTextStyle.caption2.of(context).copyWith(
                  fontSize: size / 20,
                  fontWeight: FontWeight.w700,
                  color: scheme.outline.withValues(alpha: .75),
                ),
            spin: widget.spinning ? _spinController.value : null,
            showNeedle: widget.showNeedle,
          ),
          child: const SizedBox.shrink(),
        ),
      ),
    );
  }
}

/// Laid-out tick labels, keyed by (text, style).
///
/// [SpeedGaugePainter] is a `const CustomPainter` and is re-created (and re-painted) on
/// every frame of the connect sweep, so it cannot hold a cache itself; this module-level
/// map survives across instances. The set is tiny and bounded — nine labels times the two
/// styles the loop picks (passed / pending) — and the entry is dropped when the style
/// changes, so a theme switch cannot serve a stale colour.
final Map<(String, TextStyle), TextPainter> _tickLabels = {};

TextPainter _tickLabel(String text, TextStyle style) {
  final key = (text, style);
  final cached = _tickLabels[key];
  if (cached != null) return cached;
  // A restyle invalidates every entry: the map is keyed by the whole style, so entries for
  // the old one can never be hit again.
  if (_tickLabels.length > 64) {
    for (final painter in _tickLabels.values) {
      painter.dispose();
    }
    _tickLabels.clear();
  }
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  _tickLabels[key] = painter;
  return painter;
}

class SpeedGaugePainter extends CustomPainter {
  const SpeedGaugePainter({
    required this.fraction,
    required this.color,
    required this.accentColor,
    required this.trackColor,
    required this.needleColor,
    required this.labelStyle,
    required this.passedLabelColor,
    required this.spin,
    required this.showNeedle,
  });

  final double fraction;
  final Color color;
  final Color accentColor;
  final Color trackColor;
  final Color needleColor;
  final TextStyle labelStyle;
  final Color passedLabelColor;
  /// The connecting sweep's 0..1 position from the gauge's own linear
  /// repeating controller, or null when no sweep is drawn.
  final double? spin;
  final bool showNeedle;

  static const _start = math.pi * .75;
  static const _sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = size.width / 13;
    final center = Offset(size.width / 2, size.width / 2);
    final radius = size.width / 2 - strokeWidth / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    canvas.drawArc(rect, _start, _sweep, false, stroke..color = trackColor);

    final sweep = _sweep * fraction;
    if (fraction > .002) {
      canvas.drawArc(
        rect,
        _start,
        sweep,
        false,
        stroke
          ..shader = ui.Gradient.sweep(
            center,
            [color, accentColor],
            const [0, 1],
            TileMode.clamp,
            _start,
            _sweep,
          ),
      );
      stroke.shader = null;
    }

    final spin = this.spin;
    if (spin != null) {
      const length = math.pi / 5;
      canvas.drawArc(
        rect,
        _start + (_sweep - length) * spin,
        length,
        false,
        stroke..color = color.withValues(alpha: .7),
      );
      stroke.color = trackColor;
    }

    final labelRadius = radius - strokeWidth / 2 - size.width * .085;
    final segments = speedGaugeMarks.length - 1;
    for (var i = 0; i < speedGaugeMarks.length; i++) {
      final position = i / segments;
      final angle = _start + _sweep * position;
      final text = i == segments
          ? '1G+'
          : speedGaugeMarks[i].toStringAsFixed(0);
      // The tick labels never change while a frame runs, and this painter is re-invoked
      // every frame while the connect sweep spins (`_spinController.repeat()`), i.e. up to
      // 9 TextPainter builds + layouts at 60 fps for nine constant strings. Cache the two
      // styles the loop can choose (passed / not-yet-passed) per (text, style).
      final painter = _tickLabel(
        text,
        position <= fraction + .001
            ? labelStyle.copyWith(color: passedLabelColor)
            : labelStyle,
      );
      final labelCenter = center + Offset(math.cos(angle), math.sin(angle)) * labelRadius;
      painter.paint(
        canvas,
        labelCenter - Offset(painter.width / 2, painter.height / 2),
      );
    }

    if (!showNeedle) return;
    final angle = _start + sweep;
    final direction = Offset(math.cos(angle), math.sin(angle));
    final normal = Offset(-direction.dy, direction.dx);
    final outer = size.width / 2;
    final base = center - direction * outer * .1;
    final tip = center + direction * outer * .5;
    final baseHalf = outer * .06;
    final tipHalf = outer * .038;
    final needle = Path()
      ..moveTo(base.dx + normal.dx * baseHalf, base.dy + normal.dy * baseHalf)
      ..lineTo(tip.dx + normal.dx * tipHalf, tip.dy + normal.dy * tipHalf)
      ..lineTo(tip.dx - normal.dx * tipHalf, tip.dy - normal.dy * tipHalf)
      ..lineTo(base.dx - normal.dx * baseHalf, base.dy - normal.dy * baseHalf)
      ..close();
    canvas.drawPath(
      needle,
      Paint()
        ..shader = ui.Gradient.linear(
          base,
          tip,
          [
            needleColor.withValues(alpha: 0),
            needleColor.withValues(alpha: .35),
            needleColor.withValues(alpha: .9),
          ],
          const [0, .4, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(covariant SpeedGaugePainter old) =>
      old.fraction != fraction ||
      old.color != color ||
      old.accentColor != accentColor ||
      old.trackColor != trackColor ||
      old.needleColor != needleColor ||
      old.passedLabelColor != passedLabelColor ||
      old.spin != spin ||
      old.showNeedle != showNeedle ||
      old.labelStyle != labelStyle;
}

/// The three phase dots. [phase] is one of the kernel's stage names
/// (`latency`, `download`, `upload`) or `done`; null means no test started.
class SpeedPhaseSteps extends StatelessWidget {
  const SpeedPhaseSteps({super.key, required this.phase, this.scale = 1});

  /// `latency` / `download` / `upload` / `done`, else null.
  final String? phase;
  final double scale;

  static const _phases = ['latency', 'download', 'upload'];

  /// Which dot [phase] lights, -1 for "nothing started". The two callers speak
  /// different vocabularies: the kernel's own tester sends `done`, while the
  /// batch session relays `complete` / `cancelled` / `error` from the Android
  /// runner. Both map onto the last dot here, so one widget serves both.
  int _stepOf(String? phase) {
    switch (phase) {
      case null:
        return -1;
      case 'done' || 'complete' || 'cancelled' || 'error':
        return _phases.length;
      case 'discovery' || 'connecting' || '':
        return 0;
      default:
        return _phases.indexOf(phase);
    }
  }

  String _label(BuildContext context, String phase) => switch (phase) {
    'latency' => context.tr('Delay'),
    'download' => context.tr('Download'),
    _ => context.tr('Upload'),
  };

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final current = _stepOf(phase);
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _phases.length; i++) ...[
            if (i > 0)
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 16 * scale,
                height: 1.5 * scale,
                margin: EdgeInsets.symmetric(horizontal: 5 * scale),
                color: i <= current
                    ? scheme.primary.withValues(alpha: .5)
                    : scheme.outlineVariant,
              ),
            _PhaseDot(
              label: _label(context, _phases[i]),
              done: i < current,
              active: i == current,
              scale: scale,
            ),
          ],
        ],
      ),
    );
  }
}

class _PhaseDot extends StatelessWidget {
  const _PhaseDot({
    required this.label,
    required this.done,
    required this.active,
    required this.scale,
  });

  final String label;
  final bool done;
  final bool active;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final color = done || active ? scheme.primary : scheme.outline;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: (active ? 14 : 6) * scale,
          height: 6 * scale,
          decoration: BoxDecoration(
            color: done || active ? color : scheme.outlineVariant,
            borderRadius: BorderRadius.circular(3 * scale),
          ),
        ),
        SizedBox(width: 4 * scale),
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 300),
          style: AppTextStyle.caption2.of(context).copyWith(
            color: color,
            fontSize: 11 * scale,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
          child: Text(label),
        ),
      ],
    );
  }
}

/// Download and upload over one shared peak, as Bettbox overlays them. The
/// values are byte/s samples; [revision] forces a repaint when a new sample
/// lands with the same count (a retried phase).
class SpeedCurves extends StatelessWidget {
  const SpeedCurves({
    super.key,
    required this.download,
    required this.upload,
    this.height = 120,
    this.revision = 0,
    this.downloadColor,
    this.uploadColor,
  });

  final List<double> download;
  final List<double> upload;
  final double height;
  final int revision;
  final Color? downloadColor;
  final Color? uploadColor;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final peak = [0.0, ...download, ...upload].reduce(math.max);
    final scale = peak <= 0 ? 1.0 : peak;
    // The two lines use distinct hues, so an overlapping download and upload are
    // never read as one series. Callers pass the same pair to their legend.
    final colors = speedSeriesColors(context);
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: SpeedCurvesPainter(
          download: [for (final value in download) value / scale],
          upload: [for (final value in upload) value / scale],
          downloadColor: downloadColor ?? colors.download,
          uploadColor: uploadColor ?? colors.upload,
          gridColor: scheme.outlineVariant.withValues(alpha: .5),
          revision: revision,
        ),
      ),
    );
  }
}

class SpeedCurvesPainter extends CustomPainter {
  const SpeedCurvesPainter({
    required this.download,
    required this.upload,
    required this.downloadColor,
    required this.uploadColor,
    required this.gridColor,
    required this.revision,
  });

  final List<double> download;
  final List<double> upload;
  final Color downloadColor;
  final Color uploadColor;
  final Color gridColor;
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    _line(canvas, size, download, downloadColor);
    _line(canvas, size, upload, uploadColor);
  }

  void _line(Canvas canvas, Size size, List<double> values, Color color) {
    if (values.length < 2) return;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height * (1 - values[i].clamp(0.0, 1.0));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    // A soft fill under the line, so two overlapping series stay readable.
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, size.height),
          [color.withValues(alpha: .22), color.withValues(alpha: 0)],
        ),
    );
  }

  @override
  bool shouldRepaint(covariant SpeedCurvesPainter old) =>
      old.revision != revision ||
      old.downloadColor != downloadColor ||
      old.uploadColor != uploadColor ||
      old.gridColor != gridColor ||
      // Compare the samples, not only their count: a rolling window and a
      // re-normalised curve keep the same length while every value moves, and
      // the length-only check left the line painted at stale geometry.
      !_sameSamples(old.download, download) ||
      !_sameSamples(old.upload, upload);

  static bool _sameSamples(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
