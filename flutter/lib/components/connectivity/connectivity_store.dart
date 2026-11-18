import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One service the connectivity page checks. The short label stands in for the
/// Bettbox platform SVGs we do not vendor: a compact brand-coloured chip keeps
/// the row readable without another asset pipeline.
enum ConnectivityCategory { ai, streaming, china, social }

class ConnectivityService {
  const ConnectivityService({
    required this.id,
    required this.name,
    required this.short,
    required this.color,
    required this.category,
    required this.url,
  });

  final String id;
  final String name;
  final String short;
  final int color;
  final ConnectivityCategory category;
  final String url;
}

enum ConnectivityStatus { unknown, testing, completed, limited, blocked, failed }

class ConnectivityResult {
  const ConnectivityResult({
    this.status = ConnectivityStatus.unknown,
    this.latencyMs = 0,
    this.error = '',
    this.countryCode = '',
  });

  final ConnectivityStatus status;
  final int latencyMs;
  final String error;
  final String countryCode;

  bool get isCompleted =>
      status == ConnectivityStatus.completed || status == ConnectivityStatus.limited;
  bool get isBlocked => status == ConnectivityStatus.blocked;
}

const connectivityServices = <ConnectivityService>[
  ConnectivityService(id: 'openai', name: 'OpenAI', short: 'AI', color: 0xFF10A37F,
    category: ConnectivityCategory.ai, url: 'https://chatgpt.com/'),
  ConnectivityService(id: 'claude', name: 'Claude', short: 'C', color: 0xFFD97757,
    category: ConnectivityCategory.ai, url: 'https://claude.ai/'),
  ConnectivityService(id: 'gemini', name: 'Gemini', short: 'G', color: 0xFF4285F4,
    category: ConnectivityCategory.ai, url: 'https://gemini.google.com/'),
  ConnectivityService(id: 'grok', name: 'Grok', short: 'X', color: 0xFF111111,
    category: ConnectivityCategory.ai, url: 'https://grok.com/'),
  ConnectivityService(id: 'openrouter', name: 'OpenRouter', short: 'OR', color: 0xFF6B4EFF,
    category: ConnectivityCategory.ai, url: 'https://openrouter.ai/'),
  ConnectivityService(id: 'perplexity', name: 'Perplexity', short: 'P', color: 0xFF20808D,
    category: ConnectivityCategory.ai, url: 'https://www.perplexity.ai/'),
  ConnectivityService(id: 'cloudflare', name: 'Cloudflare', short: 'CF', color: 0xFFF38020,
    category: ConnectivityCategory.ai, url: 'https://www.cloudflare.com/'),
  ConnectivityService(id: 'netflix', name: 'Netflix', short: 'N', color: 0xFFE50914,
    category: ConnectivityCategory.streaming, url: 'https://www.netflix.com/'),
  ConnectivityService(id: 'disney', name: 'Disney+', short: 'D+', color: 0xFF113CCF,
    category: ConnectivityCategory.streaming, url: 'https://www.disneyplus.com/'),
  ConnectivityService(id: 'youtube', name: 'YouTube', short: 'YT', color: 0xFFFF0000,
    category: ConnectivityCategory.streaming, url: 'https://www.youtube.com/'),
  ConnectivityService(id: 'spotify', name: 'Spotify', short: 'S', color: 0xFF1DB954,
    category: ConnectivityCategory.streaming, url: 'https://open.spotify.com/'),
  ConnectivityService(id: 'tiktok', name: 'TikTok', short: 'TT', color: 0xFF010101,
    category: ConnectivityCategory.streaming, url: 'https://www.tiktok.com/'),
  ConnectivityService(id: 'ehentai', name: 'E-Hentai', short: 'EH', color: 0xFFE32636,
    category: ConnectivityCategory.streaming, url: 'https://e-hentai.org/'),
  ConnectivityService(id: 'bilibili', name: 'Bilibili', short: 'B', color: 0xFF00A1D6,
    category: ConnectivityCategory.china, url: 'https://www.bilibili.com/'),
  ConnectivityService(id: 'douyin', name: 'Douyin', short: 'DY', color: 0xFF161823,
    category: ConnectivityCategory.china, url: 'https://www.douyin.com/'),
  ConnectivityService(id: 'tencent', name: 'Tencent', short: 'T', color: 0xFF1296DB,
    category: ConnectivityCategory.china, url: 'https://www.qq.com/'),
  ConnectivityService(id: 'netease', name: 'NetEase', short: 'NE', color: 0xFFD43C33,
    category: ConnectivityCategory.china, url: 'https://www.163.com/'),
  ConnectivityService(id: 'reddit', name: 'Reddit', short: 'R', color: 0xFFFF4500,
    category: ConnectivityCategory.social, url: 'https://www.reddit.com/'),
  ConnectivityService(id: 'x', name: 'X', short: 'X', color: 0xFF111111,
    category: ConnectivityCategory.social, url: 'https://x.com/'),
  ConnectivityService(id: 'discord', name: 'Discord', short: 'DC', color: 0xFF5865F2,
    category: ConnectivityCategory.social, url: 'https://discord.com/'),
  ConnectivityService(id: 'v2ex', name: 'V2EX', short: 'V2', color: 0xFF778087,
    category: ConnectivityCategory.social, url: 'https://www.v2ex.com/'),
  ConnectivityService(id: 'telegram', name: 'Telegram', short: 'TG', color: 0xFF229ED9,
    category: ConnectivityCategory.social, url: 'https://telegram.org/'),
];

