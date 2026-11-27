import 'dart:async';

import 'package:flutter/services.dart';
import '../widgets.dart';
import '../components/profile_panel.dart';
import '../components/configuration_card.dart';
import 'configuration_editor.dart';
import 'configuration.dart';
import '../components/form.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

/// The configuration's own page. Every field the old pencil form edited is
/// editable here: changes save on a short debounce (text) or immediately
/// (switch), so there is no separate edit step or edit button.
class ConfigurationDetailsPage extends ConsumerStatefulWidget {
  const ConfigurationDetailsPage({super.key, this.profile});
  final Json? profile;
  @override
  ConsumerState<ConfigurationDetailsPage> createState() => _ConfigurationDetailsPageState();
}

class _ConfigurationDetailsPageState extends ConsumerState<ConfigurationDetailsPage> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _interval = TextEditingController();

  int _loadedId = 0;
  bool _saving = false;
  bool _savePending = false;
  bool _remote = false;
  bool _auto = false;
  String? _error;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _url.dispose();
    _interval.dispose();
    super.dispose();
  }

  void _load(Json profile) {
    final id = (profile['id'] as num?)?.toInt() ?? 0;
    if (id == _loadedId) return;
    _loadedId = id;
    _remote = profile['remote'] == true;
    _name.text = profile['name']?.toString() ?? '';
    _url.text = profile['url']?.toString() ?? '';
    final interval = (profile['interval'] as num?)?.toInt() ?? 0;
    _interval.text = '${interval > 0 ? interval : 1440}';
    _auto = profile['autoUpdate'] == true;
  }

  ({String? field, String? message})? get _issue {
    if (!_remote && _name.text.trim().isEmpty) {
      return (field: 'name', message: '${context.tr('Name')}: ${context.tr('Required')}');
    }
    if (_remote) {
      final uri = Uri.tryParse(_url.text.trim());
      if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
        return (field: 'url', message: context.tr('sing-box JSON URL'));
      }
      if (_auto && (int.tryParse(_interval.text) ?? 0) < 15) {
        return (field: 'interval', message: context.tr('At least 15 minutes'));
      }
    }
    return null;
  }

  void _changed(String _) {
    setState(() => _error = null);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
    if (!mounted) return;
    // A change that lands while the previous save is in flight must not be
    // dropped: the debounce fires once, sees _saving, and would otherwise
    // return without ever scheduling another attempt.
    if (_saving) {
      _savePending = true;
      return;
    }
    final box = ref.read(boxControllerProvider);
    final p = _profile(box);
    if (p == null) return;
    final issue = _issue;
    if (issue != null) {
      setState(() => _error = issue.message);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final interval = int.tryParse(_interval.text) ?? 1440;
      await box.configurationSave({
        ...p,
        'name': _name.text.trim(),
        'url': _remote ? _url.text.trim() : '',
        'autoUpdate': _remote && _auto,
        'interval': interval >= 15 ? interval : 1440,
      });
    } catch (error) {
      box.report(error);
      if (mounted) setState(() => _error = BoxController.describe(error));
    } finally {
      if (mounted) setState(() => _saving = false);
      if (_savePending && mounted) {
        _savePending = false;
        unawaited(_save());
      }
    }
  }

  Json? _profile(BoxController box) {
    if (box.remote) return null;
    final profile = widget.profile;
    if (profile == null) return box.selectedConfiguration;
    return box.configurations.where((p) => p['id'] == profile['id']).firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final box = ref.watchBoxState();
    final p = _profile(box);
    if (!box.remote && widget.profile != null && p == null) {
      return const BoxPage(title: 'Edit', children: [EmptyState('Profile no longer exists')]);
    }
    if (p == null) {
      return BoxPage(title: 'Edit', children: [DetailRows({
        'Name': '—', 'Remote control': box.dashboard['remote'] ?? '—',
        'Proxy groups': box.groups.length,
      })]);
    }
    _load(p);
    final remote = _remote;
    final quota = SubscriptionQuota.of(p);
    final issue = _issue;
    return BoxPage(
      title: 'Edit',
      loading: _saving,
      error: _error ?? issue?.message,
      actions: [
        if (remote)
          IconButtonData(
            glyph: AppGlyphs.sync,
            tooltip: context.tr('Update'),
            onPressed: () => box.configurationUpdate(p['id']),
          ),
      ],
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 14, children: [
            EmojiText(_name.text.trim().isEmpty ? p['name'].toString() : _name.text.trim(),
                style: AppTextStyle.title2.of(context, emphasized: true)),
            ProfileStats(profile: p),
          ]),
        ),
        generateSection(items: [
          FormRow(title: context.tr('Name'), invalid: issue?.field == 'name',
            trailing: FormRowTextField(controller: _name,
              hintText: context.tr(remote ? 'Optional' : 'Required'),
              textInputAction: TextInputAction.next, onChanged: _changed)),
          if (remote) FormRow(title: context.tr('URL'), invalid: issue?.field == 'url',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: FormRowTextField(controller: _url,
                hintText: context.tr('Required'), keyboardType: TextInputType.text,
                textInputAction: TextInputAction.next, autocorrect: false, onChanged: _changed)),
              IconButton(
                icon: const GlyphIcon(AppGlyphs.copy),
                tooltip: context.tr('Copy'),
                onPressed: () => Clipboard.setData(ClipboardData(text: _url.text)),
              ),
            ])),
          // The subscription's own figures, read from the host's preformatted
          // `traffic`/`expiry` fields; a segment with nothing behind it is absent.
          if (quota.traffic != null) ListItem(title: Text(context.tr('Remaining')), subtitle: Text(context.tr(quota.traffic!))),
          if (quota.expires != null) ListItem(title: Text(context.tr(quota.expired ? 'Expired' : 'Expires')), subtitle: Text(quota.expires!)),
          if (quota.permanent) ListItem(title: Text(context.tr('Expires')), subtitle: Text(context.tr('Permanent'))),
          ListItem(title: Text(context.tr('Last updated')), subtitle: Text(
            (p['updatedAt'] as num? ?? 0) <= 0 ? context.tr('Unknown') : localDate(p['updatedAt']))),
          if (remote) ...[
            FormRow(title: context.tr('Auto update'),
              onPressed: () => setState(() { _auto = !_auto; _changed(''); }),
              trailing: Switch(value: _auto, onChanged: (value) {
                setState(() => _auto = value);
                _changed('');
                _debounce?.cancel();
                _save();
              })),
            if (_auto) FormRow(title: context.tr('Update interval'), invalid: issue?.field == 'interval',
              trailing: Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: [
                Flexible(child: FormRowTextField(controller: _interval,
                  hintText: context.tr('Required'), keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly], onChanged: _changed)),
                Text(context.tr('minutes'), style: AppTextStyle.subheadline.of(context)),
              ])),
          ],
        ]),
        generateSection(items: [
          ListItem.open(leading: const GlyphIcon(AppGlyphs.customize), title: Text(context.tr('Advanced configuration')), widget: ProfileConfigurationPage(profile: p)),
          ListItem.open(leading: const GlyphIcon(AppGlyphs.code), title: Text(context.tr('Open configuration')), widget: ConfigurationEditor(profile: p)),
        ]),
      ],
    );
  }
}
