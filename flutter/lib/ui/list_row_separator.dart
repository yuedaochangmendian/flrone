part of 'list.dart';

/// Draws a row's bottom separator from where its title starts. A pressed row (or the row
/// above a pressed one) paints its line in the theme accent colour instead of dropping it,
/// which is how the tools and settings lists show the press without a row wash.
class _ListRowSeparator extends SingleChildRenderObjectWidget {
  final bool separated;
  final bool emphasized;
  final WidgetStatesController states;
  final double endIndent;

  const _ListRowSeparator({
    required this.separated,
    required this.emphasized,
    required this.states,
    required this.endIndent,
    required super.child,
  });

  Color _color(BuildContext context) => Divider.colorOf(context);

  Color _accent(BuildContext context) => context.colorScheme.primary;

  @override
  _RenderListRowSeparator createRenderObject(BuildContext context) =>
      _RenderListRowSeparator(
        separated: separated,
        emphasized: emphasized,
        states: states,
        remote: RemoteFocusAdapter.isEnabledOf(context),
        endIndent: endIndent,
        color: _color(context),
        accentColor: _accent(context),
        textDirection: Directionality.of(context),
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderListRowSeparator renderObject,
  ) {
    renderObject
      ..separated = separated
      ..emphasized = emphasized
      ..states = states
      ..remote = RemoteFocusAdapter.isEnabledOf(context)
      ..endIndent = endIndent
      ..color = _color(context)
      ..accentColor = _accent(context)
      ..textDirection = Directionality.of(context)
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    // A reorder hands a row a new neighbour below without changing any of
    // its own properties.
    if (separated) {
      renderObject.markNeedsPaint();
    }
  }
}

class _ListRowSeparatorStart extends SingleChildRenderObjectWidget {
  const _ListRowSeparatorStart({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderListRowSeparatorStart();
}

class _RenderListRowSeparatorStart extends RenderProxyBox {
  _RenderListRowSeparator? _row;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    var node = parent;
    while (node != null && node is! _RenderListRowSeparator) {
      node = node.parent;
    }
    _row = node as _RenderListRowSeparator?;
    _row?._start = this;
  }

  @override
  void detach() {
    if (_row?._start == this) {
      _row!._start = null;
    }
    _row = null;
    super.detach();
  }
}

class _RenderListRowSeparator extends RenderProxyBox {
  _RenderListRowSeparator({
    required bool separated,
    required bool emphasized,
    required WidgetStatesController states,
    required bool remote,
    required double endIndent,
    required Color color,
    required Color accentColor,
    required TextDirection textDirection,
    required double devicePixelRatio,
  }) : _separated = separated,
       _emphasized = emphasized,
       _states = states,
       _remote = remote,
       _endIndent = endIndent,
       _color = color,
       _accentColor = accentColor,
       _textDirection = textDirection,
       _devicePixelRatio = devicePixelRatio {
    _highlighted = _resolveHighlighted();
    _accented = _resolveAccented();
  }

  static const _maxSearchDepth = 32;

  _RenderListRowSeparatorStart? _start;
  late bool _highlighted;
  late bool _accented;
  double? _paintedOverhang;
  double? _settlingOverhang;
  bool _realignRequested = false;

  bool _separated;

  set separated(bool value) {
    if (_separated == value) {
      return;
    }
    _separated = value;
    markNeedsPaint();
  }

  bool _emphasized;

  set emphasized(bool value) {
    if (_emphasized == value) {
      return;
    }
    _emphasized = value;
    _updateHighlighted();
  }

  WidgetStatesController _states;

  set states(WidgetStatesController value) {
    if (_states == value) {
      return;
    }
    if (attached) {
      _states.removeListener(_updateHighlighted);
      value.addListener(_updateHighlighted);
    }
    _states = value;
    _updateHighlighted();
  }

  bool _remote;

  set remote(bool value) {
    if (_remote == value) {
      return;
    }
    _remote = value;
    _updateHighlighted();
  }

  double _endIndent;

  set endIndent(double value) {
    if (_endIndent == value) {
      return;
    }
    _endIndent = value;
    markNeedsPaint();
  }

  Color _color;

  set color(Color value) {
    if (_color == value) {
      return;
    }
    _color = value;
    markNeedsPaint();
  }

  Color _accentColor;

  set accentColor(Color value) {
    if (_accentColor == value) {
      return;
    }
    _accentColor = value;
    markNeedsPaint();
  }

  TextDirection _textDirection;

  set textDirection(TextDirection value) {
    if (_textDirection == value) {
      return;
    }
    _textDirection = value;
    markNeedsPaint();
  }

  double _devicePixelRatio;

  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) {
      return;
    }
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  double get _thickness {
    final pixels = (_devicePixelRatio * 0.75).round();
    return (pixels < 1 ? 1 : pixels) / _devicePixelRatio;
  }

  /// A pressed line is bolder as well as coloured: on a hairline the colour alone is easy to
  /// miss, and the extra weight reads as press feedback against the normal line.
  double get _accentThickness {
    final pixels = (_devicePixelRatio * 1.5).round();
    return (pixels < 1 ? 1 : pixels) / _devicePixelRatio;
  }

  bool _resolveHighlighted() {
    if (_emphasized) {
      return true;
    }
    final states = _states.value;
    return states.contains(WidgetState.pressed) ||
        (states.contains(WidgetState.focused) &&
            (_remote || FocusMovedByKey.instance.value));
  }

  /// The press this row's line should accent. `emphasized` (an invalid row) keeps the old
  /// iOS behaviour of hiding the line instead.
  bool _resolveAccented() {
    if (_emphasized) {
      return false;
    }
    return _resolveHighlighted();
  }

