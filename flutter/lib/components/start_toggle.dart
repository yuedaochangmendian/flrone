import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_new_shapes/material_new_shapes.dart';
import '../widgets.dart';
import 'shape_badge.dart';

const _morphDuration = Duration(milliseconds: 450);
const _stateDuration = Duration(milliseconds: 150);

/// Pre-rasterised silhouettes of the morph's blurred shadow.
///
/// FlClash draws the shadow with `MaskFilter.blur` on every frame of the turn —
/// the code is identical here, but a rotated blur pass re-rasterises per frame
/// and is a known performance cliff on the Impeller renderer this build ships
/// (the jank users see while the button turns). A soft 7 dp blur at 30 % alpha
/// is isotropic: rasterising it once per morph stage and drawing the result as
/// an image gives the same pixels with no blur pass in the animation. The
/// shadow colour is applied at draw time (srcIn over the white coverage), so
/// one cache serves every theme.
class _ShadowSprites {
  _ShadowSprites._();

  static const int _stages = 4;
  static const double _margin = 0.32;
  static const double _px = 128;

  static final Map<int, ui.Image> _images = {};
  static bool _started = false;

  /// Renders the stages one macrotask at a time: a few ms of rasterisation
  /// must never join a frame's build/paint budget.
  static void warm() {
    if (_started) return;
    _started = true;
    void renderNext(int stage) {
      if (stage >= _stages) return;
      Future<void>.delayed(Duration.zero, () {
        _images[stage] ??= _render(stage / (_stages - 1));
        renderNext(stage + 1);
      });
    }

    renderNext(0);
  }

  static ui.Image? of(double progress) {
    final stage = (progress.clamp(0.0, 1.0) * (_stages - 1)).round();
    return _images[stage];
  }

  static ui.Image _render(double progress) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final scale = _px / (1 + 2 * _margin);
    canvas
      ..scale(scale)
      ..translate(_margin, _margin);
    canvas.drawPath(
      _morphPath(progress),
      // The blur sigma scales with the canvas transform, so divide it back
      // out: 7 sprite-px, matching the live shadow's 7 logical px at the
      // 88 dp button size (the sprite stretches ~1:1 when drawn).
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 7.0 / scale),
    );
    final image = recorder.endRecording().toImageSync(_px.round(), _px.round());
    return image;
  }
}

final _startMorph = Morph(MaterialShapes.circle, MaterialShapes.cookie9Sided);

/// The morph's endpoint cubics, captured once. [_morphPath] lerps between them
/// directly into a Path — the same geometry and the same lerp formula
/// (`start * (1 - f) + stop * f`) as `Morph.toPath`, without the per-frame
/// Cubic/List churn that GC'd mid-turn.
final List<List<double>> _morphStartCubics = [
  for (final cubic in _startMorph.asCubics(0)) cubic.points,
];
final List<List<double>> _morphEndCubics = [
  for (final cubic in _startMorph.asCubics(1)) cubic.points,
];

Path _morphPath(double progress) {
  double lerp(double start, double stop) =>
      start * (1 - progress) + stop * progress;
  final path = Path()
    ..moveTo(
      lerp(_morphStartCubics.first[0], _morphEndCubics.first[0]),
      lerp(_morphStartCubics.first[1], _morphEndCubics.first[1]),
    );
  for (var i = 0; i < _morphStartCubics.length; i++) {
    final s = _morphStartCubics[i], e = _morphEndCubics[i];
    path.cubicTo(
      lerp(s[2], e[2]),
      lerp(s[3], e[3]),
      lerp(s[4], e[4]),
      lerp(s[5], e[5]),
      lerp(s[6], e[6]),
      lerp(s[7], e[7]),
    );
  }
  return path..close();
}

double _morphTurn(double progress) => progress * 2 * math.pi / 9;