ConnectivityService? connectivityService(String id) {
  for (final service in connectivityServices) {
    if (service.id == id) return service;
  }
  return null;
}

/// The process-wide last connectivity run. Dashboard and page both read it, so
/// opening the page after a card refresh does not start a second sweep.
class ConnectivityStore extends ChangeNotifier {
  ConnectivityStore._();

  static final ConnectivityStore instance = ConnectivityStore._();
  static const _timeout = Duration(seconds: 6);

  final Map<String, ConnectivityResult> _results = {};
  Map<String, ConnectivityResult> get results => Map.unmodifiable(_results);
  bool running = false;
  String countryCode = '';
  DateTime? testedAt;
  Set<ConnectivityCategory> categories = {...ConnectivityCategory.values};

  void setCategories(Set<ConnectivityCategory> value) {
    categories = value;
    notifyListeners();
  }

  Future<void>? _inFlight;

  Future<void> runAll({int concurrency = 4}) {
    final active = _inFlight;
    if (active != null) return active;
    final future = _runAll(concurrency);
    _inFlight = future;
    return future;
  }

  Future<void> _runAll(int concurrency) async {
    running = true;
    notifyListeners();
    try {
      countryCode = await _probeCountry() ?? countryCode;
      final targets = connectivityServices
          .where((service) => categories.contains(service.category))
          .toList();
      for (var index = 0; index < targets.length; index += concurrency) {
        final batch = targets.skip(index).take(concurrency).toList();
        await Future.wait(batch.map(_test));
      }
      testedAt = DateTime.now();
    } finally {
      running = false;
      _inFlight = null;
      notifyListeners();
    }
  }

  Future<void> runOne(ConnectivityService service) async {
    await _test(service);
    testedAt = DateTime.now();
    notifyListeners();
  }

  Future<void> _test(ConnectivityService service) async {
    _results[service.id] = const ConnectivityResult(status: ConnectivityStatus.testing);
    notifyListeners();
    final result = await _probe(service);
    _results[service.id] = ConnectivityResult(
      status: result.status,
      latencyMs: result.latencyMs,
      error: result.error,
      countryCode: countryCode,
    );
    notifyListeners();
  }

  Future<ConnectivityResult> _probe(ConnectivityService service) async {
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..idleTimeout = _timeout;
    try {
      final watch = Stopwatch()..start();
      final request = await client.getUrl(Uri.parse(service.url)).timeout(_timeout);
      request.followRedirects = true;
      request.headers.set(HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36');
      final response = await request.close().timeout(_timeout);
      final latency = watch.elapsedMilliseconds;
      await response.drain<void>().timeout(const Duration(seconds: 2)).catchError((_) {});
      return ConnectivityResult(status: statusForCode(response.statusCode), latencyMs: latency);
    } on TimeoutException {
      return const ConnectivityResult(status: ConnectivityStatus.failed, error: 'timeout');
    } catch (error) {
      return ConnectivityResult(status: ConnectivityStatus.failed, error: '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// HTTP status -> row status. A Cloudflare challenge or a regional 403/451 is
  /// "blocked"; 429 is a rate limit, not a blocked exit.
  static ConnectivityStatus statusForCode(int code) => switch (code) {
    429 => ConnectivityStatus.limited,
    403 || 451 => ConnectivityStatus.blocked,
    >= 200 && < 400 => ConnectivityStatus.completed,
    _ => ConnectivityStatus.failed,
  };

  Future<String?> _probeCountry() async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.getUrl(Uri.parse('https://ipwho.is/')).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      final body = await utf8.decoder.bind(response).join().timeout(_timeout);
      final data = jsonDecode(body);
      if (data is Map && data['success'] == true) {
        final code = '${data['country_code'] ?? ''}'.trim();
        if (code.isNotEmpty) return code.toUpperCase();
      }
    } catch (_) {
      // The country is decoration; a failed lookup must not fail the sweep.
    } finally {
      client.close(force: true);
    }
    return null;
  }
}
