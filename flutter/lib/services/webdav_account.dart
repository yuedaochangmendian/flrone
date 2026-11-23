// The WebDAV account's authority (ADR 0005 phase 1), plus its password at rest (S10).
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
//
// At rest (S10) the password is sealed by the Android Keystore: the document
// value is `enc:v1:<base64(nonce||ciphertext)>` (see
// `app/src/main/java/io/flrone/bridge/SecureBox.kt`) and the plaintext exists
// only in memory. The form, the account map shape and the `webdav.*` answers do
// not change — [WebDavAccountStore.read] opens the envelope and [save] seals a
// fresh password, so every caller sees the same `{uri, user, password, fileName}`.
//
// Migration is lazy on purpose: a legacy plaintext account is read as-is (no
// write during a pure read) and becomes ciphertext the next time it is saved.
// A document written by an older build therefore keeps working, and no read
// path can fail because a write failed.

import 'package:flutter/services.dart';

import 'webdav_client.dart' show WebDavAccount;

/// The key under which the account lives in the `preferences` document. Grouped
/// as one value so a partial write cannot leave three fields of one account and
/// one of another; `preferences.set` merges by key, and a null removes it.
const webdavAccountKey = 'webdavAccount';

/// The four wire fields, kept identical to the old `webdav.get` answer so the
/// form (`{uri, user, password, fileName}`) and `defaultWebDavCheck` need no
/// changes. `password` is the one field that may be an envelope on disk.
const webdavAccountFields = <String>['uri', 'user', 'password', 'fileName'];

/// The host channel that seals and opens the password (S10). Its name also sits
/// in `tools/diagnostics/aar_channels.txt`; keep the two in step.
const secureChannelName = 'io.flrone/secure';

/// The envelope prefix this build writes. Mirrors `EnvelopeCodec.PREFIX` in
/// `SecureBox.kt`: a token with any other prefix is not this build's ciphertext.
const sealedPasswordPrefix = 'enc:v1:';

const MethodChannel _secureChannel = MethodChannel(secureChannelName);

/// True when [value] is already an envelope, i.e. there is nothing left to seal.
bool isSealedPassword(String value) => value.startsWith(sealedPasswordPrefix);

