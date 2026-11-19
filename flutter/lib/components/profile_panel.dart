import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';
import '../widgets.dart';
import '../pages/profiles.dart';
import '../pages/profile_details.dart';
import 'profile_card.dart';

class ProfilePanel extends ConsumerStatefulWidget {
  const ProfilePanel({super.key});
  @override ConsumerState<ProfilePanel> createState() => _ProfilePanelState();
}
class _ProfilePanelState extends ConsumerState<ProfilePanel> {
  bool _updating = false;
  @override Widget build(BuildContext context) {
    // Mixed read/write: all reads go through the narrow providers; the one
    // write (profileUpdate) still goes through the controller.
    final box = ref.read(boxControllerProvider);
    final remote = ref.watch(remoteProvider);
    final profile = remote ? null : ref.watch(selectedProfileProvider);
    final name = remote ? context.tr('Remote configuration') : profile?['name'];
    final profiles = ref.watch(profilesProvider);
    final transitioning = ref.watch(transitioningProvider);
    final label = AppTextStyle.caption1.of(context).copyWith(color: context.colorScheme.onSurfaceVariant);
    return BoxPanel(onTap: () => remote ? openForm(context, const ProfileDetailsPage()) : profile == null
      ? openForm(context, const AddProfilePage()) : openForm(context, ProfileDetailsPage(profile: profile)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PanelTitle('Profile', AppGlyphs.profiles, trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (profile?['remote'] == true) SizedBox.square(dimension: 26, child: _updating ? const Center(child: ActivityIndicator(size: 18)) : IconButton(
            padding: EdgeInsets.zero, tooltip: context.tr('Update'), icon: const GlyphIcon(AppGlyphs.sync, size: 18), onPressed: () async {
              setState(() => _updating = true);
              await box.profileUpdate(profile!['id']);
              if (mounted) setState(() => _updating = false);
            })),
          const GlyphIcon(AppGlyphs.chevronForward, size: 18),
        ])),
        const SizedBox(height: 12),
        Row(children: [
          Flexible(child: EmojiText(name?.toString() ?? context.tr('Add profile'), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyle.headline.of(context, emphasized: true))),
          if (!remote && profiles.length > 1) SizedBox.square(dimension: 32, child: IconButton(padding: EdgeInsets.zero,
            tooltip: context.tr('Switch profile'), icon: const GlyphIcon(AppGlyphs.swap, size: 18),
            onPressed: transitioning ? null : () => openForm(context, const ProfilesPage(picker: true)))),
        ]),
        if (profile != null || remote) ...[
          Row(spacing: 12, children: [
            Expanded(child: profile == null ? const SizedBox.shrink() : ProfileUpdateTime(
              milliseconds: (profile['updatedAt'] as num?)?.toInt(), style: label, showLabel: true)),
            Text(context.tr(remote || profile?['remote'] == true ? 'Remote' : 'Local'), style: label),
          ]),
          const SizedBox(height: 14),
          ProfileStats(profile: profile),
        ],
      ]),
    );
  }
}

class ProfileStats extends ConsumerWidget {
  const ProfileStats({super.key, this.profile});
  final Json? profile;
  @override Widget build(BuildContext context, WidgetRef ref) => FutureBuilder<Json>(
    future: profile == null ? null : ref.read(boxControllerProvider).profileStats((profile!['id'] as num).toInt()),
    builder: (context, snapshot) {
      final figure = AppTextStyle.title3.of(context, emphasized: true).toTabular.copyWith(letterSpacing: 0);
      final label = AppTextStyle.caption1.of(context).copyWith(color: context.colorScheme.onSurfaceVariant);
      return LayoutBuilder(builder: (context, constraints) => FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerStart,
        child: ConstrainedBox(constraints: BoxConstraints(minWidth: constraints.maxWidth), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, spacing: 16, children: [
          for (final (key, name) in [('groups', 'Proxy groups'), ('outbounds', 'Outbounds'), ('rules', 'Routing rules')])
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (snapshot.connectionState == ConnectionState.waiting) SkeletonText(width: 34, style: figure)
              else Text(snapshot.data?[key]?.toString() ?? '—', maxLines: 1, style: figure),
              Text(context.tr(name), maxLines: 1, style: label),
            ]),
        ])),
      ));
    },
  );
}
