/// FlClash keeps its routed probe answer in a provider keyed by the route state
/// (`providers/routed_probe.dart`), so the exit-IP answer outlives the card that asked for it.
/// The status card used to keep the answer in its own State, so leaving and reopening the
/// dashboard — or the card being rebuilt by a layout edit — re-ran the outbound probe even
/// when the route had not moved. This is that provider's cache without a provider: a small
/// controller-owned map keyed by the host's route stamp plus the selected outbound.
///
/// The cache never starts a probe; it only remembers what a probe already answered, and it
/// cannot outlive the route it was measured on: the host's `routeVersion` moves on exactly the
/// events that decide where traffic exits, and a version change drops every older entry.
library;

/// The route identity an egress answer belongs to.
///
/// [routeVersion] is the host's S7 stamp (null on a wire that predates it). [outbound] is the
/// selected node/chain identity: the profile and every group's chosen member, so two chains
/// that resolve through different groups cannot share an answer even inside one version.
final class EgressKey {
  const EgressKey({required this.routeVersion, required this.outbound});
  final int? routeVersion;
  final String outbound;

  @override
  bool operator ==(Object other) =>
      other is EgressKey &&
      other.routeVersion == routeVersion &&
      other.outbound == outbound;

  @override
  int get hashCode => Object.hash(routeVersion, outbound);

  @override
  String toString() => 'EgressKey(${routeVersion ?? '?'}, $outbound)';
}

/// The outbound half of [EgressKey]: the active profile plus every group's `tag:selected`.
///
/// The host's counts-only group rows (the shape every screen but Proxies receives) still carry
/// both fields, so the dashboard builds the same identity the Proxies screen would.
String egressOutboundIdentity({
  required List<Map<String, dynamic>> groups,
  required int profileId,
}) {
  final selections = [
    for (final group in groups) '${group['tag']}:${group['selected']}',
  ]..sort();
  return '$profileId:${selections.join(',')}';
}

/// What the cache knows about a key right now.
sealed class EgressLookup {
  const EgressLookup();
}

/// A fresh answer: paint it without asking the host.
final class EgressHit extends EgressLookup {
  const EgressHit(this.answer);
  final Map<String, dynamic> answer;
}

/// A confirmed failure from the same route, still inside its cooldown.
final class EgressFailed extends EgressLookup {
  const EgressFailed(this.message, this.retryAfter);
  final String message;

  /// How much of the failure cooldown is left.
  final Duration retryAfter;
}

/// A probe for this key started too recently to start another.
final class EgressThrottled extends EgressLookup {
  const EgressThrottled(this.retryAfter);
  final Duration retryAfter;
}

/// Nothing reusable: ask the host.
final class EgressMiss extends EgressLookup {
  const EgressMiss();
}

class _EgressEntry {
  _EgressEntry.attempt(this.startedAt)
    : answeredAt = null,
      answer = null,
      failure = null;
  _EgressEntry.answer(this.startedAt, this.answeredAt, Map<String, dynamic> this.answer)
    : failure = null;
  _EgressEntry.failure(this.startedAt, this.answeredAt, String this.failure)
    : answer = null;

  final DateTime startedAt;
  final DateTime? answeredAt;
  final Map<String, dynamic>? answer;
  final String? failure;
}

class EgressCache {
  EgressCache({DateTime Function()? now}) : now = now ?? DateTime.now;

  /// Long enough to cover a dashboard switch or a card rebuild, short enough that an
  /// answer is never presented as current long after the exit was measured.
  static const maxAge = Duration(seconds: 60);

  /// FlClash's `throttleDuration`: one key may not ask the host twice inside this window.
  /// The card's own cooldown uses the same value.
  static const throttle = Duration(seconds: 5);

  /// A failure is remembered only for the cooldown the card already applies after one
  /// (`_throttleDuration`): it must not pin a failure where the current behavior would retry.
  static const failureCooldown = Duration(seconds: 5);

  /// Route versions and outbounds that are no longer current are pruned on a change, so this
  /// only bounds a session that keeps moving between chains inside one version.
  static const maxEntries = 8;

  final DateTime Function() now;
  final _entries = <EgressKey, _EgressEntry>{};
  int? _route;

  /// Drops every entry measured on another route. Null (a wire without the stamp) cannot
  /// prove a move and leaves the map alone.
  void noteRoute(int? routeVersion) {
    if (routeVersion == null || routeVersion == _route) return;
    _route = routeVersion;
    _entries.removeWhere((key, _) => key.routeVersion != routeVersion);
  }

  EgressLookup read(EgressKey key) {
    final entry = _entries[key];
    if (entry == null) return const EgressMiss();
    final moment = now();
    final answeredAt = entry.answeredAt;
    final answer = entry.answer;
    if (answer != null && answeredAt != null) {
      final age = moment.difference(answeredAt);
      if (!age.isNegative && age < maxAge) {
        return EgressHit(Map<String, dynamic>.from(answer));
      }
      _entries.remove(key);
      return const EgressMiss();
    }
    final failure = entry.failure;
    if (failure != null && answeredAt != null) {
      final age = moment.difference(answeredAt);
      if (!age.isNegative && age < failureCooldown) {
        return EgressFailed(failure, failureCooldown - age);
      }
      // An expired failure is also older than the throttle (it was answered after its
      // attempt started), so dropping it lets the card probe again.
      _entries.remove(key);
      return const EgressMiss();
    }
    final waited = moment.difference(entry.startedAt);
    if (waited.isNegative || waited < throttle) {
      return EgressThrottled(throttle - waited);
    }
    _entries.remove(key);
    return const EgressMiss();
  }

  /// Records that a probe for [key] is starting. Replaces whatever the key held: a probe is
  /// only started when nothing fresh could be reused.
  void noteAttempt(EgressKey key) {
    _evictFor(key);
    _entries[key] = _EgressEntry.attempt(now());
  }

  /// Stores an accepted egress answer. The map is copied so a later quality merge on the
  /// caller's copy cannot pollute the cache (or the next hit).
  void store(EgressKey key, Map<String, dynamic> answer) {
    final startedAt = _entries[key]?.startedAt;
    final moment = now();
    _evictFor(key);
    _entries[key] = _EgressEntry.answer(
      startedAt ?? moment,
      moment,
      Map<String, dynamic>.from(answer),
    );
  }

  /// Stores a failure the card painted (one that passed the confirmation rule, or a measured
  /// timeout); it may only be reused for [failureCooldown].
  void storeFailure(EgressKey key, String message) {
    final startedAt = _entries[key]?.startedAt;
    final moment = now();
    _evictFor(key);
    _entries[key] = _EgressEntry.failure(startedAt ?? moment, moment, message);
  }

  /// A manual refresh asks the host itself; the remembered answer must not stand in for it.
  void invalidate(EgressKey key) => _entries.remove(key);

  void _evictFor(EgressKey key) {
    if (_entries.containsKey(key) || _entries.length < maxEntries) return;
    _entries.remove(_entries.keys.first);
  }
}
