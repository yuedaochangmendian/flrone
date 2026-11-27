import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:flutter/foundation.dart';

import '../box.dart';

String _two(int value) => value.toString().padLeft(2, '0');

int _at(Object? value) => value is num ? value.toInt() : (value is String ? int.tryParse(value) ?? 0 : 0);

/// One bucket of attributed traffic (a host, node, rule or app).
class TrafficSlice {
  TrafficSlice({this.up = 0, this.down = 0});
  int up;
  int down;
  int get total => up + down;

  void add(int upDelta, int downDelta) {
    up += upDelta;
    down += downDelta;
  }

  List<int> toJson() => [up, down];

  static TrafficSlice fromJson(Object? value) {
    if (value is List && value.length >= 2) {
      return TrafficSlice(up: _at(value[0]), down: _at(value[1]));
    }
    if (value is Map) return TrafficSlice(up: _at(value['up']), down: _at(value['down']));
    return TrafficSlice();
  }
}

class ProfileTraffic {
  ProfileTraffic();
  String name = '';
  int up = 0;
  int down = 0;
  int get total => up + down;

  void add(int upDelta, int downDelta) {
    up += upDelta;
    down += downDelta;
  }

  Json toJson() => {'n': name, 'up': up, 'down': down};

  static ProfileTraffic fromJson(Json data) => ProfileTraffic()
    ..name = data['n']?.toString() ?? ''
    ..up = _at(data['up'])
    ..down = _at(data['down']);
}

/// One day of traffic: hour buckets, the proxy/direct split, the per-profile split and the
/// attributed breakdown the host's poller reports.
class DayTraffic {
  DayTraffic();
  int up = 0;
  int down = 0;
  final List<int> hourUp = List<int>.filled(24, 0);
  final List<int> hourDown = List<int>.filled(24, 0);
  int proxyUp = 0;
  int proxyDown = 0;
  int directUp = 0;
  int directDown = 0;
  final Map<String, TrafficSlice> hosts = {};
  final Map<String, TrafficSlice> nodes = {};
  final Map<String, TrafficSlice> rules = {};
  final Map<String, TrafficSlice> processes = {};
  final Map<String, ProfileTraffic> profiles = {};

  static const maxHosts = 200;
  static const maxNodes = 100;
  static const maxRules = 100;
  static const maxProcesses = 100;
  static const maxProfiles = 50;

  int get total => up + down;

  DayTraffic add(int upDelta, int downDelta, DateTime at, {String? profileId, String? profileName}) {
    final hour = at.hour;
    up += upDelta;
    down += downDelta;
    hourUp[hour] += upDelta;
    hourDown[hour] += downDelta;
    if (profileId != null && upDelta + downDelta > 0) {
      final profile = profiles.putIfAbsent(profileId, ProfileTraffic.new);
      profile.name = profileName ?? profile.name;
      profile.add(upDelta, downDelta);
      _trim(profiles, maxProfiles);
    }
    return this;
  }

  /// Merges one `trafficDeltas` payload from the host's poller. The payload's totals are not
  /// applied here: the day/hours come from the core's exact cumulative totals, and only the
  /// attribution (split + maps) comes from the poller, so the two can never double count.
  void mergeAttribution(Json payload) {
    proxyUp += _at(payload['proxyUp']);
    proxyDown += _at(payload['proxyDown']);
    directUp += _at(payload['directUp']);
    directDown += _at(payload['directDown']);
    _mergeSlices(hosts, payload['hosts'], maxHosts);
    _mergeSlices(nodes, payload['nodes'], maxNodes);
    _mergeSlices(rules, payload['rules'], maxRules);
    _mergeSlices(processes, payload['processes'], maxProcesses);
  }

