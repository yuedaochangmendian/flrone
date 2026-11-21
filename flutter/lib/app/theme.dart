import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

const _seed = Color(0xFF4C8DFF);

ThemeData appTheme(Brightness brightness, {Color? seed}) {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: seed ?? _seed,
      brightness: brightness,
    ),
    fontFamily: null,
  );
}
