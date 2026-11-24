/// Three-state view of the Dart-owned profiles document, for the in-app
/// diagnostics on the backup page. The UI never parses profiles.json itself:
/// this type is the only shape crossing into the widget layer.
///
/// `ok` carries the row counts and (when the filesystem can report it) the byte
/// size of the document, which is enough to tell "empty but valid" from a
/// document that never got created.
sealed class ConfigurationDocumentStatus {
  const ConfigurationDocumentStatus();
}

/// `<filesDir>/documents/profiles.json` is not on disk: the one-time Room
/// handover never completed (or the file was deleted).
class ConfigurationDocumentMissing extends ConfigurationDocumentStatus {
  const ConfigurationDocumentMissing();
}

/// The file exists but cannot be trusted: bad JSON, a bad envelope or a read
/// failure. [message] is safe to show to the user.
class ConfigurationDocumentCorrupt extends ConfigurationDocumentStatus {
  const ConfigurationDocumentCorrupt(this.message);
  final String message;
}

/// The document exists and parsed on a forced reload.
class ConfigurationDocumentOk extends ConfigurationDocumentStatus {
  const ConfigurationDocumentOk({
    required this.groups,
    required this.profiles,
    this.bytes,
  });

  /// Number of proxy groups in the document.
  final int groups;
  /// Number of profiles (nodes) in the document.
  final int profiles;
  /// Byte size of profiles.json on disk, when the filesystem can report it.
  final int? bytes;
}
