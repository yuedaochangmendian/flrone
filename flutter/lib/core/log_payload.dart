// Structured view of a kernel log line, ported from FlClash's
// `lib/common/log_payload.dart` so a routing or dial failure reads as
// destination / rule / proxy / error instead of one long sentence.
//
// The patterns match mihomo's wording; a line that matches nothing keeps its
// plain text. Parsing is lazy (only a visible row builds its payload), so a
// 5000-line tail costs nothing until the reader scrolls to it.

/// The routing or dial fields one log line can carry.
class LogRoute {
  const LogRoute({
    required this.source,
    this.sourceDetail = '',
    required this.destination,
    this.rule = '',
    required this.proxy,
    this.error = '',
  });

  final String source;
  final String sourceDetail;
  final String destination;
  final String rule;
  final String proxy;
  final String error;
}

const _endpoint = r'((?:\[[^\]]+\]|[^\s\[\]()]+):\d+|mihomo)(?:\((.*)\))?';

final _tagPattern = RegExp(r'^\[([^\]]+)\] (.+)$', dotAll: true);

final _routePattern = RegExp(
  r'^' +
      _endpoint +
      r" --> (\S+) (?:(?:match (.+?)|(doesn't match any rule)) )?using (.+)$",
);

final _dialPattern = RegExp(
  r'^dial (.+?) (?:\(match (.+?)\) )?' +
      _endpoint +
      r' --> (\S+) error: (.+)$',
  dotAll: true,
);

/// One parsed kernel line: an optional `[tag]` prefix and, for mihomo routing
/// lines, the route it describes.
class LogPayload {
  const LogPayload({this.tag = '', required this.message, this.route});

  final String tag;
  final String message;
  final LogRoute? route;

  factory LogPayload.parse(String payload) {
    final tagged = _tagPattern.firstMatch(payload);
    final message = tagged?[2] ?? payload;
    return LogPayload(
      tag: tagged?[1] ?? '',
      message: message,
      route: _parseRoute(message),
    );
  }

  static LogRoute? _parseRoute(String message) {
    final route = _routePattern.firstMatch(message);
    if (route != null) {
      return LogRoute(
        source: route[1]!,
        sourceDetail: route[2] ?? '',
        destination: route[3]!,
        rule: route[4] ?? route[5] ?? '',
        proxy: route[6]!,
      );
    }
    final dial = _dialPattern.firstMatch(message);
    if (dial != null) {
      return LogRoute(
        proxy: dial[1]!,
        rule: dial[2] ?? '',
        source: dial[3]!,
        sourceDetail: dial[4] ?? '',
        destination: dial[5]!,
        error: dial[6]!,
      );
    }
    return null;
  }
}
