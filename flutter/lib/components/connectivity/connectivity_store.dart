import 'dart:async';

import 'package:flutter/foundation.dart';

import 'connectivity_checker.dart';

/// One service the connectivity page checks. Ids match Bettbox's
/// `MediaPlatform.name`, so `assets/images/platforms/<id>.svg` is the same
/// artwork the reference app ships.
enum ConnectivityCategory { ai, streaming, china, social, developer, gaming, crypto }

class ConnectivityService {
  const ConnectivityService({
    required this.id,
    required this.name,
    required this.category,
  });

  final String id;
  final String name;
  final ConnectivityCategory category;

  /// Bettbox's platform SVG, copied from its `assets/images/platforms`.
  String get asset => 'assets/images/platforms/$id.svg';
}

/// The page's status vocabulary, matching Bettbox's `MediaUnlockStatus`:
/// unlocked / limited / flagged / blocked / failed, plus the page's own
/// `testing` and `unknown`.
enum ConnectivityStatus { unknown, testing, completed, limited, flagged, blocked, failed }

class ConnectivityResult {
  const ConnectivityResult({
    this.status = ConnectivityStatus.unknown,
    this.latencyMs = 0,
    this.error = '',
    this.region = '',
    this.colo = '',
    this.ip = '',
    this.isWarp = false,
  });

  final ConnectivityStatus status;
  final int latencyMs;
  final String error;

  /// The exit region the probe reported (ISO-2 where the service tells us).
  final String region;
  final String colo;
  final String ip;
  final bool isWarp;

  bool get isCompleted =>
      status == ConnectivityStatus.completed || status == ConnectivityStatus.limited;
  bool get isBlocked =>
      status == ConnectivityStatus.blocked ||
      status == ConnectivityStatus.flagged ||
      status == ConnectivityStatus.failed;
}