  static void _mergeSlices(Map<String, TrafficSlice> target, Object? value, int cap) {
    if (value is! Map) return;
    for (final entry in value.entries) {
      final key = entry.key.toString();
      if (key.isEmpty) continue;
      final slice = target.putIfAbsent(key, TrafficSlice.new);
      final incoming = TrafficSlice.fromJson(entry.value);
      slice.add(incoming.up, incoming.down);
    }
    _trim(target, cap);
  }

  static void _trim<T extends Object>(Map<String, T> target, int cap) {
    if (target.length <= cap) return;
    int totalOf(T value) => switch (value) {
          TrafficSlice slice => slice.total,
          ProfileTraffic profile => profile.total,
          _ => 0,
        };
    final keep = target.entries.toList()..sort((a, b) => totalOf(b.value).compareTo(totalOf(a.value)));
    final kept = keep.take(cap).map((entry) => entry.key).toSet();
    target.removeWhere((key, _) => !kept.contains(key));
  }

  Json toJson() => {
        'up': up,
        'down': down,
        'hu': hourUp,
        'hd': hourDown,
        'pu': proxyUp,
        'pd': proxyDown,
        'du': directUp,
        'dd': directDown,
        if (hosts.isNotEmpty) 'h': {for (final entry in hosts.entries) entry.key: entry.value.toJson()},
        if (nodes.isNotEmpty) 'n': {for (final entry in nodes.entries) entry.key: entry.value.toJson()},
        if (rules.isNotEmpty) 'r': {for (final entry in rules.entries) entry.key: entry.value.toJson()},
        if (processes.isNotEmpty) 'a': {for (final entry in processes.entries) entry.key: entry.value.toJson()},
        if (profiles.isNotEmpty) 'p': {for (final entry in profiles.entries) entry.key: entry.value.toJson()},
      };

  static DayTraffic fromJson(Json data) {
    final day = DayTraffic()
      ..up = _at(data['up'])
      ..down = _at(data['down'])
      ..proxyUp = _at(data['pu'])
      ..proxyDown = _at(data['pd'])
      ..directUp = _at(data['du'])
      ..directDown = _at(data['dd']);
    final up = data['hu'];
    final down = data['hd'];
    for (var i = 0; i < 24; i++) {
      day.hourUp[i] = up is List && i < up.length ? _at(up[i]) : 0;
      day.hourDown[i] = down is List && i < down.length ? _at(down[i]) : 0;
    }
    _loadSlices(day.hosts, data['h']);
    _loadSlices(day.nodes, data['n']);
    _loadSlices(day.rules, data['r']);
    _loadSlices(day.processes, data['a']);
    final profiles = data['p'];
    if (profiles is Map) {
      for (final entry in profiles.entries) {
        final value = entry.value;
        if (value is Map) {
          final profile = ProfileTraffic.fromJson(json(value));
          if (profile.name.isEmpty && profile.total == 0) continue;
          day.profiles[entry.key.toString()] = profile;
        }
      }
    }
    return day;
  }

  static void _loadSlices(Map<String, TrafficSlice> target, Object? value) {
    if (value is! Map) return;
    for (final entry in value.entries) {
      final slice = TrafficSlice.fromJson(entry.value);
      if (slice.total == 0) continue;
      target[entry.key.toString()] = slice;
    }
  }
}

