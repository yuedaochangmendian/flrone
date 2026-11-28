// S8: the stored-row Xray bridge.
//
// The Xray runtime is gone, and S8 removes the remaining Kotlin dependency:
// `ProxyEntity.parseOutbound` no longer runs `LegacyXray.migrateStored`. The
// old rows are instead rewritten once in the Dart-owned
// `documents/profiles.json`, through the Go `profileMigrate` action
// (`buildScript/core-patch/core/mobile/profile_migrate_xray.go`, the
// byte-parity port of LegacyXray's stored-row half). Kotlin then only ever
// reads already-migrated document rows.
//
// Detection mirrors `LegacyXray.migrateStored`'s own precedence exactly:
//
//   1. the row's stored type or JSON `type` is `xrayvless`;
//   2. the stored/JSON type is `custom` and its subtype is `xrayoutbound` or
//      `xrayfullconfig`;
//   3. otherwise the JSON has a top-level `protocol` key (the shape every old
//      Xray outbound row had).
//
// A `custom` row of another subtype is NOT legacy even when the config it
// embeds happens to contain `protocol`, so a modern custom outbound can never
// be rewritten by this scan.
//
// One scan produces ONE `ConfigurationStore.applyCombined` edit: every
// migrated `type`/`outbound_json`/`name` patch and the document's completion
// marker land in one serialized write, so no reader sees a half-migrated
// document. A refusal (`migrated:false` with a reason) keeps the row untouched
// and is logged once; the marker still records the scan because the Go action
// already decided that data has no sing-box counterpart. An action/transport
// error aborts without the marker, so the owner can retry after the kernel
// driver attaches (and a later app start tries again).
//
// The migration is idempotent: the marker short-circuits every run, and a
// second run without a marker re-scans and finds nothing to patch.

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import 'configuration_store.dart';

/// The document marker version this migration writes. Bump only when the scan
/// has new work to do on documents an older build already marked done.
const int legacyXrayMigrationVersion = 1;

/// One row's answer from the Go `profileMigrate` action.
///
/// `{"migrated":true,"type":"vless","json":"…","name":"…",…}` is a converted
/// node. `{"migrated":false,"reason":"…"}` is a refusal whose text is a plain
/// source string (no Android resources). `{"migrated":false}` with no reason
/// is LegacyXray.migrateStored returning null: the row is ordinary, not the
/// legacy shape the detector expected (for example an empty/infra Xray
/// object), and is left exactly as it is.
class LegacyXrayMigrationReply {
  const LegacyXrayMigrationReply({
    required this.migrated,
    this.reason = '',
    this.type = '',
    this.name = '',
    this.json = '',
  });

  final bool migrated;
  final String reason;
  final String type;
  final String name;
  final String json;

  /// Decodes the action reply; null when it is not a JSON object (the caller
  /// treats that as a transport/shape error and leaves the marker unwritten).
  static LegacyXrayMigrationReply? fromWire(Object? raw) {
    if (raw is! Map) return null;
    String text(String key) {
      final value = raw[key];
      return value == null ? '' : '$value';
    }

    return LegacyXrayMigrationReply(
      migrated: raw['migrated'] == true,
      reason: text('reason'),
      type: text('type'),
      name: text('name'),
      json: text('json'),
    );
  }
}

/// Calls the Go `profileMigrate` action for one stored row. The production
/// binding waits for the kernel action bus; tests substitute a fake.
typedef LegacyXrayRowMigrator = Future<LegacyXrayMigrationReply> Function(
  String type,
  String json,
);

/// A diagnostic sink; production uses `debugPrint`, tests collect.
typedef LegacyXrayMigrationLog = void Function(String message);

void _debugLog(String message) => debugPrint(message);

/// What one [LegacyXrayMigration.ensure] call did.
class LegacyXrayMigrationOutcome {
  const LegacyXrayMigrationOutcome({
    required this.completed,
    required this.changed,
    this.alreadyDone = false,
    this.migrated = 0,
    this.refused = 0,
    this.skipped = 0,
    this.error,
  });

  /// The document now carries the completion marker (it already did, or this
  /// run wrote it).
  final bool completed;

  /// At least one row's `type`/`outbound_json` changed; consumers must refresh
  /// their read caches.
  final bool changed;

  /// The marker was already present; no scan ran.
  final bool alreadyDone;

  final int migrated;

  /// Rows the Go action refused (kept untouched, logged once).
  final int refused;

  /// Detected rows the action answered as ordinary (no reason), left untouched.
  final int skipped;

  /// A document read, apply or action failure. The marker is NOT written, so a
  /// later call retries.
  final String? error;
}

/// The one-time, document-owned legacy-row scan.
///
/// Call [ensure] from the document owner after the store resolves. Concurrent
/// callers share one run; a failed run is retried by the next [ensure].
class LegacyXrayMigration {
  LegacyXrayMigration({
    required this.store,
    required this.migrate,
    LegacyXrayMigrationLog? log,
  }) : log = log ?? _debugLog;

  final ConfigurationStore store;
  final LegacyXrayRowMigrator migrate;
  final LegacyXrayMigrationLog log;

