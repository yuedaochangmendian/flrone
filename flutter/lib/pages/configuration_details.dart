import 'package:flutter/services.dart';
import '../widgets.dart';
import '../components/profile_panel.dart';
import '../components/configuration_card.dart';
import 'configurations.dart';
import 'configuration_editor.dart';
import 'configuration.dart';
import '../components/form.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

class ConfigurationDetailsPage extends ConsumerWidget {
  const ConfigurationDetailsPage({super.key, this.profile});
  final Json? profile;
  @override Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watchBoxState();
    final p = box.remote ? null : profile == null ? box.selectedProfile : box.profiles.where((p) => p['id'] == profile!['id']).firstOrNull;
    if (!box.remote && profile != null && p == null) return const BoxPage(title: 'Edit', children: [EmptyState('Profile no longer exists')]);
    if (p == null) {
      return BoxPage(title: 'Edit', children: [DetailRows({
      'Name': '—', 'Remote control': box.dashboard['remote'] ?? '—',
      'Proxy groups': box.groups.length,
    })]);
    }
    final quota = SubscriptionQuota.of(p);
    return BoxPage(title: 'Edit', actions: [
      IconButtonData(glyph: AppGlyphs.edit, tooltip: context.tr('Edit'), onPressed: () => openForm(context, ConfigurationForm(initial: p))),
      if (p['remote'] == true) IconButtonData(glyph: AppGlyphs.sync, tooltip: context.tr('Update'), onPressed: () => box.profileUpdate(p['id'])),
    ], children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 14, children: [
        EmojiText(p['name'].toString(), style: AppTextStyle.title2.of(context, emphasized: true)),
        ProfileStats(profile: p),
      ])),
      generateSection(items: [
        // The subscription's own figures, read from the host's preformatted
        // `traffic`/`expiry` fields; a segment with nothing behind it is absent.
        if (quota.traffic != null) ListItem(title: Text(context.tr('Remaining')), subtitle: Text(context.tr(quota.traffic!))),
        if (quota.expires != null) ListItem(title: Text(context.tr(quota.expired ? 'Expired' : 'Expires')), subtitle: Text(quota.expires!)),
        if (quota.permanent) ListItem(title: Text(context.tr('Expires')), subtitle: Text(context.tr('Permanent'))),
        if (p['remote'] == true) ListItem(title: Text(context.tr('URL')), subtitle: SelectableText(p['url'].toString()),
          trailing: IconButton(icon: const GlyphIcon(AppGlyphs.copy), tooltip: context.tr('Copy'), onPressed: () => Clipboard.setData(ClipboardData(text: p['url'].toString())))),
        ListItem(title: Text(context.tr('Last updated')), subtitle: Text(
          (p['updatedAt'] as num? ?? 0) <= 0 ? context.tr('Unknown') : localDate(p['updatedAt']))),
        if (p['remote'] == true) ...[
          ListItem(title: Text(context.tr('Auto update')), trailing: Text(context.tr(p['autoUpdate'] == true ? 'Turn on' : 'Turn off'), style: context.listValueStyle)),
          ListItem(title: Text(context.tr('Update interval (minutes)')), trailing: Text(p['interval'].toString(), style: context.listValueStyle)),
        ],
      ]),
      generateSection(items: [
        ListItem.open(leading: const GlyphIcon(AppGlyphs.customize), title: Text(context.tr('Advanced configuration')), widget: ProfileConfigurationPage(profile: p)),
        ListItem.open(leading: const GlyphIcon(AppGlyphs.code), title: Text(context.tr('Open configuration')), widget: ConfigurationEditor(profile: p)),
      ]),
    ]);
  }
}
