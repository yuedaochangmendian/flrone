import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:flrone/ui/icons/icons.dart';
import 'package:flrone/ui/popup.dart';

part 'generated/models.freezed.dart';

@freezed
abstract class IconButtonData with _$IconButtonData {
  const factory IconButtonData({
    required Glyph glyph,
    required VoidCallback? onPressed,
    String? tooltip,
    @Default(false) bool isLoading,

    /// Non-null makes the button a toggle that shows this state.
    bool? isSelected,

    /// Non-null makes the button open these items as a menu.
    List<PopupMenuItem> Function()? menuItems,
  }) = _IconButtonData;
}
