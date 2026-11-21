import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Bettbox's `MediaUnlockChecker`, ported to plain `dart:io` (no Dio, no proxy
/// adapter). The app's VPN already routes this process's traffic, so each check
/// measures exactly the exit the speed/status cards measure.
///
/// Every check follows the reference implementation's probe, status rule and
/// region extraction:
///
///   * Cloudflare-fronted services use `/cdn-cgi/trace` and read ip/loc/colo.
///   * Streaming services use their own redirect/title/geo endpoints.
///   * China services use the provider's own IP echo endpoint.
///
/// Status mapping: `unlocked` (reachable and unblocked), `limited` (partial
/// catalogue), `flagged` (reachable but region-flagged), `blocked` (region
/// rejection), `failed` (no answer).
enum MediaUnlockStatus { unlocked, limited, flagged, blocked, failed }

class MediaUnlockResult {
  const MediaUnlockResult(
    this.status, {
    this.region,
    this.latencyMs = 0,
    this.colo,
    this.ip,
    this.isWarp = false,
    this.error,
  });

  final MediaUnlockStatus status;
  final String? region;
  final int latencyMs;
  final String? colo;
  final String? ip;
  final bool isWarp;
  final String? error;
}

/// The unsupported-region sets Bettbox ships; a Cloudflare-trace answer whose
/// `loc` is in the set is "blocked" even though the trace itself succeeded.
const _openaiUnsupportedRegions = {
  'CN', 'HK', 'MO', 'RU', 'IR', 'KP', 'SY', 'CU', 'VE', 'BY',
  'AF', 'SS', 'YE', 'ZW', 'MM', 'SD', 'SO', 'CF',
};

const _claudeUnsupportedRegions = {
  'CN', 'HK', 'MO', 'RU', 'IR', 'KP', 'SY', 'CU', 'BY', 'VN', 'TR',
  'AF', 'SS', 'YE', 'ZW', 'MM', 'SD', 'SO', 'CF', 'VE',
};

const _geminiUnsupportedRegions = {
  'CN', 'CHN', 'MO', 'MAC', 'RU', 'RUS', 'BY', 'BLR', 'IR', 'IRN',
  'KP', 'PRK', 'SY', 'SYR', 'CU', 'CUB', 'VE', 'VEN', 'MM', 'MMR',
  'SD', 'SDN', 'AF', 'AFG', 'SS', 'SSD', 'YE', 'YEM', 'ZW', 'ZWE',
};

/// `1,2,3` -> `1.2.3`-style three-letter codes normalised to ISO-2 where the
/// reference checker does the same (`utils.normalizeRegion`).
String? normalizeRegion(String? raw) {
  if (raw == null) return null;
  final code = raw.trim().toUpperCase();
  if (code.isEmpty) return null;
  if (code.length == 2) return code;
  const map = {
    'CHN': 'CN', 'MAC': 'MO', 'RUS': 'RU', 'BLR': 'BY', 'IRN': 'IR',
    'PRK': 'KP', 'SYR': 'SY', 'CUB': 'CU', 'VEN': 'VE', 'MMR': 'MM',
    'SDN': 'SD', 'AFG': 'AF', 'SSD': 'SS', 'YEM': 'YE', 'ZWE': 'ZW',
    'USA': 'US', 'GBR': 'GB', 'JPN': 'JP', 'KOR': 'KR', 'SGP': 'SG',
    'HKG': 'HK', 'TWN': 'TW', 'DEU': 'DE', 'FRA': 'FR', 'NLD': 'NL',
    'CAN': 'CA', 'AUS': 'AU', 'IND': 'IN', 'BRA': 'BR', 'TUR': 'TR',
  };
  return map[code] ?? (code.length == 3 ? code : null);
}

/// One HTTP probe, shared by every check. `followRedirects` defaults to true,
/// matching the reference calls; `head` marks HEAD requests (`dio.head`).
class _Probe {
  _Probe({required this.url, this.head = false, this.followRedirects = true});

  final String url;
  final bool head;
  final bool followRedirects;

