// The WebDAV account's authority (ADR 0005 phase 1).
//
// Before this module the four account fields lived in four Room `settings`
// rows, reached only through the `webdav.get`/`webdav.set` method channels.
// That made Kotlin the writer and Dart a courier. Now the account is one value
// in the `preferences` JSON document — the same document `preferences.set`
// already persists — with Dart as the only writer.
//
// The host performs two compatibility jobs during the transition, neither of
// which is a data authority:
//   * on `ready` it folds a legacy Room account (BboxBackup.webdav(), the
//     reader behind the old `webdav.get`) into the preferences payload when no
//     stored account exists yet, so an upgrade sees the old server/user/secret;
//   * on `preferences.set` it mirrors the `webdavAccount` value back into the
//     four Room rows, because WebDavBackup.configured() (webdav.upload/read)
//     still reads Room until the container codec moves in phase 4.
// Both live in Kotlin; this class only reads and writes the document. Nothing
// here calls a WebDAV channel, and no credentials are sent over `webdav.get`.

import 'webdav_client.dart' show WebDavAccount;

/// The key under which the account lives in the `preferences` document. Grouped
/// as one value so a partial write cannot leave three fields of one account and
/// one of another; `preferences.set` merges by key, and a null removes it.
const webdavAccountKey = 'webdavAccount';

/// The four wire fields, kept identical to the old `webdav.get` answer so the
/// form (`{uri, user, password, fileName}`) and `defaultWebDavCheck` need no
/// changes.
const webdavAccountFields = <String>['uri', 'user', 'password', 'fileName'];

/// Reads one field as a string. A non-string (bad channel value, hand-edited
/// document) becomes an empty string rather than being passed to the host as a
/// dynamic that later throws at the call site.
String _field(WebDavAccount account, String key) {
  final value = account[key];
  return value is String ? value : '';
}

/// Parses the stored value into an account map. `null` means no account; a
/// corrupt value (not a map) is treated the same way, so a bad write cannot
/// present a half-account to the form or the connectivity probe.
WebDavAccount? parseWebDavAccount(Object? raw) {
  if (raw is! Map) return null;
  final map = WebDavAccount.from(raw.map(
    (key, value) => MapEntry<String, dynamic>(key.toString(), value),
  ));
  return <String, dynamic>{
    for (final key in webdavAccountFields) key: _field(map, key),
  };
}

/// Dart-side read/write of the WebDAV account document value.
///
/// [readPreferences] exposes the current `preferences` document (the
/// controller's `preferences` field); [writePreferences] persists a partial
/// update through the existing `preferences.set` channel and returns the merged
/// document. Both are injected so a test can use an in-memory map and so this
/// class has no dependency on `BoxController` or the channel layer.
class WebDavAccountStore {
  WebDavAccountStore({
    required Map<String, dynamic> Function() readPreferences,
    required Future<void> Function(Map<String, dynamic> values) writePreferences,
  })  : _readPreferences = readPreferences,
        _writePreferences = writePreferences;

  final Map<String, dynamic> Function() _readPreferences;
  final Future<void> Function(Map<String, dynamic> values) _writePreferences;

  /// Reads the bound account, or null when none is bound. No caching: the
  /// preferences map is the single copy, and `preferences` events refresh it —
  /// a cached account here would be the stale-overlay bug ADR 0002 warns about.
  WebDavAccount? read() => parseWebDavAccount(_readPreferences()[webdavAccountKey]);

  /// Binds, rebinds or (with null) unbinds the account. Returns the stored
  /// account so callers can hand it straight to the form/UI, matching the old
  /// `webdav.set` answer.
  Future<WebDavAccount?> save(WebDavAccount? value) async {
    if (value == null) {
      await _writePreferences(<String, dynamic>{webdavAccountKey: null});
      return null;
    }
    final stored = <String, dynamic>{
      for (final key in webdavAccountFields) key: _field(value, key),
    };
    await _writePreferences(<String, dynamic>{webdavAccountKey: stored});
    return stored;
  }
}
