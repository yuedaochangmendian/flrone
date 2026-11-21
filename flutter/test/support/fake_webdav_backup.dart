// Deterministic WebDAV backup transport for widget tests (ADR 0005 phase 4).
// Implements the same interface as the real WebDavBackupService without HTTP
// or Room. Each field is injectable so a test can model success, latency,
// empty listings, auth failures and corrupt downloads.

import 'package:flrone/services/backup_webdav.dart';

class FakeWebDavBackup implements WebDavBackupTransport {
  FakeWebDavBackup({
    this.uploadResult = const WebDavUploadResult('throne_backup_test.thrbackup', null),
    List<WebDavBackupEntry>? entries,
    this.uploadError,
    this.listError,
    this.downloadError,
    this.downloadBytes = const <int>[],
    this.uploadCompleter,
  }) : entries = entries ?? <WebDavBackupEntry>[];

  WebDavUploadResult uploadResult;
  final List<WebDavBackupEntry> entries;
  final Object? uploadError;
  final Object? listError;
  final Object? downloadError;
  final List<int> downloadBytes;
  final Future<void>? uploadCompleter;

  final List<List<int>> uploaded = <List<int>>[];
  final List<Set<String>> uploadedParts = <Set<String>>[];
  int downloadCount = 0;

  @override
  Future<WebDavUploadResult> upload(List<int> bytes, Set<String> parts) async {
    if (uploadCompleter != null) await uploadCompleter;
    if (uploadError != null) throw uploadError!;
    uploaded.add(bytes);
    uploadedParts.add(parts);
    return uploadResult;
  }

  @override
  Future<List<WebDavBackupEntry>> list() async {
    if (listError != null) throw listError!;
    return entries;
  }

  @override
  Future<List<int>> download(WebDavBackupEntry entry) async {
    if (downloadError != null) throw downloadError!;
    downloadCount++;
    return downloadBytes;
  }
}
