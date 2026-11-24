import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

import '../providers/box_providers.dart';
import '../widgets.dart';
import '../pages/configurations.dart';
import '../core/kernel_control.dart';
import '../core/turn_profiler.dart';
import 'start_toggle.dart';
import 'shape_badge.dart';
import 'dashboard_chip.dart';
import '../common/egress_cache.dart';
import '../common/ip_quality.dart';
import '../common/ip_quality_cache.dart';
import '../common/routed_ip_probe.dart';
import 'form.dart';

/// Route provenance for the status card's probes (S7).
///
/// The Dart route stamp catches a selection change only after the host has pushed it; a probe
/// that is in flight across the push could still land with the old exit. The host stamps every
/// dashboard and egress wire with a `routeVersion` that moves on exactly those events, and this
/// gate compares the version a probe started under with the one its answer was built under.
///
/// It also owns the failure-confirmation rule: one transient failure (a probe racing a switch,
/// a source rate-limiting one request) must not paint "Check failed" under the new selection.
/// The first failure under a route version is held back; the caller retries once, and only a
/// second failure under the same version is painted. A timeout that spent its whole budget is
/// painted at once — retrying it would only make the card look stuck. Success clears both.
class ProbeFreshness {
  int? _start;
  bool _failed = false;
  int? _failedVersion;

  /// Records the route version a probe is starting under. The baseline only ever moves
  /// forward: a discard raises it to the version the discarded answer was built under, and a
  /// later `begin` that still reads the (stale) dashboard must not lower it back — that would
  /// make the retry discard its own answer and probe forever. Null (a wire without the stamp)
  /// leaves the baseline alone.
  void begin(int? routeVersion) {
    if (routeVersion == null) return;
    final start = _start;
    if (start == null || routeVersion > start) _start = routeVersion;
  }

  /// Whether an answer built under [answerVersion] belongs to a route the probe did not start
  /// under. Unknown versions on either side cannot prove staleness, so the gate stays open.
  bool stale(int? answerVersion) {
    final start = _start;
    return start != null && answerVersion != null && answerVersion != start;
  }

  /// Records a failure observed under [routeVersion]. Returns true when it should be painted:
  /// it is a timeout that already used its budget, or the previous failure is still unconfirmed
  /// for this same route version. Returns false on the first ordinary failure, which asks the
  /// caller to retry once.
  bool failure(int? routeVersion, {bool timeout = false}) {
    if (timeout) return true;
    final repeated = _failed &&
        (_failedVersion == null ||
            routeVersion == null ||
            routeVersion == _failedVersion);
    if (repeated) return true;
    _failed = true;
    _failedVersion = routeVersion;
    return false;
  }

  /// A success replaces any unconfirmed failure immediately.
  void success() {
    _failed = false;
    _failedVersion = null;
  }
}

/// Whether [error] is a probe that ran out of time rather than one that was refused. The host
/// reports OkHttp's message ("Read timed out", "timeout"); the card's own ceiling would arrive
/// as a TimeoutException.
bool _probeTimedOut(Object error) {
  if (error is TimeoutException) return true;
  final text = BoxController.describe(error).toLowerCase();
  return text.contains('timeout') || text.contains('timed out');
}

/// Mobile layout from FlClash's current_outbound.dart, with sing-box data.
class StatusPanel extends ConsumerStatefulWidget {
  const StatusPanel({super.key});
  @override
  ConsumerState<StatusPanel> createState() => _StatusPanelState();
}

