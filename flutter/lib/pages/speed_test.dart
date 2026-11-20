import 'dart:async';
import 'dart:math' as math;

import '../widgets.dart';
import '../components/data_subscription.dart';
import '../components/speed_gauge.dart';
import '../components/speed_outbound_card.dart';
import '../components/speed_test_settings.dart';
import '../services/speed_test_history.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

/// The kernel's speed test, laid out the way Bettbox's screen lays it out: the
/// outbound card, then the gauge with the start button and the phase steps, the
/// throughput curves, the result tiles, and the credit line.
///
/// Everything measured comes from the kernel (`core/mobile/speedtest.go`):
/// `start` returns at once and this page polls `query` while the test runs, so
/// the numbers are the core's own samples rather than a UI reconstruction.
class SpeedTestPage extends ConsumerStatefulWidget {
  const SpeedTestPage({
    super.key,
    this.outbound,
    this.download = true,
    this.upload = true,
  });

  /// The outbound the run measures through; null keeps the stored choice (and
  /// the box's default outbound when none was stored).
  final String? outbound;

  /// Which directions the run measures. The node card's submenu narrows one;
  /// the screen's own start button asks for both.
  final bool download;
  final bool upload;

  @override
  ConsumerState<SpeedTestPage> createState() => _SpeedTestPageState();
}

/// TestSpec.KIND_SPEED: the native session's speed run.
const _kindSpeed = 2;

/// TestUiState's speed modes (TestUiState.SPEED_MODE_*): FULL=0, DOWNLOAD=1,
/// UPLOAD=2, SIMPLE_DOWNLOAD=3, COUNTRY=4; -1 follows the Testing setting.
/// The screen used 0/1 for the two single-direction modes, so "download only"
/// asked the engine for a full run and "upload only" asked for download only.
const _speedModeDownloadOnly = 1;
const _speedModeUploadOnly = 2;

/// The reason a ended session's rows carry, or null when they name none.
///
/// `TestSessionModel` reports a profile the engine never measured as aborted and
/// keeps the engine's own text on the row (`TestSession.notMeasured`), while the
/// session's `failure` is only the coarse enum. The bare abort markers name no
/// cause — "test aborted" is the word for "stopped" — so they are skipped, and
/// "aborted: instance is not running" keeps what actually happened.
String? speedTestRowReason(Json session) {
  for (final row in rows(session['rows'])) {
    final reason = '${row['error'] ?? ''}'.trim();
    if (reason.isEmpty) continue;
    final lower = reason.toLowerCase();
    if (lower == 'test aborted' || lower == 'aborted') continue;
    if (lower == 'context canceled' || lower == 'context cancelled') continue;
    return reason;
  }
  return null;
}