/// The pure traffic ledger: local-date keyed days, with a retention window.
class TrafficLedger {
  TrafficLedger({DateTime Function()? clock, this.retentionDays = 7}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  int retentionDays;
  final Map<String, DayTraffic> days = {};
  String? _sessionDay;

  static String keyOf(DateTime at) => '${at.year}-${_two(at.month)}-${_two(at.day)}';

  DateTime today() => _clock();

  void record(int upDelta, int downDelta, {String? profileId, String? profileName}) {
    if (upDelta <= 0 && downDelta <= 0) return;
    final at = _clock();
    final key = keyOf(at);
    final day = days.putIfAbsent(key, DayTraffic.new);
    day.add(upDelta < 0 ? 0 : upDelta, downDelta < 0 ? 0 : downDelta, at,
        profileId: profileId, profileName: profileName);
    if (_sessionDay != key) {
      _sessionDay = key;
      prune(at);
    }
  }

  /// Merges one host attribution payload into today's buckets.
  void mergeAttribution(Json payload) {
    final day = days.putIfAbsent(keyOf(_clock()), DayTraffic.new);
    day.mergeAttribution(payload);
  }

  void prune(DateTime now, {int? retentionDays}) {
    final daysToKeep = retentionDays ?? this.retentionDays;
    final cutoff = DateTime(now.year, now.month, now.day).subtract(Duration(days: daysToKeep - 1));
    days.removeWhere((key, _) => key.compareTo(keyOf(cutoff)) < 0);
  }

  DayTraffic? day(DateTime at) => days[keyOf(at)];

  int totalBetween(DateTime from, DateTime to) {
    var total = 0;
    for (final entry in days.entries) {
      if (entry.key.compareTo(keyOf(from)) >= 0 && entry.key.compareTo(keyOf(to)) <= 0) {
        total += entry.value.total;
      }
    }
    return total;
  }

  Json toJson() => {
        'v': 2,
        'days': {for (final entry in days.entries) entry.key: entry.value.toJson()},
      };

  void load(Json data) {
    final stored = data['days'];
    if (stored is! Map) return;
    days.clear();
    for (final entry in stored.entries) {
      final value = entry.value;
      if (value is Map) days[entry.key.toString()] = DayTraffic.fromJson(json(value));
    }
    prune(_clock());
  }
}

/// Samples the core's cumulative totals for the exact day/hour numbers and merges the host's
/// attribution deltas for the breakdown; persists the ledger in preferences.
class TrafficStatsStore extends ChangeNotifier {
  TrafficStatsStore._();

  static final instance = TrafficStatsStore._();
  static const prefsKey = 'trafficStatsV1';
  static const enabledKey = 'trafficStatsEnabled';
  static const detailsKey = 'trafficStatsDetails';
  static const webIconsKey = 'trafficStatsWebIcons';
  static const retentionKey = 'trafficStatsRetention';
  static const flushEvery = Duration(minutes: 5);

  final TrafficLedger ledger = TrafficLedger();
  BoxController? _box;
  StreamSubscription<Json>? _deltas;
  int? _lastUp, _lastDown;
  DateTime? _lastFlush;
  bool _loaded = false;
  String _persisted = '';

  /// Off by default (the page's own switch turns recording on).
  bool enabled = false;
  bool details = true;
  bool webIcons = true;
  int retentionDays = 7;

  void attach(BoxController box) {
    if (_box == box) return;
    _deltas?.cancel();
    _box?.removeListener(_sample);
    _box = box;
    box.addListener(_sample);
    _deltas = box.trafficDeltas.listen(_onDeltas);
    _sample();
  }

  void _load(BoxController box) {
    _loaded = true;
    final prefs = box.preferences;
    enabled = prefs[enabledKey] == true;
    details = prefs[detailsKey] != false;
    webIcons = prefs[webIconsKey] != false;
    final retention = _at(prefs[retentionKey]);
    retentionDays = retention <= 0 ? 7 : retention;
    ledger.retentionDays = retentionDays;
    final stored = prefs[prefsKey];
    if (stored is String && stored.isNotEmpty) {
      try {
        ledger.load(json(jsonDecode(stored)));
        _persisted = stored;
      } catch (_) {
        // A corrupt store is replaced by a fresh ledger on the next flush.
      }
    }
    ledger.prune(DateTime.now());
    _armHost();
  }

  static int _at(Object? value) => value is num ? value.toInt() : (value is String ? int.tryParse(value) ?? 0 : 0);

