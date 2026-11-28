// The stored `autoselector` outbound document, as the profile row keeps it.
//
// S7: the auto-selector editor's document state moved from Kotlin's
// `FlroneProfiles.autoSelector*` + the Throne `AutoSelector` outbound model to
// Dart, which owns `profiles.json` anyway. Only the runtime shadow (a live
// status read, a recheck request, the pin notice) stays in Kotlin — those need
// the kernel-backed service engine.
//
// This is a codec, not a second model: it mirrors `AutoSelector.exportToJson`
// (app/src/main/java/io/nekohasekai/sagernet/outbound/types/AutoSelector.kt) key
// for key, including the sorted-key compact text `JsonWriter` emits, so a row
// written here parses identically in Kotlin's `DartProfileStore` and Go's
// `config_build_selector.go`. The `pool` / `last_built` / `history` columns are
// runtime state: reads carry them through and only an explicit save of those
// fields would touch them — the editor never sends them, so a Dart edit cannot
// wipe a live ranking the service engine wrote.

import 'dart:convert';

/// The outbound type string every selector row and document carries.
const String autoSelectorType = 'autoselector';

/// The name a selector created without one gets (`createAutoSelector`).
const String autoSelectorDefaultName = 'Auto Selector';

/// One stored auto-selector document (`AutoSelector.exportToJson`).
class AutoSelectorDocument {
  AutoSelectorDocument({
    this.name = '',
    List<int>? gids,
    this.nameFilter = '',
    this.countryFilter = '',
    this.excludeUnavailable = true,
    this.poolCap = 1000,
    this.buildLimit = 300,
    this.resultValidityMins = 1440,
    this.testURL = '',
    this.connectivityURL = '',
    this.intervalSec = 300,
    this.benchIntervalSec = 600,
    this.watchIntervalSec = 15,
    this.activeSize = 8,
    this.sampling = 10,
    this.toleranceMs = 300,
    this.maxRTTms = 0,
    this.expected = 3,
    this.dialRetries = 2,
    this.interruptOnSwitch = true,
    this.balance = false,
    this.balanceMode = 'rotate',
    this.balanceIntervalSec = 30,
    List<int>? pool,
    this.poolRankedAt = 0,
    this.pinnedId = -1,
    List<int>? lastBuilt,
    this.lastBuiltAt = 0,
    List<Object?>? history,
  })  : gids = gids ?? <int>[],
        pool = pool ?? <int>[],
        lastBuilt = lastBuilt ?? <int>[],
        history = history ?? <Object?>[];

  /// `AutoSelector()`'s member defaults: a fresh selector tracks no group and
  /// has no ranking yet.
  factory AutoSelectorDocument.defaults() => AutoSelectorDocument();

  /// Parses one stored `outbound_json`, applying `AutoSelector.parseFromJson`'s
  /// defaults for absent keys and its lenient type rules for wrong ones, then
  /// [normalize] (`parseFromJson` runs it before every plan).
  factory AutoSelectorDocument.fromJson(Map<String, dynamic> json) {
    final document = AutoSelectorDocument(
      name: json['name'] is String ? json['name'] as String : '',
      gids: _parseGids(json),
      nameFilter: json['name_filter'] is String ? json['name_filter'] as String : '',
      countryFilter:
          json['country_filter'] is String ? json['country_filter'] as String : '',
      excludeUnavailable: _boolOr(json['exclude_unavailable'], true),
      poolCap: _intOr(json['pool_cap'], 1000),
      buildLimit: _intOr(json['build_limit'], 300),
      resultValidityMins: _intOr(json['result_validity_mins'], 1440),
      testURL: json['test_url'] is String ? json['test_url'] as String : '',
      connectivityURL:
          json['connectivity_url'] is String ? json['connectivity_url'] as String : '',
      intervalSec: _intOr(json['interval_sec'], 300),
      benchIntervalSec: _intOr(json['bench_interval_sec'], 600),
      watchIntervalSec: _intOr(json['watch_interval_sec'], 15),
      activeSize: _intOr(json['active_size'], 8),
      sampling: _intOr(json['sampling'], 10),
      toleranceMs: _intOr(json['tolerance_ms'], 300),
      maxRTTms: _intOr(json['max_rtt_ms'], 0),
      expected: _intOr(json['expected'], 3),
      dialRetries: _intOr(json['dial_retries'], 2),
      interruptOnSwitch: _boolOr(json['interrupt_on_switch'], true),
      balance: _boolOr(json['balance'], false),
      balanceMode:
          json['balance_mode'] is String ? json['balance_mode'] as String : 'rotate',
      balanceIntervalSec: _intOr(json['balance_interval_sec'], 30),
      pool: _intList(json['pool']),
      poolRankedAt: _doubleAsLong(json['pool_ranked_at']),
      pinnedId: _longOr(json['pinned_id'], -1),
      lastBuilt: _intList(json['last_built']),
      lastBuiltAt: _doubleAsLong(json['last_built_at']),
      history: json['history'] is List
          ? List<Object?>.of(json['history'] as List)
          : <Object?>[],
    );
    return document..normalize();
  }