  Future<_ProbeResponse> send({
    Duration timeout = const Duration(seconds: 8),
    int bodyLimit = 150 * 1024,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;
    try {
      final watch = Stopwatch()..start();
      final request = await client.openUrl(head ? 'HEAD' : 'GET', Uri.parse(url)).timeout(timeout);
      request.followRedirects = followRedirects;
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
      final response = await request.close().timeout(timeout);
      final body = head ? '' : await _readBody(response, bodyLimit, timeout);
      return _ProbeResponse(
        statusCode: response.statusCode,
        body: body,
        headers: response.headers,
        finalUrl: response.redirects.isEmpty
            ? url
            : response.redirects.last.location.toString(),
        latencyMs: watch.elapsedMilliseconds,
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _readBody(
    HttpClientResponse response,
    int limit,
    Duration timeout,
  ) async {
    final bytes = <int>[];
    final completer = Completer<String>();
    late StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (chunk) {
        bytes.addAll(chunk);
        if (bytes.length >= limit) {
          unawaited(subscription.cancel());
          if (!completer.isCompleted) {
            completer.complete(utf8.decode(bytes, allowMalformed: true));
          }
        }
      },
      onError: (Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(utf8.decode(bytes, allowMalformed: true));
        }
      },
      cancelOnError: false,
    );
    return completer.future.timeout(timeout, onTimeout: () {
      unawaited(subscription.cancel());
      return utf8.decode(bytes, allowMalformed: true);
    });
  }

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';
}

class _ProbeResponse {
  const _ProbeResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
    required this.finalUrl,
    required this.latencyMs,
  });

  final int statusCode;
  final String body;
  final HttpHeaders headers;
  final String finalUrl;
  final int latencyMs;

  bool get ok => statusCode >= 200 && statusCode < 400;
  String? header(String name) => headers.value(name);
  String headerList(String name) => headers[name]?.join('; ') ?? '';
}

/// Bettbox's per-platform checks, keyed by the `ConnectivityService.id` the
/// page uses. Ids match Bettbox's `MediaPlatform.name` so the bundled SVGs are
/// the same assets.
class ConnectivityChecker {
  ConnectivityChecker({this.timeout = const Duration(seconds: 8)});

  final Duration timeout;

  Future<MediaUnlockResult> check(String id) {
    final future = switch (id) {
      'openai' => _cloudflareTrace('chatgpt.com', unsupported: _openaiUnsupportedRegions),
      'claude' => _cloudflareTrace('api.anthropic.com', unsupported: _claudeUnsupportedRegions),
      'gemini' => _gemini(),
      'grok' => _cloudflareTrace('api.x.ai'),
      'openrouter' => _cloudflareTrace('openrouter.ai'),
      'poe' => _cloudflareTrace('poe.com'),
      'suno' => _cloudflareTrace('suno.com'),
      'cloudflare' => _cloudflareTrace('api.cloudflare.com'),
      'perplexity' => _cloudflareTrace('www.perplexity.ai'),
      'netflix' => _netflix(),
      'disney' => _disney(),
      'youtube' => _youtube(premium: true),
      'youtubemusic' => _youtube(premium: false),
      'spotify' => _spotify(),
      'tiktok' => _tiktok(),
      'bilibili' => _bilibili(),
      'iqiyi' => _iqiyi(),
      'crunchyroll' => _cloudflareTrace('crunchyroll.com'),
      'missav' => _cloudflareTrace('missav.ws', fallbackDomains: const ['missav.ai']),
      'ehentai' => _cloudflareTrace('e-hentai.org'),
      'tencent' => _tencent(),
      'alibaba' => _alibaba(),
      'netease' => _netease(),
      'douyin' => _douyin(),
      'cloudflarecn' => _cloudflareTrace('www.cloudflare-cn.com'),
      'reddit' => _reddit(),
      'x' => _cloudflareTrace('x.com', fallbackUrl: 'https://x.com/'),
      'discord' => _cloudflareTrace('gateway.discord.gg'),
      'v2ex' => _cloudflareTrace('v2ex.com'),
      'medium' => _cloudflareTrace('medium.com'),
      'stackoverflow' => _cloudflareTrace('stackoverflow.com'),
      'quora' => _cloudflareTrace('www.quora.com'),
      'telegram' => _telegram(),
      'github' => _github(),
      'wikipedia' => _wikipedia(),
      'apple' => _apple(),
      'onetrust' => _onetrust(),
      'gitlab' => _cloudflareTrace('gitlab.com'),
      'npm' => _cloudflareTrace('registry.npmjs.org'),
      'cdnjs' => _cloudflareTrace('cdnjs.cloudflare.com'),
      'unpkg' => _cloudflareTrace('unpkg.com'),
      'nodejs' => _cloudflareTrace('nodejs.org'),
      'steam' => _steam(),
      'epic' => _cloudflareTrace('store.epicgames.com'),
      'ubisoft' => _cloudflareTrace('store.ubisoft.com'),
      'humblebundle' => _cloudflareTrace('humblebundle.com'),
      'coinbase' => _cloudflareTrace('www.coinbase.com'),
      'okx' => _cloudflareTrace('www.okx.com'),
      'kraken' => _cloudflareTrace('www.kraken.com'),
      'cryptocom' => _cloudflareTrace('crypto.com'),
      'phantom' => _cloudflareTrace('phantom.com'),
      'paypal' => _paypal(),
      'mytvsuper' => _mytvsuper(),
      'viutv' => _viutv(),
      'hoytv' => _hoytv(),
      'rthk' => _rthk(),
      _ => Future.value(const MediaUnlockResult(
        MediaUnlockStatus.failed,
        error: 'unknown service',
      )),
    };
    return future.timeout(timeout, onTimeout: () {
      return const MediaUnlockResult(MediaUnlockStatus.failed, error: 'timeout');
    });
  }

