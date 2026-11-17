import '../widgets.dart';

/// Bettbox's toolbox palette: each entry owns one colour, and only its icon wears it.
abstract final class ToolColors {
  static const blue = Color(0xFF2F80ED);
  static const purple = Color(0xFF7B61FF);
  static const teal = Color(0xFF00A3A3);
  static const orange = Color(0xFFE58A00);
  static const green = Color(0xFF3B9C4A);
  static const pink = Color(0xFFD9466F);
  static const blueDeep = Color(0xFF2E7DD7);
  static const burntOrange = Color(0xFFC2571A);
  static const indigo = Color(0xFF5C6BC0);
  static const cyan = Color(0xFF0097D6);
  static const orchid = Color(0xFFAA47BC);
}

/// A toolbox or settings row: the leading icon takes the entry's own colour while the row
/// is pressed or hovered, with no ink ripple, wash or shadow of its own.
///
/// The row owns the tap — `ListItem.open` hands it to an `OpenContainer`, whose recognizer
/// wins the gesture arena before an inner press surface sees a tap-down — so the entry
/// observes its own pointer events (`Listener`/`MouseRegion` do not join the arena) and
/// publishes them to a `WidgetStatesController` the icon listens to. The tint is applied
/// directly on pointer-down: no fade, no sparkle, nothing that reads as a blink.
class ToolEntry extends StatefulWidget {
  const ToolEntry({
    super.key,
    required this.glyph,
    required this.color,
    required this.title,
    this.subtitle,
    required this.page,
  });

  final Glyph glyph;

  /// The entry's colour from [ToolColors], worn by the icon during a press or hover.
  final Color color;
  final String title;
  final String? subtitle;
  final Widget page;

  @override State<ToolEntry> createState() => _ToolEntryState();
}

class _ToolEntryState extends State<ToolEntry> {
  final _states = WidgetStatesController();

  @override void dispose() {
    _states.dispose();
    super.dispose();
  }

  @override Widget build(BuildContext context) {
    final subtitle = widget.subtitle;
    return Listener(
      onPointerDown: (_) => _set(WidgetState.pressed, true),
      onPointerUp: (_) => _set(WidgetState.pressed, false),
      onPointerCancel: (_) => _set(WidgetState.pressed, false),
      child: MouseRegion(
        onEnter: (_) => _set(WidgetState.hovered, true),
        onExit: (_) => _set(WidgetState.hovered, false),
        child: ListItem.open(
          leading: ToolIcon(
            glyph: widget.glyph,
            color: widget.color,
            states: _states,
          ),
          title: Text(widget.title),
          subtitle: subtitle == null ? null : Text(subtitle),
          // Only the icon answers: no row wash, no shadow, no separator change.
          pressTint: const Color(0x00000000),
          widget: widget.page,
        ),
      ),
    );
  }

  void _set(WidgetState state, bool value) {
    if (mounted) _states.update(state, value);
  }
}

/// A row's leading glyph, taking the entry's own colour while it is pressed or hovered.
///
/// Only the glyph changes: no chip behind it and no row band, so the press reads as the icon
/// lighting up. The 40 dp box keeps the leading column from shifting when it does.
class ToolIcon extends StatelessWidget {
  const ToolIcon({
    super.key,
    required this.glyph,
    required this.color,
    required this.states,
  });

  final Glyph glyph;
  final Color color;
  final WidgetStatesController states;

  static bool _active(Set<WidgetState> values) =>
      values.contains(WidgetState.pressed) ||
      values.contains(WidgetState.hovered) ||
      values.contains(WidgetState.focused);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: states,
      builder: (context, _) {
        final active = _active(states.value);
        // The colour is applied as soon as the pointer goes down and held: no fade, no chip.
        return SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: GlyphIcon(glyph, color: active ? color : null),
          ),
        );
      },
    );
  }
}