  /// The Kotlin `parseFromJson` failure case: an empty object is not a selector.
  static bool isSelectorJson(Map<String, dynamic> json) => json.isNotEmpty;

  String name;
  List<int> gids;
  String nameFilter;
  String countryFilter;
  bool excludeUnavailable;
  int poolCap;
  int buildLimit;
  int resultValidityMins;
  String testURL;
  String connectivityURL;
  int intervalSec;
  int benchIntervalSec;
  int watchIntervalSec;
  int activeSize;
  int sampling;
  int toleranceMs;
  int maxRTTms;
  int expected;
  int dialRetries;
  bool interruptOnSwitch;
  bool balance;
  String balanceMode;
  int balanceIntervalSec;

  /// Runtime ranking state (the service engine's core writes it). Carried
  /// through unchanged by an editor save.
  List<int> pool;
  int poolRankedAt;

  /// The hand-picked member, -1 = automatic.
  int pinnedId;

  /// Runtime build state, carried through like [pool].
  List<int> lastBuilt;
  int lastBuiltAt;
  List<Object?> history;

  /// `AutoSelector.normalize` (autoselector.h:140-167), in its exact order: the
  /// stored document is what the next config build reads, so clamping has to
  /// happen on the same values here.
  void normalize() {
    final seen = <int>{};
    gids = <int>[
      for (final gid in gids)
        if (gid >= 0 && seen.add(gid)) gid,
    ];
    if (poolCap < 1) poolCap = 1;
    if (poolCap > maxPoolCap) poolCap = maxPoolCap;
    if (buildLimit < 1) buildLimit = 1;
    if (buildLimit > maxBuildLimit) buildLimit = maxBuildLimit;
    if (buildLimit > poolCap) buildLimit = poolCap;
    if (resultValidityMins < 0) resultValidityMins = 0;
    if (intervalSec < 10) intervalSec = 10;
    if (benchIntervalSec < intervalSec) benchIntervalSec = intervalSec;
    if (watchIntervalSec < 5) watchIntervalSec = 5;
    if (watchIntervalSec > intervalSec) watchIntervalSec = intervalSec;
    if (activeSize < 1) activeSize = 1;
    if (expected < 1) expected = 1;
    if (activeSize < expected) activeSize = expected;
    if (activeSize > buildLimit) activeSize = buildLimit;
    if (sampling < 2) sampling = 2;
    if (sampling > 60) sampling = 60;
    if (toleranceMs < 0) toleranceMs = 0;
    if (maxRTTms < 0) maxRTTms = 0;
    if (expected > buildLimit) expected = buildLimit;
    if (dialRetries < 0) dialRetries = 0;
    if (dialRetries > 5) dialRetries = 5;
    if (balanceIntervalSec < 5) balanceIntervalSec = 5;
    if (balanceMode != 'connection') balanceMode = 'rotate';
  }

