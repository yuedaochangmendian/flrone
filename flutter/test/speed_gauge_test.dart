// The speed gauge's two animations and its two curve series.
//
// The connecting sweep used to read the caller's AnimationController value at
// build time. That controller belonged to the page, which only rebuilt on the
// kernel's ~200 ms samples and the host's ~400 ms session relay, so the arc
// jumped between those irregular ticks instead of turning at a steady rate.
// These tests pin that the gauge owns a linear ping-pong controller: with no
// external rebuild at all, equal time steps move the sweep by equal amounts,
// it reverses at the right end instead of wrapping, and a stopped gauge stops
// repainting.
//
// The download and upload curves share one peak and often overlap. They used
// to be two strengths of the same accent (primary, primary at 45% over the
// card), which read as one blue line. These tests pin two distinct hues, the
// same pair the legend and the painter use, on every theme including one where
// the theme's tertiary role is nearly the same hue as primary.

import 'package:flrone/components/speed_gauge.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// Find a CustomPaint by its painter type: PrismApp itself draws several.
CustomPaint _paintOf<T extends CustomPainter>(WidgetTester tester) => tester
    .widget<CustomPaint>(find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is T,
    ));

SpeedGaugePainter _gaugePainter(WidgetTester tester) =>
    _paintOf<SpeedGaugePainter>(tester).painter! as SpeedGaugePainter;

void main() {
  testWidgets('the connecting sweep turns at a steady rate on its own',
      (tester) async {
    await tester.pumpWidget(const TestApp(
      child: Center(
        child: SpeedGauge(
          size: 280,
          fraction: 0,
          color: Color(0xFF3482FF),
          spinning: true,
        ),
      ),
    ));
    // No setState, no box notification, no channel event between these pumps:
    // only the gauge's own linear controller may move the sweep.
    final first = _gaugePainter(tester).spin;
    expect(first, isNotNull);

    await tester.pump(const Duration(milliseconds: 275));
    final quarter = _gaugePainter(tester).spin!;
    await tester.pump(const Duration(milliseconds: 275));
    final half = _gaugePainter(tester).spin!;
    await tester.pump(const Duration(milliseconds: 275));
    final threeQuarter = _gaugePainter(tester).spin!;
    await tester.pump(const Duration(milliseconds: 275));
    final rightEnd = _gaugePainter(tester).spin!;

    // 1100 ms per leg: a quarter turn every 275 ms, with the same delta each
    // step, then the sweep bounces back from the right end instead of wrapping.
    expect(quarter, closeTo(0.25, 0.03));
    expect(half, closeTo(0.5, 0.03));
    expect(threeQuarter, closeTo(0.75, 0.03));
    expect(quarter - first!, closeTo(half - quarter, 0.02));
    expect(half - quarter, closeTo(threeQuarter - half, 0.02));
    expect(rightEnd, closeTo(1.0, 0.03));

    await tester.pump(const Duration(milliseconds: 275));
    final bouncedBack = _gaugePainter(tester).spin!;
    expect(bouncedBack, closeTo(0.75, 0.03), reason: 'the sweep reverses at the right end');
  });

  testWidgets('a gauge that is not connecting draws no sweep and stays still',
      (tester) async {
    await tester.pumpWidget(const TestApp(
      child: Center(
        child: SpeedGauge(
          size: 280,
          fraction: .4,
          color: Color(0xFF3482FF),
          spinning: false,
        ),
      ),
    ));
    final first = _gaugePainter(tester);
    expect(first.spin, isNull);
    await tester.pump(const Duration(milliseconds: 600));
    // Still the same painter instance: no controller is ticking behind a
    // value that is already shown.
    expect(_gaugePainter(tester), same(first));
    expect(_gaugePainter(tester).spin, isNull);
  });

  testWidgets('the sweep starts and stops with spinning', (tester) async {
    Widget gauge(bool spinning) => TestApp(
          child: Center(
            child: SpeedGauge(
              size: 280,
              fraction: 0,
              color: const Color(0xFF3482FF),
              spinning: spinning,
            ),
          ),
        );
    await tester.pumpWidget(gauge(true));
    expect(_gaugePainter(tester).spin, isNotNull);
    await tester.pump(const Duration(milliseconds: 275));
    expect(_gaugePainter(tester).spin, closeTo(0.25, 0.03));

    // The same widget with spinning flipped off must stop repainting.
    await tester.pumpWidget(gauge(false));
    final stopped = _gaugePainter(tester);
    expect(stopped.spin, isNull);
    await tester.pump(const Duration(milliseconds: 600));
    expect(_gaugePainter(tester), same(stopped));
  });

  group('speedSeriesColors', () {
    ({Color download, Color upload}) colorsOf({
      required Color seed,
      required Brightness brightness,
      ColorStyle style = ColorStyle.vivid,
    }) =>
        speedSeriesColorsOf(ColorScheme.fromSeed(
          seedColor: seed,
          brightness: brightness,
          style: style,
        ));

    double hueDistance(Color a, Color b) {
      final ha = HSLColor.fromColor(a).hue;
      final hb = HSLColor.fromColor(b).hue;
      final delta = (ha - hb).abs() % 360;
      return delta > 180 ? 360 - delta : delta;
    }

    for (final brightness in Brightness.values) {
      test('download and upload are distinct hues ($brightness)', () {
        final colors = colorsOf(
          seed: const Color(0xFF3482FF),
          brightness: brightness,
        );
        expect(colors.download, isNot(colors.upload));
        // The two lines must be far enough apart in hue to never read as one
        // series, even where they cross.
        expect(hueDistance(colors.download, colors.upload), greaterThan(30));
      });
    }

    test('a near-monochrome theme still gets two distinct hues', () {
      // Monochrome derives an achromatic primary and tertiary; neither has a
      // hue to rotate, so the HCT fallback must build a chromatic second color.
      final colors = colorsOf(
        seed: const Color(0xFF3482FF),
        brightness: Brightness.dark,
        style: ColorStyle.monochrome,
      );
      expect(colors.download, isNot(colors.upload));
      // A near-grey primary has no meaningful HSL hue; assert the upload is
      // genuinely saturated instead of relying on a hue delta against grey.
      expect(HSLColor.fromColor(colors.upload).saturation, greaterThan(0.3));
    });
  });

  testWidgets('the curves painter receives two different colours',
      (tester) async {
    await tester.pumpWidget(const TestApp(
      child: Center(
        child: SizedBox(
          width: 200,
          child: SpeedCurves(
            download: [0.0, 4.0, 8.0, 3.0],
            upload: [0.0, 1.0, 5.0, 9.0],
          ),
        ),
      ),
    ));
    final painter =
        _paintOf<SpeedCurvesPainter>(tester).painter! as SpeedCurvesPainter;
    expect(painter.downloadColor, isNot(painter.uploadColor));
  });

  testWidgets('a caller can override the curve pair explicitly',
      (tester) async {
    await tester.pumpWidget(const TestApp(
      child: Center(
        child: SizedBox(
          width: 200,
          child: SpeedCurves(
            download: [0.0, 4.0, 8.0],
            upload: [0.0, 2.0, 6.0],
            downloadColor: Color(0xFF00FF00),
            uploadColor: Color(0xFFFF0000),
          ),
        ),
      ),
    ));
    final painter =
        _paintOf<SpeedCurvesPainter>(tester).painter! as SpeedCurvesPainter;
    expect(painter.downloadColor, const Color(0xFF00FF00));
    expect(painter.uploadColor, const Color(0xFFFF0000));
  });
}
