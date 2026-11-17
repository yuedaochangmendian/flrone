import 'package:flrone/ui/hct/hct.dart';

import '../widgets.dart';

/// One Bettbox toolbox colour, resolved to a readable tone for the current theme: the
/// light theme darkens the seed to HCT tone 40 and the dark theme lightens it to tone 80.
///
/// The raw Bettbox hexes are designed for the toolbox's tinted icon chips, not for a bare
/// glyph on the app surface; orange at #E58A00 is only 2.64:1 on white and burnt orange is
/// 3.82:1 on the dark surface. Keeping the hue and fixing the tone preserves each entry's
/// identity while the pressed icon stays readable.
class ToolColor {
  const ToolColor(this.seed);

  final int seed;

  Color resolve(Brightness brightness) {
    final base = Hct.fromInt(seed);
    final tone = brightness == Brightness.light ? 40.0 : 80.0;
    return Color(Hct.from(base.hue, base.chroma, tone).toInt());
  }
}

/// Bettbox's toolbox palette: each entry owns one colour, and only its icon wears it.
abstract final class ToolColors {
  static const blue = ToolColor(0xFF2F80ED);
  static const purple = ToolColor(0xFF7B61FF);
  static const teal = ToolColor(0xFF00A3A3);
  static const orange = ToolColor(0xFFE58A00);
  static const green = ToolColor(0xFF3B9C4A);
  static const pink = ToolColor(0xFFD9466F);
  static const blueDeep = ToolColor(0xFF2E7DD7);
  static const burntOrange = ToolColor(0xFFC2571A);
  static const indigo = ToolColor(0xFF5C6BC0);
  static const cyan = ToolColor(0xFF0097D6);
  static const orchid = ToolColor(0xFFAA47BC);

  static const all = <ToolColor>[
    blue,
    purple,
    teal,
    orange,
    green,
    pink,
    blueDeep,
    burntOrange,
    indigo,
    cyan,
    orchid,
  ];
}

/// A toolbox or settings row: the leading icon takes the entry's own colour while the row
/// is pressed, hovered or focused, with no ink ripple, wash or shadow of its own.
///
/// The row owns the tap — `ListItem.open` hands it to an `OpenContainer`, whose recognizer
/// wins the gesture arena before an inner press surface sees a tap-down — so the entry
/// observes its own pointer events (`Listener`/`MouseRegion` do not join the arena) and
/// publishes them to a `WidgetStatesController` the icon listens to. Focus comes through
/// the card's own press surface, on a second controller: sharing the pointer controller
/// would let a scroll's tap-cancel clear the colour while the finger is still down.
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

  /// The entry's colour from [ToolColors], worn by the icon while it is active.
  final ToolColor color;
  final String title;
  final String? subtitle;
  final Widget page;

  @override State<ToolEntry> createState() => _ToolEntryState();
}

class _ToolEntryState extends State<ToolEntry> {
  final _states = WidgetStatesController();
  final _focus = WidgetStatesController();

  @override void dispose() {
    _states.dispose();
    _focus.dispose();
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
            focusStates: _focus,
          ),
          title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: subtitle == null
              ? null
              : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          // Only the icon answers: no row wash, no shadow, no separator change.
          pressTint: const Color(0x00000000),
          statesController: _focus,
          widget: widget.page,
        ),
      ),
    );
  }

  void _set(WidgetState state, bool value) {
    if (mounted) _states.update(state, value);
  }
}

/// A row's leading glyph, taking the entry's own colour while it is pressed, hovered or
/// focused.
///
/// Only the glyph changes: no chip behind it and no row band, so the press reads as the icon
/// lighting up. The 40 dp box keeps the leading column from shifting when it does.
class ToolIcon extends StatelessWidget {
  const ToolIcon({
    super.key,
    required this.glyph,
    required this.color,
    required this.states,
    this.focusStates,
  });

  final Glyph glyph;
  final ToolColor color;
  final WidgetStatesController states;

  /// Focus/disabled states from the row's press surface; pressed is ignored here.
  final WidgetStatesController? focusStates;

  static bool _active(Set<WidgetState> values) =>
      values.contains(WidgetState.pressed) ||
      values.contains(WidgetState.hovered);

  @override
  Widget build(BuildContext context) {
    final listenable = focusStates == null
        ? states
        : Listenable.merge([states, focusStates!]);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final focused = focusStates?.value.contains(WidgetState.focused) ?? false;
        final active = _active(states.value) || focused;
        final resolved = color.resolve(Theme.of(context).brightness);
        // The colour is applied as soon as the pointer goes down and held: no fade, no chip.
        return SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: GlyphIcon(glyph, color: active ? resolved : null),
          ),
        );
      },
    );
  }
}
