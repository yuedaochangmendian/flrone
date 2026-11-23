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
        // A 0.5dp hairline separates the near-white icon edge from the near-white
        // page surface in light mode; the shadow stack is gone (surface levels do it).
        DecoratedBox(decoration: ShapeDecoration(
          shape: AppShape.all(AppCorner.lg).copyWith(side: const BorderSide(color: Color(0x14000000), width: 0.5)),
          image: const DecorationImage(image: AssetImage('assets/images/app_icon.webp'), fit: BoxFit.cover),
        ), child: const SizedBox.square(dimension: 96)),
        const SizedBox(height: 20),
        Text('Flrone', style: AppTextStyle.title2.of(context, emphasized: true)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
          _Pill(label: 'v$version', color: colors.primary, foreground: colors.onPrimary),
          _Pill(label: 'GPL-3.0', color: context.raisedSurfaceLevel.colorOf(colors), foreground: colors.onSurfaceVariant),
        ]),
        const SizedBox(height: 16),
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Text(context.tr('A sing-box client with the FlClash Android interface.'),
          textAlign: TextAlign.center, style: AppTextStyle.subheadline.of(context).copyWith(color: colors.onSurfaceVariant, height: 1.5))),
        const SizedBox(height: 20),
        TonalButton(size: TonalButtonSize.bar, glyph: AppGlyphs.sync, label: context.tr('Check for updates'),
          onPressed: _checking || _dialogOpen ? null : _check),
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
        ].where((part) => part.isNotEmpty).join(' '), 'https://github.com/SagerNet/sing-box'),
        _link(AppGlyphs.paintbrush, 'FlClash interface', 'chen08209/FlClash · v0.9.2 · GPL-3.0', 'https://github.com/chen08209/FlClash/tree/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7'),
        // Credit where it is due: B-box's bridge + Flutter-module setup is the migration
        // approach this port follows, so the thanks belongs in the app, not just the README.
        _link(AppGlyphs.star, 'Thanks for the migration approach', 'giturass/B-box', 'https://github.com/giturass/B-box'),
        // Bettbox (FlClash descendant) is the architecture/data-plane reference this
        // port follows (ADR 0002/0004/0006), so the credit belongs here as well.
        _link(AppGlyphs.star, 'Bettbox reference', 'appshubcc/Bettbox', 'https://github.com/appshubcc/Bettbox'),
        ListItem(leading: const _LinkBadge(glyph: AppGlyphs.info), title: Text(context.tr('Open-source licenses')),
          onTap: () => showLicensePage(context: context, applicationName: 'Flrone', applicationVersion: version)),
      ]),
    ]);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color, required this.foreground});
  final String label;
  final Color color, foreground;
  @override Widget build(BuildContext context) => DecoratedBox(decoration: ShapeDecoration(color: color, shape: AppShape.full),
    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Text(label,
      style: AppTextStyle.caption1.of(context, emphasized: true).copyWith(color: foreground))));
}

class _LinkBadge extends StatelessWidget {
  const _LinkBadge({required this.glyph});
  final Glyph glyph;
  @override Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(color: context.raisedSurfaceLevel.colorOf(context.colorScheme), shape: AppShape.md),
    child: SizedBox.square(dimension: 40, child: Center(child: GlyphIcon(glyph, size: 20, color: context.colorScheme.onSurfaceVariant))));
}
