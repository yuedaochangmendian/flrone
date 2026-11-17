import 'package:material_ui/material_ui.dart'
  hide
    AlertDialog,
    Banner,
    ButtonLayerBuilder,
    ButtonStyle,
    ButtonTheme,
    ButtonThemeData,
    Card,
    Checkbox,
    Chip,
    ColorScheme,
    Divider,
    ExpandIcon,
    FilledButton,
    IconButton,
    InputBorder,
    InputDecoration,
    LinearProgressIndicator,
    NavigationBar,
    NavigationDestination,
    OutlinedButton,
    PopupMenuItem,
    Scaffold,
    ScaffoldState,
    Scrollbar,
    SelectableText,
    SelectionArea,
    Slider,
    Switch,
    TabBarView,
    TabController,
    TextButton,
    TextField,
    TextFormField,
    Theme,
    ThemeData,
    ThemeMode;
import 'box.dart';
import 'l10n.dart';
import 'ui/ui.dart';
import 'ui/icons/icons.dart';

// Prism's widgets take the names Material uses for the same ideas; ours are the
// prism ones, so Material's are hidden here rather than shadowing them.
export 'package:material_ui/material_ui.dart'
  hide
    AlertDialog,
    Banner,
    ButtonLayerBuilder,
    ButtonStyle,
    ButtonTheme,
    ButtonThemeData,
    Card,
    Checkbox,
    Chip,
    ColorScheme,
    Divider,
    ExpandIcon,
    FilledButton,
    IconButton,
    InputBorder,
    InputDecoration,
    LinearProgressIndicator,
    NavigationBar,
    NavigationDestination,
    OutlinedButton,
    PopupMenuItem,
    Scaffold,
    ScaffoldState,
    Scrollbar,
    SelectableText,
    SelectionArea,
    Slider,
    Switch,
    TabBarView,
    TabController,
    TextButton,
    TextField,
    TextFormField,
    Theme,
    ThemeData,
    ThemeMode;
export 'box.dart';
export 'l10n.dart';
export 'components/option_sheet.dart';
export 'components/settings_controls.dart';
export 'pages/settings_pages.dart';
export 'pages/route_fragment_page.dart';
export 'pages/route_profile_editor_page.dart';
export 'pages/route_rule_editor_page.dart';
export 'pages/route_import_page.dart';
export 'pages/route_texts.dart';
export 'pages/rule_import.dart';
export 'pages/auto_selector.dart';
export 'pages/speed_test.dart';
export 'pages/node_tuning.dart';
export 'ui/ui.dart';
export 'ui/icons/icons.dart';

class BoxMenu extends StatelessWidget {
  const BoxMenu({super.key, required this.items});
  final List<PopupMenuItem> items;
  @override Widget build(BuildContext context) => PopupAnchor(
    targetBuilder: (open) => IconButton(tooltip: context.tr('More'), onPressed: open, icon: const GlyphIcon(AppGlyphs.more)),
    popupBuilder: (_) => PopupMenu(items: items),
  );
}

/// The ordinary page's gutters and its clearance above and below the chrome.
EdgeInsets boxPagePadding(BuildContext context) => EdgeInsets.fromLTRB(
  16, context.contentTopPadding, 16, 24 + context.bottomInset,
);

/// The one page shell: title bar, optional validation line, and a scrolling
/// body. Forms, settings screens and plain lists all use it.
class BoxPage extends StatelessWidget {
  const BoxPage({super.key, required this.title, required this.children, this.actions = const [], this.menuItems = const [], this.primaryAction, this.confirmationAction, this.loading = false, this.error, this.absorbing = false});
  final String title;
  final List<Widget> children;
  final List<IconButtonData> actions;
  final List<PopupMenuItem> menuItems;
  final IconButtonData? primaryAction, confirmationAction;
  final bool loading;

  /// A validation or save failure shown above the body. Kept at a stable index
  /// so the children below it keep their state when the message appears.
  final String? error;

  /// Blocks interaction with the body without unmounting it (a form saving in
  /// the background keeps its scroll position and focus).
  final bool absorbing;

  @override
  Widget build(BuildContext context) => Scaffold(
    title: context.tr(title),
    iconActions: actions,
    menuItems: menuItems,
    primaryAction: primaryAction,
    confirmationAction: confirmationAction,
    isLoading: loading,
    body: AbsorbPointer(
      absorbing: absorbing,
      child: ListView(
        padding: boxPagePadding(context),
        children: [
          if (error != null)
            Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(error!, style: context.listCaptionStyle.copyWith(color: context.colorScheme.error)))
          else
            const SizedBox.shrink(),
          ...children,
        ],
      ),
    ),
  );
}

