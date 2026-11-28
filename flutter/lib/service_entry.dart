// Service-engine entry point (phase 1 of the engine split).
//
// A second Flutter engine runs this entry point. It owns the FFI kernel, the
// in-process worker (kernel_worker.dart, Bettbox-style: no worker isolate for
// the kernel's own bookkeeping) and the platform channel. The UI engine only
// sees a [KernelProxy] (kernel_proxy.dart) speaking the small map IPC defined in
// kernel_control.dart over IsolateNameServer.
//
// Two isolates, one engine — and why:
//
// The Android embedder merges the platform and UI task runners
// (`flutter::Settings::merged_platform_ui_thread` defaults to `kEnabled`,
// common/settings.h), so a `FlutterEngine` constructed on the main thread runs
// *its* Dart isolates on the main thread too — the same thread the UI engine
// builds frames on. The kernel's boot is two synchronous FFI calls
// (`ThroneCore.create` + `start`, 365 ms measured: service 6, config 37,
// instance 169, start 159), so running `KernelService.startService` from this
// entrypoint froze the UI for the whole start. That was the start-only jank the
// card kept showing, and it explained the probes' silence: no `slow event` (the
// UI's own handlers were idle), no `frame work` (no frame could begin), no
// `ipc lag` (the sender was the busy side — nothing was in flight, so nothing
// arrived late). `ui stall 303ms` at `last=rates`, bracketing `core started in
// 365ms`, was the shared thread.
//
// So:
//   * this root isolate stays on the platform thread and owns only the
//     `io.flrone/service` MethodChannel and EventChannel — the embedding answers
//     channels on the platform thread (`DartExecutor` asserts it). It forwards
//     every host command to the worker and runs the worker's `host.call`s here.
//   * [kernelWorker] runs on its own VM thread (a spawned isolate is not merged),
//     where `KernelService`, the FFI driver and the UI-facing IPC port live. It
//     keeps this engine's isolate group, so the kernel's heap and GC stay
//     separate from the UI engine's — the reason the engine is standalone
//     (`ServiceEngineManager`).
//
// Modelled on Bettbox's `_service` / `_handleMainIpc` (lib/main.dart): register
// a named port, answer requests, and forward kernel events to the UI's port.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'core/action.dart';
import 'core/kernel_control.dart';
import 'core/kernel_service.dart';
import 'core/log_batch.dart';
import 'core/platform_value.dart';
import 'core/throne_kernel.dart';
import 'data/configuration_store.dart'
    show ConfigurationStore, NodeRow, profilesFileName;
import 'data/configuration_store_source.dart'
    show AppliedProfilesDocument, ConfigurationStoreSource, decodeAppliedProfiles;
import 'data/legacy_xray_migration.dart'
    show
        LegacyXrayMigration,
        LegacyXrayMigrationLog,
        LegacyXrayMigrationOutcome,
        LegacyXrayMigrationReply,
        LegacyXrayRowMigrator;
import 'data/profile_document_service.dart' show ProfileDocumentService;
import 'services/subscription_engine.dart';
import 'services/subscription_refresh.dart';
import 'services/subscription_transport.dart'
    show SubscriptionFetchResult, SubscriptionHostFetchReply;