/// A circle with a play glyph while stopped that grows the cookie-9 of a
/// running tunnel, the way the M3 Expressive loader morphs between shapes.
///
/// The animation code is FlClash's `_StartToggle` verbatim: one 450 ms
/// timeline, `easeOutBack` forward / `easeInCubic` back on the shape, the
/// glyph a continuous `playPause` vertex morph on the same duration and
/// curve, and the state layer tweening its ink alpha (the fill is blended per
/// frame). Same motion language, byte for byte.
class StartToggle extends StatefulWidget {
  const StartToggle({super.key,
    required this.size,
    required this.enabled,
    required this.running,
    required this.suspended,
    required this.onTap,
  });

  final VoidCallback onTap;
  final double size;
  final bool enabled;

  /// The shape target: the running (cookie/pause) form. The card passes the
  /// user's intent — `Started` *or* `Starting` — so the button springs toward
  /// its target on the tap that asked for it instead of waiting for the core
  /// (FlClash flips `isStart` on tap; the transition is the feedback).
  final bool running;
  final bool suspended;

  @override
  State<StartToggle> createState() => _StartToggleState();
}

class _StartToggleState extends State<StartToggle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _morphDuration,
    value: widget.running ? 1 : 0,
  );
  late final CurvedAnimation _progress = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );
  var _hovered = false;
  var _pressed = false;
  var _focused = false;

  /// The M3 state layer, painted inside the shape: the card's decoration
  /// covers the button, so ink on the card's Material would never show.
  double get _overlay => !widget.enabled
      ? 0
      : _focused
      ? 0.1
      : _hovered
      ? 0.08
      : 0;

  @override
  void didUpdateWidget(StartToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.running != widget.running) {
      widget.running ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void initState() {
    super.initState();
    // Bake the shadow silhouettes once, after the first frame settles.
    WidgetsBinding.instance.addPostFrameCallback((_) => _ShadowSprites.warm());
  }

  @override
  void dispose() {
    _progress.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    // No tap lock: the lifecycle chain serialises ops and the card's toggle
    // carries a stale-result token, so absorbing taps here would only hide
    // real state (FlClash's button has no lock either).
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final glass = LiquidGlassScope.of(context);
    final size = widget.size;
    final enabled = widget.enabled;
    final fill = enabled
        ? colorScheme.primary
        : SurfaceLevel.inset.colorOf(context.colorScheme);
    final ink = enabled ? colorScheme.onPrimary : colorScheme.onSurfaceVariant;
    final tooltip = widget.suspended
        ? context.tr('Remote')
        : widget.running
        ? context.tr('Stop')
        : context.tr('Start');
    final stateDuration = context.motionDuration(_stateDuration);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        container: true,
        button: true,
        enabled: enabled,
        label: tooltip,
        child: InkResponse(
          onTap: enabled ? _toggle : null,
          onHover: (value) => setState(() => _hovered = value),
          onHighlightChanged: (value) => setState(() => _pressed = value),
          onFocusChange: (value) => setState(() => _focused = value),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          child: ElasticPress(
            enabled: enabled,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: _overlay),
              duration: stateDuration,
              builder: (_, overlay, child) => AnimatedBuilder(
                animation: _progress,
                builder: (_, child) {
                  final progress = _progress.value;
                  final color = Color.alphaBlend(
                    ink.withValues(alpha: overlay),
                    fill,
                  );
                  return CustomPaint(
                    painter: _MorphPainter(
                      progress: progress,
                      color: glass ? null : color,
                      shadow: enabled
                          ? colorScheme.primary.withValues(alpha: 0.3)
                          : Colors.transparent,
                      ring: _focused
                          ? focusRingSide(colorScheme, standsOff: true)
                          : null,
                    ),
                    child: glass
                        ? LiquidGlass(
                            style: LiquidGlassStyle.tinted(colorScheme, color),
                            clipper: _MorphClipper(progress),
                            pressed: _pressed,
                            child: child,
                          )
                        : child,
                  );
                },
                child: child,
              ),
              child: SizedBox.square(
                dimension: size,
                child: Center(
                  child: widget.suspended
                      ? GlyphIcon(
                          AppGlyphs.wifiOff,
                          size: size * 0.34,
                          color: ink,
                          fill: 1,
                        )
                      : TweenAnimationBuilder<double>(
                          tween: Tween(end: widget.running ? 1 : 0),
                          duration: _morphDuration,
                          curve: Curves.easeOutBack,
                          builder: (_, progress, _) => GlyphIcon(
                            AppGlyphs.playPause(progress),
                            size: size * 0.34,
                            color: ink,
                            fill: 1,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fills the morph, or with no [color] leaves its inside to glass and casts
/// [shadow] only outside it, as one under glass would show through.
class _MorphPainter extends CustomPainter {
  const _MorphPainter({
    required this.progress,
    required this.color,
    required this.shadow,
    required this.ring,
  });

  static const _shadowOffset = Offset(0, 6);
  static const _shadowBlur = 14.0;

  final double progress;
  final Color? color;
  final Color shadow;
  final BorderSide? ring;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _morphPath(progress);
    final color = this.color;
    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2)
      ..rotate(_morphTurn(progress))
      ..scale(size.width, size.height)
      ..translate(-0.5, -0.5);
    if (shadow.a > 0) {
      canvas.save();
      // At the resting states the sprite is bypassed: the stopped button is
      // what the FlClash pixel-parity test captures, so its shadow stays on
      // the live-blur reference path. Mid-turn — where the rotated blur pass
      // used to drop frames — the pre-baked sprite takes over.
      final atRest = progress <= 0.001 || progress >= 0.999;
      final sprite = (color == null || atRest) ? null : _ShadowSprites.of(progress);
      if (sprite == null) {
        // Glass mode shades outside the shape (an even-odd clip punches the
        // shape out of the shadow — geometry the sprite does not carry), and
        // the pre-bake fallback before warm-up finishes: FlClash's live-blur
        // path covers both.
        if (color == null) {
          canvas.clipPath(
            Path()
              ..fillType = PathFillType.evenOdd
              ..addRect(const Rect.fromLTRB(-1, -1, 2, 2))
              ..addPath(path, Offset.zero),
          );
        }
        canvas
          ..translate(
            _shadowOffset.dx / size.width,
            _shadowOffset.dy / size.height,
          )
          ..drawPath(
            path,
            Paint()
              ..color = shadow
              ..maskFilter = MaskFilter.blur(
                BlurStyle.normal,
                _shadowBlur / 2 / size.width,
              ),
          );
      } else {
        // The sprite carries the shape's blurred silhouette; the colour rides
        // on top at draw time. No blur pass happens during the turn.
        canvas
          ..translate(0, _shadowOffset.dy / size.height)
          ..drawImageRect(
            sprite,
            ui.Rect.fromLTWH(
              0,
              0,
              sprite.width.toDouble(),
              sprite.height.toDouble(),
            ),
            ui.Rect.fromLTRB(
              -_ShadowSprites._margin,
              -_ShadowSprites._margin,
              1 + _ShadowSprites._margin,
              1 + _ShadowSprites._margin,
            ),
            Paint()..colorFilter = ui.ColorFilter.mode(shadow, ui.BlendMode.srcIn),
          );
      }
      canvas.restore();
    }
    if (color != null) {
      canvas.drawPath(path, Paint()..color = color);
    }
    if (ring case final ring?) {
      strokeUnitShape(canvas, path, size.width, ring);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MorphPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.shadow != shadow ||
      oldDelegate.ring != ring;
}

class _MorphClipper extends CustomClipper<Path> {
  const _MorphClipper(this.progress);

  final double progress;

  @override
  Path getClip(Size size) {
    final transform =
        Matrix4.translationValues(size.width / 2, size.height / 2, 0)
          ..rotateZ(_morphTurn(progress))
          ..scaleByDouble(size.width, size.height, 1, 1)
          ..translateByDouble(-0.5, -0.5, 0, 1);
    return _morphPath(progress).transform(transform.storage);
  }

  @override
  bool shouldReclip(_MorphClipper oldClipper) =>
      oldClipper.progress != progress;
}
