import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../widgets.dart';
import '../components/form.dart';
import '../data/profile_document_status.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

const defaultBackupFileName = 'Flrone-backup.json';

// Layout and dialogs adapted from FlClash v0.9.2 backup_and_restore.dart.
class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});
  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  Json? _account;
  Object? _accountError;
  bool _loaded = false, _locked = false, _loading = false, _checking = false;
  bool? _connected;
  String? _connectionError;
  int _generation = 0, _accountRevision = 0;
  // Configuration-document diagnostics. Null until the first forced parse
  // finishes; a failed parse is a visible status, not an exception.
  ProfileDocumentStatus? _docStatus;
  bool _repairing = false;
  // The host's view of the same document (directory, existence, its parser's
  // counts, parse error). Null until the forced parse finishes; shown next to
  // the Dart-side status so a "catalog empty but document OK" report is
  // diagnosable from this page.
  Json? _hostView;
  Object? _hostViewError;

  @override
  void initState() {
    super.initState();
    // Load the document status on the first frame. A post-frame callback keeps
    // the async filesystem parse out of the first build and does not fight the
    // page's entry transition.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadDocumentStatus());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      unawaited(_loadAccount());
    }
  }

  Future<void> _loadDocumentStatus() async {
    final box = ref.read(boxControllerProvider);
    // Backup widget tests inject backupCreateFn but have no document seam and
    // no real data.path/document; loading there would only produce a synthetic
    // "corrupt" status. Production uses the real store (no seam, no creator).
    if (box.profileDocumentStatusFn == null && box.backupCreateFn != null) return;
    try {
      final status = await box.profileDocumentStatus();
      if (mounted) setState(() => _docStatus = status);
    } catch (error) {
      if (mounted) setState(() => _docStatus = ProfileDocumentCorrupt(BoxController.describe(error)));
    }
    // The host view is a second, independent read: a status failure must not
    // hide it, and it is what explains a healthy document with an empty
    // catalog. Widget tests that fake the status are skipped unless they also
    // inject the host seam, so no test observes a synthetic empty view.
    if (box.profileDocumentKotlinViewFn == null && box.profileDocumentStatusFn != null) return;
    try {
      final view = await box.profileDocumentKotlinView();
      if (mounted) {
        setState(() {
          _hostView = view;
          _hostViewError = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _hostViewError = error);
    }
  }

  /// The host view as one sentence: its own counts, or the parser error that
  /// keeps the catalog empty. The directory is a separate row (it is a path,
  /// not a status).
  String _hostViewText() {
    final error = _hostViewError;
    if (error != null) {
      return context
          .tr('unavailable: {message}')
          .replaceAll('{message}', BoxController.describe(error));
    }
    final view = _hostView ?? const <String, dynamic>{};
    final hostError = view['error']?.toString() ?? '';
    if (hostError.isNotEmpty) {
      return context.tr('unavailable: {message}').replaceAll('{message}', hostError);
    }
    final groups = view['groups'];
    final profiles = view['profiles'];
    final text = context.tr('{count} configurations / {nodes} nodes')
        .replaceAll('{count}', groups == null ? '-' : '$groups')
        .replaceAll('{nodes}', profiles == null ? '-' : '$profiles');
    // An empty directory and a missing file are distinct failure modes the
    // counts alone cannot express (0/0 looks the same as "not read").
    if (view['directory'] is String && (view['directory'] as String).isEmpty) {
      return '$text (${context.tr('directory not set')})';
    }
    if (view['exists'] == false) {
      return '$text (${context.tr('profiles.json is missing (not migrated yet)')})';
    }
    return text;
  }

  String _documentStatusText(ProfileDocumentStatus? status) {
    if (status == null) return context.tr('Loading');
    if (status is ProfileDocumentMissing) {
      return context.tr('profiles.json is missing (not migrated yet)');
    }
    if (status is ProfileDocumentCorrupt) {
      return context
          .tr('profiles.json is corrupt: {message}')
          .replaceAll('{message}', status.message);
    }
    final ok = status as ProfileDocumentOk;
    final text = context.tr('{count} configurations / {nodes} nodes')
        .replaceAll('{count}', '${ok.groups}')
        .replaceAll('{nodes}', '${ok.profiles}');
    final bytes = ok.bytes;
    return bytes == null ? text : '$text (${context.tr('{size} bytes').replaceAll('{size}', '$bytes')})';
  }

  Future<void> _repairDocument() async {
    final box = ref.read(boxControllerProvider);
    setState(() => _repairing = true);
    try {
      final approved = await confirm(
        context,
        'Rebuild from Room',
        message: 'A valid document is never overwritten',
        action: 'Rebuild from Room',
      );
      if (!approved || !mounted) return;
      final summary = await box.repairProfileDocument();
      if (mounted) showAppBanner(context, summary);
      await _loadDocumentStatus();
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _repairing = false);
    }
  }

  Future<void> _loadAccount() async {
    final revision = _accountRevision;
    try {
      final value = await ref.read(boxControllerProvider).webdavGet();
      if (mounted && revision == _accountRevision) {
        _updateAccount(value == null ? null : json(value));
      }
    } catch (error) {
      if (mounted && revision == _accountRevision) {
        setState(() => _accountError = error);
      }
    }
  }

  void _updateAccount(Json? value) {
    _accountRevision++;
    final previous = _account;
    setState(() {
      _account = value;
      _accountError = null;
    });
    if (previous == null ||
        value == null ||
        ['uri', 'user', 'password'].any((key) => previous[key] != value[key])) {
      unawaited(_check());
    }
  }

  Future<void> _check() async {
    final generation = ++_generation;
    if (_account == null) {
      setState(() {
        _checking = false;
        _connected = null;
      });
      return;
    }
    setState(() {
      _checking = true;
      _connected = null;
      _connectionError = null;
    });
    try {
      final connected = await ref.read(boxControllerProvider).webdavCheck() == true;
      if (mounted && generation == _generation) {
        setState(() => _connected = connected);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _connected = false;
          _connectionError = BoxController.describe(error);
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _checking = false);
      }
    }
  }

  Future<void> _edit() async {
    if (_locked) return;
    setState(() => _locked = true);
    try {
      final result = await openForm<Json>(
        context,
        WebDAVForm(initial: _account),
      );
      if (mounted && result != null) {
        _updateAccount(result['deleted'] == true ? null : result);
      }
    } finally {
      if (mounted) setState(() => _locked = false);
    }
  }

  Future<void> _fileName(String? value) async {
    if (value == null || _account == null || _locked) return;
    final box = ref.read(boxControllerProvider);
    setState(() => _locked = true);
    try {
      final result = await box.webdavSet({..._account!, 'fileName': value});
      if (mounted) _updateAccount(json(result));
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _locked = false);
    }
  }

  void _showLoading(bool value) {
    if (mounted) setState(() => _loading = value);
  }

  Future<void> _success(String title, String message) =>
      showAppDialog<void>(
        context,
        child: Builder(builder: (dialogContext) => AlertDialog(
          title: dialogContext.tr(title),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(dialogContext.tr('Close')),
            ),
          ],
          child: Text(dialogContext.tr(message)),
        )),
      );

  Future<void> _backup(bool remote) async {
    if (_locked) return;
    final box = ref.read(boxControllerProvider);
    setState(() {
      _locked = true;
      _loading = true;
    });
    try {
      bool saved;
      String? warning;
      if (remote) {
        // `webdavUpload` answers the warning text when the file uploaded but
        // the index did not: a bare "Backup complete" over that half-failure
        // made backups vanish from the restore list silently.
        final uploaded = await box.webdavUpload();
        saved = uploaded == true || uploaded is String;
        if (uploaded is String) warning = uploaded;
      } else {
        final data = await box.backupCreate();
        // The envelope carries the whole container as base64: megabytes of
        // JSON text. Encode it off the UI isolate (FlClash's backupTask
        // pattern) — this was the local-export tap's stall. The helper is
        // top-level on purpose: an Isolate.run closure shares its enclosing
        // scope's Context, and this scope holds the widget State.
        final encoded = await _encodeBackupEnvelopeOffUi(data);
        saved = await box.documentSave(defaultBackupFileName, encoded) == true;
      }
      _showLoading(false);
      if (saved && mounted) {
        await _success('Backup', warning ?? 'Backup complete');
      }
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _locked = false;
        });
      }
    }
  }

  Future<void> _restore(bool remote) async {
    if (_locked || ref.read(boxControllerProvider).remote) return;
    final box = ref.read(boxControllerProvider);
    setState(() {
      _locked = true;
      _loading = true;
    });
    try {
      // Local restore asks the user for a file; WebDAV reads the newest one. A cancelled picker
      // answers null for both, and only the remote read has a "nothing there" meaning to report.
      // ADR 0005 phase 4: the remote read is now a Dart-owned facade method
      // (WebDAV listing/download + THRN decode); the envelope it returns keeps
      // the exact same shape, so the confirmation flow below is unchanged.
      final data = remote
          ? await box.webdavRead()
          : await box.call('backup.open');
      _showLoading(false);
      if (!mounted) return;
      if (data == null) {
        if (remote) await _success('Restore', 'No remote backup found');
        return;
      }
      // The scope narrows what the envelope read brings back.
      final scope = await askRestoreScope(context);
      if (scope == null || !mounted) return;
      await restorePayload(
        context,
        json(data),
        box: ref.read(boxControllerProvider),
        scope: scope,
        onLoading: _showLoading,
      );
      if (!mounted) return;
      // A restore that took the settings moved the WebDAV account under the page.
      if (scope == 'all') await _loadAccount();
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _locked = false;
        });
      }
    }
  }

  Widget _indicator() {
    final label = _checking
        ? 'Checking connection'
        : _connected == true
        ? 'Connected'
        : 'Connection failed';
    return Semantics(
      label: context.tr(label),
      child: Tooltip(
        message: _connectionError ?? context.tr(label),
        child: FadeThroughBox(
          child: _checking
              ? const ActivityIndicator(size: 12)
              : SizedBox.square(
                  dimension: 12,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _connected == true
                          ? context.colorScheme.success
                          : context.colorScheme.error,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final box = ref.watchBoxState();
    final account = _account;
    // The account is a channel payload: read every field through a type check so a
    // partial map renders as an empty string instead of throwing inside build().
    String text(Object? value) => value is String ? value : '';
    return BoxEditGuard(
      dirty: false,
      busy: _locked,
      child: Scaffold(
        title: context.tr('Backup and restore'),
        isLoading: _loading,
        body: AbsorbPointer(
          absorbing: _locked,
          child: ListView(
            // This body opens on a grouped section, so it keeps
            // sectionsTopPadding (the section header brings its own gap);
            // the horizontal gutters and foot match boxPagePadding.
            padding: EdgeInsets.fromLTRB(
              16,
              context.sectionsTopPadding,
              16,
              24 + context.bottomInset,
            ),
            children: [
              generateSection(
                title: context.tr('Remote'),
                items: [
                  if (_accountError != null)
                    ErrorState(_accountError!, retry: _loadAccount)
                  else if (account == null)
                    ListItem(
                      leading: const GlyphIcon(AppGlyphs.account),
                      title: Text(context.tr('No account')),
                      subtitle: Text(context.tr('Bind a WebDAV account')),
                      trailing: TonalButton(
                        label: context.tr('Bind'),
                        onPressed: _locked ? null : _edit,
                      ),
                    )
                  else ...[
                    ListItem(
                      leading: const GlyphIcon(AppGlyphs.account),
                      title: TooltipText(
                        text: Text(
                          text(account['user']).isEmpty
                              ? text(account['uri'])
                              : text(account['user']),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          spacing: 8,
                          children: [
                            Flexible(
                              child: Text(
                                context.tr('Connectivity'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            _indicator(),
                          ],
                        ),
                      ),
                      trailing: TonalButton(
                        label: context.tr('Edit'),
                        onPressed: _locked ? null : _edit,
                      ),
                    ),
                    ListItem.input(
                      title: Text(context.tr('File')),
                      subtitle: Text(text(account['fileName'])),
                      dialogTitle: context.tr('File'),
                      value: text(account['fileName']),
                      resetValue: defaultBackupFileName,
                      maxLength: 128,
                      validator: (value) => backupFileIssue(value) == null
                          ? null
                          : context.tr('Invalid backup file name'),
                      onChanged: _fileName,
                    ),
                    ListItem(
                      key: const ValueKey('remote-backup'),
                      title: Text(context.tr('Backup')),
                      onTap: () => _backup(true),
                    ),
                    ListItem(
                      key: const ValueKey('remote-restore'),
                      title: Text(context.tr('Restore')),
                      onTap: box.remote ? null : () => _restore(true),
                    ),
                  ],
                ],
              ),
              generateSection(
                title: context.tr('Local'),
                items: [
                  ListItem(
                    key: const ValueKey('local-backup'),
                    title: Text(context.tr('Backup')),
                    onTap: () => _backup(false),
                  ),
                  ListItem(
                    key: const ValueKey('local-restore'),
                    title: Text(context.tr('Restore')),
                    onTap: box.remote ? null : () => _restore(false),
                  ),
                ],
              ),
              generateSection(
                title: context.tr('Options'),
                items: [
                  ListItem<String>.options(
                    title: Text(context.tr('Restore strategy')),
                    options: const ['Compatible', 'Override'],
                    value:
                        box.preferences['restoreStrategy'] as String? ??
                        'Compatible',
                    textBuilder: context.tr,
                    onChanged: (value) =>
                        box.setPreference('restoreStrategy', value),
                  ),
                ],
              ),
              // Shown once the first forced parse completes. Keeping it out of
              // the very first frame avoids a layout jump on entry.
              if (_docStatus != null)
                generateSection(
                  title: context.tr('Configuration document'),
                  items: [
                    ListItem(
                      key: const ValueKey('document-status'),
                      leading: const GlyphIcon(AppGlyphs.profiles),
                      title: Text(context.tr('Status')),
                      subtitle: Text(_documentStatusText(_docStatus)),
                    ),
                    if (_hostView != null || _hostViewError != null)
                      ListItem(
                        key: const ValueKey('document-host-view'),
                        leading: const GlyphIcon(AppGlyphs.proxies),
                        title: Text(context.tr('Host view')),
                        subtitle: Text(_hostViewText()),
                      ),
                    if ((_hostView?['directory'] as String? ?? '').isNotEmpty)
                      ListItem(
                        key: const ValueKey('document-directory'),
                        leading: const GlyphIcon(AppGlyphs.profiles),
                        title: Text(context.tr('Directory')),
                        subtitle: Text(_hostView!['directory'] as String),
                      ),
                    ListItem(
                      key: const ValueKey('document-rebuild'),
                      leading: const GlyphIcon(AppGlyphs.refresh),
                      title: Text(context.tr('Rebuild from Room')),
                      subtitle: Text(context.tr('A valid document is never overwritten')),
                      trailing: TonalButton(
                        label: context.tr(_repairing ? 'Rebuilding from Room' : 'Rebuild from Room'),
                        onPressed: _repairing || box.remote ? null : _repairDocument,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Confirms and restores a backup the caller already holds. The page's own two reads, the WebDAV
/// download and a .thrbackup the platform handed us all end here, so the confirmation is worded the
/// same way whichever route brought the envelope in. The strategy is the page's stored preference.
Future<void> restorePayload(
  BuildContext context,
  Json payload, {
  required BoxController box,
  required String scope,
  ValueChanged<bool>? onLoading,
}) async {
  final count = rows(payload['profiles']).length;
  // A backup with no profiles cannot fill a profiles-only restore; saying "Restore 0 profiles?"
  // and then doing nothing is worse than saying so.
  if (count == 0 && scope != 'all') {
    await showAppDialog<void>(
      context,
      child: Builder(builder: (dialogContext) => AlertDialog(
        title: dialogContext.tr('Restore'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(dialogContext.tr('Close')),
          ),
        ],
        child: Text(dialogContext.tr('This backup holds no profiles')),
      )),
    );
    return;
  }
  final strategy =
      box.preferences['restoreStrategy'] as String? ?? 'Compatible';
  final approved = await showAppDialog<bool>(
    context,
    child: _RestoreConfirm(
      count: count,
      scope: scope,
      strategy: strategy,
    ),
  );
  if (approved != true || !context.mounted) return;
  onLoading?.call(true);
  try {
    // A failed restore throws (nothing is half-applied: the profiles document
    // is written first, atomically), so the page's caller reports it.
    await box.backupRestore(payload, scope, strategy);
  } finally {
    onLoading?.call(false);
  }
  if (!context.mounted) return;
  await showAppDialog<void>(
    context,
    child: Builder(builder: (dialogContext) => AlertDialog(
      title: dialogContext.tr('Restore'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(dialogContext.tr('Close')),
        ),
      ],
      child: Text(dialogContext.tr('Restore complete')),
    )),
  );
}

/// A .thrbackup opened from outside: the host read it before it got here, so only the scope is left
/// to ask. A refusal asks nothing further and restores nothing.
Future<void> restoreBackupFile(BuildContext context, Json payload, {required BoxController box}) async {
  final scope = await askRestoreScope(context);
  if (scope == null || !context.mounted) return;
  await restorePayload(context, payload, box: box, scope: scope);
}

/// What the restore is about to replace, before it touches anything.
///
/// Both strategies replace every profile with the backup's set (that is what
/// makes this destructive); they differ only in whether the route tables are
/// replaced too. The old copy promised a "Compatible" merge that the restore
/// has never implemented.
class _RestoreConfirm extends StatelessWidget {
  const _RestoreConfirm({
    required this.count,
    required this.scope,
    required this.strategy,
  });
  final int count;
  final String scope;
  final String strategy;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: context.tr('Restore backup'),
    destructive: true,
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text(context.tr('Cancel')),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, true),
        child: Text(context.tr('Restore')),
      ),
    ],
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Text(
          context
              .tr('Restore {count} profiles?')
              .replaceAll('{count}', '$count'),
        ),
        Text(
          context.tr(
            'All current profiles are replaced by this backup; profiles missing from it will be removed.',
          ),
        ),
        if (scope == 'all')
          Text(
            context.tr(
              'Application settings and remote servers will also be restored.',
            ),
          ),
        Text(
          context.tr(
            strategy == 'Override'
                ? 'Route tables will also be replaced.'
                : 'Route tables are kept. Choose Override to also replace them.',
          ),
        ),
      ],
    ),
  );
}

String? backupFileIssue(String? value) =>
    value == null ||
        value.isEmpty ||
        value.length > 128 ||
        value == '.' ||
        value == '..' ||
        value.runes.any((rune) => rune < 32 || rune == 47 || rune == 92)
    ? 'Invalid backup file name'
    : null;

/// What the restore is about to replace, in Prism's single-choice sheet. The
/// option identifiers and labels are the ones the restore flow and its callers
/// already use; a cancelled or dismissed sheet answers null, as before.
Future<String?> askRestoreScope(BuildContext context) => showOptionSheet<String>(
  context: context,
  title: context.tr('Restore'),
  options: [
    ('profiles', context.tr('Restore profiles only')),
    ('all', context.tr('Restore all data')),
  ],
);

class WebDAVForm extends ConsumerStatefulWidget {
  const WebDAVForm({super.key, this.initial});
  final Json? initial;
  @override
  ConsumerState<WebDAVForm> createState() => _WebDAVFormState();
}

class _WebDAVFormState extends ConsumerState<WebDAVForm> {
  // Same channel-payload caution as the card above: a non-string field used to throw
  // here (as String?) instead of opening the form with an empty box.
  String? _field(String key) {
    final value = widget.initial?[key];
    return value is String ? value : null;
  }

  late final _uri = TextEditingController(text: _field('uri') ?? '');
  late final _user = TextEditingController(text: _field('user') ?? '');
  late final _password = TextEditingController(text: _field('password') ?? '');
  bool _attempted = false, _saving = false;
  String? _error;
  bool get _dirty =>
      _uri.text != (_field('uri') ?? '') ||
      _user.text != (_field('user') ?? '') ||
      _password.text != (_field('password') ?? '');

  @override
  void dispose() {
    _uri.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  void _changed(String _) {
    setState(() => _error = null);
  }

  String? _issue() {
    try {
      final uri = Uri.tryParse(_uri.text.trim());
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          _uri.text.length > 4096) {
        return 'Enter a WebDAV HTTP or HTTPS directory address';
      }
      if (uri.hasPort && (uri.port <= 0 || uri.port > 65535)) {
        return 'Enter a WebDAV HTTP or HTTPS directory address';
      }
    } catch (_) {
      return 'Enter a WebDAV HTTP or HTTPS directory address';
    }
    if (_user.text.length > 4096 || _password.text.length > 4096) {
      return 'Invalid WebDAV credentials';
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving) return;
    final issue = _issue();
    if (issue != null) {
      setState(() => _attempted = true);
      return;
    }
    final box = ref.read(boxControllerProvider);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await box.webdavSet({
        'uri': _uri.text.trim(),
        'user': _user.text,
        'password': _password.text,
        'fileName': widget.initial?['fileName'] ?? defaultBackupFileName,
      });
      if (mounted) context.safeNestedPop(json(result));
    } catch (error) {
      if (mounted) setState(() => _error = BoxController.describe(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    if (_saving) return;
    if (!await confirm(context, 'Delete WebDAV account', action: 'Delete') ||
        !mounted) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(boxControllerProvider).webdavSet(null);
      if (mounted) context.safeNestedPop({'deleted': true});
    } catch (error) {
      if (mounted) setState(() => _error = BoxController.describe(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final issue = _attempted ? _issue() : null;
    return BoxEditGuard(
      dirty: _dirty,
      busy: _saving,
      child: BoxPage(
      title: 'WebDAV configuration',
      confirmationAction: IconButtonData(glyph: AppGlyphs.check, tooltip: context.tr('Save'), isLoading: _saving, onPressed: _saving ? null : _save),
      error: _error ?? (issue == null ? null : context.tr(issue)),
      loading: _saving,
      absorbing: _saving,
      children: [
          generateSection(
            footer: context.tr(
              'Enter the WebDAV directory URL. Backups are stored in a folder on that server.',
            ),
            items: [
              FormRow(
                title: context.tr('Address'),
                invalid:
                    issue == 'Enter a WebDAV HTTP or HTTPS directory address',
                trailing: FormRowTextField(
                  controller: _uri,
                  hintText: context.tr('Required'),
                  keyboardType: TextInputType.text,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  inputFormatters: [LengthLimitingTextInputFormatter(4096)],
                  onChanged: _changed,
                ),
              ),
              FormRow(
                title: context.tr('Account'),
                trailing: FormRowTextField(
                  controller: _user,
                  hintText: context.tr('Optional'),
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  inputFormatters: [LengthLimitingTextInputFormatter(4096)],
                  onChanged: _changed,
                ),
              ),
              FormRow(
                title: context.tr('Password'),
                trailing: FormRowSecretTextField(
                  controller: _password,
                  hintText: context.tr('Optional'),
                  textInputAction: TextInputAction.done,
                  inputFormatters: [LengthLimitingTextInputFormatter(4096)],
                  onChanged: _changed,
                  onFieldSubmitted: (_) => _save(),
                ),
              ),
            ],
          ),
          if (widget.initial != null)
            generateSection(
              items: [
                FormRow(
                  title: context.tr('Delete'),
                  titleStyle: TextStyle(color: context.colorScheme.error),
                  onPressed: _delete,
                ),
              ],
            ),
        ],
    ),
    );
  }
}

// Top-level on purpose: an Isolate.run closure shares its enclosing scope's
// Context — inside the page that Context holds the widget State, which cannot
// cross an isolate boundary. Here the scope is exactly [envelope].
Future<String> _encodeBackupEnvelopeOffUi(Object? envelope) =>
    // The timeout fallback is what widget tests ride (their fake clock cannot
    // complete a real isolate future) and what a wedged isolate degrades to.
    Isolate.run(() => jsonEncode(envelope)).timeout(
      const Duration(seconds: 2),
      onTimeout: () => jsonEncode(envelope),
    );