/// The service engine's root isolate: the platform channel, and nothing else.
///
/// Every kernel operation is forwarded to [kernelWorker]. Commands that arrive
/// before the worker said hello are queued: `ServiceBridge.startKernel` only
/// retries on a thrown `MissingPluginException`, so a silently dropped command
/// (a tile/boot start racing the worker's spawn) would surface as a tunnel that
/// never came up.
@pragma('vm:entry-point')
Future<void> serviceMain(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('io.flrone/service');
  // S6: the service engine is the single owner of documents/profiles.json.
  // Kotlin (DartProfileWriter) invokes this channel with a small envelope:
  // {id, method, args}. The root isolate cannot touch the document (channels
  // are answered on the platform thread), so it forwards the envelope to the
  // kernelWorker's owner module over the SAME port used for commands and host
  // replies, then echoes the answer back to Kotlin by id.
  const documentChannel = MethodChannel('io.flrone/profiles_doc');
  final inbox = ReceivePort();
  SendPort? worker;
  final queued = <Map<String, dynamic>>[];
  final pendingDocuments = <int, Completer<dynamic>>{};
  var nextDocumentId = 0;
  // S6: the automatic poll is a request/reply command (the host must not report
  // success until the engine's queue idles). Ids share the one command port with
  // fire-and-forget commands; only awaitable ones carry an id.
  final pendingCommands = <int, Completer<dynamic>>{};
  var nextCommandId = 0;

  void send(Map<String, dynamic> command) {
    final port = worker;
    if (port == null) {
      queued.add(command);
      return;
    }
    port.send(command);
  }

  inbox.listen((raw) {
    final message = normalizePlatformValue(raw);
    if (message is! Map<String, dynamic>) return;
    switch (message['kind']) {
      case 'ready':
        final port = message['port'];
        if (port is! SendPort) return;
        worker = port;
        for (final command in queued) {
          port.send(command);
        }
        queued.clear();
      case 'host':
        // The worker's door to the platform. Answering here (and not there) is
        // what keeps this channel on the platform thread the embedding expects.
        final method = message['method'];
        if (method is! String) return;
        final arguments = message['args'];
        _serveHostCall(
          method,
          arguments is Map<String, dynamic> ? arguments : null,
          message['id'],
          () => worker,
        );
      case 'documentResult':
        // The owner answered one document op. Settle the Kotlin call that is
        // waiting on this id; an unknown/stale id is dropped (Kotlin may have
        // detached and retried with a new id).
        final id = (message['id'] as num?)?.toInt();
        if (id == null) return;
        final completer = pendingDocuments.remove(id);
        if (completer == null || completer.isCompleted) return;
        final error = message['error'];
        if (error != null) {
          completer.completeError(StateError('$error'));
        } else {
          completer.complete(message['result']);
        }
      case 'commandResult':
        // An awaitable command finished in the worker. A late/unknown id (a
        // cancelled channel call) is dropped exactly like a document reply.
        final id = (message['id'] as num?)?.toInt();
        if (id == null) return;
        final completer = pendingCommands.remove(id);
        if (completer == null || completer.isCompleted) return;
        final error = message['error'];
        if (error != null) {
          completer.completeError(StateError('$error'));
        } else {
          completer.complete(message['result']);
        }
    }
  });

  // S6: Kotlin's document writes land here. Forward the envelope verbatim to
  // the worker (queueing is inherited from `send` until the worker says hello)
  // and reply with the owner's small ack/error. The worker is the single writer;
  // this isolate only relays, so no document state lives here.
  documentChannel.setMethodCallHandler((call) async {
    if (call.method != 'document') {
      throw MissingPluginException('unknown profiles_doc method: ${call.method}');
    }
    final envelope = normalizePlatformValue(call.arguments);
    if (envelope is! Map<String, dynamic>) {
      throw ArgumentError('missing document envelope');
    }
    final id = ++nextDocumentId;
    final completer = Completer<dynamic>();
    pendingDocuments[id] = completer;
    send(<String, dynamic>{
      'kind': 'document',
      'id': id,
      'method': envelope['method'],
      'args': envelope['args'],
    });
    try {
      return await completer.future;
    } finally {
      pendingDocuments.remove(id);
    }
  });

  // Host-pushed events for this engine: the Wi-Fi monitor and IPC reconnect
  // hints. The UI engine's channel handlers cannot serve these — the monitor
  // belongs to the process, not to the UI engine.
  channel.setMethodCallHandler((call) async {
    int? revision() => call.arguments is Map
        ? ((call.arguments as Map)['revision'] as num?)?.toInt()
        : null;
    switch (call.method) {
      case 'reload':
        send(<String, dynamic>{'kind': 'command', 'method': 'reload'});
      case 'serviceStop':
        // The revision is the one in force when the STOP command arrived; a start
        // that landed after it claims a higher one and this stop is stale
        // (FlClash's notifyStopped commandRevision contract).
        send(<String, dynamic>{
          'kind': 'command',
          'method': 'serviceStop',
          'revision': revision(),
        });
      case 'startKernel':
        send(<String, dynamic>{
          'kind': 'command',
          'method': 'startKernel',
          'revision': revision(),
        });
      case 'forceGc':
        // Host memory-pressure hint; the worker owns the kernel action bus.
        // The host always sends an explicit level; a missing/mistyped flag is
        // refused rather than silently escalating to the full trim.
        final rawFull = call.arguments is Map
            ? (call.arguments as Map)['full']
            : null;
        if (rawFull is! bool) {
          debugPrint('serviceMain: forceGc requires a bool full flag');
          return null;
        }
        send(<String, dynamic>{'kind': 'command', 'method': 'forceGc', 'full': rawFull});
      case 'setDoze':
        // Device doze hint from the Android host. Forward the exact desired
        // value; the worker owns the kernel action bus and remembers it across
        // a pre-attach call.
        final enabled = call.arguments is Map
            ? (call.arguments as Map)['enabled'] == true
            : false;
        send(<String, dynamic>{
          'kind': 'command',
          'method': 'setDoze',
          'enabled': enabled,
        });
      case 'subscription.refresh':
      case 'subscription.refreshAll':
      case 'subscription.awaitIdle':
        // S6: the UI trigger for the Dart-owned subscription queue. The worker
        // owns the queue; this isolate only forwards (fire-and-forget).
        final args = call.arguments is Map
            ? Map<String, dynamic>.from(normalizePlatformValue(call.arguments) as Map)
            : <String, dynamic>{};
        send(<String, dynamic>{
          'kind': 'command',
          'method': call.method,
          'args': args,
        });
      case 'subscription.create':
      case 'subscription.refreshMany':
        // Both are request/reply commands: the poll must not report success
        // before its queue idles, and the editor needs the new group id back.
        // Forward with an id and await the worker's result envelope.
        final args = call.arguments is Map
            ? Map<String, dynamic>.from(normalizePlatformValue(call.arguments) as Map)
            : <String, dynamic>{};
        final id = ++nextCommandId;
        final completer = Completer<dynamic>();
        pendingCommands[id] = completer;
        send(<String, dynamic>{
          'kind': 'command',
          'id': id,
          'method': call.method,
          'args': args,
        });
        try {
          return await completer.future;
        } finally {
          pendingCommands.remove(id);
        }
    }
    return null;
  });
  const EventChannel('io.flrone/service/events')
      .receiveBroadcastStream()
      .listen((raw) {
    final event = normalizePlatformValue(raw);
    if (event is Map && event['type'] == 'wifi.state') {
      send(<String, dynamic>{'kind': 'command', 'method': 'wifi.state'});
    }
  }, onError: (Object error) {
    debugPrint('serviceMain: service event stream error: $error');
  });

  try {
    await Isolate.spawn<List<Object?>>(
      kernelWorker,
      <Object?>[inbox.sendPort, args],
      debugName: 'kernel',
    );
  } catch (error) {
    debugPrint('serviceMain: kernel worker spawn failed: $error');
  }
}

/// The service engine's document owner (S6 Option A).
///
/// This isolate is the single writer of `documents/profiles.json`. It owns the
/// [ConfigurationStoreSource] and [ProfileDocumentService]; Kotlin row writes
/// and the UI's narrow relay ops both arrive as one `applyDocument` envelope
/// and run inside the store's serialized edit. No profile logic lives in Kotlin
/// — the relay only forwards the existing Dart document ops.
///
/// The store path comes from the host's `document.path` (this isolate has no
/// `data.path`/Activity of its own); the default group name rides in the same
/// fact. Every owner write calls `host.call('data.refresh')` so Kotlin's read
/// cache is invalidated and the catalog is pushed to the UI.
///
/// S8: resolving the store also runs the one-time legacy Xray row migration
/// ([LegacyXrayMigration]). `ProxyEntity.parseOutbound` no longer converts
/// stored Xray rows, so the document must be rewritten through the Go
/// `profileMigrate` action before subscription/config consumers read it. The
/// scan is recorded in the document's `migrations.legacyXray` marker, is
/// idempotent, and a failed run (the kernel driver is not attached yet) leaves
/// the marker unwritten so [ensureLegacyXrayMigration] can retry.
class DocumentOwner {
  DocumentOwner(
    this.host, {
    LegacyXrayRowMigrator? migrateLegacyXrayRow,
    LegacyXrayMigrationLog? migrationLog,
  })  : _migrateLegacyXrayRow = migrateLegacyXrayRow,
        _migrationLog = migrationLog;

  final KernelHost host;
  final LegacyXrayRowMigrator? _migrateLegacyXrayRow;
  final LegacyXrayMigrationLog? _migrationLog;

  ConfigurationStoreSource? _source;
  ProfileDocumentService? _service;
  Future<void>? _resolving;
  Future<LegacyXrayMigrationOutcome>? _migration;

  /// Resolves the store from `document.path` once. Concurrent first writes
  /// share one resolution so the store is not created twice. Every consumer
  /// waits for the one-time legacy-row scan before it can read the document.
  Future<ProfileDocumentService> get service async {
    final resolved = await _resolveService();
    final migration = _migration;
    if (migration != null) await migration;
    return resolved;
  }

