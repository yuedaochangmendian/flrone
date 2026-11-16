// A single-choice list in a sheet: what Material's SimpleDialog was used for
// at every call site in this app (a title over a list of options, one popped
// value). Prism has no dialog for that shape — its own vocabulary is a sheet
// with a titled section of rows — so this is that composition, not a new
// widget: showSheet + generateSection + ListItem.open.

import 'package:flutter/widgets.dart';
import 'package:flrone/ui/context.dart';
import 'package:flrone/ui/list.dart';
import 'package:flrone/ui/list_item.dart';
import 'package:flrone/ui/sheet.dart';
import 'package:flrone/ui/selection_mark.dart';
import 'package:flrone/ui/typography.dart';

/// Shows [options] under [title] and answers the picked value, or null.
///
/// Each option is one row; picking it closes the sheet and returns [T]. The
/// sheet is prism's own (bottom sheet on a phone, side sheet elsewhere), so
/// dismissal, drag and the surface come from the same place as every other
/// sheet in the app. [selected] gets the primary check, not a tinted row.
/// [note] explains the choice above the list (a recording floor, a scope).
Future<T?> showOptionSheet<T>({
  required BuildContext context,
  required String title,
  required List<(T, String)> options,
  T? selected,
  String? note,
}) {
  return showSheet<T>(
    context: context,
    builder: (sheetContext) => _OptionSheet<T>(
      title: title,
      options: options,
      selected: selected,
      note: note,
    ),
  );
}

class _OptionSheet<T> extends StatelessWidget {
  const _OptionSheet({required this.title, required this.options, this.selected, this.note});

  final String title;
  final List<(T, String)> options;
  final T? selected;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final note = this.note;
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.fromLTRB(16, context.sectionsTopPadding, 16, 24 + context.bottomInset),
      children: [
        if (note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text(note,
              style: AppTextStyle.footnote.of(context).copyWith(color: context.colorScheme.onSurfaceVariant)),
          ),
        generateSection(
          title: title,
          items: [
            for (final (value, label) in options)
              ListItem(
                title: Text(
                  label,
                  style: value == selected
                      ? AppTextStyle.body.of(context, emphasized: true)
                      : null,
                ),
                trailing: value == selected ? const SelectionCheck() : null,
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ],
    );
  }
}