  /// Starts or stops the core's attribution feed to match the settings. Safe to call often.
  ///
  /// Unlike the rates tick, which only samples a visible UI, this feed is never
  /// visibility-gated: the ledger's continuity depends on sampling whatever the
  /// tunnel carries, including while the app is in the background. That is a
  /// deliberate exception to FlClash's UI-only rule — the feed is data work,
  /// not a frame.
  Future<void> _armHost() async {
    final box = _box;
    if (box == null) return;
    // A demand signal, not a transaction: a send that is queued behind the
    // engine handshake must not make a settings toggle (or its teardown) wait
    // for a microtask the test/route may never pump.
    unawaited(box.watchConnectionFeed(
      'attribution',
      enabled,
      intervalMs: 5000,
      details: details,
    ));
  }

  void _sample() {
    final box = _box;
    if (box == null || !box.ready) return;
    if (!_loaded) _load(box);
    final up = _at(box.dashboard['uploadTotal']);
    final down = _at(box.dashboard['downloadTotal']);
    final previousUp = _lastUp, previousDown = _lastDown;
    _lastUp = up;
    _lastDown = down;
    if (previousUp == null || previousDown == null) return;
    if (up < previousUp || down < previousDown) return; // core restart: baseline moved
    final deltaUp = up - previousUp;
    final deltaDown = down - previousDown;
    if (deltaUp == 0 && deltaDown == 0) return;
    // Recording starts when the user turns the page's switch on; the baseline keeps moving so
    // enabling mid-session does not back-fill the earlier traffic.
    if (!enabled) return;
    final profileId = _at(box.dashboard['selectedProfileId']);
    ledger.record(deltaUp, deltaDown,
        profileId: profileId > 0 ? '$profileId' : null,
        profileName: box.dashboard['selectedProfileName']?.toString());
    notifyListeners();
    _maybeFlush();
  }

  void _onDeltas(Json payload) {
    if (!enabled) return;
    ledger.mergeAttribution(payload);
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (enabled == value) return;
    enabled = value;
    notifyListeners();
    await _persistSettings();
    await _armHost();
    if (!value) await flush(force: true);
  }

  Future<void> setDetails(bool value) async {
    if (details == value) return;
    details = value;
    notifyListeners();
    await _persistSettings();
    await _armHost();
  }

  Future<void> setWebIcons(bool value) async {
    if (webIcons == value) return;
    webIcons = value;
    notifyListeners();
    await _persistSettings();
  }

  Future<void> setRetention(int days) async {
    if (retentionDays == days) return;
    retentionDays = days;
    ledger.retentionDays = days;
    ledger.prune(DateTime.now(), retentionDays: days);
    notifyListeners();
    await _persistSettings();
    await flush(force: true);
  }

  Future<void> clear() async {
    ledger.days.clear();
    ledger.prune(DateTime.now());
    notifyListeners();
    await flush(force: true);
  }

  Future<void> _persistSettings() async {
    final box = _box;
    if (box == null) return;
    try {
      await box.setPreferences({
        enabledKey: enabled,
        detailsKey: details,
        webIconsKey: webIcons,
        retentionKey: retentionDays,
      });
    } catch (_) {
      // Preferences are re-applied on the next change; the in-memory state still serves the UI.
    }
  }

  Future<bool> flush({bool force = false}) async {
    final box = _box;
    if (box == null || !_loaded) return false;
    final now = DateTime.now();
    if (!force && _lastFlush != null && now.difference(_lastFlush!) < flushEvery) return false;
    _lastFlush = now;
    final encoded = jsonEncode(ledger.toJson());
    if (encoded == _persisted) return false;
    _persisted = encoded;
    try {
      await box.setPreferences({prefsKey: encoded});
    } catch (_) {
      _persisted = '';
    }
    return true;
  }

  void _maybeFlush() {
    final now = DateTime.now();
    if (_lastFlush == null || now.difference(_lastFlush!) >= flushEvery) {
      _lastFlush = now;
      unawaited(flush(force: true));
    }
  }
}