/// Opens an app alert on Prism's floating-surface route, preserving its result.
Future<T?> showAppDialog<T>(
  BuildContext context, {
  required Widget child,
  bool dismissible = true,
}) => showFloatingDialog<T>(context: context, dismissible: dismissible, child: child);

/// The app's transient message, as prism layers it over the page.
void showAppBanner(BuildContext context, String text, {BannerLevel level = BannerLevel.info}) =>
  BannerHost.maybeOf(context)?.show(text, level: level);

Future<T?> openPage<T>(BuildContext context, Widget page) => showExtend<T>(context, builder: (_) => page);
Future<T?> openForm<T>(BuildContext context, Widget page) => showFormSheet<T>(context: context, builder: (_) => page);

/// Applies the same edit guard to system back, sheet close and sheet dismissal.
class BoxEditGuard extends StatefulWidget {
  const BoxEditGuard({super.key, required this.dirty, required this.child, this.busy = false});
  final bool dirty, busy;
  final Widget child;
  @override State<BoxEditGuard> createState() => _BoxEditGuardState();
}

class _BoxEditGuardState extends State<BoxEditGuard> {
  ValueNotifier<SheetDismissHandler?>? _dismissHandler;
  SheetDismissHandler? _previousHandler;
  bool _confirming = false;

  @override void didChangeDependencies() {
    super.didChangeDependencies();
    final handler = SheetDismissScope.of(context);
    if (identical(handler, _dismissHandler)) return;
    _release();
    _dismissHandler = handler;
    _previousHandler = handler?.value;
    if (handler != null) handler.value = _dismiss;
  }

  void _release() {
    if (_dismissHandler?.value == _dismiss) _dismissHandler!.value = _previousHandler;
    _dismissHandler = null;
    _previousHandler = null;
  }
  @override void dispose() { _release(); super.dispose(); }

  Future<bool> _canLeave(BuildContext context) async {
    if (widget.busy || _confirming) return false;
    if (!widget.dirty) return true;
    _confirming = true;
    try {
      final discard = await confirm(context, 'Discard changes?', action: 'Discard');
      return mounted && discard && !widget.busy;
    } finally { _confirming = false; }
  }

  Future<void> _dismiss() async {
    if (await _canLeave(context) && mounted) context.safeNestedPop();
  }

  @override Widget build(BuildContext context) {
    final guarded = PopGuard(onPop: widget.dirty || widget.busy ? _canLeave : null, child: widget.child);
    return SheetProvider.of(context)?.copyWith(onClose: _dismiss, child: guarded) ?? guarded;
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState(this.title, {super.key, this.message, this.action, this.glyph = AppGlyphs.info});
  final String title;
  final String? message;
  final Widget? action;
  final Glyph glyph;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      GlyphIcon(glyph, size: 56, color: context.colorScheme.onSurfaceVariant),
      const SizedBox(height: 20),
      Text(context.tr(title), style: AppTextStyle.title3.of(context), textAlign: TextAlign.center),
      if (message != null) Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(context.tr(message!), textAlign: TextAlign.center, style: context.listSubtitleStyle),
      ),
      if (action != null) Padding(padding: const EdgeInsets.only(top: 16), child: action),
    ]),
  );
}

class ErrorState extends StatelessWidget {
  const ErrorState(this.error, {super.key, this.retry});
  final Object error;
  final VoidCallback? retry;
  @override
  Widget build(BuildContext context) => EmptyState(
    'Error',
    message: BoxController.describe(error),
    action: retry == null ? null : FilledButton(onPressed: retry, child: Text(context.tr('Retry'))),
  );
}

Future<bool> confirm(BuildContext context, String title, {String? message, String action = 'Delete'}) async {
  // The alert's own context is the one its navigator can pop.
  final result = await showFloatingDialog<bool>(
    context: context,
    child: Builder(builder: (context) => AlertDialog(
      title: context.tr(title),
      child: message == null ? null : Text(context.tr(message)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr('Cancel'))),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text(context.tr(action))),
      ],
    )),
  );
  return result ?? false;
}

class DetailRows extends StatelessWidget {
  const DetailRows(this.values, {super.key});
  final Map<String, dynamic> values;
  @override
  Widget build(BuildContext context) => generateGroup([
    for (final item in values.entries)
      ListItem(title: Text(context.tr(item.key)), subtitle: SelectableText(item.value?.toString() ?? '—')),
  ]);
}

