import '../widgets.dart';

/// A toolbox or settings row: the leading icon takes the theme colour while the row is
/// pressed or hovered, with no ink ripple of its own.
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
    required this.title,
    this.subtitle,
    required this.page,
  });

  final Glyph glyph;
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
          leading: ToolIcon(glyph: widget.glyph, states: _states),
          title: Text(widget.title),
          subtitle: subtitle == null ? null : Text(subtitle),
          // The row paints no band of its own; the icon above carries the press feedback.
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

/// A row's leading glyph, taking the theme colour while it is pressed or hovered.
///
/// Only the glyph changes: no chip behind it and no row band, so the press reads as the icon
/// lighting up. The 40 dp box keeps the leading column from shifting when it does.
class ToolIcon extends StatelessWidget {
  const ToolIcon({super.key, required this.glyph, required this.states});

  final Glyph glyph;
  final WidgetStatesController states;

  static bool _active(Set<WidgetState> values) =>
      values.contains(WidgetState.pressed) ||
      values.contains(WidgetState.hovered) ||
      values.contains(WidgetState.focused);

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return ListenableBuilder(
      listenable: states,
      builder: (context, _) {
        final active = _active(states.value);
        // The colour is applied as soon as the pointer goes down and held: no fade, no chip.
        return SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: GlyphIcon(glyph, color: active ? colorScheme.primary : null),
          ),
        );
      },
    );
  }
}