class _StatusPanelState extends ConsumerState<StatusPanel>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // FlClash common/constant.dart and providers/routed_probe.dart.
  static const _throttleDuration = Duration(seconds: 5);
  // Long enough to swallow the burst of state changes a connect or a profile switch emits, short
  // enough that the card is not visibly waiting: the probe starts as soon as the route is settled.
  static const _moveSettleDuration = Duration(milliseconds: 120);
  bool _checking = false, _qualityChecking = false;
  // A probe for this route started inside the cache's throttle (possibly by the State this
  // one replaced): the card is waiting for that window to lapse, not probing.
  bool _cacheWait = false;
  Json? _egress;
  String? _error, _qualityError, _stamp;
  BoxController? _box;
  RoutedIpProbe? _probe;
  Timer? _qualityExpiry, _cooldown, _settle;
  Timer? _routeSync;
  /// S7: the version a probe started under and the unconfirmed-failure state it carries.
  final _freshness = ProbeFreshness();
  Timer? _failureRetry;
  final _detailsRevision = ValueNotifier(0);
  int _generation = 0;
  // The tap intent: FlClash flips `isStart` on the tap frame and the morph is
  // the feedback. Rides over the box state until the two converge (or a failed
  // op drops it); a newer tap flips it again.
  bool? _tapIntent;
  // Serial number of the newest `_toggle`, so a late failure from an earlier
  // one (released by the safety-net timeout) is not reported into its UI.
  int _toggleSeq = 0;
  // True from the frame the button's morph starts until it settles. The probe,
  // the skeletons and the country flag's spin all wait for it: they used to
  // start the moment `transitioning` flipped false (the kernel's Started often
  // lands mid-turn), putting a 60 fps flag spin and a routed HTTP probe into
  // the morph's frame budget.
  bool _turnRunning = false;
  TurnProfiler? _turnProfile;
  bool _foreground = true, _refreshScheduled = false;
  bool _ipDue = true,
      _qualityDue = false,
      _manual = false,
      _routeChanged = false;
  static bool _visible(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = _visible(WidgetsBinding.instance.lifecycleState);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = _visible(state);
    // Like FlClash, visibility alone does not invalidate a successful answer
    // or cancel work already sent. Route changes still cancel stale requests.
    if (_foreground) {
      if (state == AppLifecycleState.resumed &&
          !_checking &&
          (_egress == null || _error != null)) {
        _ipDue = true;
      }
      _scheduleRefresh();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final box = ref.read(boxControllerProvider);
    if (!identical(_box, box)) {
      _box?.stateChanges.removeListener(_scheduleRouteSync);
      _box = box;
      box.stateChanges.addListener(_scheduleRouteSync);
    }
    _syncRoute();
  }

  /// A state event can arrive in the middle of a frame. Recomputing the route
  /// and calling setState there put the work in the same UI-isolate turn as the
  /// kernel's `Started` event; a zero-delay timer coalesces the burst and lets
  /// the event callback return first.
  void _scheduleRouteSync() {
    if (_routeSync != null || _box == null) return;
    _routeSync = Timer(Duration.zero, () {
      _routeSync = null;
      if (mounted) _syncRoute();
    });
  }

  void _syncRoute() {
    // Paused applications do not render frames. Observe controller events so
    // route changes cancel stale requests without waiting for a widget rebuild.
    final box = _box!;
    // The host's stamp is the egress cache's invalidation key: a move drops every answer
    // measured on the old route even if this card never probes again.
    box.egressCache.noteRoute(box.routeVersion);
    final selections =
        box.groups.map((g) => '${g['tag']}:${g['selected']}').toList()..sort();
    final addresses = box.lanAddresses..sort();
    final route = box.running
        ? '${box.dashboard['startedAt']}:${box.selectedProfileId}:${box.dashboard['mode']?.toString().toLowerCase()}:${selections.join(',')}'
        : '';
    // S7: the host's route version is part of the route stamp. A selection the host has
    // already moved (but whose dashboard fields have not reached this widget yet) invalidates
    // an answer in flight the same way a mode change does.
    final stamp =
        '${box.routeVersion}:${box.dashboard['status']}:${box.running}:${box.remote}:${box.dashboard['remote']}:$route:${box.lan['stamp']}:$addresses';
    if (_stamp == stamp) return;
    final changed = _stamp != null;
    _stamp = stamp;
    _generation++;
    _probe?.cancel();
    _probe = null;
    _qualityExpiry?.cancel();
    // The route moved: an unconfirmed failure belonged to the old one.
    _failureRetry?.cancel();
    _failureRetry = null;
    _freshness.success();
    setState(() {
      _egress = null;
      _error = null;
      _qualityError = null;
      _checking = false;
      _qualityChecking = false;
      _cacheWait = false;
      _ipDue = true;
      _qualityDue = false;
      _manual = false;
      _routeChanged = changed;
    });
    if (changed && _settle == null) {
      _settle = Timer(_moveSettleDuration, () {
        _settle = null;
        _scheduleRefresh();
      });
    }
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    if (_refreshScheduled) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (mounted) _flushRefresh();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// The morph started or settled. While it runs, every deferred card duty
  /// (probe, skeletons, flag spin) holds; when it ends they get their chance.
  ///
  /// The callback fires from `StartToggle.didUpdateWidget`, i.e. inside the
  /// build phase, so only the gate flips synchronously (that is what the next
  /// frame's `_flushRefresh` reads); the profiler work and the rebuild wait a
  /// frame.
  void _onTurnChanged(bool running) {
    if (!mounted) return;
    _turnRunning = running;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (running) {
        _turnProfile?.stop();
        final label = _tapIntent == false ? 'stop' : 'start';
        _turnProfile = TurnProfiler.start(label, _logTurn, vsync: this);
      } else {
        _turnProfile?.stop();
        _turnProfile = null;
        _scheduleRefresh();
      }
      setState(() {});
    });
  }

  /// One line per turn in the app log: frame counts and the worst build/raster/
  /// vsync times. Cheap enough to stay on, and the only profile a device we
  /// cannot attach to will give us.
  void _logTurn(String text) {
    if (!mounted) return;
    final box = ref.read(boxControllerProvider);
    unawaited(
      box.call('log.note', {'text': text}).then((_) {}, onError: (_) {}),
    );
  }

  void _retry() {
    if (_checking || _qualityChecking) return;
    _ipDue = true;
    _manual = true;
    _scheduleRefresh();
  }

  void _flushRefresh() {
    final box = ref.read(boxControllerProvider);
    // A tap intent means a transition is coming: starting the IP/quality probe
    // in that window spent the morph's frame budget on network callbacks and a
    // 60 fps flag spin (FlClash's card probes nothing while it toggles). The
    // convergence event re-triggers this through the route stamp change. The
    // turn gate covers the window after convergence too: the kernel reports
    // Started before the 450 ms morph settles, and the probe used to start
    // inside the turn's tail.
    if (!_foreground ||
        _checking ||
        _qualityChecking ||
        box.transitioning ||
        _tapIntent != null ||
        _turnRunning ||
        box.remote) {
      return;
    }
    if (_ipDue &&
        !_manual &&
        (_settle != null || (!_routeChanged && _cooldown != null))) {
      return;
    }
    if (_ipDue || _qualityDue) {
      unawaited(_refresh(readIp: _ipDue, manual: _manual));
    }
  }

  Future<void> _refresh({required bool readIp, required bool manual}) async {
    final box = ref.read(boxControllerProvider);
    if (readIp) {
      // S7: record the route this probe is answering for. An answer stamped with a newer
      // version is the old exit and is discarded instead of painted.
      _freshness.begin(box.routeVersion);
      _failureRetry?.cancel();
      _failureRetry = null;
    }
    final retryQualityFor = manual && _qualityError != null
        ? (_egress?['ip'])
        : null;
    // A tap, or a route the card already knows changed, must not be answered from a cache.
    final force = manual || _routeChanged;
    // FlClash's routed-probe cache: the answer belongs to the route, not to this State, so a
    // remount under the same stamp reuses it instead of asking the host again. A hit paints
    // immediately; a miss falls through to the existing probe with all of S7 intact.
    EgressKey? key;
    Json? remembered;
    if (readIp) {
      final cache = box.egressCache;
      cache.noteRoute(box.routeVersion);
      key = EgressKey(
        routeVersion: box.routeVersion,
        outbound: egressOutboundIdentity(
          groups: box.groups,
          profileId: box.selectedProfileId,
        ),
      );
      if (force) {
        cache.invalidate(key);
      } else {
        switch (cache.read(key)) {
          case EgressHit(:final answer):
            remembered = answer;
          case EgressFailed(:final message, :final retryAfter) when _error == null:
            // A previous State confirmed this failure under the same route. Paint it here
            // and keep the remainder of its cooldown; the due probe waits it out, exactly as
            // the cooldown set by a live failure holds its own retry back.
            _cooldown?.cancel();
            _cooldown = Timer(retryAfter, () {
              _cooldown = null;
              _scheduleRefresh();
            });
            setState(() {
              _egress = null;
              _checking = false;
              _qualityChecking = false;
              _error = message;
            });
            return;
          case EgressFailed():
            // This State painted the failure itself; the cooldown its own probe set owns the
            // next attempt, so the cached entry must not hold it back any longer.
            break;
          case EgressThrottled(:final retryAfter):
            // A probe for this route started very recently (possibly by the State this one
            // replaced). Wait the throttle out instead of asking the host twice.
            _cacheWait = true;
            _cooldown?.cancel();
            _cooldown = Timer(retryAfter, () {
              _cooldown = null;
              _scheduleRefresh();
            });
            setState(() {});
            return;
          case EgressMiss():
            break;
        }
      }
    }
    _ipDue = false;
    _qualityDue = false;
    _manual = false;
    _routeChanged = false;
    if (readIp && remembered == null) {
      _cooldown?.cancel();
      _cooldown = Timer(_throttleDuration, () {
        _cooldown = null;
        _scheduleRefresh();
      });
    }
    final generation = ++_generation;
    _qualityExpiry?.cancel();
    final probe = RoutedIpProbe(box);
    _probe?.cancel();
    _probe = probe;
    setState(() {
      _cacheWait = false;
      _checking = readIp && remembered == null;
      _qualityChecking = !readIp;
      _error = null;
      _qualityError = null;
    });
    try {
      final Json result;
      if (!readIp) {
        result = _egress!;
      } else if (remembered != null) {
        result = remembered;
      } else {
        box.egressCache.noteAttempt(key!);
        result = await probe.egress(force: force);
      }
      if (!mounted || generation != _generation) return;
      if (readIp) {
        // The host stamps the answer with the version it was built under; a route that moved
        // while the request was in flight answers with a newer one. (A wire from a host that
        // has no stamp answers null and cannot prove staleness, so it is accepted.)
        final answerVersion =
            (result['routeVersion'] as num?)?.toInt() ?? box.routeVersion;
        if (_freshness.stale(answerVersion)) {
          // Do not paint the old exit under the new selection: probe again under it. The
          // answer names the route the host is on now, so the retry starts from that version
          // instead of the one the discarded probe began under.
          _freshness.begin(answerVersion);
          _ipDue = true;
          _manual = true;
          return;
        }
        _freshness.success();
      }
      final ip = result['ip'] as String?;
      // A direct answer is this device's own address: the quality sources would grade the phone's uplink
      // rather than an exit, so the card keeps the address, region and carrier and skips the check.
      // The wire's `direct` is the host's verdict (it probes over the device network while the service is
      // stopped); an answer that *is* one of this device's own LAN addresses is the same situation even if
      // the flag says otherwise, and grading it would report the phone's uplink as the exit's quality.
      final direct =
          result['direct'] == true ||
          (ip != null && box.lanAddresses.contains(ip));
      if (readIp && force) {
        result['checkedAt'] = DateTime.now().millisecondsSinceEpoch;
      }
      if (readIp && key != null && remembered == null && result.isNotEmpty) {
        // Remember only what this State accepted: the stale check above has already run, and
        // the stored copy is taken before the quality merge mutates this one.
        box.egressCache.store(key, result);
      }
      setState(() {
        _egress = result.isEmpty ? null : result;
        _checking = false;
        _qualityChecking = ip != null && !direct;
      });
      _detailsRevision.value++;
      if (ip == null || direct) return;
      try {
        // The transport opens its native session on first get, so the lookup works on both the
        // fresh-IP path (no session opened yet) and the quality-only path. Each answer the lookup
        // would deliver lands on the card as it arrives — an inferred one first, then the precise
        // one that replaces it — instead of the card waiting for the chain to converge.
        final record = await box.ipQualities.lookup(
          probe,
          ip,
          refresh: !readIp || ip == retryQualityFor,
          onAnswer: (quality) {
            if (!mounted || generation != _generation) return;
            setState(() {
              result.remove('qualityError');
              result.remove('qualityFailures');
              result.addAll(quality.toDashboard(DateTime.now()));
            });
            _detailsRevision.value++;
          },
        );
        if (!mounted || generation != _generation) return;
        setState(() {
          result.remove('qualityError');
          result.remove('qualityFailures');
          result.addAll(record.quality.toDashboard(record.checkedAt));
          _qualityChecking = false;
        });
        _detailsRevision.value++;
        final remaining = record.checkedAt
            .add(IpQualityCache.maxAge)
            .difference(DateTime.now());
        _qualityExpiry = Timer(
          remaining.isNegative ? Duration.zero : remaining,
          () {
            if (mounted && generation == _generation) {
              _qualityDue = true;
              _scheduleRefresh();
            }
          },
        );
      } catch (error) {
        if (mounted && generation == _generation) {
          setState(() {
            _qualityChecking = false;
            _qualityError = BoxController.describe(error);
            result['qualityError'] = _qualityError;
            if (error is IpQualityLookupException) {
              result['qualityFailures'] = [
                for (final failure in error.failures)
                  {
                    'source': failure.source.label,
                    'status': failure.status.name,
                  },
              ];
            }
          });
          _detailsRevision.value++;
        }
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      if (readIp) {
        final currentVersion = box.routeVersion;
        if (_freshness.stale(currentVersion)) {
          // The failure belongs to a route that is already gone; the answer under the current
          // one has not been asked for yet. Probe again instead of painting this failure.
          _freshness.begin(currentVersion);
          _ipDue = true;
          _manual = true;
          return;
        }
        // S7: one failure is not proof. A probe that loses a race with its own route switch
        // (or a source rate-limiting a single request) must not flash "Check failed" under
        // the new selection, so the first ordinary failure is held back and retried once after
        // a second; only a second failure under the same version is painted. A timeout that
        // spent its whole budget is already a measured answer and is painted at once.
        if (!_freshness.failure(currentVersion, timeout: _probeTimedOut(error))) {
          _failureRetry?.cancel();
          _failureRetry = Timer(const Duration(seconds: 1), () {
            _failureRetry = null;
            if (!mounted) return;
            _ipDue = true;
            _manual = true;
            _scheduleRefresh();
          });
          return;
        }
      }
      final message = BoxController.describe(error);
      if (readIp && key != null) {
        // Only a painted failure is remembered, and only for the cooldown this card already
        // applies after one; a failure still awaiting confirmation is not.
        box.egressCache.storeFailure(key, message);
      }
      setState(() {
        // A failed check must look failed: Bettbox shows its "try a manual
        // refresh" state rather than pretending the last answer is current.
        _egress = null;
        _error = message;
      });
    } finally {
      await probe.close();
      if (mounted && generation == _generation) {
        setState(() {
          _checking = false;
          _qualityChecking = false;
          _probe = null;
        });
        if (_ipDue || _qualityDue) _scheduleRefresh();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _box?.stateChanges.removeListener(_scheduleRouteSync);
    _generation++;
    _probe?.cancel();
    _qualityExpiry?.cancel();
    _cooldown?.cancel();
    _settle?.cancel();
    _routeSync?.cancel();
    _failureRetry?.cancel();
    _detailsRevision.dispose();
    _turnProfile?.cancel();
    super.dispose();
  }

  Future<void> _toggle() async {
    final box = ref.read(boxControllerProvider);
    if (!box.running && box.selectedProfile == null && _tapIntent != true) {
      await openForm(context, const AddConfigurationPage());
      return;
    }
    // FlClash's button stays blue and pressable through the transition and
    // flips its shape on the tap frame (`_setLocalRunning` in setup.dart): the
    // tap asks for the opposite of the current visual state — a tap during
    // Starting is a cancel — and the lifecycle chain serialises the requests.
    // The old `_busy`/`transitioning` lock made the button look alive but
    // swallow every tap for seconds.
    final seq = ++_toggleSeq;
    final current = _tapIntent ??
        (box.running ||
            (box.transitioning && box.dashboard['status'] == 'Starting'));
    final wantRun = !current;
    setState(() => _tapIntent = wantRun);
    try {
      // A stale completion must not report into a newer toggle (the
      // `_RunRequest`/`_isCurrent` pattern from FlClash's setup.dart). The ops
      // bound their own platform calls (30 s ceiling each); this net is longer
      // than every one of them and only fires for a hang outside those bounds.
      final ok = await (wantRun ? box.serviceStart() : box.serviceStop())
          .timeout(const Duration(seconds: 35));
      if (!ok && seq == _toggleSeq && mounted) {
        // The service API reports its own failure and answers false. The
        // optimistic morph must still fall back to the box's truth.
        setState(() => _tapIntent = null);
        _scheduleRefresh();
      }
    } catch (error) {
      // A stale failure must not roll back a newer tap's intent.
      if (seq != _toggleSeq || !mounted) return;
      if (kernelUnanswered(error)) {
        // The kernel never answered: a transport timeout, a dropped link, or
        // the engine still booting. Keep the optimistic shape — rolling back
        // here showed "stopped" while the tunnel was still coming up, and the
        // heartbeat recovery converges the truth a moment later.
        _scheduleRefresh();
        return;
      }
      // An explicit refusal rolls the optimistic shape back to the box's truth,
      // the way FlClash's `_rollbackRunning` does.
      setState(() => _tapIntent = null);
      box.report(error);
      // The deferred probe has no convergence event to wait for now.
      _scheduleRefresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    // The old `context.box` subscribed to every state aspect. Watch the exact
    // fields this card renders so unrelated state changes don't rebuild it.
    final color = context.colorScheme;
    final dashboard = ref.watch(dashboardStatusProvider);
    final running = ref.watch(runningProvider);
    final transitioning = ref.watch(transitioningProvider);
    final remote = ref.watch(remoteProvider);
    final selectedProfile = ref.watch(selectedProfileProvider);
    // FlClash flips `isStart` on the tap frame; the tap intent rides over the
    // box state until the two converge (a failed op drops it in _toggle).
    final boxRun =
        running || (transitioning && dashboard.status == 'Starting');
    if (_tapIntent == boxRun) _tapIntent = null;
    final runTarget = _tapIntent ?? boxRun;
    final status = transitioning
        ? dashboard.status
        : running
        ? 'Running'
        : 'Not running';
    final info = _egress;
    final ip = info?['ip'] as String?;
    // The emphasis visuals follow the tap intent (runTarget), the same source
    // the button and the badge spring from. Core truth here left the card's
    // colours/tones seconds behind its own button — the same mispairing the
    // badge used to have. The status text and the run clock stay on truth.
    final foreground = runTarget ? color.onSurface : color.onSurfaceVariant;
    final scale = math.max(1.0, MediaQuery.textScalerOf(context).scale(1));
    final ipLoading =
        _checking ||
        _cacheWait ||
        (_routeChanged && _ipDue && !transitioning && !remote);
    // A quality answer on the card stays put while the lookup refines it; skeletons
    // stand in only while nothing is known yet.
    final qualityReady = info?['type'] != null || info?['quality'] != null;
    final loading =
        (ipLoading && ip == null) || (_qualityChecking && !qualityReady);
    final city =
        [
          info?['city'] as String?,
          info?['countryName'] as String?,
          info?['country'] as String?,
        ].whereType<String>().where((item) => item.isNotEmpty).firstOrNull ??
        '';
    return Semantics(
      container: true,
      label: context.tr('Status'),
      child: BoxPanel(
        padding: EdgeInsets.zero,
        clipBehavior: Clip.none,
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipPath(
                clipper: ShapeBorderClipper(
                  // Match the BoxPanel's full-width xl card radius; the alert
                  // radius belongs to dialogs, not ordinary cards.
                  shape: AppShape.all(AppCorner.xl),
                  textDirection: Directionality.of(context),
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    PositionedDirectional(
                      end: -60,
                      top: -66,
                      child: TweenAnimationBuilder<double>(
                        // The tap intent, like the button itself (FlClash's `isStart`):
                        // core truth here made the 240dp badge spring seconds after the
                        // 88dp button — "it moved, then hitched" — whenever the two
                        // 450 ms timelines diverged during Starting.
                        tween: Tween(end: runTarget ? 1 : 0),
                        duration: context.motionDuration(
                          const Duration(milliseconds: 450),
                        ),
                        curve: Curves.easeOutBack,
                        builder: (_, progress, _) => Transform.rotate(
                          angle: math.pi / 6 * progress,
                          child: Transform.scale(
                            scale: 1 + .12 * progress,
                            child: ShapeBadge(
                              shape: MaterialShapes.cookie12Sided,
                              size: 240,
                              color: Color.lerp(
                                SurfaceLevel.block.colorOf(color),
                                Color.alphaBlend(
                                  color.primary.withValues(alpha: .1),
                                  SurfaceLevel.card.colorOf(color),
                                ),
                                progress.clamp(0, 1),
                              )!,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 18, 16, 18),
              child: Row(
                spacing: 10,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 26 * scale,
                          child: Row(
                            spacing: 8,
                            children: [
                              GlyphIcon(
                                AppGlyphs.status,
                                size: 18,
                                color: color.onSurfaceVariant,
                              ),
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, constraints) => Row(
                                    spacing: 8,
                                    children: [
                                      Flexible(
                                        child: Text(
                                          context.tr('Status'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppTextStyle.subheadline.of(
                                            context,
                                            emphasized: true,
                                          ),
                                        ),
                                      ),
                                      ConstrainedBox(
                                        constraints: BoxConstraints(
                                          maxWidth: math.max(
                                            0,
                                            constraints.maxWidth - 8,
                                          ),
                                        ),
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          alignment:
                                              AlignmentDirectional.centerStart,
                                          child: DashboardChip(
                                            label: context.tr(status),
                                            tone: runTarget
                                                ? DashboardChipTone.ok
                                                : DashboardChipTone.idle,
                                            dot: runTarget,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          spacing: 12,
                          children: [
                            _CountryBadge(
                              country: info?['country'] as String?,
                              active: runTarget,
                              // A lookup already in flight keeps its state but
                              // holds the spin while the button turns: the
                              // rotation is 60 fps of re-tessellation, and the
                              // turn owns the frame budget.
                              checking:
                                  (ipLoading || _qualityChecking) &&
                                  !_turnRunning,
                              onRefresh:
                                  !transitioning &&
                                      !remote &&
                                      !_checking &&
                                      !_qualityChecking
                                  ? _retry
                                  : null,
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // The IP foreground follows the run state;
                                  // fading it beats the hard cut between
                                  // onSurfaceVariant and onSurface.
                                  TweenAnimationBuilder<Color?>(
                                    tween: ColorTween(end: foreground),
                                    duration: context.motionDuration(
                                      const Duration(milliseconds: 200),
                                    ),
                                    curve: Curves.easeOutCubic,
                                    builder: (_, animatedForeground, _) {
                                      final ipStyle = AppTextStyle.title2
                                          .of(context, emphasized: true)
                                          .toTabular
                                          .copyWith(
                                            color:
                                                animatedForeground ??
                                                foreground,
                                            letterSpacing: 0,
                                          );
                                      return SizedBox(
                                        height:
                                            AppTextStyle.title2.leading * scale,
                                        child: Align(
                                          alignment:
                                              AlignmentDirectional.centerStart,
                                          child: ip != null
                                              ? Tooltip(
                                                  message: context.tr(
                                                    'Outbound IP details',
                                                  ),
                                                  child: FocusRing(
                                                    shape: AppShape.xs,
                                                    standsOff: true,
                                                    child: InkWell(
                                                      onTap: () => openForm(
                                                        context,
                                                        EgressDetails(
                                                          info: info!,
                                                          updates:
                                                              _detailsRevision,
                                                          read: () =>
                                                              _egress ?? info,
                                                        ),
                                                      ),
                                                      customBorder: AppShape.xs,
                                                      hoverColor:
                                                          Colors.transparent,
                                                      splashColor:
                                                          Colors.transparent,
                                                      highlightColor:
                                                          Colors.transparent,
                                                      child: _IpText(
                                                        ip: ip,
                                                        style: ipStyle,
                                                      ),
                                                    ),
                                                  ),
                                                )
                                              : ipLoading
                                              ? SkeletonText(
                                                  width: 140,
                                                  style: ipStyle,
                                                )
                                              : Text(
                                                  _error == null
                                                      ? '—'
                                                      : context.tr(
                                                          'Check failed',
                                                        ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: ipStyle.copyWith(
                                                    color: _error == null
                                                        ? (animatedForeground ??
                                                              foreground)
                                                        : color.error,
                                                  ),
                                                ),
                                        ),
                                      );
                                    },
                                  ),
                                  const SizedBox(height: 4),
                                  SizedBox(
                                    height: 28,
                                    child: ClipRect(
                                      child: _error != null && ip == null
                                          ? Align(
                                              alignment: AlignmentDirectional
                                                  .centerStart,
                                              child: Tooltip(
                                                message: _error!,
                                                child: Text(
                                                  context.tr(
                                                    'Tap icon to retry',
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: _statusLabelStyle(
                                                    context,
                                                  ),
                                                ),
                                              ),
                                            )
                                          : Wrap(
                                              spacing: 6,
                                              runSpacing: 28,
                                              children: [
                                                if (loading) ...[
                                                  const SkeletonPill(
                                                    width: 48,
                                                    height: 28,
                                                  ),
                                                  const SkeletonPill(
                                                    width: 72,
                                                    height: 28,
                                                  ),
                                                ] else ...[
                                                  Tooltip(
                                                    message:
                                                        _qualityError == null
                                                        ? ''
                                                        : context.tr(
                                                            'IP quality unavailable',
                                                          ),
                                                    child: DashboardChip(
                                                      label: context.tr(
                                                        info?['type']
                                                                as String? ??
                                                            'Unknown type',
                                                      ),
                                                      large: true,
                                                    ),
                                                  ),
                                                  if (info?['quality'] != null)
                                                    DashboardChip(
                                                      label:
                                                          '${context.tr('Quality')} ${context.tr(info!['quality'] as String)}',
                                                      large: true,
                                                      tone:
                                                          info['quality'] ==
                                                              'Good'
                                                          ? DashboardChipTone.ok
                                                          : info['quality'] ==
                                                                'Risky'
                                                          ? DashboardChipTone
                                                                .warn
                                                          : DashboardChipTone
                                                                .idle,
                                                    ),
                                                ],
                                              ],
                                            ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          // The reference layout keeps the clock in a narrow
                          // column and lets the city take the rest, with the two
                          // labels a readable distance apart. Run time gets a
                          // floor wide enough for `HH:MM:SS` at the largest text
                          // scale the app offers (it grows to 999:00:00 and used
                          // to ellipsise at 56-62 dp), and the city takes
                          // whatever is left.
                          spacing: 16,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(minWidth: 84),
                              child: _StatusCell(
                                label: 'Run time',
                                child: _RuntimeValue(
                                  // The service's own elapsed time is the
                                  // authority; `startedAt` stays as the fallback
                                  // for a control that cannot report it.
                                  uptime: running
                                      ? ref
                                            .read(boxControllerProvider)
                                            .kernel
                                            .uptime
                                      : null,
                                  startedAt: running ? dashboard.startedAt : null,
                                ),
                              ),
                            ),
                            Expanded(
                              child: _StatusCell(
                                label: 'City',
                                child: city.isNotEmpty
                                    ? Text(
                                        city,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: _statusCellStyle(context),
                                      )
                                    : loading
                                    ? SkeletonText(
                                        width: 72,
                                        style: _statusCellStyle(context),
                                      )
                                    : Text(
                                        '—',
                                        maxLines: 1,
                                        style: _statusCellStyle(context),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 88,
                    child: Center(
                      // FlClash's `_StartToggle` gets `enabled: hasProfile` —
                      // the button stays blue and pressable through the whole
                      // transition, and the morph follows the tap intent on
                      // the tap frame (the transition IS the feedback).
                      child: AnimatedSwitcher(
                        duration: context.motionDuration(
                          const Duration(milliseconds: 200),
                        ),
                        child: remote
                            ? const GlyphIcon(
                                AppGlyphs.proxies,
                                key: ValueKey('remote'),
                                size: 60,
                              )
                            : RepaintBoundary(
                                child: StartToggle(
                                  key: const ValueKey('toggle'),
                                  size: 88,
                                  enabled: running || selectedProfile != null,
                                  running: runTarget,
                                  suspended: false,
                                  onTap: _toggle,
                                  onTurnChanged: _onTurnChanged,
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// FlClash stops shrinking at 75% so a long IPv6 address remains readable.
class _IpText extends StatelessWidget {
  const _IpText({required this.ip, required this.style});
  final String ip;
  final TextStyle style;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = MeasureScope.of(context)
          .computeTextSize(Text(ip, style: style))
          .width;
      if (width * .75 <= constraints.maxWidth) {
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(ip, maxLines: 1, style: style),
        );
      }
      return TooltipText(
        text: Text(
          ip,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      );
    },
  );
}

/// The regional-indicator emoji for a two-letter ISO code, the way Bettbox's network card shows the flag.
String _countryCodeToEmoji(String? code) {
  if (code == null || code.length != 2) return code ?? '';
  final first = code.codeUnitAt(0) - 0x41 + 0x1F1E6;
  final second = code.codeUnitAt(1) - 0x41 + 0x1F1E6;
  return String.fromCharCodes([first, second]);
}

class _CountryBadge extends StatefulWidget {
  const _CountryBadge({
    this.country,
    required this.active,
    required this.checking,
    this.onRefresh,
  });
  final String? country;
  final bool active, checking;
  final VoidCallback? onRefresh;
  @override
  State<_CountryBadge> createState() => _CountryBadgeState();
}

class _CountryBadgeState extends State<_CountryBadge>
    with SingleTickerProviderStateMixin {
  late final _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  bool _hovered = false, _focused = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _spin();
  }

  @override
  void didUpdateWidget(_CountryBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.checking != widget.checking) _spin();
  }

  void _spin() {
    if (context.disableAnimations) {
      _turn.value = 0;
    } else if (widget.checking) {
      _turn.repeat();
    } else {
      final rest = (_turn.value * 4).ceil() / 4;
      _turn.animateTo(
        rest,
        duration: const Duration(milliseconds: 1500) * (rest - _turn.value),
      );
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.active
        ? context.colorScheme.onSurface
        : context.colorScheme.onSurfaceVariant;
    final enabled = widget.onRefresh != null;
    final country = widget.country?.trim();
    final code = country == null || country.isEmpty
        ? null
        : country.toUpperCase();
    // Two-letter ISO codes render as regional-indicator emoji; anything else keeps its text.
    final showsFlag = code != null && code.length == 2;
    final background = Color.alphaBlend(
      color.withValues(alpha: enabled && _hovered ? .08 : 0),
      SurfaceLevel.inset.colorOf(context.colorScheme),
    );
    return Tooltip(
      message: context.tr('Retry'),
      child: Semantics(
        button: true,
        label: context.tr('Retry'),
        enabled: enabled,
        child: InkResponse(
          onTap: widget.onRefresh,
          onHover: (value) => setState(() => _hovered = value),
          onFocusChange: (value) => setState(() => _focused = value),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          child: ElasticPress(
            enabled: enabled,
            child: AnimatedBuilder(
              animation: _turn,
              builder: (_, child) {
                final rotation = _turn.value * 2 * math.pi;
                return ShapeBadge(
                  shape: MaterialShapes.clover4Leaf,
                  color: background,
                  size: 48,
                  rotation: rotation,
                  ring: _focused ? focusRingSide(context.colorScheme) : null,
                  child: child,
                );
              },
              child: code == null
                  ? GlyphIcon(AppGlyphs.proxies, size: 48 * .42, color: color)
                  : showsFlag
                  ? FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _countryCodeToEmoji(code),
                        key: const Key('country-badge-flag'),
                        style: const TextStyle(fontSize: 24),
                      ),
                    )
                  : Text(
                      code,
                      maxLines: 1,
                      style: AppTextStyle.footnote
                          .of(context, emphasized: true)
                          .copyWith(
                            color: color,
                            letterSpacing: .04 * AppTextStyle.footnote.size,
                          ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

TextStyle _statusLabelStyle(BuildContext context) => AppTextStyle.caption1
    .of(context)
    .toTabular
    .copyWith(color: context.colorScheme.onSurfaceVariant);
TextStyle _statusCellStyle(BuildContext context) =>
    AppTextStyle.subheadline.of(context, emphasized: true).toTabular;

class _StatusCell extends StatelessWidget {
  const _StatusCell({required this.label, required this.child});
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        context.tr(label),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _statusLabelStyle(context),
      ),
      const SizedBox(height: 2),
      child,
    ],
  );
}

class _RuntimeValue extends StatefulWidget {
  const _RuntimeValue({this.uptime, this.startedAt});

  /// The service's own elapsed time, preferred over [startedAt]: it comes from
  /// the core, so a wall-clock jump cannot make the figure jump or go negative.
  final Duration? uptime;

  /// The fallback when the control cannot report an elapsed time.
  final int? startedAt;
  @override
  State<_RuntimeValue> createState() => _RuntimeValueState();
}

class _RuntimeValueState extends State<_RuntimeValue>
    with WidgetsBindingObserver {
  Timer? _timer;

  /// The last service snapshot and when it was taken: ticks add the local
  /// elapsed time to it, and every rebuild re-syncs from the service.
  Duration? _base;
  DateTime? _syncedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sync();
    _schedule();
  }

  void _sync() {
    _base = widget.uptime;
    _syncedAt = DateTime.now();
  }

  @override
  void didUpdateWidget(_RuntimeValue oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uptime != widget.uptime ||
        oldWidget.startedAt != widget.startedAt) {
      _sync();
    }
  }

  /// The clock only ticks while the app can show it, so a backgrounded app stops
  /// waking up every second to format a time nobody is reading.
  void _schedule() {
    _timer?.cancel();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _elapsed != null) setState(() {});
      });
    }
  }

  Duration? get _elapsed {
    final base = _base;
    if (base != null) {
      final syncedAt = _syncedAt;
      if (syncedAt == null) return base;
      final extra = DateTime.now().difference(syncedAt);
      return extra.isNegative ? base : base + extra;
    }
    final startedAt = widget.startedAt;
    if (startedAt == null) return null;
    final elapsed = DateTime.now().millisecondsSinceEpoch - startedAt;
    return Duration(milliseconds: elapsed < 0 ? 0 : elapsed);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _schedule();
    if (state == AppLifecycleState.resumed && mounted) {
      _sync();
      setState(() {});
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = _elapsed;
    final seconds = elapsed == null
        ? 0
        : math.min(999 * 3600 + 59 * 60 + 59, math.max(0, elapsed.inSeconds));
    final text = elapsed == null
        ? '—'
        : [
            seconds ~/ 3600,
            seconds ~/ 60 % 60,
            seconds % 60,
          ].map((n) => n.toString().padLeft(2, '0')).join(':');
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _statusCellStyle(context),
    );
  }
}

class EgressDetails extends StatelessWidget {
  const EgressDetails({super.key, required this.info, this.updates, this.read});
  final Json info;
  final ValueListenable<int>? updates;

  /// Reads the panel's *current* egress. `info` is only the open-time
  /// snapshot; the [updates] notifier fires when a quality answer refines it,
  /// and without this the rebuilt page kept showing the stale copy.
  final Json Function()? read;
  @override
  Widget build(BuildContext context) => updates == null
      ? _page(context)
      : ValueListenableBuilder<int>(
          valueListenable: updates!,
          builder: (context, _, _) => _page(context),
        );
  Widget _page(BuildContext context) {
    final info = read?.call() ?? this.info;
    return BoxPage(
    title: 'Outbound IP',
    actions: [
      IconButtonData(
        glyph: AppGlyphs.copy,
        tooltip: context.tr('Copy'),
        onPressed: () =>
            Clipboard.setData(ClipboardData(text: info['ip'] as String)),
      ),
    ],
    children: [
      DetailRows({
        'IP': info['ip'], 'Country': info['countryName'] ?? info['country'],
        if (info['city'] != null) 'City': info['city'],
        if (info['region'] != null) 'Region': info['region'],
        'Organization': info['organization'],
        if (info['isp'] != null) 'ISP': info['isp'],
        'ASN': info['asn'],
        'Type': context.tr(info['type'] as String? ?? 'Unknown type'),
        if (info['quality'] != null)
          'Quality': context.tr(info['quality'] as String),
        // One row, not two: show the source that actually answered (the quality lookup
        // when it ran, otherwise the egress probe), never both side by side.
        'IP source': info['source'] ?? info['ipSource'],
        'Last checked': localDate(_latestCheckTimestamp(info)),
      }),
      if (info['qualityError'] != null)
        generateSection(
          title: context.tr('IP quality unavailable'),
          items: [
            for (final failure in rows(info['qualityFailures']))
              ListItem(
                title: Text(failure['source'].toString()),
                trailing: Text(
                  context.tr(
                    {
                          'noType': 'No type data',
                          'timeout': 'Timeout',
                          'rateLimited': 'Rate limited',
                          'failed': 'Unavailable',
                          'ipMismatch': 'IP mismatch',
                        }[failure['status']] ??
                        'Unavailable',
                  ),
                  style: context.listValueStyle,
                ),
              ),
          ],
        ),
    ],
    );
  }
}

/// The IP probe refreshes more often than the quality cache; "last checked" is
/// whichever answer reached this card most recently, not an older quality hit.
num? _latestCheckTimestamp(Json info) {
  final quality = info['qualityCheckedAt'] as num?;
  final checked = info['checkedAt'] as num?;
  if (quality == null) return checked;
  if (checked == null) return quality;
  return quality > checked ? quality : checked;
}