const connectivityServices = <ConnectivityService>[
  ConnectivityService(id: 'openai', name: 'OpenAI', category: ConnectivityCategory.ai),
  ConnectivityService(id: 'claude', name: 'Claude', category: ConnectivityCategory.ai),
  ConnectivityService(id: 'gemini', name: 'Gemini', category: ConnectivityCategory.ai),
  ConnectivityService(id: 'grok', name: 'Grok', category: ConnectivityCategory.ai),
  ConnectivityService(id: 'openrouter', name: 'OpenRouter', category: ConnectivityCategory.ai),
  ConnectivityService(id: 'perplexity', name: 'Perplexity', category: ConnectivityCategory.ai),
  ConnectivityService(id: 'poe', name: 'Poe', category: ConnectivityCategory.ai),
  ConnectivityService(id: 'suno', name: 'Suno', category: ConnectivityCategory.ai),
  ConnectivityService(id: 'cloudflare', name: 'Cloudflare', category: ConnectivityCategory.ai),
  ConnectivityService(id: 'netflix', name: 'Netflix', category: ConnectivityCategory.streaming),
  ConnectivityService(id: 'disney', name: 'Disney+', category: ConnectivityCategory.streaming),
  ConnectivityService(id: 'youtube', name: 'YouTube', category: ConnectivityCategory.streaming),
  ConnectivityService(id: 'youtubemusic', name: 'YouTube Music', category: ConnectivityCategory.streaming),
  ConnectivityService(id: 'spotify', name: 'Spotify', category: ConnectivityCategory.streaming),
  ConnectivityService(id: 'tiktok', name: 'TikTok', category: ConnectivityCategory.streaming),
  ConnectivityService(id: 'iqiyi', name: 'iQIYI', category: ConnectivityCategory.streaming),
  ConnectivityService(id: 'crunchyroll', name: 'Crunchyroll', category: ConnectivityCategory.streaming),
  ConnectivityService(id: 'missav', name: 'MissAV', category: ConnectivityCategory.streaming),
  ConnectivityService(id: 'ehentai', name: 'E-Hentai', category: ConnectivityCategory.streaming),
  ConnectivityService(id: 'tencent', name: 'Tencent', category: ConnectivityCategory.china),
  ConnectivityService(id: 'alibaba', name: 'Alibaba', category: ConnectivityCategory.china),
  ConnectivityService(id: 'netease', name: 'NetEase', category: ConnectivityCategory.china),
  ConnectivityService(id: 'douyin', name: 'Douyin', category: ConnectivityCategory.china),
  ConnectivityService(id: 'bilibili', name: 'Bilibili', category: ConnectivityCategory.china),
  ConnectivityService(id: 'cloudflarecn', name: 'Cloudflare CN', category: ConnectivityCategory.china),
  ConnectivityService(id: 'reddit', name: 'Reddit', category: ConnectivityCategory.social),
  ConnectivityService(id: 'x', name: 'X', category: ConnectivityCategory.social),
  ConnectivityService(id: 'discord', name: 'Discord', category: ConnectivityCategory.social),
  ConnectivityService(id: 'v2ex', name: 'V2EX', category: ConnectivityCategory.social),
  ConnectivityService(id: 'medium', name: 'Medium', category: ConnectivityCategory.social),
  ConnectivityService(id: 'stackoverflow', name: 'Stack Overflow', category: ConnectivityCategory.social),
  ConnectivityService(id: 'quora', name: 'Quora', category: ConnectivityCategory.social),
  ConnectivityService(id: 'telegram', name: 'Telegram', category: ConnectivityCategory.social),
  ConnectivityService(id: 'github', name: 'GitHub', category: ConnectivityCategory.developer),
  ConnectivityService(id: 'wikipedia', name: 'Wikipedia', category: ConnectivityCategory.developer),
  ConnectivityService(id: 'apple', name: 'Apple', category: ConnectivityCategory.developer),
  ConnectivityService(id: 'onetrust', name: 'OneTrust', category: ConnectivityCategory.developer),
  ConnectivityService(id: 'gitlab', name: 'GitLab', category: ConnectivityCategory.developer),
  ConnectivityService(id: 'npm', name: 'npm', category: ConnectivityCategory.developer),
  ConnectivityService(id: 'cdnjs', name: 'cdnjs', category: ConnectivityCategory.developer),
  ConnectivityService(id: 'unpkg', name: 'unpkg', category: ConnectivityCategory.developer),
  ConnectivityService(id: 'nodejs', name: 'Node.js', category: ConnectivityCategory.developer),
  ConnectivityService(id: 'steam', name: 'Steam', category: ConnectivityCategory.gaming),
  ConnectivityService(id: 'epic', name: 'Epic Games', category: ConnectivityCategory.gaming),
  ConnectivityService(id: 'ubisoft', name: 'Ubisoft', category: ConnectivityCategory.gaming),
  ConnectivityService(id: 'humblebundle', name: 'Humble Bundle', category: ConnectivityCategory.gaming),
  ConnectivityService(id: 'coinbase', name: 'Coinbase', category: ConnectivityCategory.crypto),
  ConnectivityService(id: 'okx', name: 'OKX', category: ConnectivityCategory.crypto),
  ConnectivityService(id: 'kraken', name: 'Kraken', category: ConnectivityCategory.crypto),
  ConnectivityService(id: 'cryptocom', name: 'Crypto.com', category: ConnectivityCategory.crypto),
  ConnectivityService(id: 'phantom', name: 'Phantom', category: ConnectivityCategory.crypto),
  ConnectivityService(id: 'paypal', name: 'PayPal', category: ConnectivityCategory.crypto),
  ConnectivityService(id: 'mytvsuper', name: 'myTV SUPER', category: ConnectivityCategory.streaming),
  ConnectivityService(id: 'viutv', name: 'ViuTV', category: ConnectivityCategory.streaming),
  ConnectivityService(id: 'hoytv', name: 'HOY TV', category: ConnectivityCategory.streaming),
  ConnectivityService(id: 'rthk', name: 'RTHK', category: ConnectivityCategory.streaming),
];

/// Services Bettbox hides behind its "more streaming platforms" switch.
const connectivityMoreStreaming = {'mytvsuper', 'viutv', 'hoytv', 'rthk'};

ConnectivityService? connectivityService(String id) {
  for (final service in connectivityServices) {
    if (service.id == id) return service;
  }
  return null;
}

/// The process-wide connectivity run, modelled on Bettbox's
/// `MediaUnlockStateNotifier`:
///
///   * one request id per run; a newer run invalidates older callbacks,
///   * each result lands as it arrives (100 ms coalescing), so the page fills
///     progressively instead of waiting for the slowest service,
///   * a per-service retry only replaces that service's row,
///   * a timed-out or failed probe records `failed` without discarding the
///     previous answer of the other rows.
///
/// Unlike the reference, this checker is not proxy-configured: the app's VPN
/// already routes the process, which is the exit the cards report.
class ConnectivityStore extends ChangeNotifier {
  ConnectivityStore._();