class _SpeedTestPageState extends ConsumerState<SpeedTestPage>
    with SingleTickerProviderStateMixin {
  SpeedTestSettings _settings = const SpeedTestSettings();
  String _outbound = '';
  List<String> _outbounds = const [];
  /// The outbound picker's list with the ids that go on the wire: `groups.nodes`
  /// answers `{id, tag}` per node, and the engine needs the ProxyEntity id — the
  /// dashboard's `selectedProfileId` is a *group* id and measures nothing.
  List<Json> _nodes = const [];
  bool _savedRecord = false;
  /// The finished session's stamp seen when this run began. The host re-emits the
  /// last session when the feed subscribes, so a wire stamped at or before this
  /// still describes the previous run and must be ignored.
  int _startedFrom = 0;
  /// This run's wall-clock start, for a replay that arrives after the start call
  /// returned without the host having published the old session first.
  int _startWall = 0;
  /// The session the box already held at [_start]: the feed replaying exactly
  /// that wire is never this run, even when it carries no stamp.
  String _baseline = '';

  Json _state = const {};
  bool _running = false;
  bool _starting = false;
  String? _error;
  Timer? _poll;
  /// The one-wire wait for the row that names a failed run (see [_awaitReason]).
  Timer? _reasonWait;
  VoidCallback? _reasonCheck;
  BoxController? _reasonBox;
  /// The box this page subscribed to, kept for dispose() (see _pollSession).
  BoxController? _box;
  StreamSubscription<Map<String, dynamic>>? _pushSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    // Leaving mid-run is the common case (the spinner is up), and the box is a
    // shared, long-lived controller: a listener left behind here is invoked on
    // every notification for the rest of the process. _stopFollowing also
    // cancels the poll and the push subscription, and is idempotent.
    _stopFollowing();
    _cancelReasonWait();
    super.dispose();
  }

  Future<void> _load() async {
    final box = ref.read(boxControllerProvider);
    final stored = box.preferences;
    setState(() {
      _settings = SpeedTestSettings.fromJson(stored);
      _outbound = widget.outbound ?? stored['speedTestOutbound']?.toString() ?? '';
    });
    try {
      // The node list comes from the same catalog the rule editor's outbound
      // picker reads, so there is one source for "what can be measured". The ids
      // stay alongside the tags: the session start takes node ids.
      final nodes = await box.groupNodes();
      if (mounted) {
        setState(() {
          _nodes = nodes;
          _outbounds = [for (final node in nodes) '${node['tag']}'];
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = BoxController.describe(error));
    }
  }

  void _persist() {
    ref.read(boxControllerProvider).setPreferences({
      ..._settings.toPreferences(),
      'speedTestOutbound': _outbound,
    });
  }

  /// The arguments the `speedTestSessionStart` bus action takes for a speed run.
  ///
  /// `kind` is TestSpec.KIND_SPEED; `speedMode` is one of TestUiState's
  /// SPEED_MODE_* values, and follows the Testing settings (-1) unless the node
  /// card narrowed the run to one direction.
  Map<String, dynamic> _sessionArgs() {
    final ids = _measureIds;
    if (ids.isEmpty) {
      // Nothing names a profile, so the run measures the running connection —
      // upstream's startCurrent(KIND_SPEED) (F6). TestSessionClient ignores the
      // ids of a test-current spec ("the id only keys the row"), so the
      // dashboard's selection rides along as that key and is never resolved.
      final key = ref.read(boxControllerProvider).selectedProfileId;
      return {
        'kind': _kindSpeed,
        'profileIds': [if (key > 0) key],
        'testCurrent': true,
        'speedMode': _speedMode,
      };
    }
    return {
      'kind': _kindSpeed,
      'profileIds': ids,
      'testCurrent': false,
      'speedMode': _speedMode,
    };
  }

  /// The mode the run asks the engine for: one of TestUiState's SPEED_MODE_*
  /// values, or -1 to follow the Testing setting.
  ///
  /// The node card's menu narrows the run to one direction and outranks the
  /// stored choice; otherwise the settings dialog's direction answers, and
  /// "both" follows the Testing setting.
  int get _speedMode => !widget.upload
      ? _speedModeDownloadOnly
      : !widget.download
      ? _speedModeUploadOnly
      : _settings.speedMode;

  /// The node ids the run measures, in the order that keeps it meaningful.
  ///
  /// 1. the node the caller named (`widget.outbound`, passed by the node card or
  ///    picked on this screen), matched by tag and then by id against
  ///    `groups.nodes`;
  /// 2. the selected node of the group the screen measures through
  ///    (`group['selectedId']` in `box.groups`);
  /// 3. nothing — [SpeedTestPage] then starts a test-current session, which is
  ///    what upstream's `MainActivity` F6 does (`startCurrent(KIND_SPEED)`).
  ///
  /// The order exists because the dashboard's `selectedProfileId` is not a node
  /// id: `ThroneBoxBridge.dashboardWire` sets it to `BboxCatalog.selectedGroupId`
  /// (a group id), and `TestSession.resolve()` reads it with
  /// `ProfileManager.getProfiles`, which finds no row — the engine then measured
  /// nothing at all and the screen spun until the page was closed.
  ///
  /// `DIRECT` is not a node either: the picker's Direct entry measures the
  /// running connection, so it resolves to no id rather than to some node whose
  /// tag happens to be left over.
  List<int> get _measureIds {
    final named = _outbound.trim();
    // DIRECT is not a proxy row: the picker's Direct entry measures whatever the
    // running box dials, which is a test-current session.
    if (named == 'DIRECT') return const [];
    if (named.isNotEmpty) {
      for (final node in _nodes) {
        if ('${node['tag']}'.trim() != named) continue;
        final id = (node['id'] as num?)?.toInt() ?? 0;
        if (id > 0) return [id];
      }
      // The card hands over the tag; a caller that read the id instead keeps
      // working as long as the catalog knows that row.
      final byId = int.tryParse(named);
      if (byId != null &&
          byId > 0 &&
          _nodes.any((node) => (node['id'] as num?)?.toInt() == byId)) {
        return [byId];
      }
    }
    final selected = _selectedNodeId;
    return selected > 0 ? [selected] : const [];
  }

  /// The selected node of the group the screen measures through.
  ///
  /// `box.groups` carries `selectedId` per group (`BboxGroupsWire`), which is a
  /// real ProxyEntity id. The group whose selection is the named node wins, then
  /// one whose rows contain it, then the first group that has a selection.
  int get _selectedNodeId {
    Json? fallback;
    final named = _outbound.trim();
    for (final group in ref.read(boxControllerProvider).groups) {
      final id = (group['selectedId'] as num?)?.toInt() ?? 0;
      if (id <= 0) continue;
      fallback ??= group;
      if (named.isEmpty) continue;
      if ('${group['selected'] ?? ''}'.trim() == named) return id;
      for (final node in rows(group['items'])) {
        if ('${node['tag']}'.trim() != named) continue;
        if ((node['id'] as num?)?.toInt() == id) return id;
      }
    }
    return (fallback?['selectedId'] as num?)?.toInt() ?? 0;
  }

  Future<void> _start() async {
    if (_starting || _running) return;
    // This run's verdict replaces whatever the previous one left behind, so a
    // wait for its late reason is over.
    _cancelReasonWait();
    // The host re-emits the last session whenever the feed subscribes. Remember
    // where the previous run began so its wire cannot pass for this run's; the
    // wall-clock stamp and the payload itself cover a replay the host publishes
    // after the start call re-subscribes the feed, before this run's own
    // startedAt can be told apart.
    final held = ref.read(boxControllerProvider).testSession;
    _startedFrom = (held['startedAt'] as num?)?.toInt() ?? 0;
    _baseline = held.isEmpty ? '' : _identity(held);
    _startWall = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _starting = true;
      _error = null;
      _savedRecord = false;
    });
    try {
      // Throne's own test session: TestEngine runs SpeedTestRunner against the
      // started profile, and the progress arrives as the same `testSession`
      // event the batch panel draws.
      final started = await ref.read(boxControllerProvider).groupTestSessionStartChecked(_sessionArgs());
      if (!mounted) return;
      if (!started) {
        // `act` answers the host's boolean verdict as-is, and reports the exception
        // itself when the call threw — so "a session is running" and "the start
        // failed" both arrive here as false. The session the box holds is what
        // separates them: a refused start leaves the running session in place, a
        // start that threw leaves none. An empty wire (none ever published) carries
        // no distinction, so the busy verdict stands there.
        final held = ref.read(boxControllerProvider).testSession;
        final busy = held['running'] == true || held.isEmpty;
        setState(() {
          _starting = false;
          // A refused start measured nothing, but the previous run's figures stay
          // readable; only the verdict line changes.
          _error = busy
              ? context.tr('A speed test is already running')
              : context.tr('Start failed');
        });
        return;
      }
      setState(() {
        _starting = false;
        _running = true;
      });
      _pollSession();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = BoxController.describe(error);
      });
    }
  }

  /// One relay tick of the host's `testSession` feed: it publishes what changed
  /// every 400 ms, so a verdict written between two frames reaches the page on the
  /// next one. [_awaitReason] waits two of these before giving up on a late row.
  static const _relayTick = Duration(milliseconds: 450);

  /// Subscribes to the test session.
  ///
  /// The session pushes a `testSession` event while it runs and one more when it
  /// finishes, so this follows the event bus the rest of the app already listens
  /// on — no polling, and no second progress channel.
  void _pollSession() {
    _poll?.cancel();
    _poll = null;
    _pushSub?.cancel();
    _pushSub = null;
    final box = ref.read(boxControllerProvider);
    // Kept so dispose() can unsubscribe: looking an ancestor up in dispose() is
    // not allowed ("Looking up a deactivated widget's ancestor is unsafe").
    _box = box;
    _applySession(box.testSession);
    box.addListener(_onBoxChanged);
  }

  /// The `testSession` map last handed to [_applySession].
  Json? _lastSession;

  void _onBoxChanged() {
    if (!mounted) return;
    final session = _box?.testSession ?? ref.read(boxControllerProvider).testSession;
    // `box.addListener` fires for every aspect — the 1 Hz rates push, the 300 ms log and
    // connection batches, memory trims. Only `testSession` matters here, and the controller
    // replaces that map on every session event while other events leave it identical, so an
    // identity check is enough to skip the rest: this was ~2.5-4 full-page setStates a
    // second during a run, of which about a quarter were real.
    if (identical(session, _lastSession)) return;
    _lastSession = session;
    _applySession(session);
  }

  void _stopFollowing() {
    _pushSub?.cancel();
    _pushSub = null;
    _poll?.cancel();
    _poll = null;
    // Only ever unsubscribe from the box we subscribed to. Touching `context`
    // here would be unsafe from dispose(), and there is nothing to remove when
    // _pollSession never ran.
    _box?.removeListener(_onBoxChanged);
  }

  /// Whether [session] still describes the run that finished before this one.
  ///
  /// The host replays the last session whenever the feed subscribes, and the page
  /// also reads `box.testSession` the moment it starts following — so the previous
  /// run's finished wire arrives as if it were this run's: the screen showed
  /// "Complete" instantly, stopped following and wrote a history record for a run
  /// it never saw. [TestSessionModel] stamps `startedAt` when a session is created
  /// and `BboxTestSessions.wire` carries it, which is what identifies the session.
  ///
  /// Only a *closed* wire (not running, or its last frame marked finished) is
  /// judged: dropping a live one could leave the spinner up, which is the failure
  /// this guard exists to prevent, and a finished session never emits live frames.
  /// A closed wire is the previous run when its stamp is the one the box still
  /// held when this run began (the replay case), or — with no session held — when
  /// it predates this run's own wall-clock start.
  bool _staleSession(Json session) {
    if (session.isEmpty) return false;
    final live = json(session['speed']);
    final stage = '${live['stage'] ?? ''}';
    final closed =
        session['running'] == false ||
        live['finished'] == true ||
        stage == 'complete' ||
        stage == 'error' ||
        stage == 'cancelled';
    if (!closed) return false;
    // The exact wire the box already held when this run began: the feed replaying
    // it is the previous run whatever its stamp says (an older host sends none).
    if (_baseline.isNotEmpty && _identity(session) == _baseline) return true;
    final startedAt = (session['startedAt'] as num?)?.toInt() ?? 0;
    if (startedAt <= 0) return false;
    if (_startedFrom > 0) return startedAt <= _startedFrom;
    return _startWall > 0 && startedAt < _startWall;
  }

  /// Applies the session's current speed snapshot.
  ///
  /// The native snapshot carries the live rates, the ping and the samples; the
  /// page's widgets were written against the Bettbox state's names, so this maps
  /// between them and leaves the fields the native run does not measure at zero.
  void _applySession(Json session) {
    if (!mounted) return;
    if (_staleSession(session)) return;
    final speed = json(session['speed']);
    if (speed.isEmpty) {
      _applyClosedSession(session);
      return;
    }
    final stage = '${speed['stage'] ?? ''}';
    final failure = '${speed['error'] ?? ''}'.trim();
    // The session envelope can close a run the live frame does not describe:
    // TestSessionModel.finish sets `cancelled`/`failure` on the state and leaves
    // the engine's last live stage as it was, so a stopped run would otherwise
    // read as "download finished" and be recorded.
    final closed = session['running'] == false;
    final stopped =
        speed['cancelled'] == true ||
        stage == 'cancelled' ||
        (closed && session['cancelled'] == true);
    final failed = stage == 'error' || failure.isNotEmpty;
    final finished = speed['finished'] == true || stopped || failed || stage == 'complete';
    // The row is where a profile the engine never measured says why
    // (`TestSession.notMeasured` prefixes its reason). It outranks the page's own
    // "cancelled" verdict: "aborted: instance is not running" names what happened,
    // while "Cancelled" describes a stop nobody asked for.
    final reason = speedTestRowReason(session);
    final mapped = <String, dynamic>{
      'phase': _phaseOf(stage, finished),
      'download': (speed['dlBps'] as num? ?? 0).toDouble(),
      'upload': (speed['ulBps'] as num? ?? 0).toDouble(),
      'latency': (speed['pingMs'] as num? ?? 0).toDouble(),
      'server': _serverOf(speed),
      'outbound': speed['name'],
      'downloadCurve': _curveOf(speed['samples'], upload: false),
      'uploadCurve': _curveOf(speed['samples'], upload: true),
      // `cancelled` is the page's own verdict code; the build translates it.
      if (stopped) 'error': reason ?? 'cancelled'
      else if (failure.isNotEmpty) 'error': failure
      else if (failed && reason != null) 'error': reason,
    };
    setState(() {
      _state = mapped;
      _running = !finished;
    });
    // A run that failed or was stopped measured nothing worth recording: the
    // history would show a row of zeros the user cannot tell from a dead link.
    if (stopped) {
      // `TestSessionModel.finish` keeps `cancelled` and the failure verdict on
      // the same state: a stop the user asked for ends `NONE`, while a session
      // the host tore down (an unreachable or dead core, a busy tester) carries
      // the verdict — and that verdict, not "Cancelled", is what happened.
      _failSession(
        'cancelled',
        text:
            reason ??
            (_sessionFailure(session) != 'NONE'
                ? _failureText('', session)
                : context.tr('Cancelled')),
      );
    } else if (failed) {
      // The live frame's code wins when it has one (the build translates it); with
      // none, the row's own reason is the sentence and the verdict is the fallback.
      _failSession(
        failure,
        text: failure.isEmpty ? reason ?? _failureText('', session) : null,
      );
      if (failure.isEmpty && _needsReason(session)) _awaitReason();
    } else if (finished) {
      _finishSession();
    } else if (closed) {
      // A closed envelope whose frame never said finished had no result to keep
      // (`TestSessionModel.finish` marks the live state finished, so this is a
      // run that died mid-way). It ends the spinner without a record.
      _failSession(
        failure,
        text: reason ?? _failureText(failure, session),
      );
      if (_needsReason(session)) _awaitReason();
    }
  }

  /// Whether [session] ended without naming why: neither the live frame's code
  /// nor the failure verdict nor a row carries a reason.
  bool _needsReason(Json session) =>
      '${json(session['speed'])['error'] ?? ''}'.trim().isEmpty &&
      _sessionFailure(session) == 'NONE' &&
      speedTestRowReason(session) == null;

  /// The session's failure verdict (`TestFailure`), `NONE` when it ended clean.
  String _sessionFailure(Json session) =>
      '${session['failure'] ?? 'NONE'}';

  /// The message for a run that ended without a measurement.
  ///
  /// The kernel's own code (`timeout`, `unavailable`, …) is left to the build's
  /// translation table; a session that failed before any probe answered only
  /// carries the enum, so its verdict names the outcome in the user's words —
  /// the same five sentences the batch panel prints.
  String? _failureText(String failure, Json session) {
    if (failure.isNotEmpty) return null;
    return switch (_sessionFailure(session)) {
      'EMPTY' => context.tr('Nothing to test'),
      'BUSY' => context.tr('A test is already running'),
      'UNREACHABLE' => context.tr('The core service is unreachable'),
      'CORE_DIED' => context.tr('The core service died'),
      _ => context.tr('The test did not finish'),
    };
  }

  /// A session the host closed without ever producing a live snapshot.
  ///
  /// `BboxTestSessions.wire` reports a run that ended before any probe answered —
  /// an empty scope (`EMPTY`), a busy tester, an unreachable or dead core — as
  /// `running: false` with `speed: null`. The page returned early on the missing
  /// snapshot, so `_running` stayed true and the spinner never stopped.
  void _applyClosedSession(Json session) {
    // Only a run this page started can end here; a session the panel left
    // behind must not put its verdict on a screen nobody tested from.
    if (!_running && !_starting) return;
    final kind = (session['kind'] as num?)?.toInt() ?? -1;
    // No session at all, or the panel's latency/IP session: not this run. The
    // host replaying an idle state right after the start must not end it.
    if (kind != _kindSpeed) return;
    if (session['running'] != false) return;
    final verdict = _sessionFailure(session);
    // The rows are where a run that measured nothing says why: the engine's own
    // text rides on the row it reported against (`TestSession.notMeasured`), while
    // the envelope's `failure` is only the coarse enum — and `finish` also ends a
    // stopped or mid-way run with `failure: NONE`. The row name is the sentence;
    // the enum, then the page's own two defaults, are the fallbacks.
    final reason = speedTestRowReason(session);
    final stopped = session['cancelled'] == true;
    final text =
        reason ??
        (verdict != 'NONE'
            ? _failureText('', session)
            : context.tr(stopped ? 'Cancelled' : 'The test did not finish'));
    // Nothing was measured, so the tiles go back to "—" rather than showing the
    // last run's figures under this one's verdict. A stop keeps them: the run it
    // interrupted may still have said something worth reading.
    _failSession(
      stopped ? 'cancelled' : '',
      text: text,
      reset: !stopped,
    );
    // Neither a row name nor a verdict: the 400 ms relay caught the session
    // between the engine's verdict and the row it writes, so the reason is one
    // tick away. It is picked up rather than left as the generic sentence.
    if (reason == null && verdict == 'NONE' && !stopped) _awaitReason();
  }

  /// Picks up the row that names a failure a relay tick after the verdict.
  ///
  /// `ThroneBoxBridge.setTestSessionVisible` publishes the client's model every
  /// 400 ms, and `SpeedTestRunner` reports the live snapshot (which already says
  /// `stage: error`) just before the result that writes the row's `error`. A
  /// closed envelope relayed in between therefore has the verdict but not its
  /// text, and the page has stopped following by then. It keeps listening for the
  /// next session update instead, and replaces the generic sentence once a row
  /// names the cause; the deadline is two ticks, after which the host is not going
  /// to write one.
  void _awaitReason() {
    _cancelReasonWait();
    final box = ref.read(boxControllerProvider);
    _reasonBox = box;
    void check() {
      // A run started in the meantime owns the screen: its verdict is not this
      // one's, and the bar must not be repainted with a previous run's reason.
      if (!mounted || _running || _starting) {
        _cancelReasonWait();
        return;
      }
      final reason = speedTestRowReason(box.testSession);
      if (reason == null) return;
      _cancelReasonWait();
      setState(() {
        _state = {..._state, 'error': reason};
        _error = reason;
      });
    }

    _reasonCheck = check;
    box.addListener(check);
    _reasonWait = Timer(_relayTick * 2, _cancelReasonWait);
  }

  /// Stops waiting for a late reason, if one is being waited for.
  void _cancelReasonWait() {
    _reasonWait?.cancel();
    _reasonWait = null;
    final check = _reasonCheck;
    _reasonCheck = null;
    if (check != null) _reasonBox?.removeListener(check);
    _reasonBox = null;
  }

  /// The fields that tell one session's wire from another's.
  String _identity(Json session) => [
    session['startedAt'] ?? '',
    session['finishedAt'] ?? '',
    session['running'] ?? '',
    session['failure'] ?? '',
    session['cancelled'] ?? '',
    (json(session['speed'])['stage']) ?? '',
  ].join('|');

  /// The provider's server, as the outbound card's map.
  ///
  /// The kernel's live snapshot carries `server` (the provider's own name) and
  /// `serverCountry` as two strings, while the card reads a
  /// `{country, city, colo, sponsor, host}` map — passing the string through
  /// printed the first character of it as a "country". The name is the host and
  /// the country its own field; the history stores the same map.
  Map<String, String> _serverOf(Json speed) {
    final host = '${speed['server'] ?? ''}'.trim();
    final country = '${speed['serverCountry'] ?? ''}'.trim();
    return {
      if (country.isNotEmpty) 'country': country,
      if (host.isNotEmpty) 'host': host,
    };
  }

  /// The Bettbox phase names the widgets know, from the native stage.
  String _phaseOf(String stage, bool finished) {
    if (finished) return 'done';
    return switch (stage) {
      'discovery' || 'latency' => 'latency',
      'download' => 'download',
      'upload' => 'upload',
      _ => stage.isEmpty ? 'connecting' : 'connecting',
    };
  }

  /// One curve's points: the samples carry [t, bps, isUpload].
  List<double> _curveOf(dynamic samples, {required bool upload}) {
    if (samples is! List) return const [];
    return [
      for (final sample in samples)
        if (sample is List && sample.length >= 3 && (sample[2] == true) == upload)
          (sample[1] as num? ?? 0).toDouble(),
    ];
  }

  /// Stops following and records the run once.
  void _finishSession() {
    _stopFollowing();
    if (!mounted) return;
    setState(() => _running = false);
    // A finished run is a record, once. The feed can replay the final wire (a
    // re-subscribe, a restart), so the guard covers both that and the start path.
    if (!_savedRecord) {
      _savedRecord = true;
      _recordRun();
    }
  }

  /// Stops following and shows [error], or [text] when the run has no code.
  ///
  /// [text] is already localized; [error] is the kernel's code and goes through
  /// the page's own translation table at build time. [reset] drops the previous
  /// run's figures for a session that never measured anything, so the tiles read
  /// "—" instead of the last run's numbers. Nothing is recorded either way: a
  /// failed, cancelled or empty run has no measurement to keep.
  void _failSession(Object error, {String? text, bool reset = false}) {
    _stopFollowing();
    if (!mounted) return;
    setState(() {
      _running = false;
      if (reset) _state = const {'phase': 'done'};
      _error = text ?? BoxController.describe(error);
    });
  }

  /// Appends the finished run to the stored history.
  Future<void> _recordRun() async {
    final box = ref.read(boxControllerProvider);
    try {
      await appendSpeedTestRecord(
        SpeedTestRecord.fromState(
          _state,
          time: DateTime.now().millisecondsSinceEpoch,
          proxy: _outbound,
        ),
        read: () => readSpeedTestHistory(box),
        write: (records) => writeSpeedTestHistory(box, records),
      );
    } catch (error) {
      // A history write is not worth failing the screen over.
      box.report(error);
    }
  }

  Future<void> _cancel() async {
    // Read before the await: no BuildContext crosses the async gap.
    final box = ref.read(boxControllerProvider);
    try {
      await box.groupTestSessionStop();
    } catch (error) {
      box.report(error);
    }
    _stopFollowing();
    if (mounted) setState(() => _running = false);
  }

  Future<void> _openSettings() async {
    final saved = await showSpeedTestSettings(context, _settings);
    if (saved == null || !mounted) return;
    setState(() => _settings = saved);
    _persist();
  }

  Future<void> _openHistory() async {
    await showSpeedTestHistory(context, box: ref.read(boxControllerProvider));
    if (mounted) setState(() {});
  }

  Future<void> _pickOutbound() async {
    // A single-choice list is a titled option sheet in Prism: the value is the
    // outbound tag ('' follows the box's default), the sheet keeps its typing,
    // marks the current choice, and scrolls when the catalog is long.
    final picked = await showOptionSheet<String>(
      context: context,
      title: context.tr('Outbound'),
      selected: _outbound,
      options: [
        ('', context.tr('The selected outbound')),
        ('DIRECT', context.tr('Direct')),
        for (final tag in _outbounds) (tag, tag),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() => _outbound = picked);
    _persist();
  }

  /// The phase the gauge and the step row read, from the kernel's `phase`.
  String? get _phase {
    final phase = _state['phase']?.toString() ?? '';
    if (phase.isEmpty) return null;
    return phase;
  }

  bool get _finished =>
      !_running &&
      _state.isNotEmpty &&
      (_phase == 'done' || (_state['error']?.toString() ?? '').isNotEmpty);

  double get _gaugeValue {
    final phase = _phase;
    // The kernel's snapshot has no single "speed" field: a live run reports
    // dlBps/ulBps and the phase says which one the gauge shows. Reading one
    // shared key here left the needle at 0 for the whole run.
    if (phase == 'download') return (_state['download'] as num? ?? 0).toDouble();
    if (phase == 'upload') return (_state['upload'] as num? ?? 0).toDouble();
    if (phase == 'done') return (_state['download'] as num? ?? 0).toDouble();
    return 0;
  }

  bool get _hasValue =>
      _phase == 'download' || _phase == 'upload' || _phase == 'done';

  /// One of the kernel's curve series (byte/s per sample), as the chart wants.
  List<double> _curve(String key) => [
    for (final value in _state[key] as List? ?? const [])
      (value as num).toDouble(),
  ];

  bool get _connecting => _starting || (_running && !_hasValue);

  /// The gauge's caption: what the run is doing, in one word.
  String get _readoutLabel {
    if (_connecting) return context.tr('Connecting');
    final phase = _phase;
    return switch (phase) {
      null => context.tr('Ready'),
      'done' => context.tr('Complete'),
      'upload' => context.tr('Upload'),
      'download' => context.tr('Download'),
      _ => context.tr('Ready'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    // The core can start or stop while this sheet is open; the cached read at _load time
    // would keep saying "core stopped" for the rest of the visit.
    final box = ref.watchBoxState();
    // A run needs the core up: the tester dials through the instance's own
    // outbound, so with the VPN stopped there is nothing to measure through.
    final coreRunning = box.running;
    // The gauge and result tiles show one value at a time, so they keep reading
    // one accent at two strengths (surfaces.md). The two overlapping curves use
    // two distinct hues instead: their legend and the painter take the same pair.
    final second = secondSeriesColor(context);
    final series = speedSeriesColors(context);
    // Converted once per build: the SpeedCurves call used to run `_curve()` four times
    // (two per direction) for the same two lists, doubling the allocation of every sample
    // on a page that rebuilds on each session relay.
    final downloadCurve = _curve('downloadCurve');
    final uploadCurve = _curve('uploadCurve');
    final error = _state['error']?.toString() ?? _error ?? '';
    final isUpload = _phase == 'upload';
    final gaugeColor = isUpload ? second : scheme.primary;
    final errorText = error.isEmpty
        ? null
        : switch (error) {
            'cancelled' => context.tr('Cancelled'),
            // `blocked` now means one thing only: the provider answered with a
            // status that refuses the request (a 4xx upload, a non-200
            // download, a trace without an exit IP). "The endpoint is blocked"
            // read as "your network is being censored" and sent users after a
            // firewall that did not exist whenever a provider simply timed out;
            // those runs report `timeout`/`unavailable` now.
            'blocked' => context.tr('The test endpoint refused the request'),
            'rejected' => context.tr('The selected outbound rejects traffic'),
            'timeout' => context.tr('The test timed out'),
            'unavailable' => context.tr('The test endpoint is unavailable'),
            _ => error,
          };
    // The host only relays `testSession` while the session data is subscribed:
    // without this the page's read of `box.testSession` would never change, no
    // matter how long a run went on. BoxDataSubscription owns the visibility
    // bookkeeping (page activity, app lifecycle), so the page keeps none.
    return BoxDataSubscription(data: BoxData.testSession, child: Scaffold(
      title: context.tr('Speed test'),
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.clock,
          tooltip: context.tr('Speed test history'),
          onPressed: _openHistory,
        ),
        IconButtonData(
          glyph: AppGlyphs.settings,
          tooltip: context.tr('Speed test settings'),
          onPressed: _running ? null : _openSettings,
        ),
      ],
      body: ListView(
        padding: boxPagePadding(context),
        children: [
          // The outbound card, in Bettbox's three-row shape: the node the run
          // dialled, the route that sent it there, and the provider's server.
          SpeedOutboundCard(
            rows: SpeedOutboundRows.of(
              _state,
              coreRunning: coreRunning,
              pinnedOutbound: _outbound,
              unavailable: context.tr('Core stopped'),
            ),
            coreRunning: coreRunning,
            onTap: _running ? null : _pickOutbound,
          ),
          const SizedBox(height: 16),
          // The gauge and its neighbours, as Bettbox stacks them narrow.
          BoxPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PanelTitle('Speed test', AppGlyphs.speed),
                const SizedBox(height: 8),
                Center(
                  child: Column(
                    children: [
                      SpeedGauge(
                        size: math.min(
                          MediaQuery.sizeOf(context).width - 96,
                          300,
                        ),
                        fraction: _hasValue ? _gaugeValue : 0,
                        color: gaugeColor,
                        accentColor: isUpload ? scheme.primary : second,
                        spinning: _connecting,
                        showNeedle: _hasValue || _connecting,
                      ),
                      const SizedBox(height: 4),
                      _GaugeReadout(
                        label: _readoutLabel,
                        value: _hasValue
                            ? speedValueText(_gaugeValue)
                            : '—',
                        unit: _hasValue ? speedUnitText(_gaugeValue) : '',
                        color: gaugeColor,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SpeedPhaseSteps(phase: _phase),
                const SizedBox(height: 14),
                Center(
                  child: TonalButton(
                    size: TonalButtonSize.bar,
                    glyph: _running ? AppGlyphs.close : AppGlyphs.bolt,
                    label: context.tr(
                      _running
                          ? 'Stop'
                          : _finished
                          ? 'Test again'
                          : 'Start',
                    ),
                    onPressed: _starting
                        ? null
                        : _running
                        ? _cancel
                        : coreRunning
                        ? _start
                        : null,
                  ),
                ),
                if (!coreRunning && !_running) ...[
                  const SizedBox(height: 12),
                  Text(
                    context.tr(
                      'Start the VPN first: the test measures through the running core.',
                    ),
                    textAlign: TextAlign.center,
                    style: context.listCaptionStyle,
                  ),
                ],
                if (errorText != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    errorText,
                    textAlign: TextAlign.center,
                    style: context.listCaptionStyle.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          // The curves, kept after the run so the run can be re-read.
          BoxPanel(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _Legend(
                      label: context.tr('Download'),
                      color: series.download,
                    ),
                    const SizedBox(width: 12),
                    _Legend(label: context.tr('Upload'), color: series.upload),
                  ],
                ),
                const SizedBox(height: 8),
                SpeedCurves(
                  download: downloadCurve,
                  upload: uploadCurve,
                  height: 120,
                  revision: downloadCurve.length + uploadCurve.length,
                  downloadColor: series.download,
                  uploadColor: series.upload,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _ResultTiles(state: _state),
        ],
      ),
    ));
  }
}

/// The gauge's centre: the phase label, the big number and its unit.
class _GaugeReadout extends StatelessWidget {
  const _GaugeReadout({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  final String label;
  final String value;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Text(
          label,
          key: ValueKey(label),
          style: context.listCaptionStyle,
        ),
      ),
      Text(
        value,
        style: AppTextStyle.title1
            .of(context, emphasized: true)
            .toTabular
            .copyWith(letterSpacing: -.5, height: 1.05),
      ),
      if (unit.isNotEmpty)
        Text(unit, style: context.listCaptionStyle.copyWith(color: color)),
    ],
  );
}

/// The server line: the provider's own answer once a test ran, the picked
/// speedtest.net server before that.

class _Legend extends StatelessWidget {
  const _Legend({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 4,
    children: [
      DecoratedBox(
        decoration: ShapeDecoration(color: color, shape: AppShape.circle),
        child: const SizedBox.square(dimension: 8),
      ),
      Text(label, style: context.listCaptionStyle),
    ],
  );
}

/// The measured figures: the delay, then the two throughputs.
///
/// Bettbox's grid also carries jitter, the loaded latencies and RPM. The kernel's
/// speed run (`core/mobile/speedtest.go`, relayed by BboxTestSession) measures none
/// of them — the snapshot has `pingMs`, `dlBps`, `ulBps`, the samples and the
/// server, nothing else — so those four tiles sat at `—` for the life of every run.
/// They are gone rather than left as decoration; add each back with the field that
/// would fill it.
class _ResultTiles extends StatelessWidget {
  const _ResultTiles({required this.state});
  final Json state;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    double value(String key) => (state[key] as num? ?? 0).toDouble();
    final idle = value('latency');
    final tiles = <(String, String, Color)>[
      (
        context.tr('Delay'),
        idle > 0 ? '${idle.round()} ms' : '—',
        scheme.primary,
      ),
      (
        context.tr('Download'),
        value('download') > 0 ? speedRateText(value('download')) : '—',
        scheme.primary,
      ),
      (
        context.tr('Upload'),
        value('upload') > 0 ? speedRateText(value('upload')) : '—',
        scheme.onSurface,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 480 ? 3 : 2;
        return Column(
          children: [
            for (var start = 0; start < tiles.length; start += columns) ...[
              if (start > 0) const SizedBox(height: 10),
              _TileRow(tiles: tiles, start: start, columns: columns),
            ],
          ],
        );
      },
    );
  }
}

/// One row of the result grid: [columns] slots starting at [start], with the
/// trailing slots padded to nothing when the tiles run out.
class _TileRow extends StatelessWidget {
  const _TileRow({
    required this.tiles,
    required this.start,
    required this.columns,
  });

  final List<(String, String, Color)> tiles;
  final int start;
  final int columns;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 10,
    children: [
      for (var slot = 0; slot < columns; slot++)
        Expanded(child: _slot(start + slot)),
    ],
  );

  Widget _slot(int index) {
    if (index >= tiles.length) return const SizedBox.shrink();
    final (title, value, color) = tiles[index];
    return _ResultTile(title: title, value: value, color: color);
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.title,
    required this.value,
    required this.color,
  });
  final String title;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => BoxPanel(
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.listCaptionStyle,
        ),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyle.subheadline
              .of(context, emphasized: true)
              .toTabular
              .copyWith(color: color),
        ),
      ],
    ),
  );
}