  void _updateHighlighted() {
    final highlighted = _resolveHighlighted();
    final accented = _resolveAccented();
    if (_highlighted == highlighted && _accented == accented) {
      return;
    }
    _highlighted = highlighted;
    _accented = accented;
    markNeedsPaint();
    _neighbour(below: false)?.markNeedsPaint();
  }

  _RenderListRowSeparator? _neighbour({required bool below}) {
    RenderObject node = this;
    for (
      var depth = 0;
      node.parentData is! ContainerParentDataMixin<RenderObject>;
      depth++
    ) {
      final parent = node.parent;
      if (parent == null || depth == _maxSearchDepth) {
        return null;
      }
      node = parent;
    }
    final siblings = node.parentData! as ContainerParentDataMixin<RenderObject>;
    RenderObject? candidate = below
        ? siblings.nextSibling
        : siblings.previousSibling;
    for (var depth = 0; candidate != null; depth++) {
      if (candidate is _RenderListRowSeparator) {
        return candidate;
      }
      if (depth == _maxSearchDepth) {
        return null;
      }
      RenderObject? onlyChild;
      var childCount = 0;
      candidate.visitChildren((child) {
        onlyChild = child;
        childCount++;
      });
      candidate = childCount == 1 ? onlyChild : null;
    }
    return null;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _states.addListener(_updateHighlighted);
    FocusMovedByKey.instance.addListener(_updateHighlighted);
    _highlighted = _resolveHighlighted();
    _PixelRealignment.watch(this);
  }

  @override
  void detach() {
    _PixelRealignment.unwatch(this);
    _states.removeListener(_updateHighlighted);
    FocusMovedByKey.instance.removeListener(_updateHighlighted);
    super.detach();
  }

  /// Null while an ancestor has stopped painting the row, such as a sliver
  /// that moved it into its keep-alive bucket: its paint transform is then
  /// all zeros, which [localToGlobal] turns into NaN.
  double? _pixelOverhang() {
    final deviceBottom =
        localToGlobal(Offset(0, size.height)).dy * _devicePixelRatio;
    if (!deviceBottom.isFinite) {
      return null;
    }
    return deviceBottom - (deviceBottom + 1e-3).floorToDouble();
  }

  /// Returns whether the row needs another frame, either to see it stop
  /// moving or to repaint: this runs after the frame has painted, when a
  /// [markNeedsPaint] no longer schedules one.
  bool _realign() {
    final painted = _paintedOverhang;
    if (painted == null) {
      return false;
    }
    final overhang = _pixelOverhang();
    if (overhang == null) {
      return false;
    }
    bool same(double? other) =>
        other != null && (overhang - other).abs() < 0.01;
    if (same(painted)) {
      _settlingOverhang = null;
      return false;
    }
    if (!same(_settlingOverhang)) {
      _settlingOverhang = overhang;
      return true;
    }
    if (_realignRequested) {
      return false;
    }
    _realignRequested = true;
    markNeedsPaint();
    return true;
  }

  @override
  void performLayout() {
    super.performLayout();
    // A lazily built row arrives below a row that has already painted.
    if (_highlighted) {
      _neighbour(below: false)?.markNeedsPaint();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    _paintedOverhang = null;
    _realignRequested = false;
    if (!_separated) {
      return;
    }
    final below = _neighbour(below: true);
    // The pressed row's own line and the one above it (this row's line, when the row below is
    // pressed) take the accent colour. An invalid row keeps hiding its line, as on iOS.
    final accented = _accented || (below?._accented ?? false);
    if (!accented && (_highlighted || (below?._highlighted ?? false))) {
      return;
    }
    final start = _start;
    final title = start != null && start.hasSize
        ? MatrixUtils.transformRect(
            start.getTransformTo(this),
            Offset.zero & start.size,
          )
        : null;
    final (left, right) = switch (_textDirection) {
      TextDirection.ltr => (title?.left ?? 0.0, size.width - _endIndent),
      TextDirection.rtl => (_endIndent, title?.right ?? size.width),
    };
    // Layout is not snapped to device pixels, and a line straddling pixel rows
    // renders with faint, blurred edges.
    final overhang = _pixelOverhang() ?? 0;
    _paintedOverhang = overhang;
    final bottom = size.height - overhang / _devicePixelRatio;
    final thickness = accented ? _accentThickness : _thickness;
    context.canvas.drawRect(
      Rect.fromLTRB(left, bottom - thickness, right, bottom).shift(offset),
      Paint()..color = accented ? _accentColor : _color,
    );
  }
}

/// Scrolling, sheets and transitions move a painted row without repainting
/// it, which can leave its line between device pixels. Once nothing is moving
/// any more, a row whose line drifted off the pixel grid paints again.
abstract final class _PixelRealignment {
  static final _rows = <_RenderListRowSeparator>{};
  static var _listening = false;

  static void watch(_RenderListRowSeparator row) {
    _rows.add(row);
    if (!_listening) {
      _listening = true;
      SchedulerBinding.instance.addPersistentFrameCallback(_check);
    }
  }

  static void unwatch(_RenderListRowSeparator row) => _rows.remove(row);

  static void _check(Duration _) {
    if (_rows.isEmpty || SchedulerBinding.instance.hasScheduledFrame) {
      return;
    }
    var needsFrame = false;
    for (final row in _rows) {
      needsFrame = row._realign() || needsFrame;
    }
    if (needsFrame) {
      SchedulerBinding.instance.scheduleFrame();
    }
  }
}