  // --- Cloudflare trace (the reference's default probe) ----------------------

  Future<MediaUnlockResult> _cloudflareTrace(
    String domain, {
    List<String> fallbackDomains = const [],
    Set<String>? unsupported,
    String? fallbackUrl,
  }) async {
    final watch = Stopwatch()..start();
    MediaUnlockStatus? detected;
    String? detectedRegion, detectedColo, detectedIp;
    var detectedWarp = false;
    var gotResponse = false;
    var activeDomain = domain;

    for (final candidate in [domain, ...fallbackDomains]) {
      try {
        final res = await ( _Probe(url: 'https://$candidate/cdn-cgi/trace') ).send(timeout: timeout);
        gotResponse = true;
        String? ip, loc, colo;
        var warp = false;
        if (res.ok && res.body.isNotEmpty && !res.body.contains('<!DOCTYPE')) {
          for (final line in res.body.split('\n')) {
            final idx = line.indexOf('=');
            if (idx <= 0) continue;
            final key = line.substring(0, idx).trim();
            final value = line.substring(idx + 1).trim();
            if (key == 'ip') ip = value;
            if (key == 'loc') loc = value;
            if (key == 'colo') colo = value;
            if (key == 'warp') warp = value != 'off';
          }
        }
        colo ??= _extractColo(res.header('cf-ray'));
        final region = loc?.toUpperCase();
        if (ip != null && ip.isNotEmpty) {
          final blocked = unsupported != null && region != null && unsupported.contains(region);
          detected = blocked ? MediaUnlockStatus.blocked : MediaUnlockStatus.unlocked;
          detectedRegion = region;
          detectedColo = colo?.toUpperCase();
          detectedIp = ip;
          detectedWarp = warp;
          activeDomain = candidate;
          break;
        } else if (_isCloudflareChallenge(res)) {
          detected = MediaUnlockStatus.flagged;
          detectedColo ??= colo?.toUpperCase();
          activeDomain = candidate;
        }
      } catch (_) {
        // Try the next mirror; the reference swallows per-domain failures.
      }
    }

    MediaUnlockStatus status;
    if (detected != null) {
      status = detected;
    } else if (fallbackUrl != null) {
      try {
        final res = await (_Probe(url: fallbackUrl)).send(timeout: timeout);
        gotResponse = true;
        final colo = _extractColo(res.header('cf-ray'));
        if (_isCloudflareChallenge(res)) {
          status = MediaUnlockStatus.flagged;
          detectedColo ??= colo?.toUpperCase();
        } else if (res.ok) {
          status = MediaUnlockStatus.unlocked;
          detectedColo ??= colo?.toUpperCase();
        } else {
          status = MediaUnlockStatus.blocked;
        }
      } catch (_) {
        status = MediaUnlockStatus.failed;
      }
    } else if (!gotResponse) {
      return MediaUnlockResult(
        MediaUnlockStatus.failed,
        latencyMs: watch.elapsedMilliseconds,
        error: 'no response',
      );
    } else {
      status = MediaUnlockStatus.blocked;
    }

    final latency = await _measureLatency(activeDomain, watch.elapsedMilliseconds);
    return MediaUnlockResult(
      status,
      region: detectedRegion,
      latencyMs: latency,
      colo: detectedColo,
      ip: detectedIp,
      isWarp: detectedWarp,
    );
  }

  /// The labelled latency Bettbox measures when `unifiedDelay` is on: a HEAD to
  /// the service root; falls back to the trace's own timing.
  Future<int> _measureLatency(String domain, int fallback) async {
    try {
      final res = await (_Probe(url: 'https://$domain/', head: true)).send(
        timeout: const Duration(seconds: 3),
      );
      return res.latencyMs > 0 ? res.latencyMs : fallback;
    } catch (_) {
      return fallback;
    }
  }

