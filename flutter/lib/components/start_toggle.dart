import 'dart:async';
import 'dart:math' as math;
import 'package:material_new_shapes/material_new_shapes.dart';
import '../widgets.dart';
import 'shape_badge.dart';

const _morphDuration = Duration(milliseconds: 450);
const _stateDuration = Duration(milliseconds: 150);

final _startMorph = Morph(MaterialShapes.circle, MaterialShapes.cookie9Sided);

Path _morphPath(double progress) => _startMorph.toPath(
  progress: progress,
  rotationPivotX: 0.5,
  rotationPivotY: 0.5,
);

double _morphTurn(double progress) => progress * 2 * math.pi / 9;

/// A circle with a play glyph while stopped that grows the cookie-9 of a
/// running tunnel, the way the M3 Expressive loader morphs between shapes.
class StartToggle extends StatefulWidget {
  const StartToggle({super.key,
    required this.size,
    required this.enabled,
    required this.running,
    required this.suspended,
    this.connecting = false,
    required this.onTap,
  });

  final VoidCallback onTap;
  final double size;
  final bool enabled;
  final bool running;
  final bool suspended;

  /// The service is between states: the icon becomes an activity indicator
  /// (FlClash's CoreStatusButton) instead of morphing straight to the target.
  final bool connecting;

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
    // No overshoot: the shape change reads as the button settling into its
    // next state. The old easeOutBack kicked past the target and looked stiff
    // next to FlClash's start button.
    curve: Curves.easeInOutCubic,
    reverseCurve: Curves.easeInOutCubic,
  );
  var _hovered = false;
  var _pressed = false;
  var _focused = false;

  /// FlClash holds the start button for 600 ms after a press. Rapid stop/start
  /// taps used to queue lifecycle ops faster than the service could settle;
  /// the button now absorbs that burst itself.
  Timer? _tapLock;

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
  void dispose() {
    _tapLock?.cancel();
    _progress.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_tapLock != null) return;
    _tapLock = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _tapLock = null);
    });
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
              // The overlay tween only rebuilds when its end value changes, but
              // the fill also depends on `enabled` and the current scheme. A
              // false -> true transition (or an accent change) can leave the
              // end at 0, so without this key the subtree keeps the painter
              // built with the old grey/inset colour indefinitely. Recreating
              // the tween on those changes makes the button pick up its theme
              // colour deterministically on the first frame it becomes usable.
              key: ValueKey('start-overlay:$enabled:${fill.toARGB32()}'),
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
                  // One icon at a time, cross-faded and scaled, the way
                  // FlClash's CoreStatusButton swaps its play/indicator/check
                  // states. The old glyph tween restarted on every rebuild and
                  // read as a hard cut between play and pause.
                  child: AnimatedSwitcher(
                    duration: context.motionDuration(_stateDuration),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.86, end: 1)
                            .animate(animation),
                        child: child,
                      ),
                    ),
                    child: widget.suspended
                        ? GlyphIcon(
                            AppGlyphs.wifiOff,
                            key: const ValueKey('suspended'),
                            size: size * 0.34,
                            color: ink,
                            fill: 1,
                          )
                        : widget.connecting
                        ? ActivityIndicator(
                            key: const ValueKey('connecting'),
                            size: size * 0.3,
                            color: ink,
                          )
                        : GlyphIcon(
                            AppGlyphs.playPause(widget.running ? 1 : 0),
                            key: ValueKey('running:${widget.running}'),
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
        )
        ..restore();
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