  /// Applies the editor's form values (`autoSelectorSave`). Only the documented
  /// keys change; absent keys keep their stored value, strings are trimmed and
  /// ints get `coerceAtLeast` — the same rules as `FlroneProfiles.autoSelectorSave`,
  /// which deliberately does NOT normalise (the next load does).
  void applyEditorValues(Map<String, dynamic> values) {
    final name = values['name'];
    if (name is String) this.name = name.trim();
    final nameFilter = values['nameFilter'];
    if (nameFilter is String) this.nameFilter = nameFilter.trim();
    final countryFilter = values['countryFilter'];
    if (countryFilter is String) this.countryFilter = countryFilter.trim();
    final testURL = values['testURL'];
    if (testURL is String) this.testURL = testURL.trim();
    final connectivityURL = values['connectivityURL'];
    if (connectivityURL is String) this.connectivityURL = connectivityURL.trim();
    final balanceMode = values['balanceMode'];
    if (balanceMode is String) this.balanceMode = balanceMode.trim();
    final excludeUnavailable = values['excludeUnavailable'];
    if (excludeUnavailable is bool) this.excludeUnavailable = excludeUnavailable;
    final interruptOnSwitch = values['interruptOnSwitch'];
    if (interruptOnSwitch is bool) this.interruptOnSwitch = interruptOnSwitch;
    final balance = values['balance'];
    if (balance is bool) this.balance = balance;

    int? intOf(String key) {
      final value = values[key];
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    }

    void setAtLeast(String key, int minimum, void Function(int) assign) {
      final value = intOf(key);
      if (value != null) assign(value < minimum ? minimum : value);
    }

    setAtLeast('poolCap', 0, (value) => poolCap = value);
    setAtLeast('buildLimit', 0, (value) => buildLimit = value);
    setAtLeast('resultValidityMins', 0, (value) => resultValidityMins = value);
    setAtLeast('intervalSec', 1, (value) => intervalSec = value);
    setAtLeast('benchIntervalSec', 1, (value) => benchIntervalSec = value);
    setAtLeast('watchIntervalSec', 1, (value) => watchIntervalSec = value);
    setAtLeast('activeSize', 1, (value) => activeSize = value);
    setAtLeast('sampling', 1, (value) => sampling = value);
    setAtLeast('toleranceMs', 0, (value) => toleranceMs = value);
    setAtLeast('maxRTTms', 0, (value) => maxRTTms = value);
    setAtLeast('expected', 1, (value) => expected = value);
    setAtLeast('dialRetries', 0, (value) => dialRetries = value);
    setAtLeast('balanceIntervalSec', 1, (value) => balanceIntervalSec = value);

    final gids = values['gids'];
    if (gids is List) {
      this.gids = <int>[
        for (final gid in gids)
          if (gid is num) gid.toInt(),
      ];
    }
  }

  /// The editor's seed (`FlroneProfiles.autoSelectorInfo`): the camelCase keys
  /// `auto_selector.dart` reads. `id`, `gids` (already ints) and `pinnedId` are
  /// the historical shapes; Kotlin widened the ids to Long for Room and narrowed
  /// them back here.
  Map<String, dynamic> toEditor() => <String, dynamic>{
        'name': name,
        'nameFilter': nameFilter,
        'countryFilter': countryFilter,
        'excludeUnavailable': excludeUnavailable,
        'poolCap': poolCap,
        'buildLimit': buildLimit,
        'resultValidityMins': resultValidityMins,
        'testURL': testURL,
        'connectivityURL': connectivityURL,
        'intervalSec': intervalSec,
        'benchIntervalSec': benchIntervalSec,
        'watchIntervalSec': watchIntervalSec,
        'activeSize': activeSize,
        'sampling': sampling,
        'toleranceMs': toleranceMs,
        'maxRTTms': maxRTTms,
        'expected': expected,
        'dialRetries': dialRetries,
        'interruptOnSwitch': interruptOnSwitch,
        'balance': balance,
        'balanceMode': balanceMode,
        'balanceIntervalSec': balanceIntervalSec,
        'gids': <int>[...gids],
        'pinnedId': pinnedId,
      };