/// A full-width content panel, one lightness step above its parent surface.
///
/// The alert radius belongs to dialogs, not ordinary cards. [BoxPanel] uses
/// the full-width `xl` token by default; a medium card can opt into `lg`.
///
/// A tappable panel shows its press on the title icon alone ([PressTintIcon]): the card
/// paints no wash or band, so the press reads as the icon taking the theme colour.
class BoxPanel extends StatefulWidget {
  const BoxPanel({super.key, required this.child, this.onTap, this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 18), this.radius = AppCorner.xl, this.clipBehavior = Clip.antiAlias});
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Clip clipBehavior;
  @override State<BoxPanel> createState() => _BoxPanelState();
}

class _BoxPanelState extends State<BoxPanel> {
  final _states = WidgetStatesController();

  @override void dispose() {
    _states.dispose();
    super.dispose();
  }

  @override Widget build(BuildContext context) {
    final level = context.raisedSurfaceLevel;
    final surface = level.colorOf(context.colorScheme);
    final inset = widget.padding is EdgeInsets ? widget.padding as EdgeInsets : const EdgeInsets.symmetric(horizontal: 20, vertical: 18);
    final onTap = widget.onTap;
    if (onTap == null) {
      return Surface(
        color: surface,
        shape: AppShape.all(widget.radius),
        clipBehavior: widget.clipBehavior,
        child: Padding(padding: widget.padding, child: SurfaceScope(level: level, child: widget.child)),
      );
    }
    // A raw pointer listener colours the icon on pointer-down. The card's own press surface
    // deliberately waits 150 ms inside a scroll view (the iOS scroll-hold rule), which is far
    // too long for "the icon lights up when I touch the card".
    return Listener(
      onPointerDown: (_) => _states.update(WidgetState.pressed, true),
      onPointerUp: (_) => _states.update(WidgetState.pressed, false),
      onPointerCancel: (_) => _states.update(WidgetState.pressed, false),
      child: Card(
        onPressed: onTap,
        radius: widget.radius,
        padding: inset,
        // No card-wide wash or band: the title icon carries the press feedback. The card
        // keeps its own state private — sharing the controller let a scroll's tap-cancel
        // clear the icon's colour while the finger was still down.
        pressTint: const Color(0x00000000),
        child: PressTintScope(states: _states, child: widget.child),
      ),
    );
  }
}

/// Publishes a card's press states to the widgets inside it, so a title icon can react
/// without a press surface of its own competing for the tap.
class PressTintScope extends InheritedWidget {
  const PressTintScope({super.key, required this.states, required super.child});
  final WidgetStatesController states;
  static WidgetStatesController? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PressTintScope>()?.states;
  @override bool updateShouldNotify(PressTintScope oldWidget) => states != oldWidget.states;
}

/// A panel title's glyph: the theme colour while the card is pressed, the muted colour otherwise.
class PressTintIcon extends StatelessWidget {
  const PressTintIcon(this.glyph, {super.key, this.size = 18});
  final Glyph glyph;
  final double size;

  static bool _active(Set<WidgetState> values) =>
      values.contains(WidgetState.pressed) ||
      values.contains(WidgetState.hovered) ||
      values.contains(WidgetState.focused);

  @override Widget build(BuildContext context) {
    final idle = context.colorScheme.onSurfaceVariant;
    final states = PressTintScope.of(context);
    if (states == null) return GlyphIcon(glyph, size: size, color: idle);
    return ListenableBuilder(
      listenable: states,
      builder: (context, _) => GlyphIcon(
        glyph,
        size: size,
        color: _active(states.value) ? context.colorScheme.primary : idle,
      ),
    );
  }
}

class PanelTitle extends StatelessWidget {
  const PanelTitle(this.title, this.glyph, {super.key, this.trailing});
  final String title;
  final Glyph glyph;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => SizedBox(height: 26 * MediaQuery.textScalerOf(context).scale(1), child: Row(children: [
    PressTintIcon(glyph),
    const SizedBox(width: 8),
    Expanded(child: Text(context.tr(title), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyle.subheadline.of(context, emphasized: true))),
    ?trailing,
  ]));
}

String localDate(dynamic value) {
  final ms = (value as num?)?.toInt() ?? 0;
  if (ms <= 0) return '—';
  // libbox connection timestamps are milliseconds; do not infer fabricated ages.
  return DateTime.fromMillisecondsSinceEpoch(ms).toLocal().toString().split('.').first;
}