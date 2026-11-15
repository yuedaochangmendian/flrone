import 'dart:async';
import 'dart:math' as math;

import '../widgets.dart';
import '../components/data_subscription.dart';
import '../components/speed_gauge.dart';
import '../components/speed_outbound_card.dart';
import '../components/speed_test_settings.dart';
import '../services/speed_test_history.dart';

/// The kernel's speed test, laid out the way Bettbox's screen lays it out: the
/// outbound card, then the gauge with the start button and the phase steps, the
/// throughput curves, the result tiles, and the credit line.
///
/// Everything measured comes from the kernel (`core/mobile/speedtest.go`):
/// `start` returns at once and this page polls `query` while the test runs, so
/// the numbers are the core's own samples rather than a UI reconstruction.
class SpeedTestPage extends StatefulWidget {
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
  State<SpeedTestPage> createState() => _SpeedTestPageState();
}

/// TestSpec.KIND_SPEED: the native session's speed run.
const _kindSpeed = 2;

/// TestUiState's speed modes (TestUiState.SPEED_MODE_*): FULL=0, DOWNLOAD=1,
/// UPLOAD=2, SIMPLE_DOWNLOAD=3, COUNTRY=4; -1 follows the Testing setting.
/// The screen used 0/1 for the two single-direction modes, so "download only"
/// asked the engine for a full run and "upload only" asked for download only.
const _speedModeDownloadOnly = 1;
const _speedModeUploadOnly = 2;

/// The providers the kernel knows, in the order the picker lists them.
const _providers = <(String, String)>[
  ('apple', 'Apple'),
  ('cloudflare', 'Cloudflare'),
  ('speedtest', 'Speedtest'),
];

