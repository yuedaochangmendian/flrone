import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../app/l10n.dart';
import '../box.dart';
import '../providers/box_providers.dart';
import '../ui/icons/icons.dart';
import '../ui/list_item.dart';
import '../ui/scaffold/scaffold.dart';

const _backupFileName = 'Flrone-backup.json';

class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  var _busy = false;

  @override
  Widget build(BuildContext context) {
    final box = ref.watch(boxStateProvider);
    final strategy =
        box.preferences['restoreStrategy']?.toString() ?? 'Compatible';
    return Scaffold(
      title: context.tr('Backup and restore'),
      isLoading: _busy,
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          24 + context.bottomInset,
        ),
        children: [
          _Section(
            title: 'Local',
            children: [
              ListItem(
                leading: const GlyphIcon(AppGlyphs.export),
                title: Text('Backup'),
                subtitle: const Text('Save a local .json backup'),
                onTap: _busy ? null : () => _createBackup(local: true),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.importFile),
                title: Text('Restore'),
                subtitle: const Text('Open a local backup file'),
                onTap: _busy || box.remote ? null : _restoreLocal,
              ),
            ],
          ),
          const SizedBox(height: 14),
          _Section(
            title: 'WebDAV',
            children: [
              ListItem(
                leading: const GlyphIcon(AppGlyphs.cloudDownload),
                title: Text('Backup to WebDAV'),
                subtitle: Text(
                  box.webDavAccount.read() == null
                      ? 'Configure a WebDAV account first'
                      : 'Upload the current backup',
                ),
                onTap: _busy || box.webDavAccount.read() == null
                    ? null
                    : () => _createBackup(local: false),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.cloudSync),
                title: Text('Restore from WebDAV'),
                subtitle: const Text('Read the newest remote backup'),
                onTap: _busy || box.remote ? null : _restoreRemote,
              ),
            ],
          ),
          const SizedBox(height: 14),
          _Section(
            title: 'Options',
            children: [
              ListItem<String>.options(
                leading: const GlyphIcon(AppGlyphs.sliders),
                title: Text('Restore strategy'),
                options: const ['Compatible', 'Override'],
                value: strategy,
                textBuilder: (value) => value,
                onChanged: (value) =>
                    box.setPreference('restoreStrategy', value),
              ),
              ListItem(
                leading: const GlyphIcon(AppGlyphs.info),
                title: Text('What is restored'),
                subtitle: const Text(
                  'Profiles are replaced. All-data restore also replaces settings and routes.',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _createBackup({required bool local}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final box = ref.read(boxControllerProvider);
    try {
      if (!local) {
        final uploaded = await box.webdavUpload();
        final ok = uploaded == true || uploaded is String;
        if (mounted) {
          BannerHost.maybeOf(context)
              ?.show(ok ? 'WebDAV backup complete' : 'WebDAV backup failed');
        }
        return;
      }
      final data = await box.backupCreate();
      final encoded = await _encodeOffUi(data);
      final saved = await box.documentSave(_backupFileName, encoded) == true;
      if (mounted) {
        BannerHost.maybeOf(context)
            ?.show(saved ? 'Backup complete' : 'Backup cancelled');
      }
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreLocal() async {
    if (_busy) return;
    final box = ref.read(boxControllerProvider);
    setState(() => _busy = true);
    try {
      final data = await box.call('backup.open');
      if (!mounted) return;
      if (data == null) return;
      await _restorePayload(json(data));
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreRemote() async {
    if (_busy) return;
    final box = ref.read(boxControllerProvider);
    setState(() => _busy = true);
    try {
      final data = await box.webdavRead();
      if (!mounted) return;
      if (data == null) {
        BannerHost.maybeOf(context)?.show('No remote backup found');
        return;
      }
      await _restorePayload(json(data));
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restorePayload(Json payload) async {
    final scope = await showFloatingDialog<String>(
      context: context,
      child: AlertDialog(
        title: 'Restore',
        destructive: true,
        child: const Text(
          'Choose what to replace. Profiles are always replaced.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'profiles'),
            child: const Text('Profiles only'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'all'),
            child: const Text('All data'),
          ),
        ],
      ),
    );
    if (scope == null || !mounted) return;
    final box = ref.read(boxControllerProvider);
    final strategy =
        box.preferences['restoreStrategy']?.toString() ?? 'Compatible';
    try {
      await box.backupRestore(payload, scope, strategy);
      if (mounted) {
        BannerHost.maybeOf(context)?.show('Restore complete');
      }
    } catch (error) {
      box.report(error);
    }
  }
}

Future<String> _encodeOffUi(Object? data) {
  return Isolate.run(() => jsonEncode(data))
      .timeout(const Duration(seconds: 2), onTimeout: () => jsonEncode(data));
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            title,
            style: AppTextStyle.caption1
                .of(context)
                .copyWith(
                  color: context.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: ShapeDecoration(
            color: SurfaceLevel.card.colorOf(context.colorScheme),
            shape: AppShape.all(AppCorner.xl),
          ),
          child: Column(
            children: [
              for (final (index, child) in children.indexed) ...[
                child,
                if (index != children.length - 1) const Divider(height: 1),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