  /// The path resolution alone, without the migration gate: the migration
  /// itself resolves the store through here (calling [service] would await the
  /// very future it is about to create).
  Future<ProfileDocumentService> _resolveService() async {
    final existing = _service;
    if (existing != null) return existing;
    final pending = _resolving;
    if (pending != null) {
      await pending;
      return _service!;
    }
    final completer = Completer<void>();
    _resolving = completer.future;
    try {
      final reply = await host.call('document.path');
      final map = reply is Map ? Map<String, dynamic>.from(reply) : <String, dynamic>{};
      final directory = map['directory'];
      if (directory is! String || directory.isEmpty) {
        throw StateError('document.path did not provide a documents directory');
      }
      final defaultName = map['defaultGroupName'] is String
          ? map['defaultGroupName'] as String
          : 'Default';
      // ConfigurationStoreSource derives `<app>/files/documents` from a Room
      // database path's grandparent. The host already gives us the documents
      // directory, so inject a store whose path is exactly that file; the
      // resolvePath closure is still required by the source constructor.
      final store = ConfigurationStore(path: '$directory${Platform.pathSeparator}$profilesFileName');
      final resolved = ConfigurationStoreSource(
        resolvePath: () async => <String, dynamic>{
          'path': '$directory${Platform.pathSeparator}..${Platform.pathSeparator}..',
        },
        store: store,
      );
      _source = resolved;
      _service = ProfileDocumentService(
        storeSource: resolved,
        refreshCatalog: () async {
          await host.call('data.refresh');
        },
        repositionTestResults: (groupId) async {
          await host.call('sort.reposition', <String, dynamic>{'payload': <String, dynamic>{'id': groupId}});
        },
        beginGroupEdit: (groupId) async {
          await host.call('revision.edit', <String, dynamic>{'payload': <String, dynamic>{'id': groupId}});
        },
        rescheduleSubscriptions: () async {
          await host.call('subscription.schedule', <String, dynamic>{'payload': <String, dynamic>{}});
        },
        readDefaultGroupName: () async => defaultName,
      );
      // Start the one-time scan with the store. The first caller of `service`
      // awaits it below; concurrent callers await `_resolving` first.
      _migration = _runLegacyXrayMigration();
      return _service!;
    } finally {
      completer.complete();
      _resolving = null;
    }
  }

  /// Runs (or retries) the one-time legacy Xray row scan.
  ///
  /// The first call starts the lazy scan that [service] awaits. [force] starts
  /// a fresh scan after the current one settles: used after the kernel driver
  /// attached (the lazy attempt can arrive before `KernelService.initialize()`)
  /// and after a whole-document replace reset the marker (backup restore). The
  /// forced scan still reads the marker, so a completed document costs one
  /// cheap check and no write.
  Future<LegacyXrayMigrationOutcome> ensureLegacyXrayMigration({
    bool force = false,
  }) async {
    await _resolveService();
    final current = _migration;
    if (current != null) {
      final outcome = await current;
      // A successful run is reused; a failed one is retried even without
      // `force`, because config builds read the document directly.
      if (!force && outcome.error == null) return outcome;
    }
    final started = _runLegacyXrayMigration();
    _migration = started;
    return started;
  }

  Future<LegacyXrayMigrationOutcome> _runLegacyXrayMigration() async {
    final migrate = _migrateLegacyXrayRow;
    final source = _source;
    if (migrate == null || source == null) {
      return const LegacyXrayMigrationOutcome(completed: false, changed: false);
    }
    try {
      final store = await source.store();
      final outcome = await LegacyXrayMigration(
        store: store,
        migrate: migrate,
        log: _migrationLog,
      ).ensure();
      if (outcome.changed) {
        // Kotlin's document cache and the UI catalog may already hold the
        // pre-migration rows; invalidate exactly like any other owner write.
        try {
          await host.call('data.refresh');
        } catch (error) {
          debugPrint('kernelWorker: data.refresh after legacy Xray migration failed: $error');
        }
      }
      if (outcome.error != null) {
        debugPrint('kernelWorker: legacy Xray migration left rows for a retry: ${outcome.error}');
      }
      return outcome;
    } catch (error) {
      debugPrint('kernelWorker: legacy Xray migration failed: $error');
      return LegacyXrayMigrationOutcome(
        completed: false,
        changed: false,
        error: '$error',
      );
    }
  }

  /// The writable document store this owner owns. Subscription refresh reads
  /// it through [ConfigurationStoreSubscriptionGateway] and writes through the
  /// same single edit path as every other document mutation.
  Future<ConfigurationStore> get store async {
    await service;
    return _source!.store();
  }

  /// Runs one document op by name. [applyDocument] is the Kotlin row-map path;
  /// the rest are the UI relay ops forwarded by box_api. Every op that writes
  /// the document goes through ProfileDocumentService, whose hooks call
  /// `host.call('data.refresh')`, so Kotlin's read view is invalidated once.
  Future<Object?> perform(String method, Object? raw) async {
    final svc = await service;
    final args = raw is Map
        ? Map<String, dynamic>.from(normalizePlatformValue(raw) as Map)
        : <String, dynamic>{};
    switch (method) {
      case 'applyDocument':
        return applyDocument(raw);
      case 'configurationWrite':
        final result = await svc.write(
          (args['id'] as num?)?.toInt() ?? 0,
          args['revision'] as String?,
          '${args['content'] ?? ''}',
        );
        return Map<String, dynamic>.from(result);
      case 'configurationClearTestResults':
        await svc.clearTestResults((args['id'] as num?)?.toInt() ?? 0);
        return true;
      case 'nodeReorder':
        await svc.reorderNodes(
          (args['groupId'] as num?)?.toInt() ?? 0,
          [for (final id in (args['ids'] as List? ?? const [])) (id as num).toInt()],
        );
        return true;
      case 'configurationReorder':
        await svc.reorderGroups([
          for (final id in (args['ids'] as List? ?? const [])) (id as num).toInt()
        ]);
        return true;
      case 'configurationNodeList':
        // nodeList prunes empty containers, so it is a WRITE, not a read.
        return Map<String, dynamic>.from(await svc.nodeList());
      case 'autoSelectorSave':
        final values = args['value'] is Map
            ? Map<String, dynamic>.from(args['value'] as Map)
            : <String, dynamic>{};
        return Map<String, dynamic>.from(
          await svc.autoSelectorSave((args['id'] as num?)?.toInt() ?? 0, values),
        );
      case 'autoSelectorPin':
        return Map<String, dynamic>.from(
          await svc.autoSelectorPin(
            (args['id'] as num?)?.toInt() ?? 0,
            (args['memberId'] as num?)?.toInt() ?? -1,
          ),
        );
      case 'autoSelectorCreate':
        return Map<String, dynamic>.from(
          await svc.autoSelectorCreate(
            (args['groupId'] as num?)?.toInt(),
            args['name'] as String?,
          ),
        );
      case 'applyRestoredProfiles':
        final restored = decodeAppliedProfiles(args['document']);
        if (restored == null || restored.profiles == null || restored.groups == null) {
          throw ArgumentError('applyRestoredProfiles needs a full document');
        }
        await _source!.apply(AppliedProfilesDocument(
          profiles: restored.profiles,
          groups: restored.groups,
          nextProfileId: restored.nextProfileId,
          nextGroupId: restored.nextGroupId,
          replaceAll: true,
        ));
        // A restore replaces every row, so the document marker was reset: the
        // restored rows may still be legacy Xray rows from an older backup.
        await ensureLegacyXrayMigration(force: true);
        await host.call('data.refresh');
        return true;
      default:
        throw UnsupportedError('unknown document op: $method');
    }
  }