  /// `AutoSelector.exportToJson`: every key is always written, `gid` keeps older
  /// builds tracking one group, and the text is key-sorted like `JsonWriter`
  /// (`jsonEncode` preserves insertion order, so the literal is in sorted order).
  Map<String, dynamic> toJson() => <String, dynamic>{
        'active_size': activeSize,
        'balance': balance,
        'balance_interval_sec': balanceIntervalSec,
        'balance_mode': balanceMode,
        'bench_interval_sec': benchIntervalSec,
        'build_limit': buildLimit,
        'connectivity_url': connectivityURL,
        'country_filter': countryFilter,
        'dial_retries': dialRetries,
        'exclude_unavailable': excludeUnavailable,
        'expected': expected,
        'gid': gids.isEmpty ? -1 : gids.first,
        'gids': <int>[...gids],
        'history': List<Object?>.of(history),
        'interrupt_on_switch': interruptOnSwitch,
        'interval_sec': intervalSec,
        'last_built': <int>[...lastBuilt],
        'last_built_at': lastBuiltAt,
        'max_rtt_ms': maxRTTms,
        'name': name,
        'name_filter': nameFilter,
        'pinned_id': pinnedId,
        'pool': <int>[...pool],
        'pool_cap': poolCap,
        'pool_ranked_at': poolRankedAt,
        'result_validity_mins': resultValidityMins,
        'sampling': sampling,
        'test_url': testURL,
        'tolerance_ms': toleranceMs,
        'type': autoSelectorType,
        'watch_interval_sec': watchIntervalSec,
      };

  /// The compact stored text (`JsonWriter.write`, sorted keys).
  String encode() => jsonEncode(toJson());

  static const int maxPoolCap = 3000;
  static const int maxBuildLimit = 500;

  static List<int> _parseGids(Map<String, dynamic> json) {
    if (json.containsKey('gids')) {
      final raw = json['gids'];
      if (raw is! List) return <int>[];
      final gids = <int>[];
      for (final value in raw) {
        final gid = _longOr(value, -1);
        if (gid >= 0) gids.add(gid);
      }
      return gids;
    }
    if (json.containsKey('gid')) {
      final gid = _longOr(json['gid'], -1);
      return gid >= 0 ? <int>[gid] : <int>[];
    }
    return <int>[];
  }

  /// `obj.array(key).mapTo { JsonValues.toInteger(it) }`: a non-number element
  /// reads as 0, a whole double that fits a long reads as that number.
  static List<int> _intList(Object? value) {
    if (value is! List) return <int>[];
    return <int>[
      for (final item in value) _toInteger(item),
    ];
  }

  static int _toInteger(Object? value) {
    if (value is int) return value;
    if (value is double) {
      if (value.isFinite &&
          value == value.truncateToDouble() &&
          value >= -9223372036854775808.0 &&
          value < 9223372036854775807.0) {
        return value.toInt();
      }
    }
    return 0;
  }

  /// `obj.double(key).toLong()`: only a number counts, truncated toward zero.
  static int _doubleAsLong(Object? value) {
    if (value is int) return value;
    if (value is double) {
      if (!value.isFinite) return 0;
      final truncated = value.truncateToDouble();
      if (truncated < -9223372036854775808.0 ||
          truncated > 9223372036854775807.0) {
        return 0;
      }
      return truncated.toInt();
    }
    return 0;
  }

  /// `AutoSelector.intOr`: a whole number that fits an Int, else the default.
  static int _intOr(Object? value, int fallback) {
    if (value is int) {
      return value >= -0x80000000 && value <= 0x7fffffff ? value : fallback;
    }
    if (value is double) {
      return value == value.truncateToDouble() &&
              value >= -2147483648.0 &&
              value <= 2147483647.0
          ? value.toInt()
          : fallback;
    }
    return fallback;
  }

  /// `AutoSelector.longOr`.
  static int _longOr(Object? value, int fallback) {
    if (value is int) return value;
    if (value is double) {
      return value.isFinite &&
              value == value.truncateToDouble() &&
              value >= -9223372036854775808.0 &&
              value < 9223372036854775807.0
          ? value.toInt()
          : fallback;
    }
    return fallback;
  }

  /// `AutoSelector.boolOr`: only a JSON boolean counts.
  static bool _boolOr(Object? value, bool fallback) =>
      value is bool ? value : fallback;
}
