import '../../widgets.dart';
import 'connectivity_avatar.dart';
import 'connectivity_store.dart';

class ConnectivitySettingsPage extends StatefulWidget {
  const ConnectivitySettingsPage({super.key});
  @override State<ConnectivitySettingsPage> createState() => _ConnectivitySettingsPageState();
}

class _ConnectivitySettingsPageState extends State<ConnectivitySettingsPage> {
  late bool _card;
  late bool _moreStreaming;
  late Set<String> _pinned;
  late Set<String> _categories;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final prefs = context.box.preferences;
    _card = prefs['connectivityCard'] != false;
    _moreStreaming = prefs['connectivityMoreStreaming'] == true;
    ConnectivityStore.instance.setIncludeMoreStreaming(_moreStreaming);
    _pinned = (prefs['connectivityPinned'] as List?)?.whereType<String>().toSet() ??
        {'openai', 'cloudflare', 'ehentai'};
    _categories = (prefs['connectivityCategories'] as List?)?.whereType<String>().toSet() ??
        {for (final category in ConnectivityCategory.values) category.name};
    ConnectivityStore.instance.setCategories({
      for (final category in ConnectivityCategory.values)
        if (_categories.contains(category.name)) category,
    });
  }

  void _save() {
    context.box.setPreferences({
      'connectivityCard': _card,
      'connectivityMoreStreaming': _moreStreaming,
      'connectivityPinned': _pinned.toList(),
      'connectivityCategories': _categories.toList(),
    });
    ConnectivityStore.instance.setIncludeMoreStreaming(_moreStreaming);
    ConnectivityStore.instance.setCategories({
      for (final category in ConnectivityCategory.values)
        if (_categories.contains(category.name)) category,
    });
  }

  @override
  Widget build(BuildContext context) {
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
          value: _moreStreaming,
          onChanged: (value) { setState(() => _moreStreaming = value); _save(); },
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
            value: _categories.contains(category.name),
            onChanged: (value) {
              setState(() => value ? _categories.add(category.name) : _categories.remove(category.name));
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
