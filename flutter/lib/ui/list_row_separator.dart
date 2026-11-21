part of 'list.dart';

/// Draws a row's bottom separator from where its title starts. An invalid row keeps the iOS
/// behaviour of hiding its line; a press lifts the row itself now, so the separator no longer
/// changes colour or weight under the finger.
class _ListRowSeparator extends SingleChildRenderObjectWidget {
  final bool separated;
  final bool emphasized;
  final double endIndent;

  const _ListRowSeparator({
    required this.separated,
    required this.emphasized,
    required this.endIndent,
    required super.child,
  });

  Color _color(BuildContext context) => Divider.colorOf(context);

  @override
  _RenderListRowSeparator createRenderObject(BuildContext context) =>
      _RenderListRowSeparator(
        separated: separated,
        emphasized: emphasized,
        endIndent: endIndent,
        color: _color(context),
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
      ..endIndent = endIndent
      ..color = _color(context)
      ..textDirection = Directionality.of(context)
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    // The line starts at the title's current position; a reorder or a rebuilt
    // leading slot can move it without changing any property above.
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
    required double endIndent,
    required Color color,
    required TextDirection textDirection,
    required double devicePixelRatio,
  }) : _separated = separated,
       _emphasized = emphasized,
       _endIndent = endIndent,
       _color = color,
       _textDirection = textDirection,
       _devicePixelRatio = devicePixelRatio;

  _RenderListRowSeparatorStart? _start;
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
    markNeedsPaint();
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

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _PixelRealignment.watch(this);
  }

  @override
  void detach() {
    _PixelRealignment.unwatch(this);
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
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    _paintedOverhang = null;
    _realignRequested = false;
    if (!_separated || _emphasized) {
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
    final thickness = _thickness;
    context.canvas.drawRect(
      Rect.fromLTRB(left, bottom - thickness, right, bottom).shift(offset),
      Paint()..color = _color,
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
