import 'box.dart';

/// What the host can actually answer.
///
/// The host advertises a manifest on `ready` and the navigation prunes itself from it, so a screen
/// whose backend does not exist is never drawn. The B-box-only screens (request capture, terminal,
/// remote sessions, reports, endpoints, taildrop) were deleted outright once their flags were the
/// only thing keeping them reachable.
///
/// An empty manifest means an unmodified host that knows nothing about capabilities, so nothing is
/// pruned in that case.
class BoxCapabilities {
  const BoxCapabilities(this.values);

  final Json values;

  static const empty = BoxCapabilities(<String, dynamic>{});

  factory BoxCapabilities.parse(Object? value) => BoxCapabilities(json(value));

  bool get known => values.isNotEmpty;

  bool of(String capability) => !known || values[capability] == true;
}