  static final ConnectivityStore instance = ConnectivityStore._();
  static const _concurrency = 8;

  final ConnectivityChecker _checker = ConnectivityChecker();
  final Map<String, ConnectivityResult> _results = {};
  final Set<String> _testing = {};
  int _requestId = 0;
  // The 100 ms coalescing timer, kept so a new run can cancel the previous
  // burst instead of leaving its timer to fire into a dead closure.
  Timer? _flushTimer;
  bool running = false;
  DateTime? testedAt;
  Set<ConnectivityCategory> categories = {...ConnectivityCategory.values};

  /// Bettbox hides its four extra Hong Kong streaming services behind a switch;
  /// the page applies the same rule.
  bool includeMoreStreaming = false;

  void setIncludeMoreStreaming(bool value) {
    if (includeMoreStreaming == value) return;
    includeMoreStreaming = value;
    notifyListeners();
  }

  Map<String, ConnectivityResult> get results => Map.unmodifiable(_results);
  Set<String> get testing => Set.unmodifiable(_testing);
  bool isTesting(String id) => _testing.contains(id);

  void setCategories(Set<ConnectivityCategory> value) {
    categories = value;
    notifyListeners();
  }

  /// Runs every selected service, or only [ids] when given. A forced run
  /// invalidates the previous one; a normal run skips ids already in flight.
  Future<void> runAll({Iterable<String>? ids, bool force = true}) async {
    final targets = (ids ?? connectivityServices.map((s) => s.id))
        .where((id) {
          final service = connectivityService(id);
          return service != null && categories.contains(service.category);
        })
        .toList();
    if (targets.isEmpty) return;
    if (running && !force) return;
    final requestId = ++_requestId;
    if (force) {
      _testing.clear();
      _flushTimer?.cancel();
      _flushTimer = null;
    }
    running = true;
    _testing.addAll(targets);
    notifyListeners();

    final buffer = <String, ConnectivityResult>{};
    var flushScheduled = false;
    void flush() {
      if (flushScheduled) return;
      flushScheduled = true;
      _flushTimer = Timer(const Duration(milliseconds: 100), () {
        _flushTimer = null;
        flushScheduled = false;
        if (requestId != _requestId || buffer.isEmpty) return;
        _results.addAll(buffer);
        _testing.removeAll(buffer.keys.toList());
        buffer.clear();
        notifyListeners();
      });
    }

    final queue = List<String>.of(targets);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        if (requestId != _requestId) return;
        final id = queue.removeAt(0);
        final result = await _runOne(id);
        if (requestId != _requestId) return;
        buffer[id] = result;
        flush();
      }
    }

    await Future.wait([
      for (var i = 0; i < _concurrency && i < targets.length; i++) worker(),
    ]);
    if (requestId == _requestId) {
      testedAt = DateTime.now();
      running = false;
      _testing.clear();
      notifyListeners();
    }
  }

  /// One service, replacing only that row. A retry joins the sweep in flight
  /// instead of invalidating it: it only replaces its own row.
  Future<void> runOne(String id) async {
    final service = connectivityService(id);
    if (service == null) return;
    final requestId = _requestId;
    _testing.add(id);
    running = true;
    notifyListeners();
    final result = await _runOne(id);
    if (requestId != _requestId) return;
    _results[id] = result;
    _testing.remove(id);
    running = _testing.isNotEmpty;
    testedAt = DateTime.now();
    notifyListeners();
  }

  Future<ConnectivityResult> _runOne(String id) async {
    final result = await _checker.check(id);
    return ConnectivityResult(
      status: switch (result.status) {
        MediaUnlockStatus.unlocked => ConnectivityStatus.completed,
        MediaUnlockStatus.limited => ConnectivityStatus.limited,
        MediaUnlockStatus.flagged => ConnectivityStatus.flagged,
        MediaUnlockStatus.blocked => ConnectivityStatus.blocked,
        MediaUnlockStatus.failed => ConnectivityStatus.failed,
      },
      latencyMs: result.latencyMs,
      error: result.error ?? '',
      region: result.region ?? '',
      colo: result.colo ?? '',
      ip: result.ip ?? '',
      isWarp: result.isWarp,
    );
  }
}