  Future<LegacyXrayMigrationOutcome>? _running;

  /// Runs the scan at most once until it fails. Idempotent: a document with the
  /// marker returns immediately; a document without it is re-scanned.
  Future<LegacyXrayMigrationOutcome> ensure() {
    final existing = _running;
    if (existing != null) return existing;
    final future = _run().then(
      (outcome) {
        // A failure must not poison the single-flight: the owner retries once
        // the kernel driver is attached.
        if (outcome.error != null) _running = null;
        return outcome;
      },
      onError: (Object error) {
        _running = null;
        return LegacyXrayMigrationOutcome(
          completed: false,
          changed: false,
          error: '$error',
        );
      },
    );
    _running = future;
    return future;
  }

  Future<LegacyXrayMigrationOutcome> _run() async {
    final ProfilesDocument document;
    try {
      document = await store.document;
    } catch (error) {
      log(
        'legacy Xray migration skipped: the profiles document is unreadable: $error',
      );
      return LegacyXrayMigrationOutcome(
        completed: false,
        changed: false,
        error: '$error',
      );
    }
    if (document.legacyXrayMigration >= legacyXrayMigrationVersion) {
      return const LegacyXrayMigrationOutcome(
        completed: true,
        changed: false,
        alreadyDone: true,
      );
    }

    final candidates = <NodeRow>[
      for (final row in document.profiles)
        if (isLegacyXrayRow(row)) row,
    ];
    final patches = <int, Map<String, dynamic>>{};
    var migrated = 0;
    var refused = 0;
    var skipped = 0;

    for (final row in candidates) {
      try {
        final reply = await migrate(row.type, row.outboundJson);
        if (!reply.migrated) {
          if (reply.reason.isEmpty) {
            // The action found nothing to convert (an empty/infrastructure
            // Xray object), exactly like migrateStored returning null.
            skipped++;
          } else {
            refused++;
            log('legacy Xray row ${row.id} kept: ${reply.reason}');
          }
          continue;
        }
        if (reply.type.isEmpty || reply.json.isEmpty) {
          throw StateError(
            'profileMigrate answered a migrated row without type/json',
          );
        }
        patches[row.id] = <String, dynamic>{
          'type': reply.type,
          'outbound_json': reply.json,
          // The tag is the migrated node's display name; a row the old Xray
          // data left without one keeps the name column it already had.
          if (reply.name.isNotEmpty) 'name': reply.name,
        };
        migrated++;
      } catch (error) {
        log(
          'legacy Xray migration stopped at row ${row.id}; rows were not '
          'changed and the marker was not written: $error',
        );
        return LegacyXrayMigrationOutcome(
          completed: false,
          changed: false,
          migrated: migrated,
          refused: refused,
          skipped: skipped,
          error: '$error',
        );
      }
    }

    final bool exists;
    try {
      exists = await store.exists();
    } catch (error) {
      log('legacy Xray migration could not inspect the document: $error');
      return LegacyXrayMigrationOutcome(
        completed: false,
        changed: false,
        migrated: migrated,
        refused: refused,
        skipped: skipped,
        error: '$error',
      );
    }
    if (patches.isEmpty && !exists) {
      // A fresh install with no document: there is nothing to rewrite and no
      // file to annotate. The next run (after the first profile exists) scans.
      return LegacyXrayMigrationOutcome(
        completed: false,
        changed: false,
        migrated: 0,
        refused: refused,
        skipped: skipped,
      );
    }

    try {
      // ONE serialized edit: row patches plus the marker. `applyCombined`
      // persists the whole document once.
      await store.applyCombined(
        replaceAll: false,
        patches: patches,
        legacyXrayMigration: legacyXrayMigrationVersion,
      );
    } catch (error) {
      log('legacy Xray migration could not persist: $error');
      return LegacyXrayMigrationOutcome(
        completed: false,
        changed: false,
        migrated: migrated,
        refused: refused,
        skipped: skipped,
        error: '$error',
      );
    }

    return LegacyXrayMigrationOutcome(
      completed: true,
      changed: patches.isNotEmpty,
      migrated: migrated,
      refused: refused,
      skipped: skipped,
    );
  }

  /// Whether [row] is stored in the legacy Xray shape `LegacyXray.migrateStored`
  /// converts. Mirrors that method's branches, including its early return for a
  /// `custom` row of a non-Xray subtype.
  static bool isLegacyXrayRow(NodeRow row) {
    final object = _decodeObject(row.outboundJson);
    if (object == null) return false;
    final storedType = row.type.trim().toLowerCase();
    final rowType = _text(object['type']).trim().toLowerCase();
    if (storedType == 'xrayvless' || rowType == 'xrayvless') return true;
    if (storedType == 'custom' || rowType == 'custom') {
      final subtype = _text(object['subtype']).trim().toLowerCase();
      return subtype == 'xrayoutbound' || subtype == 'xrayfullconfig';
    }
    return object.containsKey('protocol');
  }

  static Map<String, dynamic>? _decodeObject(String text) {
    if (text.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  static String _text(Object? value) => value == null ? '' : '$value';
}