/// The password could not be sealed, so it must not be stored. Deliberately an
/// answer the form can show: the alternative — falling back to plaintext —
/// would defeat the point of the envelope.
class WebDavSecretException implements Exception {
  const WebDavSecretException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Seals [plaintext] with the device key. Throws [WebDavSecretException] when
/// the channel is absent (a desktop/test build) or the host refused the value:
/// a save must fail loudly rather than write a password in the clear.
Future<String> sealWithPlatformKeystore(String plaintext) async {
  final Object? token;
  try {
    token = await _secureChannel.invokeMethod<Object?>(
      'seal',
      <String, Object?>{'value': plaintext},
    );
  } on MissingPluginException {
    throw const WebDavSecretException(
      'Secure storage is not available on this platform, so the WebDAV password was not saved.',
    );
  } on PlatformException catch (error) {
    throw WebDavSecretException(
      'The secure store refused the WebDAV password: ${error.message ?? error.code}',
    );
  }
  if (token is! String || !isSealedPassword(token)) {
    throw const WebDavSecretException(
      'The secure store answered without an envelope, so the WebDAV password was not saved.',
    );
  }
  return token;
}

/// Opens [token]; null when the device cannot (a Keystore reset, a reinstall, a
/// token from another install). Never throws: an undecryptable password is an
/// answer the caller reports, not a crash on a page open.
Future<String?> openWithPlatformKeystore(String token) async {
  try {
    return await _secureChannel.invokeMethod<String>(
      'open',
      <String, Object?>{'value': token},
    );
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// Reads one field as a string. A non-string (bad channel value, hand-edited
/// document) becomes an empty string rather than being passed to the host as a
/// dynamic that later throws at the call site.
String _field(WebDavAccount account, String key) {
  final value = account[key];
  return value is String ? value : '';
}

/// Parses the stored value into an account map. `null` means no account; a
/// corrupt value (not a map) is treated the same way, so a bad write cannot
/// present a half-account to the form or the connectivity probe. The password
/// is returned exactly as stored — [WebDavAccountStore.read] opens the envelope.
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
/// document. [seal] and [open] are the device key, injected so a test (and any
/// host-less caller) can use an in-memory stand-in. All four are injected so
/// this class has no dependency on `BoxController` or the channel layer.
class WebDavAccountStore {
  WebDavAccountStore({
    required Map<String, dynamic> Function() readPreferences,
    required Future<void> Function(Map<String, dynamic> values) writePreferences,
    Future<String> Function(String plaintext)? seal,
    Future<String?> Function(String token)? open,
  })  : _readPreferences = readPreferences,
        _writePreferences = writePreferences,
        _seal = seal ?? sealWithPlatformKeystore,
        _open = open ?? openWithPlatformKeystore;

  final Map<String, dynamic> Function() _readPreferences;
  final Future<void> Function(Map<String, dynamic> values) _writePreferences;
  final Future<String> Function(String plaintext) _seal;
  final Future<String?> Function(String token) _open;

  /// Why the last [read] returned an empty password, or null when it did not.
  /// Set only for a stored envelope this device cannot open — never for a
  /// missing account, and never carrying the secret. The connectivity check
  /// reports it, which is where a failed password first costs the user.
  String? lastDiagnostic;

  /// Reads the bound account, or null when none is bound. No caching: the
  /// preferences map is the single copy, and `preferences` events refresh it —
  /// a cached account here would be the stale-overlay bug ADR 0002 warns about.
  ///
  /// A stored envelope is opened here. A legacy plaintext password is returned
  /// as-is (an upgrade keeps working, no write on a read); the next [save]
  /// seals it. When the envelope cannot be opened the account is still returned
  /// — with an empty password and [lastDiagnostic] set — so the URI and user
  /// stay visible and the form can ask for the secret again.
  Future<WebDavAccount?> read() async {
    lastDiagnostic = null;
    final account = parseWebDavAccount(_readPreferences()[webdavAccountKey]);
    if (account == null) return null;
    final password = account['password']!;
    if (!isSealedPassword(password)) return account;
    final plaintext = await _open(password);
    if (plaintext == null) {
      lastDiagnostic =
          'The stored WebDAV password cannot be decrypted on this device; enter it again.';
      return <String, dynamic>{...account, 'password': ''};
    }
    return <String, dynamic>{...account, 'password': plaintext};
  }

  /// Binds, rebinds or (with null) unbinds the account. A non-empty password is
  /// sealed before it is written; one that already is an envelope is left alone
  /// (re-saving an untouched form must not double-seal it).
  ///
  /// Returns the account the caller should show — the plaintext password, not
  /// the envelope, so the form keeps behaving as it did under `webdav.set`.
  /// A sealing failure propagates ([WebDavSecretException]) and nothing is
  /// written.
  Future<WebDavAccount?> save(WebDavAccount? value) async {
    if (value == null) {
      await _writePreferences(<String, dynamic>{webdavAccountKey: null});
      return null;
    }
    final stored = <String, dynamic>{
      for (final key in webdavAccountFields) key: _field(value, key),
    };
    final password = stored['password']!;
    var answer = password;
    if (password.isNotEmpty && !isSealedPassword(password)) {
      stored['password'] = await _seal(password);
    } else if (isSealedPassword(password)) {
      // A caller that re-saves what it read from the document: never echo
      // ciphertext back as a password. An unopenable one becomes empty, which
      // the next save would have written anyway.
      answer = await _open(password) ?? '';
    }
    await _writePreferences(<String, dynamic>{webdavAccountKey: stored});
    return <String, dynamic>{...stored, 'password': answer};
  }
}
