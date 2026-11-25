import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets.dart';
import '../providers/box_providers.dart';

// Hero and link badges adapted from FlClash v0.9.2 views/about.dart.
const repositoryUrl = 'https://github.com/yuedaochangmendian/throne-flclash-ui';

/// The release dialog a manual check opens. The dashboard's cached update badge
/// reuses the same flow, so both paths offer the same notes and download link.
Future<void> showUpdateDialog(BuildContext context, BoxController box, Json result) =>
  showAppDialog<void>(context, child: Builder(builder: (dialogContext) => AlertDialog(
    title: dialogContext.tr(result['available'] == true ? 'Update available' : 'Check for updates'),
    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, spacing: 12, children: [
        Text(result['available'] == true ? 'Flrone ${result['version']}' : dialogContext.tr(result['hasMetadata'] == false ? 'No release metadata available' : 'You are up to date')),
        if (result['available'] == true && result['notes'] is String && (result['notes'] as String).isNotEmpty) SelectableText(result['notes'] as String),
      ],
    ))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(dialogContext.tr('Close'))),
      if (result['available'] == true || result['hasMetadata'] == false) TextButton(onPressed: () {
        Navigator.pop(dialogContext);
        box.openUrl(result['downloadUrl'] ?? result['url'] ?? '$repositoryUrl/releases');
      }, child: Text(dialogContext.tr(result['downloadUrl'] == null ? 'Releases' : 'Download'))),
    ],
  )));

class AboutPage extends ConsumerStatefulWidget {
  const AboutPage({super.key});
  @override ConsumerState<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends ConsumerState<AboutPage> {
  bool _checking = false;
  bool _dialogOpen = false;

  Future<void> _check() async {
    if (_checking || _dialogOpen) return;
    final box = ref.read(boxControllerProvider);
    setState(() => _checking = true);
    try {
      final result = json(await box.updatesCheck());
      if (!mounted) return;
      // Release the page's loading state for the dialog (the loading overlay
      // would animate behind it forever) but keep the button locked with
      // `_dialogOpen`: releasing it here let a second check stack another
      // dialog on top of the first.
      setState(() { _checking = false; _dialogOpen = true; });
      await showUpdateDialog(context, box, result);
    } catch (error) { box.report(error); }
    finally { if (mounted) setState(() { _checking = false; _dialogOpen = false; }); }
  }

  Widget _link(Glyph glyph, String title, String label, String url) => ListItem(
    leading: _LinkBadge(glyph: glyph), title: Text(context.tr(title)),
    subtitle: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: const GlyphIcon(AppGlyphs.openExternal),
    onTap: () => ref.read(boxControllerProvider).openUrl(url),
  );

  @override Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final version = ref.watch(versionProvider), coreVersion = ref.watch(coreVersionProvider), coreRefShort = ref.watch(coreRefShortProvider);
    return BoxPage(title: 'About', loading: _checking, children: [
      Column(children: [
        // The launcher's own artwork: the watercolour range the app icon is cut from.
        // A 0.5dp hairline separates the icon edge from the page surface; it rides
        // the theme's outline so it stays visible in both light and dark mode.
        DecoratedBox(decoration: ShapeDecoration(
          shape: AppShape.all(AppCorner.lg).copyWith(side: BorderSide(color: colors.outline.withValues(alpha: 0.08), width: 0.5)),
          image: const DecorationImage(image: AssetImage('assets/images/app_icon.webp'), fit: BoxFit.cover),
        ), child: const SizedBox.square(dimension: 96)),
        const SizedBox(height: 20),
        Text('Flrone', style: AppTextStyle.title2.of(context, emphasized: true)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
          // The version badge is the update entry; the licence badge opens the
          // licence page. The separate button and "Open-source licenses" row
          // are gone.
          _Pill(label: 'v$version', color: colors.primary, foreground: colors.onPrimary,
            onPressed: _checking || _dialogOpen ? null : _check),
          _Pill(label: 'GPL-3.0', color: context.raisedSurfaceLevel.colorOf(colors), foreground: colors.onSurfaceVariant,
            onPressed: () => showLicensePage(context: context, applicationName: 'Flrone', applicationVersion: version)),
        ]),
        const SizedBox(height: 16),
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Text(context.tr('A sing-box client with the FlClash Android interface.'),
          textAlign: TextAlign.center, style: AppTextStyle.subheadline.of(context).copyWith(color: colors.onSurfaceVariant, height: 1.5))),
      ]),
      const SizedBox(height: 8),
      generateSection(title: context.tr('More'), items: [
        _link(AppGlyphs.code, 'Source code', 'yuedaochangmendian/throne-flclash-ui', repositoryUrl),
        // The core reports its own injected version; the short ref says which upstream commit
        // the AAR was built from, which is what a bug report needs when a pin moves.
        _link(AppGlyphs.cpu, 'Core', [
          'sing-box',
          coreVersion,
          if (coreRefShort.isNotEmpty) '($coreRefShort)',
        ].where((part) => part.isNotEmpty).join(' '), 'https://github.com/yuedaochangmendian/sing-box-ext'),
        // The interface follows the v0.9.3/0.9.4 surface (see components/configuration_card.dart);
        // no exact 0.9.4 commit is pinned here, so link to the repo rather than a stale ref.
        _link(AppGlyphs.paintbrush, 'FlClash interface', 'chen08209/FlClash · v0.9.4 · GPL-3.0', 'https://github.com/chen08209/FlClash'),
        // Credit where it is due: B-box's bridge + Flutter-module setup is the early
        // migration approach this port follows; Bettbox is the detailed feature reference.
        _link(AppGlyphs.star, 'B-box: early migration approach', 'giturass/B-box', 'https://github.com/giturass/B-box'),
        _link(AppGlyphs.star, 'Bettbox: detailed feature reference', 'appshubcc/Bettbox', 'https://github.com/appshubcc/Bettbox'),
      ]),
    ]);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color, required this.foreground, this.onPressed});
  final String label;
  final Color color, foreground;
  final VoidCallback? onPressed;
  @override Widget build(BuildContext context) => PressSurface(
    fill: color,
    shape: AppShape.full,
    foreground: foreground,
    onPressed: onPressed,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: Text(label,
      style: AppTextStyle.caption1.of(context, emphasized: true).copyWith(color: foreground)),
  );
}

class _LinkBadge extends StatelessWidget {
  const _LinkBadge({required this.glyph});
  final Glyph glyph;
  @override Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(color: context.raisedSurfaceLevel.colorOf(context.colorScheme), shape: AppShape.md),
    child: SizedBox.square(dimension: 40, child: Center(child: GlyphIcon(glyph, size: 20, color: context.colorScheme.onSurfaceVariant))));
}
