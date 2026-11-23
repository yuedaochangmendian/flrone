import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:flutter/foundation.dart';

import '../box.dart';

String _two(int value) => value.toString().padLeft(2, '0');

/// One day of traffic: hour buckets plus the per-profile split for the same day.
class DayTraffic {
  DayTraffic();
  int up = 0;
  int down = 0;
  final List<int> hourUp = List<int>.filled(24, 0);
  final List<int> hourDown = List<int>.filled(24, 0);
  final Map<String, ProfileTraffic> profiles = {};

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
      profile.up += upDelta;
      profile.down += downDelta;
    }
    return this;
  }

  Json toJson() => {
    'up': up,
    'down': down,
    'hu': hourUp,
    'hd': hourDown,
    if (profiles.isNotEmpty)
      'p': {for (final entry in profiles.entries) entry.key: entry.value.toJson()},
  };

  static DayTraffic fromJson(Json data) {
    final day = DayTraffic()
      ..up = (data['up'] as num?)?.toInt() ?? 0
      ..down = (data['down'] as num?)?.toInt() ?? 0;
    final up = data['hu'];
    final down = data['hd'];
    for (var i = 0; i < 24; i++) {
      day.hourUp[i] = up is List && i < up.length ? (up[i] as num?)?.toInt() ?? 0 : 0;
      day.hourDown[i] = down is List && i < down.length ? (down[i] as num?)?.toInt() ?? 0 : 0;
    }
    final profiles = data['p'];
    if (profiles is Map) {
      for (final entry in profiles.entries) {
        final value = entry.value;
        if (value is Map) {
          final profile = ProfileTraffic.fromJson(json(value));
          if (profile.name.isEmpty && profile.up + profile.down == 0) continue;
          day.profiles[entry.key.toString()] = profile;
        }
      }
    }
    return day;
  }
}

class ProfileTraffic {
  ProfileTraffic();
  String name = '';
  int up = 0;
  int down = 0;
  int get total => up + down;

  Json toJson() => {'n': name, 'up': up, 'down': down};

  static ProfileTraffic fromJson(Json data) => ProfileTraffic()
    ..name = data['n']?.toString() ?? ''
    ..up = (data['up'] as num?)?.toInt() ?? 0
    ..down = (data['down'] as num?)?.toInt() ?? 0;
}

/// The pure traffic ledger: local-date keyed days, with a retention window.
///
/// The numbers come from the core's cumulative session totals, so a day is the sum of the
/// deltas observed while this app was running — the same accounting Bettbox keeps in its Go
/// traffic_stats store, with the per-hour and per-profile split it records per day.
class TrafficLedger {
  TrafficLedger({DateTime Function()? clock, this.retentionDays = 30})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final int retentionDays;
  final Map<String, DayTraffic> days = {};
  String? _sessionDay;

  static String keyOf(DateTime at) => '${at.year}-${_two(at.month)}-${_two(at.day)}';

  DateTime today() => _clock();

  /// Records one observed delta. A day rollover starts a new bucket; old days are pruned.
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

  void prune(DateTime now) {
    final cutoff = DateTime(now.year, now.month, now.day).subtract(Duration(days: retentionDays - 1));
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
        'v': 1,
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

/// Samples the core's cumulative upload/download totals off the controller and persists the
/// ledger in preferences (every 5 minutes, and on a lifecycle pause).
///
/// A decrease means the core restarted: the sample re-baselines instead of counting a negative
/// delta, so a restart never erases the day.
class TrafficStatsStore extends ChangeNotifier {
  TrafficStatsStore._();

  static final instance = TrafficStatsStore._();
  static const prefsKey = 'trafficStatsV1';
  static const flushEvery = Duration(minutes: 5);

  final TrafficLedger ledger = TrafficLedger();
  BoxController? _box;
  int? _lastUp, _lastDown;
  DateTime? _lastFlush;
  bool _loaded = false;
  String _persisted = '';

  void attach(BoxController box) {
    if (_box == box) return;
    _box?.removeListener(_sample);
    _box = box;
    box.addListener(_sample);
    _sample();
  }

  void _sample() {
    final box = _box;
    if (box == null || !box.ready) return;
    if (!_loaded) {
      _loaded = true;
      final stored = box.preferences[prefsKey];
      if (stored is String && stored.isNotEmpty) {
        try {
          ledger.load(json(jsonDecode(stored)));
          _persisted = stored;
        } catch (_) {
          // A corrupt store is replaced by a fresh ledger on the next flush.
        }
      }
    }
    // The dashboard comes off the channel: tests and a half-written payload may carry strings
    // where the wire normally has numbers, so convert instead of casting.
    final up = _asInt(box.dashboard['uploadTotal']);
    final down = _asInt(box.dashboard['downloadTotal']);
    if (up == null || down == null) return;
    final previousUp = _lastUp, previousDown = _lastDown;
    _lastUp = up;
    _lastDown = down;
    if (previousUp == null || previousDown == null) return;
    if (up < previousUp || down < previousDown) return; // core restart: baseline moved
    final deltaUp = up - previousUp;
    final deltaDown = down - previousDown;
    if (deltaUp == 0 && deltaDown == 0) return;
    final profileId = _asInt(box.dashboard['selectedProfileId']);
    ledger.record(deltaUp, deltaDown,
        profileId: profileId != null && profileId > 0 ? '$profileId' : null,
        profileName: box.dashboard['selectedProfileName']?.toString());
    notifyListeners();
    _maybeFlush();
  }

  static int? _asInt(Object? value) =>
      value is num ? value.toInt() : (value is String ? int.tryParse(value) : null);

  /// Persists when the 5-minute window elapsed. Returns whether a write happened.
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
      // A failed write is retried at the next window; the in-memory ledger still serves the UI.
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

  @visibleForTesting
  void resetForTest({int? lastUp, int? lastDown, bool loaded = true}) {
    _box = null;
    _lastUp = lastUp;
    _lastDown = lastDown;
    _loaded = loaded;
    _persisted = '';
    _lastFlush = null;
  }
}
