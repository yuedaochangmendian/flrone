// The route profile list, read straight from Room's file.
//
// This is a read-only reproduction of `BboxRoutes.list()`, not a rewrite of it:
// the screen consumes a fixed wire shape, so the SQL and that shape have to stay
// in step. Keeping them beside each other is what makes a column change fail
// loudly here instead of quietly returning a different list.
//
// STATUS: the data-plane slice. `RouteProfilesSource` calls
// [RouteProfilesDao.listWire]; the routing UI itself reads the kernel's action
// bus. `current_route_id` is not in Room any more (schema 21), so the caller
// passes the selection in.

import 'sqlite.dart';

/// `RuleType` ids for the four "simple address" rules, matching
/// `BboxRoutes.addressTypes` (RuleType.kt). Kept as a sorted list so the SQL
/// below and the count they produce cannot drift apart.
const simpleAddressRuleTypes = <int>[1, 2, 3, 10];

/// `SettingsRegistry.CURRENT_ROUTE_ID`'s default. The Kotlin side answers
/// `1L` when the row is missing or the stored value fails `{ it > 0 }`.
const defaultCurrentRouteId = 1;

/// `OutboundIds` (RouteRule targets) as the list wire's `defaultOutbound` token,
/// matching `BboxRoutes.list()`.
const defaultOutboundTokens = <int, String>{-1: 'proxy', -3: 'block', -5: 'warp-bypass'};

/// One `route_profiles` row plus the two counts the list shows.
class RouteProfileRow {
  const RouteProfileRow({
    required this.id,
    required this.name,
    required this.defaultOutbound,
    required this.isRemote,
    required this.isRaw,
    required this.ruleCount,
    required this.simpleRuleCount,
  });

  final int id;
  final String name;

  /// The token `BboxRoutes.list()` puts in `defaultOutbound`: proxy / direct /
  /// block / warp-bypass, `direct` being the fallback for every other id.
  final String defaultOutbound;
  final bool isRemote;
  final bool isRaw;

  /// Every `route_rules` row of this profile. `RouteManager.load()` does not
  /// filter `disabled`, so neither does the count.
  final int ruleCount;

  /// The subset whose type is a simple address rule.
  final int simpleRuleCount;

  factory RouteProfileRow.fromRow(SqlRow row) => RouteProfileRow(
        id: _int(row, 'id'),
        name: _string(row, 'name'),
        defaultOutbound:
            defaultOutboundTokens[_int(row, 'default_outbound_id', fallback: -2)] ?? 'direct',
        isRemote: _bool(row, 'is_remote'),
        isRaw: _bool(row, 'is_raw'),
        ruleCount: _int(row, 'rule_count'),
        simpleRuleCount: _int(row, 'simple_rule_count'),
      );

  /// Exactly one entry of `routes.list`'s `profiles` array.
  Map<String, Object?> toWire(int currentId) => <String, Object?>{
        'id': id,
        'name': name,
        'defaultOutbound': defaultOutbound,
        'current': id == currentId,
        'isRemote': isRemote,
        'isRaw': isRaw,
        'ruleCount': ruleCount,
        'simpleRuleCount': simpleRuleCount,
      };

  // Room stores booleans as INTEGER 0/1 and a column added by a migration can
  // still be null on an older row. Both collapse here so no caller has to know.
  static int _int(SqlRow row, String column, {int fallback = 0}) {
    final value = row[column];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return fallback;
  }

  static String _string(SqlRow row, String column) {
    final value = row[column];
    return value is String ? value : '';
  }

  static bool _bool(SqlRow row, String column) => _int(row, column) != 0;

  /// `settings.value` is decimal text (SettingsStore.decodeLong). Accept the
  /// integer shape too, and treat a missing / unparsable / non-positive value as
  /// the registry default, exactly as `DataStore.currentRouteId` does.
  static int parseCurrentId(Object? value) {
    final int? parsed;
    if (value is int) {
      parsed = value;
    } else if (value is num) {
      parsed = value.toInt();
    } else if (value is String) {
      parsed = int.tryParse(value.trim());
    } else {
      parsed = null;
    }
    return parsed != null && parsed > 0 ? parsed : defaultCurrentRouteId;
  }

  @override
  String toString() => 'RouteProfileRow($id, $name, $ruleCount rules)';
}

/// Reads `route_profiles` and its rules.
///
/// The DAO takes a [Queryable] rather than a [DataDatabase] so the mapping is
/// testable without a database — the same shape as [GroupsDao].
///
/// Schema 21 retired Room's `settings` table (ADR 0006 stage C2b), so the
/// selection (`current_route_id`) can no longer be read from this file: it
/// lives in `documents/settings.json`, whose readers are the kernel's action
/// bus and the host. [listWire] takes the value as an argument instead of
/// querying for it.
class RouteProfilesDao {
  const RouteProfilesDao(this._db);

  final Queryable _db;

  /// `RouteDao.allProfiles()` orders by id; `RouteManager.load()` groups every
  /// rule row by `route_profile_id` and counts all of them, including disabled
  /// ones. LEFT JOIN + COUNT on the join key reproduces both: a profile with no
  /// rules yields 0 rather than disappearing.
  static final _select = '''
SELECT p.id, p.name, p.default_outbound_id, p.is_remote, p.is_raw,
       COUNT(r.route_profile_id) AS rule_count,
       COALESCE(SUM(CASE WHEN r.type IN (${simpleAddressRuleTypes.join(', ')}) THEN 1 ELSE 0 END), 0) AS simple_rule_count
FROM route_profiles p
LEFT JOIN route_rules r ON r.route_profile_id = p.id
GROUP BY p.id, p.name, p.default_outbound_id, p.is_remote, p.is_raw
ORDER BY p.id''';

  List<RouteProfileRow> list() =>
      _db.query(_select).map(RouteProfileRow.fromRow).toList();

  /// The whole `routes.list` reply: `{currentId, profiles: [...]}`.
  ///
  /// [currentRouteId] is the selection as the caller knows it (the settings
  /// document, or the kernel's action bus). Null — the default this slice has
  /// without one — is the fresh-install answer.
  Map<String, Object?> listWire({Object? currentRouteId}) {
    final current = RouteProfileRow.parseCurrentId(currentRouteId);
    return <String, Object?>{
      'currentId': current,
      'profiles': list().map((row) => row.toWire(current)).toList(),
    };
  }
}