class _SpeedTestPageState extends State<SpeedTestPage>
    with SingleTickerProviderStateMixin {
  SpeedTestSettings _settings = const SpeedTestSettings();
  String _outbound = '';
  List<String> _outbounds = const [];
  /// The outbound picker's list with the ids that go on the wire: `groups.nodes`
  /// answers `{id, tag}` per node, and the engine needs the ProxyEntity id — the
  /// dashboard's `selectedProfileId` is a *group* id and measures nothing.
  List<Json> _nodes = const [];
  bool _coreRunning = false;
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
  StreamSubscription<Map<String, dynamic>>? _pushSub;
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _pushSub?.cancel();
    _spin.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final box = context.box;
    final stored = box.preferences;
    setState(() {
      _settings = SpeedTestSettings.fromJson(stored);
      _outbound = widget.outbound ?? stored['speedTestOutbound']?.toString() ?? '';
      _coreRunning = box.running;
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
    context.box.setPreferences({
      ..._settings.toPreferences(),
      'speedTestOutbound': _outbound,
    });
  }

  /// The arguments `groups.testSession.start` takes for a speed run.
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
      final key = context.box.selectedProfileId;
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
  int get _speedMode => !widget.upload
      ? _speedModeDownloadOnly
      : !widget.download
      ? _speedModeUploadOnly
      : -1;

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
    for (final group in context.box.groups) {
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
    // The host re-emits the last session whenever the feed subscribes. Remember
    // where the previous run began so its wire cannot pass for this run's; the
    // wall-clock stamp and the payload itself cover a replay the host publishes
    // after the start call re-subscribes the feed, before this run's own
    // startedAt can be told apart.
    final held = context.box.testSession;
    _startedFrom = (held['startedAt'] as num?)?.toInt() ?? 0;
    _baseline = held.isEmpty ? '' : _identity(held);
    _startWall = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _starting = true;
      _error = null;
      _savedRecord = false;
    });
    _spin.repeat();
    try {
      // Throne's own test session: TestEngine runs SpeedTestRunner against the
      // started profile, and the progress arrives as the same `testSession`
      // event the batch panel draws.
      final started = await context.box.groupTestSessionStartChecked(_sessionArgs());
      if (!mounted) return;
      if (!started) {
        setState(() {
          _starting = false;
          _error = context.tr('A speed test is already running');
        });
        _spin.stop();
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
      _spin.stop();
    }
  }

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
    final box = context.box;
    _applySession(box.testSession);
    box.addListener(_onBoxChanged);
  }

  void _onBoxChanged() {
    if (!mounted) return;
    _applySession(context.box.testSession);
  }

  void _stopFollowing() {
    _pushSub?.cancel();
    _pushSub = null;
    _poll?.cancel();
    _poll = null;
    context.box.removeListener(_onBoxChanged);
  }

  /// Whether [session] still describes the run that finished before this one.
  ///
  /// The host replays the last session whenever the feed subscribes, and the page
  /// also reads `box.testSession` the moment it starts following — so the previous
  /// run's finished wire arrives as if it were this run's: the screen showed
  /// "Complete" instantly, stopped following and wrote a history record for a run
  /// it never saw. [TestSessionModel] stamps `startedAt` when a session is created
  /// and `BboxTestSession.wire` carries it, which is what identifies the session.
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
      if (stopped) 'error': 'cancelled' else if (failure.isNotEmpty) 'error': failure,
    };
    setState(() {
      _state = mapped;
      _running = !finished;
    });
    // A run that failed or was stopped measured nothing worth recording: the
    // history would show a row of zeros the user cannot tell from a dead link.
    if (stopped) {
      _failSession('cancelled');
    } else if (failed) {
      _failSession(failure, text: _failureText(failure, session));
    } else if (finished) {
      _finishSession();
    } else if (closed) {
      // A closed envelope whose frame never said finished had no result to keep
      // (`TestSessionModel.finish` marks the live state finished, so this is a
      // run that died mid-way). It ends the spinner without a record.
      _failSession(failure, text: _failureText(failure, session));
    }
  }

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
  /// `BboxTestSession.wire` reports a run that ended before any probe answered —
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
    if (session['cancelled'] == true) {
      _failSession('cancelled', text: context.tr('Cancelled'));
      return;
    }
    // Nothing was measured, so the tiles go back to "—" rather than showing the
    // last run's figures under this one's verdict.
    _failSession('', text: _failureText('', session), reset: true);
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
    _spin.stop();
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
    _spin.stop();
    if (!mounted) return;
    setState(() {
      _running = false;
      if (reset) _state = const {'phase': 'done'};
      _error = text ?? BoxController.describe(error);
    });
  }

  /// Appends the finished run to the stored history.
  Future<void> _recordRun() async {
    final box = context.box;
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
    final box = context.box;
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
    await showSpeedTestHistory(context, box: context.box);
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

  /// A run needs the core up: the tester dials through the instance's own
  /// outbound, so with the VPN stopped there is nothing to measure through.
  bool get _serviceRunning => context.box.running;

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
    // Download is the primary series; upload is primary at 45% over the card,
    // not a separate tertiary hue (surfaces.md). The gauge, its gradient, the
    // curve legend and the result tiles all read the same two strengths.
    final second = secondSeriesColor(context);
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
              coreRunning: _coreRunning,
              pinnedOutbound: _outbound,
              unavailable: context.tr('Core stopped'),
            ),
            coreRunning: _coreRunning,
            onTap: _running ? null : _pickOutbound,
          ),
          if (_state['provider']?.toString() case final String actual
              when actual.isNotEmpty && actual != _settings.provider)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${context.tr('Provider')}: '
                '${_providers.firstWhere((p) => p.$1 == actual, orElse: () => (actual, actual)).$2}'
                '${_state['providerFallback'] == true ? ' · ${context.tr('Fell back')}' : ''}',
                style: context.listCaptionStyle,
              ),
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
                        spin: _connecting ? _spin.value : null,
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
                        : _serviceRunning
                        ? _start
                        : null,
                  ),
                ),
                if (!_serviceRunning && !_running) ...[
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
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 12),
                    _Legend(label: context.tr('Upload'), color: second),
                  ],
                ),
                const SizedBox(height: 8),
                SpeedCurves(
                  download: _curve('downloadCurve'),
                  upload: _curve('uploadCurve'),
                  height: 120,
                  revision: _curve('downloadCurve').length +
                      _curve('uploadCurve').length,
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