  /// Handles one `applyDocument` envelope. The payload is the exact Room-keyed
  /// document op the UI/Kotlin built; decode it and run one combined store edit.
  Future<Map<String, dynamic>> applyDocument(Object? raw) async {
    final doc = decodeAppliedProfiles(normalizePlatformValue(raw));
    if (doc == null) throw ArgumentError('missing document');
    await service; // ensure the store is resolved
    final source = _source!;
    final allocated = await source.apply(doc);
    if (doc.replaceAll) {
      // A full rewrite is foreign data (a backup restore): the marker resets,
      // so the rows are scanned again before any consumer reads them.
      await ensureLegacyXrayMigration(force: true);
    }
    // A single apply is ONE combined edit (ConfigurationStore.applyCombined).
    final current = await (await source.store()).document;
    // Owner writes must refresh Kotlin's read view even though the op itself
    // did not go through ProfileDocumentService's refreshCatalog hook.
    await host.call('data.refresh');
    return <String, dynamic>{
      'ok': true,
      'nextProfileId': current.nextProfileId,
      'nextGroupId': current.nextGroupId,
      'profileIds': allocated.profiles.map(
        (client, real) => MapEntry(client.toString(), real),
      ),
      'groupIds': allocated.groups.map(
        (client, real) => MapEntry(client.toString(), real),
      ),
    };
  }

  void dispose() {
    _source?.dispose();
  }
}

/// Runs one [KernelHost.call] for the worker and ships the answer back.
///
/// The reply is `{kind: hostResult, id, result}` or `... error`, the same
/// request/response shape the UI's proxy uses, so timeouts stay observable.
void _serveHostCall(
  String method,
  Map<String, dynamic>? arguments,
  Object? id,
  SendPort? Function() worker,
) {
  // A reply that never leaves this isolate leaves the kernel waiting on its
  // timeout, so a synchronous codec failure answers like an async one.
  void answer(Object? result, Object? error) => worker()?.send(<String, dynamic>{
    'kind': 'hostResult',
    'id': id,
    if (error == null) 'result': result else 'error': '$error',
  });
  try {
    const MethodChannel('io.flrone/service')
        .invokeMethod<dynamic>(method, arguments)
        .then<void>(
      (result) => answer(result, null),
      onError: (Object error) => answer(null, error),
    );
  } catch (error) {
    answer(null, error);
  }
}

