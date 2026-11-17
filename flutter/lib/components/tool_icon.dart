import '../widgets.dart';

/// A toolbox row's leading glyph, tinted with the theme while its row is pressed.
///
/// The row owns the gesture — `ListItem` hands its tap to an `OpenContainer`, whose
/// recognizer wins before a nested press surface ever sees a tap-down — so the entry that
/// builds the row mirrors its pointer events into a `WidgetStatesController`, and this
/// listens to it. The icon therefore takes the theme colour for the length of the press,
/// as Bettbox's toolbox cards light their icon from the card's own press/hover state.
class ToolIcon extends StatelessWidget {
  const ToolIcon({super.key, required this.glyph, required this.states});

  final Glyph glyph;
  final WidgetStatesController states;

  static const _duration = Duration(milliseconds: 120);

  static bool _active(Set<WidgetState> values) =>
      values.contains(WidgetState.pressed) ||
      values.contains(WidgetState.hovered) ||
      values.contains(WidgetState.focused);

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final duration = context.motionDuration(_duration);
    return ListenableBuilder(
      listenable: states,
      builder: (context, _) {
        final active = _active(states.value);
        return AnimatedContainer(
          duration: duration,
          width: 40,
          height: 40,
          decoration: ShapeDecoration(
            // Transparent at rest, so the list keeps its usual look; the theme colour only
            // appears for the length of the press.
            color: active ? colorScheme.primaryContainer : const Color(0x00000000),
            shape: AppShape.all(AppCorner.sm),
          ),
          child: Center(
            child: GlyphIcon(glyph, color: active ? colorScheme.onPrimaryContainer : null),
          ),
        );
      },
    );
  }
}