  String? _extractColo(String? ray) {
    if (ray == null) return null;
    final idx = ray.lastIndexOf('-');
    if (idx < 0 || idx >= ray.length - 1) return null;
    final code = ray.substring(idx + 1).trim().toUpperCase();
    return code.length >= 3 && code.length <= 4 ? code : null;
  }

  bool _isCloudflareChallenge(_ProbeResponse res) {
    if (res.header('cf-mitigated')?.toLowerCase() == 'challenge') return true;
    final server = res.header('server')?.toLowerCase() ?? '';
    final isCf = server.contains('cloudflare') || res.header('cf-ray') != null;
    if (!isCf) return false;
    if (res.statusCode == 403 || res.statusCode == 503) return true;
    return res.body.contains('challenges.cloudflare.com') ||
        res.body.contains('cf-chl-') ||
        res.body.contains('/cdn-cgi/challenge-platform/') ||
        res.body.contains('cf-turnstile') ||
        res.body.contains(r'__CF$cv$params');
  }

  // --- Streaming -------------------------------------------------------------

  Future<MediaUnlockResult> _netflix() async {
    final watch = Stopwatch()..start();
    try {
      final first = await (_Probe(
        url: 'https://www.netflix.com/title/70143836',
        followRedirects: false,
      )).send(timeout: const Duration(seconds: 4));
      final loc = first.header('location') ?? '';
      String? region = _netflixRegion(loc);
      MediaUnlockStatus status;
      if ((first.statusCode == 301 || first.statusCode == 302) &&
          loc.contains('/title/70143836')) {
        status = MediaUnlockStatus.unlocked;
      } else if (first.statusCode == 200) {
        status = MediaUnlockStatus.unlocked;
      } else {
        final second = await (_Probe(
          url: 'https://www.netflix.com/title/81280792',
          followRedirects: false,
        )).send(timeout: const Duration(seconds: 4));
        final loc2 = second.header('location') ?? '';
        region = _netflixRegion(loc2) ?? region;
        status = (second.statusCode == 301 || second.statusCode == 302) &&
                loc2.contains('/title/81280792')
            ? MediaUnlockStatus.limited
            : MediaUnlockStatus.blocked;
      }
      return MediaUnlockResult(status, region: region, latencyMs: watch.elapsedMilliseconds);
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  String? _netflixRegion(String location) {
    final match = RegExp(r'netflix\.com/([a-z]{2})(?:-[a-z]{2})?/title/').firstMatch(location);
    return match?.group(1)?.toUpperCase();
  }

  Future<MediaUnlockResult> _disney() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(url: 'https://www.disneyplus.com/', head: true))
          .send(timeout: const Duration(seconds: 4));
      final loc = res.header('physical-location') ?? res.header('region');
      final region = (loc != null && loc.isNotEmpty) ? loc.toUpperCase() : null;
      MediaUnlockStatus status;
      if (res.statusCode == 200) {
        status = res.finalUrl.contains('unavailable')
            ? MediaUnlockStatus.blocked
            : MediaUnlockStatus.unlocked;
      } else {
        status = MediaUnlockStatus.blocked;
      }
      return MediaUnlockResult(status, region: region, latencyMs: watch.elapsedMilliseconds);
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _youtube({required bool premium}) async {
    final watch = Stopwatch()..start();
    final url = premium ? 'https://www.youtube.com/premium' : 'https://music.youtube.com/';
    try {
      final res = await (_Probe(url: url)).send(timeout: const Duration(seconds: 4));
      if (res.finalUrl.contains('sorry.google.com')) {
        return MediaUnlockResult(MediaUnlockStatus.blocked, latencyMs: watch.elapsedMilliseconds);
      }
      if (!premium && res.finalUrl.contains('unavailable')) {
        return MediaUnlockResult(MediaUnlockStatus.blocked, latencyMs: watch.elapsedMilliseconds);
      }
      if (res.statusCode != 200) {
        return MediaUnlockResult(MediaUnlockStatus.blocked, latencyMs: watch.elapsedMilliseconds);
      }
      final gl = RegExp(r'"INNERTUBE_CONTEXT_GL"\s*:\s*"([A-Z]{2})"').firstMatch(res.body);
      final cc = RegExp(r'"countryCode"\s*:\s*"([A-Z]{2})"').firstMatch(res.body);
      final requestDomain = RegExp(r'"REQUEST_DOMAIN"\s*:\s*"([a-zA-Z]{2})"').firstMatch(res.body);
      final region = gl?.group(1) ?? cc?.group(1) ?? requestDomain?.group(1)?.toUpperCase();
      final unavailable = res.body.contains('Premium is not available in your country') ||
          res.body.contains('unavailable in your country') ||
          res.body.contains('not available in your area') ||
          res.body.contains('not available in your country');
      if (premium) {
        return MediaUnlockResult(
          unavailable ? MediaUnlockStatus.flagged : MediaUnlockStatus.unlocked,
          region: region,
          latencyMs: watch.elapsedMilliseconds,
        );
      }
      final blocked = unavailable || region == 'CN' || region == 'RU';
      return MediaUnlockResult(
        blocked ? MediaUnlockStatus.blocked : MediaUnlockStatus.unlocked,
        region: region,
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _spotify() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(url: 'https://www.spotify.com/signup'))
          .send(timeout: const Duration(seconds: 4));
      final pathMatch = RegExp(r'spotify\.com/([a-z]{2})(?:-[a-z]{2})?/').firstMatch(res.finalUrl);
      String? rawRegion = pathMatch?.group(1)?.toUpperCase();
      if (rawRegion == null) {
        final geo = RegExp(r'geoCountry"?\s*:\s*"([A-Z]{2})"').firstMatch(res.body);
        rawRegion = geo?.group(1);
      }
      final region = normalizeRegion(rawRegion);
      MediaUnlockStatus status;
      if (res.finalUrl.contains('why-not-available')) {
        status = MediaUnlockStatus.blocked;
      } else if (res.finalUrl.contains('signup') && res.statusCode < 400) {
        status = MediaUnlockStatus.unlocked;
      } else if (res.statusCode == 403 || res.statusCode == 429) {
        status = MediaUnlockStatus.blocked;
      } else {
        status = res.statusCode < 400 ? MediaUnlockStatus.unlocked : MediaUnlockStatus.blocked;
      }
      return MediaUnlockResult(status, region: region, latencyMs: watch.elapsedMilliseconds);
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _tiktok() async {
    final watch = Stopwatch()..start();
    try {
      _ProbeResponse? res;
      for (final host in ['perfops1.byteperf.com', 'perfops2.byteperf.com']) {
        try {
          final candidate = await (_Probe(url: 'https://$host/500b-bench.jpg', head: true))
              .send(timeout: timeout);
          if (candidate.statusCode == 200) {
            res = candidate;
            break;
          }
          res ??= candidate;
        } catch (_) {
          // Try the second mirror.
        }
      }
      if (res == null) {
        return MediaUnlockResult(MediaUnlockStatus.failed, latencyMs: watch.elapsedMilliseconds);
      }
      final viaMatch = RegExp(r'oversea-([A-Z]{2})-', caseSensitive: false)
          .firstMatch(res.header('via') ?? '');
      final cinfo = (res.header('x-response-cinfo') ?? res.header('x-request-ip') ?? '')
          .replaceAll(RegExp(r'\d+\.\d+\.\d+\.\d+'), '');
      final cinfoMatch = RegExp(r'\b([A-Z]{2})\b').firstMatch(cinfo);
      final region = normalizeRegion(viaMatch?.group(1) ?? cinfoMatch?.group(1));
      return MediaUnlockResult(
        res.ok ? MediaUnlockStatus.unlocked : MediaUnlockStatus.blocked,
        region: region,
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  // --- China -----------------------------------------------------------------

  Future<MediaUnlockResult> _tencent() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(url: 'https://r.inews.qq.com/api/ip2city?otype=jsonp'))
          .send(timeout: timeout);
      final start = res.body.indexOf('{');
      final end = res.body.lastIndexOf('}');
      String? ip, desc;
      var region = 'CN';
      if (start >= 0 && end > start) {
        final data = jsonDecode(res.body.substring(start, end + 1));
        if (data is Map) {
          ip = data['ip']?.toString();
          final country = data['country']?.toString() ?? '';
          final province = data['province']?.toString() ?? '';
          final city = data['city']?.toString() ?? '';
          final isp = data['isp']?.toString() ?? '';
          if (country != '中国' && country != 'CN') region = country;
          final parts = [province, city, isp].where((s) => s.isNotEmpty);
          desc = parts.isNotEmpty ? parts.join(' ') : country;
        }
      }
      return MediaUnlockResult(
        (ip != null && ip.isNotEmpty) ? MediaUnlockStatus.unlocked : MediaUnlockStatus.failed,
        region: region,
        colo: desc,
        ip: ip,
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _alibaba() async {
    final watch = Stopwatch()..start();
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final rand = List.generate(16, (_) => (ts % 16).toRadixString(16)).join();
      final res = await (_Probe(
        url: 'https://$ts-$rand.dns-detect.alicdn.com/api/detect/DescribeDNSLookup?cb=cb',
      )).send(timeout: timeout);
      final start = res.body.indexOf('{');
      final end = res.body.lastIndexOf('}');
      String? ip, dns;
      if (start >= 0 && end > start) {
        final data = jsonDecode(res.body.substring(start, end + 1));
        if (data is Map) {
          final content = data['content'];
          if (content is Map) {
            ip = content['localIp']?.toString();
            dns = content['ldns']?.toString();
          }
        }
      }
      return MediaUnlockResult(
        (ip != null && ip.isNotEmpty) ? MediaUnlockStatus.unlocked : MediaUnlockStatus.failed,
        region: 'CN',
        colo: dns == null ? null : 'DNS: $dns',
        ip: ip,
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _netease() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(
        url: 'https://necaptcha.nosdn.127.net/ab7f4275c1744aa28e0a8f3a1c58c532.png',
        head: true,
      )).send(timeout: const Duration(seconds: 4));
      final ip = res.header('cdn-user-ip');
      return MediaUnlockResult(
        (ip != null && ip.isNotEmpty) || res.statusCode == 200
            ? MediaUnlockStatus.unlocked
            : MediaUnlockStatus.failed,
        region: 'CN',
        ip: ip,
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _douyin() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(
        url: 'https://perfops.byte-test.com/500b-bench.jpg',
        head: true,
      )).send(timeout: const Duration(seconds: 4));
      final ip = res.header('x-request-ip') ?? res.header('x-response-cinfo');
      return MediaUnlockResult(
        (ip != null && ip.isNotEmpty) || res.statusCode == 200
            ? MediaUnlockStatus.unlocked
            : MediaUnlockStatus.failed,
        region: 'CN',
        ip: ip,
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _bilibili() async {
    final watch = Stopwatch()..start();
    try {
      String? region;
      var status = MediaUnlockStatus.blocked;
      final zone = await (_Probe(url: 'https://api.bilibili.com/x/web-interface/zone'))
          .send(timeout: timeout);
      final zoneData = _decodeJson(zone.body);
      if (zoneData != null && zoneData['code'] == 0) {
        final data = zoneData['data'];
        if (data is Map) {
          final code = data['country_code']?.toString();
          final country = data['country']?.toString() ?? '';
          if (code == '86' || country.contains('中国')) {
            region = 'CN';
          } else if (code == '886' ||
              country.contains('台湾') ||
              country.contains('台灣') ||
              country.contains('中华民国') ||
              country.contains('中華民國')) {
            region = 'TW';
          } else if (code == '852' || country.contains('香港')) {
            region = 'HK';
          } else if (code == '853' || country.contains('澳门')) {
            region = 'MO';
          }
        }
      }
      final play = await (_Probe(
        url: 'https://api.bilibili.com/pgc/player/web/playurl?avid=82846771&qn=0'
            '&type=&otype=json&ep_id=307247&fourk=1&fnver=0&fnval=16&module=bangumi',
      )).send(timeout: timeout);
      if (_decodeJson(play.body)?['code'] == 0) {
        status = MediaUnlockStatus.unlocked;
        region ??= 'CN';
      } else {
        final tw = await (_Probe(
          url: 'https://api.bilibili.com/pgc/player/web/playurl?avid=18281381&cid=29892777'
              '&qn=0&type=&otype=json&ep_id=183799&fourk=1&fnver=0&fnval=16&module=bangumi',
        )).send(timeout: timeout);
        if (_decodeJson(tw.body)?['code'] == 0) {
          status = MediaUnlockStatus.unlocked;
          region ??= 'TW';
        } else if (zone.statusCode == 200) {
          status = MediaUnlockStatus.limited;
        }
      }
      return MediaUnlockResult(status, region: region, latencyMs: watch.elapsedMilliseconds);
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _iqiyi() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(url: 'https://www.iq.com/', head: true))
          .send(timeout: const Duration(seconds: 4));
      final cookies = res.headerList('set-cookie');
      final customIp = res.header('x-custom-client-ip') ?? '';
      final mod = RegExp(r'mod=([a-zA-Z]+)').firstMatch('$cookies $customIp');
      final region = normalizeRegion(mod?.group(1));
      return MediaUnlockResult(
        res.statusCode == 200 ? MediaUnlockStatus.unlocked : MediaUnlockStatus.blocked,
        region: region,
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  // --- Social / developer ----------------------------------------------------

  Future<MediaUnlockResult> _reddit() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(url: 'https://www.reddit.com/', head: true))
          .send(timeout: const Duration(seconds: 4));
      final pop = RegExp(r'p=([A-Z]{3})').firstMatch(res.header('server-timing') ?? '');
      final region = normalizeRegion(pop?.group(1));
      final status = res.statusCode == 200
          ? MediaUnlockStatus.unlocked
          : res.statusCode == 403
              ? MediaUnlockStatus.blocked
              : res.ok
                  ? MediaUnlockStatus.unlocked
                  : MediaUnlockStatus.blocked;
      return MediaUnlockResult(status, region: region, latencyMs: watch.elapsedMilliseconds);
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _github() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(url: 'https://github.com/', head: true))
          .send(timeout: const Duration(seconds: 4));
      final region = normalizeRegion(res.header('x-github-edge-region'));
      final status = res.statusCode == 200
          ? MediaUnlockStatus.unlocked
          : res.statusCode == 403
              ? MediaUnlockStatus.blocked
              : MediaUnlockStatus.failed;
      return MediaUnlockResult(status, region: region, latencyMs: watch.elapsedMilliseconds);
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _wikipedia() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(url: 'https://www.wikipedia.org/'))
          .send(timeout: const Duration(seconds: 4), bodyLimit: 64 * 1024);
      final geo = RegExp(r'GeoIP=([A-Z]{2}):').firstMatch(res.headerList('set-cookie'));
      return MediaUnlockResult(
        res.statusCode == 200 ? MediaUnlockStatus.unlocked : MediaUnlockStatus.blocked,
        region: geo?.group(1),
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _steam() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(url: 'https://store.steampowered.com/'))
          .send(timeout: const Duration(seconds: 4), bodyLimit: 96 * 1024);
      final match = RegExp(
        r'(?:COUNTRY|country_code|countrycode)(?:&quot;|"):\s*(?:&quot;|")([A-Z]{2})',
      ).firstMatch(res.body);
      return MediaUnlockResult(
        res.statusCode == 200 ? MediaUnlockStatus.unlocked : MediaUnlockStatus.blocked,
        region: match?.group(1),
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _gemini() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(url: 'https://gemini.google.com/'))
          .send(timeout: const Duration(seconds: 4));
      if (res.finalUrl.contains('sorry.google.com')) {
        return MediaUnlockResult(MediaUnlockStatus.blocked, latencyMs: watch.elapsedMilliseconds);
      }
      final reg = RegExp(r',2,1,200,"([A-Z]{3})"').firstMatch(res.body);
      final alt = RegExp(r'\[1,null,null,\d+,\d+,"([A-Z]{3})"').firstMatch(res.body);
      final rawRegion = reg?.group(1) ?? alt?.group(1);
      final region = normalizeRegion(rawRegion);
      final unavailable = res.statusCode != 200 ||
          res.finalUrl.contains('unavailable') ||
          res.body.contains('is not supported in your country') ||
          res.body.contains("isn't supported in your country") ||
          res.body.contains('not available in your country') ||
          res.body.contains('unavailable in your country') ||
          res.body.contains('is not currently supported') ||
          res.body.contains("isn't currently supported");
      final blockedRegion = (region != null && _geminiUnsupportedRegions.contains(region)) ||
          (rawRegion != null && _geminiUnsupportedRegions.contains(rawRegion));
      return MediaUnlockResult(
        unavailable || blockedRegion ? MediaUnlockStatus.blocked : MediaUnlockStatus.unlocked,
        region: region,
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _apple() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(url: 'https://gspe1-ssl.ls.apple.com/pep/gcc'))
          .send(timeout: const Duration(seconds: 4), bodyLimit: 16);
      final region = res.body.trim().toUpperCase();
      return MediaUnlockResult(
        res.statusCode == 200 && region.length == 2
            ? MediaUnlockStatus.unlocked
            : MediaUnlockStatus.blocked,
        region: region.length == 2 ? region : null,
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _onetrust() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(
        url: 'https://geolocation.onetrust.com/cookieconsentpub/v1/geo/location',
      )).send(timeout: const Duration(seconds: 4), bodyLimit: 32 * 1024);
      final match = RegExp(r'"country":\s*"([A-Z]{2})"').firstMatch(res.body);
      final region = match?.group(1);
      return MediaUnlockResult(
        res.statusCode == 200 && region != null
            ? MediaUnlockStatus.unlocked
            : MediaUnlockStatus.blocked,
        region: region,
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _paypal() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(url: 'https://www.paypal.com/', head: true, followRedirects: false))
          .send(timeout: const Duration(seconds: 4));
      if (res.statusCode == 403) {
        return MediaUnlockResult(MediaUnlockStatus.blocked, latencyMs: watch.elapsedMilliseconds);
      }
      final uri = Uri.tryParse(res.header('location') ?? '');
      String? region;
      if (uri != null && uri.pathSegments.isNotEmpty) {
        final segment = uri.pathSegments.first.toLowerCase();
        if (segment == 'c2') {
          region = 'CN';
        } else if (segment.length == 2) {
          region = segment.toUpperCase();
        }
      }
      return MediaUnlockResult(
        res.ok ? MediaUnlockStatus.unlocked : MediaUnlockStatus.blocked,
        region: region,
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _telegram() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(url: 'http://91.108.56.100/'))
          .send(timeout: const Duration(seconds: 4), bodyLimit: 1);
      if (res.statusCode > 0) {
        return const MediaUnlockResult(MediaUnlockStatus.unlocked, region: 'SG', colo: 'DC5')
            .copyWithLatency(watch.elapsedMilliseconds);
      }
    } catch (_) {
      // Fall through to a raw TCP connect, as the reference does when cleartext
      // HTTP is blocked.
    }
    try {
      final socket = await Socket.connect('91.108.56.100', 80,
          timeout: const Duration(seconds: 3));
      final rtt = watch.elapsedMilliseconds;
      socket.destroy();
      return const MediaUnlockResult(MediaUnlockStatus.unlocked, region: 'SG', colo: 'DC5')
          .copyWithLatency(rtt > 0 ? rtt : 1);
    } catch (_) {
      return MediaUnlockResult(MediaUnlockStatus.failed, latencyMs: watch.elapsedMilliseconds);
    }
  }

  // --- Hong Kong streaming (kept for parity with the reference list) ---------

  Future<MediaUnlockResult> _mytvsuper() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(
        url: 'https://www.mytvsuper.com/api/auth/getSession/self/',
      )).send(timeout: const Duration(seconds: 4), bodyLimit: 32 * 1024);
      final data = _decodeJson(res.body);
      final supported = data?['supported_country'] == true;
      return MediaUnlockResult(
        res.statusCode == 200 && supported
            ? MediaUnlockStatus.unlocked
            : MediaUnlockStatus.blocked,
        region: data?['country_code']?.toString().toUpperCase(),
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _viutv() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(url: 'https://www.viu.com/ott/hk/en/'))
          .send(timeout: const Duration(seconds: 4), bodyLimit: 64 * 1024);
      return MediaUnlockResult(
        res.statusCode == 200 ? MediaUnlockStatus.unlocked : MediaUnlockStatus.blocked,
        region: res.statusCode == 200 ? 'HK' : null,
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _hoytv() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(url: 'https://hoy.tv/'))
          .send(timeout: const Duration(seconds: 4), bodyLimit: 64 * 1024);
      return MediaUnlockResult(
        res.statusCode == 200 ? MediaUnlockStatus.unlocked : MediaUnlockStatus.blocked,
        region: res.statusCode == 200 ? 'HK' : null,
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Future<MediaUnlockResult> _rthk() async {
    final watch = Stopwatch()..start();
    try {
      final res = await (_Probe(url: 'https://www.rthk.hk/'))
          .send(timeout: const Duration(seconds: 4), bodyLimit: 64 * 1024);
      return MediaUnlockResult(
        res.statusCode == 200 ? MediaUnlockStatus.unlocked : MediaUnlockStatus.blocked,
        region: res.statusCode == 200 ? 'HK' : null,
        latencyMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      return MediaUnlockResult(MediaUnlockStatus.failed,
          latencyMs: watch.elapsedMilliseconds, error: '$error');
    }
  }

  Map<String, dynamic>? _decodeJson(String body) {
    final start = body.indexOf('{');
    final end = body.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final value = jsonDecode(body.substring(start, end + 1));
      return value is Map ? Map<String, dynamic>.from(value) : null;
    } catch (_) {
      return null;
    }
  }
}

extension on MediaUnlockResult {
  MediaUnlockResult copyWithLatency(int latency) => MediaUnlockResult(
        status,
        region: region,
        latencyMs: latency,
        colo: colo,
        ip: ip,
        isWarp: isWarp,
        error: error,
      );
}