/// The kernel isolate: [KernelService], the FFI driver, and the UI's port.
@pragma('vm:entry-point')
Future<void> kernelWorker(List<Object?> message) async {
  final root = message[0] as SendPort;
  final args = (message[1] as List).cast<String>();
  // The root's commands and its answers to this isolate's `host.call`s share one
  // port: both are addressed to this isolate, and one inbound queue keeps their
  // order relative to the kernel's own work.
  final commandPort = ReceivePort();

  // The kernel's log tail: encoded lines wait for a screen to watch them. Declared here so
  // the UI's `kernelLogsVisible` request (handled below) and the tail's own listener share
  // one state.
  final pendingLogs = <String>[];
  final kernelRing = <String>[];
  var kernelLogsWanted = false;

  // TODO(phase2): interpret `quick`/`boot` and auto-start the core here. Phase 1
  // only records them; the UI still drives start/stop explicitly.
  final quick = args.contains('quick');
  final boot = args.contains('boot');
  debugPrint('kernelWorker: ready (quick=$quick boot=$boot)');

  final host = KernelWorkerHost(root);
  final eventsToUi = StreamController<Map<String, dynamic>>.broadcast();
  final service = KernelService(
    host,
    sink: eventsToUi.add,
  );
  // S6: this isolate owns documents/profiles.json. The root isolate forwards
  // every Kotlin/UI document op here over the command port; replies go back by
  // id (see the 'documentResult' arm in serviceMain).
  //
  // S8: the one-time legacy Xray row bridge rides the same owner. The action
  // bus is only reachable after initialize(), so a lazy scan that arrives first
  // fails fast (no marker) and [DocumentOwner.ensureLegacyXrayMigration] is
  // retried below once the driver is attached.
  final documentOwner = DocumentOwner(
    host,
    migrateLegacyXrayRow: (type, json) async {
      if (!service.driverReady) {
        throw StateError('the kernel action bus is not attached yet');
      }
      final reply = await service.invoke<Object?>(
        ActionMethod.profileMigrate,
        data: <String, dynamic>{'type': type, 'json': json},
      );
      final parsed = LegacyXrayMigrationReply.fromWire(reply);
      if (parsed == null) {
        throw StateError('profileMigrate answered a non-object');
      }
      return parsed;
    },
  );

  /// S8: a start/reload builds the config straight from
  /// `documents/profiles.json` (Kotlin/Go read the file, not this isolate's
  /// store), so those paths also wait for the one-time legacy Xray scan. A
  /// completed scan answers from the marker and costs no document write.
  ///
  /// `initialize()` is idempotent: an early host start (boot/tile) can arrive
  /// before this worker's own attach, and the scan needs the action bus, so
  /// attach first instead of skipping the migration and building old rows.
  Future<void> documentReadyForBuild() async {
    try {
      await service.initialize();
    } catch (error) {
      debugPrint('kernelWorker: initialize before the document scan failed: $error');
    }
    await documentOwner.ensureLegacyXrayMigration();
  }

  // Log-stream visibility is a write to process-wide Go state. The UI port
  // can deliver a burst of true/false toggles (screen opened/closed in quick
  // succession); firing each setLogStream unawaited lets slow replies reorder,
  // leaving the Go sink on the wrong level. Serialise the calls and have every
  // queued step read the *latest* desired value, so the last visibility wins
  // even if an earlier step is still in flight.
  var logStreamChain = Future.value();
  void scheduleLogStream(bool visible) {
    kernelLogsWanted = visible;
    logStreamChain = logStreamChain.then((_) async {
      // Apply the current desire, not the value captured when this step was
      // queued: intermediate toggles collapse onto the final state.
      if (kernelLogsWanted != visible) return;
      try {
        await service.setLogStream(visible);
      } catch (error) {
        debugPrint('kernelWorker: setLogStream failed: $error');
      }
    });
  }

  /// The host must not assume the driver is engaged just because this engine
  /// exists: `KernelService.initialize()` returns silently when libthrone.so is
  /// absent, leaving a connected notification with no core. Push the *real*
  /// attach state (`ffiMode == _kernel != null`) to `FlroneKernel.ffiMode` on the
  /// host. Best effort — a channel failure here must not abort engine startup;
  /// the hello handshake also carries this fact for the UI proxy.
  Future<void> pushDriverReady() async {
    // ServiceBridge.attach() installs the host's MethodChannel handler on the
    // Kotlin side just after this engine is created; it can still be in flight
    // while initialize() runs here. Retry briefly so the fact is not lost to
    // that race (a missing handler surfaces as MissingPluginException).
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await host.call('driver.ready', <String, dynamic>{'ready': service.driverReady});
        return;
      } catch (error) {
        if (attempt == 4) {
          debugPrint('kernelWorker: driver.ready push failed: $error');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  // The UI talks to this isolate directly: it resolves the name this port is
  // registered under, so kernel events pay no forwarding hop and `sentAt` is
  // stamped by the isolate that owns the kernel's clock.
  final servicePort = ReceivePort();
  IsolateNameServer.registerPortWithName(servicePort.sendPort, servicePortName);
  root.send(<String, dynamic>{'kind': 'ready', 'port': commandPort.sendPort});

  SendPort? uiPort;

  /// Sends a message to the most recently greeted UI engine, if any.
  ///
  /// Every envelope is stamped: the UI measures receive-time minus `sentAt` and
  /// reports a large lag, which is the only window that covers the transport's
  /// deserialization on the receiving isolate — work no Dart callback timer can
  /// see (a 200 ms freeze that was neither an event handler nor a frame).
  ///
  /// The stamp is wall-clock (`DateTime.now()`): the two isolates share no
  /// monotonic clock, so an NTP step can skew the delta. The receiver clamps a
  /// negative delta to zero before reporting (see `lagMillis` in kernel_proxy.dart);
  /// the 100 ms threshold is unchanged.
  void deliver(Object? message) {
    final port = uiPort;
    if (port == null) return;
    final stamped = message is Map<String, dynamic>
        ? (message
          ..['sentAt'] = DateTime.now().millisecondsSinceEpoch)
        : message;
    try {
      port.send(stamped);
    } catch (error) {
      debugPrint('kernelWorker: failed to send to UI: $error');
    }
  }

  // Forward every kernel event to the UI as `{type:'event',value:<event>}`.
  // Installed once; `deliver` is a no-op until a UI engine says hello. The last
  // dashboard is kept so a late hello can resync the UI with it.
  Map<String, dynamic>? lastDashboard;
  final eventSub = eventsToUi.stream.listen((event) {
    if (event['type'] == 'dashboard' && event['value'] is Map<String, dynamic>) {
      lastDashboard = event['value'] as Map<String, dynamic>;
    }
    deliver(<String, dynamic>{'type': 'event', 'value': event});
  });

  // S6: the service engine's subscription queue. The refresh data path is
  // `subscription_refresh.dart` (pure); this block supplies the Go parser, the
  // document gateway, and the event bridge to the UI. The queue itself is the
  // same pure state machine from `subscription_queue.dart`.
  late final SubscriptionEngine subscriptionEngine;
  SubscriptionRefreshService? subscriptionRefreshService;

  /// A subscription action can arrive from the host right after engine
  /// creation, before `kernelWorker`'s `service.initialize()` has attached the
  /// FFI driver. Wait briefly for the driver; once it is ready, action errors
  /// propagate unchanged.
  Future<Object?> invokeSubscriptionAction(ActionMethod method, Map<String, dynamic> data) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await service.invoke<Object?>(method, data: data);
      } catch (_) {
        if (service.driverReady || attempt >= 50) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  Future<ProfileImportResult> parseSubscriptionBody(String body) async {
    final reply = await invokeSubscriptionAction(
      ActionMethod.profileImport,
      <String, dynamic>{'text': body},
    );
    final map = normalizePlatformValue(reply);
    if (map is! Map) throw StateError('profileImport reply is not a map');
    final nodes = <ProfileImportNode>[];
    for (final raw in (map['nodes'] as List? ?? const <Object?>[])) {
      final node = normalizePlatformValue(raw);
      if (node is! Map) continue;
      nodes.add(
        ProfileImportNode(
          type: '${node['type'] ?? ''}',
          name: '${node['name'] ?? ''}',
          json: '${node['json'] ?? ''}',
          identity: '${node['identity'] ?? ''}',
          dedupKey: '${node['dedupKey'] ?? ''}',
        ),
      );
    }
    return ProfileImportResult(
      nodes: nodes,
      supported: map['supported'] != false,
      text: '${map['reason'] ?? ''}',
    );
  }

  Future<String> identityOfStoredNode(NodeRow row) async {
    try {
      final reply = await invokeSubscriptionAction(
        ActionMethod.profileExport,
        <String, dynamic>{
          'json': row.outboundJson,
          if (row.name != null) 'name': row.name,
        },
      );
      final map = normalizePlatformValue(reply);
      if (map is Map && map['supported'] == true) return '${map['identity'] ?? ''}';
    } catch (_) {
      // Types the Go exporter has not ported fall back to content identity.
    }
    return '';
  }

  /// The service engine's `subscription.fetch` host seam: a `content://` body
  /// (ContentResolver) or a front/landing-proxy group's fetch goes through
  /// Kotlin's own `SubscriptionFetch`, then back as the Dart result shape.
  /// URLs and credentials never appear in the call's log line: the host only
  /// logs the group name, and its error text is already redacted.
  Future<SubscriptionFetchResult> hostSubscriptionFetch(
    String url, {
    required String subOptionsJson,
    int gid = 0,
  }) async {
    final reply = await host.call('subscription.fetch', <String, dynamic>{
      'url': url,
      'gid': gid,
      'subOptionsJson': subOptionsJson,
    });
    return SubscriptionHostFetchReply.parse(normalizePlatformValue(reply));
  }

  Future<SubscriptionRefreshService> subscriptionService() async {
    final existing = subscriptionRefreshService;
    if (existing != null) return existing;
    final store = await documentOwner.store;
    final created = SubscriptionRefreshService(
      gateway: ConfigurationStoreSubscriptionGateway(
        store,
        identityResolver: identityOfStoredNode,
      ),
      hostFetcher: hostSubscriptionFetch,
      parser: parseSubscriptionBody,
      onReport: (gid, title, text, popup) {
        deliver(<String, dynamic>{
          'type': 'event',
          'value': <String, dynamic>{
            'type': 'subscriptionReport',
            'value': <String, dynamic>{
              'kind': popup ? 'popup' : 'status',
              'groupName': subscriptionEngine.groupNameOf(gid),
              'title': title,
              'text': text,
            },
          },
        });
      },
      onError: (gid, message) {
        deliver(<String, dynamic>{
          'type': 'event',
          'value': <String, dynamic>{
            'type': 'subscriptionReport',
            'value': <String, dynamic>{
              'kind': 'error',
              'groupName': subscriptionEngine.groupNameOf(gid),
              'text': message,
            },
          },
        });
      },
      onUnsupportedFeature: (gid, feature) {
        debugPrint('subscription: gid=$gid unsupported feature=$feature');
      },
    );
    subscriptionRefreshService = created;
    return created;
  }

  void subscriptionForeground(bool active) {
    unawaited(
      host.call('subscription.foreground', <String, dynamic>{'active': active}).then(
        (_) {},
        onError: (Object error) {
          debugPrint('kernelWorker: subscription.foreground failed: $error');
        },
      ),
    );
  }

  subscriptionEngine = SubscriptionEngine(
    runRefresh: (gid, surface) async {
      final result = await (await subscriptionService()).refresh(
        gid,
        surface: surface,
        notifyErrors: surface != SubscriptionRefreshSurface.log,
      );
      if (result.applied) {
        // The owner wrote profiles.json; Kotlin's read cache and the UI catalog
        // must observe the new rows/metadata before the report dialog opens.
        await host.call('data.refresh');
      }
      return result;
    },
    runCreate: (input) async {
      final result = await (await subscriptionService()).create(
        name: input.name,
        url: input.url,
        subOptionsJson: input.subOptionsJson,
        autoUpdate: input.autoUpdate,
        foreground: input.foreground,
      );
      // The new group and its rows were written by the owner; Kotlin's read
      // cache and the UI catalog must see them before the editor closes.
      await host.call('data.refresh');
      return result;
    },
    listGroups: () async {
      final store = await documentOwner.store;
      final groups = await store.groups();
      return <SubscriptionGroupRef>[
        for (final group in groups)
          SubscriptionGroupRef(
            id: group.id,
            name: group.name,
            url: group.url,
            archive: group.archive,
            skipAutoUpdate: group.skipAutoUpdate,
          ),
      ];
    },
    emit: (type, value) => deliver(<String, dynamic>{
      'type': 'event',
      'value': <String, dynamic>{'type': type, 'value': value},
    }),
    onForegroundAcquire: () => subscriptionForeground(true),
    onForegroundRelease: () => subscriptionForeground(false),
  )..start();

  // Resolve the UI's port from the native port number carried by `hello`.
  // Both engines share the process-wide IsolateNameServer.
  SendPort? resolveUi(int nativePort) =>
      IsolateNameServer.lookupPortByName(uiPortName(nativePort));

  // Host commands forwarded by the root isolate (its channel is the only door
  // the host has: start/stop/reload and the Wi-Fi monitor).
  commandPort.listen((raw) {
    final message = normalizePlatformValue(raw);
    if (message is! Map<String, dynamic>) return;
    if (message['kind'] == 'hostResult') {
      host.complete(message);
      return;
    }
    if (message['kind'] == 'document') {
      // Kotlin's document write, relayed by the root isolate. Run it on the
      // owner and echo the small ack/error back by id. Serialized by the
      // store's own edit lock inside [DocumentOwner].
      final id = message['id'];
      final method = message['method'];
      unawaited(() async {
        Object? result;
        Object? error;
        try {
          if (method is! String) throw const FormatException('document op has no method');
          result = await documentOwner.perform(method, message['args']);
        } catch (e) {
          error = e;
        }
        root.send(<String, dynamic>{
          'kind': 'documentResult',
          'id': id,
          if (error == null) 'result': result else 'error': '$error',
        });
      }());
      return;
    }
    if (message['kind'] != 'command') return;
    final revision = (message['revision'] as num?)?.toInt();
    switch (message['method']) {
      case 'reload':
        unawaited(() async {
          try {
            await documentReadyForBuild();
            await service.reloadService(reason: 'host reload');
          } catch (error) {
            debugPrint('kernelWorker: host reload failed: $error');
          }
        }());
      case 'serviceStop':
        unawaited(service.stopCoreFromHost(revision: revision).catchError(
          (Object error) => debugPrint('kernelWorker: host stop failed: $error'),
        ));
      case 'startKernel':
        unawaited(() async {
          try {
            await documentReadyForBuild();
            await service.startService(revision: revision);
          } catch (error) {
            debugPrint('kernelWorker: host start failed: $error');
            deliver(<String, dynamic>{
              'type': 'event',
              'value': <String, dynamic>{'type': 'error', 'value': '$error'},
            });
          }
        }());
      case 'wifi.state':
        unawaited(service.updateWifiState().catchError((Object error) {
          debugPrint('kernelWorker: wifi.state failed: $error');
        }));
      case 'forceGc':
        // Host memory-pressure hint: the Go runtime is process-wide, so this
        // works even with no running instance. The host's notify() has no
        // reply channel; failures are logged here and swallowed. The flag is
        // explicit (the Go handler rejects a missing one).
        final full = message['full'];
        if (full is! bool) {
          debugPrint('kernelWorker: forceGc missing bool full flag');
          break;
        }
        unawaited(service.forceGc(full: full).then((_) {}, onError: (Object error) {
          debugPrint('kernelWorker: forceGc failed: $error');
        }));
      case 'setDoze':
        // Device doze hint. setDoze stores the desired value and invokes the
        // action if attached; failures are logged and swallowed.
        unawaited(service.setDoze(message['enabled'] == true).then((_) {}, onError: (Object error) {
          debugPrint('kernelWorker: setDoze failed: $error');
        }));
      case 'subscription.refresh':
        final args = message['args'] is Map
            ? Map<String, dynamic>.from(message['args'] as Map)
            : <String, dynamic>{};
        final gid = (args['gid'] as num?)?.toInt() ?? 0;
        unawaited(subscriptionEngine
            .refresh(
              gid,
              showDiff: args['showDiff'] == true,
              foreground: args['foreground'] != false,
            )
            .catchError((Object error) {
          debugPrint('kernelWorker: subscription.refresh failed: $error');
          return false;
        }));
      case 'subscription.refreshAll':
        final args = message['args'] is Map
            ? Map<String, dynamic>.from(message['args'] as Map)
            : <String, dynamic>{};
        unawaited(subscriptionEngine
            .refreshAll(
              onlyAllowed: args['onlyAllowed'] == true,
              foreground: args['foreground'] != false,
            )
            .catchError((Object error) {
          debugPrint('kernelWorker: subscription.refreshAll failed: $error');
          return false;
        }));
      case 'subscription.awaitIdle':
        unawaited(subscriptionEngine.awaitIdle().catchError((Object error) {
          debugPrint('kernelWorker: subscription.awaitIdle failed: $error');
        }));
      case 'subscription.refreshMany':
        // Awaitable variant: the automatic poll's due ids, enqueued through the
        // same per-gid dedupe queue as a manual refresh. Reply by id exactly
        // once — success or error — so the host never hangs or double-settles.
        final id = (message['id'] as num?)?.toInt();
        final args = message['args'] is Map
            ? Map<String, dynamic>.from(message['args'] as Map)
            : <String, dynamic>{};
        final gids = <int>{
          for (final raw in (args['gids'] as List? ?? const <Object?>[]))
            if (raw is num) raw.toInt(),
        };
        unawaited(() async {
          Object? result;
          Object? error;
          try {
            if (id == null) throw const FormatException('refreshMany needs an id');
            await subscriptionEngine.refreshMany(
              gids,
              foreground: args['foreground'] == true,
            );
            result = <String, dynamic>{'ok': true, 'gids': gids.toList()};
          } catch (e) {
            error = e;
          } finally {
            if (id != null) {
              root.send(<String, dynamic>{
                'kind': 'commandResult',
                'id': id,
                if (error == null) 'result': result else 'error': '$error',
              });
            }
          }
        }());
      case 'subscription.create':
        // Awaitable like refreshMany: the editor blocks until validation and
        // the document edits finished, so it can show the refusal or close
        // with the real group id. Only the small editor payload crosses the
        // channel — BDUSS and other credentials never travel through here.
        final id = (message['id'] as num?)?.toInt();
        final args = message['args'] is Map
            ? Map<String, dynamic>.from(message['args'] as Map)
            : <String, dynamic>{};
        unawaited(() async {
          Object? result;
          Object? error;
          try {
            if (id == null) throw const FormatException('subscription.create needs an id');
            final created = await subscriptionEngine.create(
              SubscriptionCreateInput(
                name: '${args['name'] ?? ''}',
                url: '${args['url'] ?? ''}',
                subOptionsJson: '${args['subOptionsJson'] ?? '{}'}',
                autoUpdate: args['autoUpdate'] != false,
                foreground: args['foreground'] == true,
              ),
            );
            result = <String, dynamic>{
              'ok': true,
              'gid': created.gid,
              'name': created.name,
              'added': created.added,
              'reportText': created.reportText,
            };
          } catch (e) {
            error = e;
          } finally {
            if (id != null) {
              root.send(<String, dynamic>{
                'kind': 'commandResult',
                'id': id,
                if (error == null) 'result': result else 'error': '$error',
              });
            }
          }
        }());
    }
  });

  servicePort.listen((raw) async {
    final message = normalizePlatformValue(raw);
    if (message is! Map<String, dynamic>) return;
    final id = message['id'] as String?;
    final method = message['method'] as String?;
    final data = message['data'];
    if (id == null || method == null) return;

    Object? result;
    Object? error;
    try {
      switch (method) {
        case 'hello':
          final port =
              (data is Map<String, dynamic> ? data['port'] : null) as num?;
          if (port == null) throw const FormatException('hello is missing port');
          final resolved = resolveUi(port.toInt());
          if (resolved == null) {
            throw StateError('the UI port was not registered for $port');
          }
          uiPort = resolved;
          // The reply carries the engine's current status so a (re)connecting
          // proxy resyncs instead of trusting the last event of a previous
          // link (kernel_proxy reads `status` and `driverReady` off this map).
          // `driverReady` is the real FFI-attach state: a stale proxy must
          // release driver arbitration when a fresh engine has no driver.
          // The last dashboard rides along: events emitted before this hello
          // (an auto-start that already ran) had no port to reach.
          result = <String, dynamic>{
            'ok': true,
            'status': service.statusWire,
            'driverReady': service.driverReady,
            'dashboard': ?lastDashboard,
          };
        case 'start':
          await documentReadyForBuild();
          await service.startService();
          result = true;
        case 'stop':
          await service.stopService();
          result = true;
        case 'stopCore':
          await service.stopCoreFromHost();
          result = true;
        case 'reload':
          final reason =
              (data is Map<String, dynamic> ? data['reason'] : null) as String?;
          await documentReadyForBuild();
          await service.reloadService(reason: reason ?? 'reload');
          result = true;
        case 'updateWifiState':
          await service.updateWifiState();
          result = true;
        // The manual "Update resources" rule-set half (KernelProxy). A refusal
        // (no running instance) leaves this `case` as the ordinary error
        // envelope below, so the UI rebuilds the same typed exception.
        case 'updateRuleSets':
          result = await service.updateRuleSets();
        case 'kernelLogsVisible':
          // A screen opened: replay the ring as one snapshot (reset) and stream from here.
          // A screen closed: keep filling the ring, send nothing.
          final visible =
              (data is Map<String, dynamic> ? data['visible'] : null) == true;
          // The Go sink still forwards warn/error/fatal/panic with the stream
          // off; this only gates the lower levels. Serialised so a burst of
          // toggles cannot reorder and leave the sink on the wrong level.
          scheduleLogStream(visible);
          if (visible) {
            deliver(<String, dynamic>{
              'type': 'event',
              'value': <String, dynamic>{
                'type': 'kernelLogs',
                'value': <String, dynamic>{
                  'payload': kernelRing.join('\n'),
                  'reset': true,
                },
              },
            });
          }
          result = true;
        case 'action':
          // The UI packs the caller's budget alongside the Action wire, so a
          // 40 s route test is not cut short by the service engine's own
          // default. The Go action JSON is untouched — only this transport
          // envelope carries the timeout. An older peer's bare wire falls
          // back to the default.
          final unpacked = unpackActionEnvelope(data);
          result = await service.invokeActionWire(
            unpacked.wire,
            timeout: unpacked.timeout,
          );
        case 'setMode':
          final mode =
              (data is Map<String, dynamic> ? data['mode'] : null) as String?;
          if (mode == null) throw const FormatException('setMode is missing mode');
          await documentReadyForBuild();
          await service.setMode(mode);
          result = true;
        case 'onSelectionChanged':
          await documentReadyForBuild();
          await service.onSelectionChanged();
          result = true;
        default:
          throw UnsupportedError('unknown kernel IPC method: $method');
      }
    } catch (e) {
      error = e;
    }
    final envelope = <String, dynamic>{'id': id};
    if (error == null) {
      envelope['result'] = result;
    } else {
      // One envelope for every failure shape: `kind: unanswered` when nothing
      // answered (the UI keeps the start button optimistic), the kernel's
      // `core_<n>` code plus the handler's payload when the core refused. A
      // string alone could not carry that split — an older peer sent a bare
      // `kind: 'failed'`, which the proxy still reads as a refusal.
      envelope.addAll(coreErrorEnvelope(error));
    }
    deliver(<String, dynamic>{'id': id, 'result': envelope});
  });

  // Best-effort: attach the FFI driver on engine start. When the library is
  // absent the service stays in channel mode and every control request simply
  // falls through to the host, so the app remains usable.
  try {
    await service.initialize();
  } catch (error) {
    debugPrint('kernelWorker: kernel driver unavailable: $error');
  }
  // Report the outcome to the host so FlroneKernel.ffiMode reflects a real FFI
  // attach, not the engine's existence (the two only match when libthrone.so
  // loaded and a worker was spawned).
  await pushDriverReady();
  // S8: a document op can arrive before initialize() finished, so the lazy
  // legacy Xray row scan may have found no action bus. Retry once the driver is
  // attached; the scan reads the marker and does nothing when the earlier run
  // succeeded (or the document has no old rows).
  unawaited(documentOwner.ensureLegacyXrayMigration(force: true).then(
    (outcome) {
      if (outcome.migrated > 0) {
        debugPrint('kernelWorker: migrated ${outcome.migrated} legacy Xray rows');
      }
    },
    onError: (Object error) {
      debugPrint('kernelWorker: legacy Xray migration could not run: $error');
    },
  ));
  // ...and to the UI over IPC. A hello handled before initialize() finished
  // stored driverReady=false as authoritative; without this push the proxy
  // would stay in channel mode for the life of the link, writing selection and
  // mode changes to the channel while this isolate drives the core over FFI.
  deliver(<String, dynamic>{
    'type': 'event',
    'value': <String, dynamic>{
      'type': 'driverReady',
      'value': service.driverReady,
    },
  });

  // The service engine owns the tunnel: a start requested by the UI, a tile, a
  // widget, always-on VPN or the boot receiver all arrive here with no other
  // Dart side to drive the core. Bring it up from the persisted selection. The
  // short delay lets BaseService finish registering the VpnService before the
  // kernel asks for its tun. A pre-warm engine ([ServiceEngineManager.ARG_PREWARM])
  // must stay idle — its real start arrives later over IPC/startKernel.
  if (!args.contains('prewarm')) {
    Future<void>.delayed(const Duration(milliseconds: 300), () async {
      try {
        await documentReadyForBuild();
        await service.startService();
      } catch (error) {
        debugPrint('kernelWorker: automatic start failed: $error');
        deliver(<String, dynamic>{
          'type': 'event',
          'value': <String, dynamic>{'type': 'error', 'value': '$error'},
        });
      }
    });
  }

  // The UI engine can no longer open the native logs port itself; forward kernel
  // log lines as IPC events so the log screen keeps working.
  //
  // Lines travel as ONE encoded string per batch (`receivedAt\tlevel\tmessage`
  // joined by newlines), not as a list of maps: a map per line is copied key by key
  // across the isolate boundary, and a start emits hundreds of them at once. The UI
  // splits the payload in a single pass, which is also the only decode it needs.
  //
  // And nothing crosses at all while no screen is watching ([setKernelLogsVisible]):
  // the ring below keeps the tail, so opening the log screen replays it — a start's
  // burst costs the UI isolate nothing until somebody looks.
  Timer? logTimer;
  void flushLogs() {
    logTimer = null;
    if (pendingLogs.isEmpty) return;
    final payload = pendingLogs.join('\n');
    pendingLogs.clear();
    deliver(<String, dynamic>{
      'type': 'event',
      'value': <String, dynamic>{
        'type': 'kernelLogs',
        'value': <String, dynamic>{'payload': payload, 'reset': false},
      },
    });
  }

  /// One line of the wire: the arrival instant, the level word and the text, with the
  /// text flattened so a stray newline cannot split a record.
  String encodeKernelLine(Map<String, dynamic> line) =>
      '${DateTime.now().millisecondsSinceEpoch}'
      '\t${line['level'] ?? ''}'
      '\t${(line['message']?.toString() ?? '').replaceAll('\n', ' ')}';

  final attached = service.attached;
  StreamSubscription<dynamic>? logSub;
  if (attached is ThroneKernel) {
    logSub = attached.logs.listen((line) {
      final encoded = encodeKernelLine(line);
      kernelRing.add(encoded);
      if (kernelRing.length > logRingLimit) {
        kernelRing.removeRange(0, kernelRing.length - logRingLimit);
      }
      if (!kernelLogsWanted) return;
      pendingLogs.add(encoded);
      if (pendingLogs.length >= maxKernelLogBatchLines) {
        logTimer?.cancel();
        flushLogs();
      } else {
        logTimer ??= Timer(logBatchWindow, flushLogs);
      }
    }, onError: (error) {
      debugPrint('kernelWorker: kernel log stream error: $error');
    });
  }

  // kernelWorker runs for the lifetime of the app; keep the subscriptions live.
  // (Retained in locals so the analyzer does not flag them as unused.)
  assert(() {
    debugPrint('kernelWorker: subscriptions ${eventSub.isPaused} / ${logSub != null}');
    return true;
  }());
}

/// The kernel isolate's door to the platform.
///
/// The `io.flrone/service` channel lives in the root isolate (the embedding only
/// answers channels on the platform thread), so every host call is one port
/// message there and back. The request/response shape matches the UI's IPC, so
/// the callers' timeouts and failure classification behave as before.
class KernelWorkerHost implements KernelHost {
  KernelWorkerHost(this._root);

  final SendPort _root;
  final Map<int, Completer<dynamic>> _pending = <int, Completer<dynamic>>{};
  int _nextId = 0;

  @override
  Map<String, dynamic> dashboard = <String, dynamic>{};

  @override
  List<Map<String, dynamic>> configurations = const <Map<String, dynamic>>[];

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? args]) {
    final id = ++_nextId;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    try {
      _root.send(<String, dynamic>{
        'kind': 'host',
        'id': id,
        'method': method,
        'args': args,
      });
    } catch (error) {
      _pending.remove(id);
      completer.completeError(StateError('the host is gone: $error'));
    }
    return completer.future;
  }

  /// Answers one [call]. A reply for a request that already timed out is dropped.
  void complete(Map<String, dynamic> message) {
    final id = (message['id'] as num?)?.toInt();
    if (id == null) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    final error = message['error'];
    if (error != null) {
      completer.completeError(StateError('$error'));
    } else {
      completer.complete(message['result']);
    }
  }
}
