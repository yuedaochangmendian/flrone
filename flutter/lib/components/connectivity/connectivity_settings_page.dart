import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/box_providers.dart';
import '../../widgets.dart';
import 'connectivity_avatar.dart';
import 'connectivity_store.dart';

/// Connectivity settings, a Riverpod pilot consumer.
///
/// [ConnectivityStore] is the single source of truth for `includeMoreStreaming`
/// and `categories`: the page reads it via `ref.watch` and rebuilds on the
/// store's own notifications, while writes go through the store's mutators.
/// Riverpod is never written back to, so there is no second source of truth.
class ConnectivitySettingsPage extends ConsumerStatefulWidget {
  const ConnectivitySettingsPage({super.key});
  @override ConsumerState<ConnectivitySettingsPage> createState() => _ConnectivitySettingsPageState();
}

class _ConnectivitySettingsPageState extends ConsumerState<ConnectivitySettingsPage> {
  late bool _card;
  late Set<String> _pinned;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final prefs = ref.read(preferencesProvider);
    // `_card` and `_pinned` have no store mirror, so they stay local form state.
    _card = prefs['connectivityCard'] != false;
    _pinned = (prefs['connectivityPinned'] as List?)?.whereType<String>().toSet() ??
        {'openai', 'cloudflare', 'ehentai'};
    // Apply persisted prefs to the store once. From here on the store owns
    // these two fields and the page only reads it.
    final store = ref.read(connectivityStoreProvider);
    store.setIncludeMoreStreaming(prefs['connectivityMoreStreaming'] == true);
    final saved = (prefs['connectivityCategories'] as List?)?.whereType<String>().toSet() ??
        {for (final category in ConnectivityCategory.values) category.name};
    store.setCategories({
      for (final category in ConnectivityCategory.values)
        if (saved.contains(category.name)) category,
    });
  }

  void _save() {
    // Persist through the existing prefs API; read the store-owned values from
    // the provider-held store, never from a duplicated local copy.
    final store = ref.read(connectivityStoreProvider);
    ref.read(boxControllerProvider).setPreferences({
      'connectivityCard': _card,
      'connectivityMoreStreaming': store.includeMoreStreaming,
      'connectivityPinned': _pinned.toList(),
      'connectivityCategories': store.categories.map((category) => category.name).toList(),
    });
  }

  @override
  Widget build(BuildContext context) {
    // Read the single store instance from the provider; rebuilds come from the
    // store's own notifications (AnimatedBuilder), never a Riverpod write.
    final store = ref.watch(connectivityStoreProvider);
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => _buildPage(context, store),
    );
  }

  Widget _buildPage(BuildContext context, ConnectivityStore store) {
    return BoxPage(title: 'Connectivity settings', children: [
      generateSection(title: context.tr('Home card'), items: [
        ListItem.toggle(
          title: Text(context.tr('Show connectivity card on the dashboard')),
          value: _card,
          onChanged: (value) { setState(() => _card = value); _save(); },
        ),
        ListItem.toggle(
          title: Text(context.tr('More streaming platforms')),
          subtitle: Text(context.tr('Also test myTV SUPER, ViuTV, HOY TV and RTHK (Hong Kong)')),
          value: store.includeMoreStreaming,
          onChanged: (value) {
            ref.read(connectivityStoreProvider).setIncludeMoreStreaming(value);
            _save();
          },
        ),
        ListItem(
          title: Text(context.tr('Pinned services')),
          subtitle: Text(context.tr('The first three pinned services appear on the card')),
        ),
        for (final service in connectivityServices)
          ListItem.toggle(
            title: Text(service.name),
            leading: ConnectivityAvatar(service: service, size: 34),
            value: _pinned.contains(service.id),
            onChanged: (value) {
              setState(() => value ? _pinned.add(service.id) : _pinned.remove(service.id));
              _save();
            },
          ),
      ]),
      generateSection(title: context.tr('Categories to test'), items: [
        for (final category in ConnectivityCategory.values)
          ListItem.toggle(
            title: Text(context.tr(_categoryLabel(category))),
            value: store.categories.contains(category),
            onChanged: (value) {
              final categories = {...store.categories};
              if (value) {
                categories.add(category);
              } else {
                categories.remove(category);
              }
              ref.read(connectivityStoreProvider).setCategories(categories);
              _save();
            },
          ),
      ]),
    ]);
  }

  static String _categoryLabel(ConnectivityCategory category) => switch (category) {
    ConnectivityCategory.ai => 'AI',
    ConnectivityCategory.streaming => 'Streaming',
    ConnectivityCategory.china => 'China direct',
    ConnectivityCategory.social => 'Social',
    ConnectivityCategory.developer => 'Developer',
    ConnectivityCategory.gaming => 'Gaming',
    ConnectivityCategory.crypto => 'Crypto',
  };
}
