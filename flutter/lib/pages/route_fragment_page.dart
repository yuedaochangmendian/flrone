// The Routing screen: one global rule table. `settings.dart` and
// `configuration.dart` open [RoutingPage], so the name and the no-argument
// constructor stay as they were; the rule list and its toolbar now live in
// [GlobalRulesPage] (the former profile editor, with the profile metadata gone).
//
// This file keeps the engine settings screen, the rule-set status caption and
// the shared date/naming helpers. Per-profile cards, remote updates, cloning,
// sharing and the current-profile marker were deleted with the profiles.

import '../widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

/// The routing screen. Thin shell over the single global rule list so the
/// existing entry points keep opening the same page.
class RoutingPage extends StatelessWidget {
  const RoutingPage({super.key});

  @override
  Widget build(BuildContext context) => const GlobalRulesPage();
}

/// The engine switches the Routing settings screen keeps (upstream
/// `settings_routing.xml`, the two "common" sections): the domain strategies,
/// the rule-set mirror and ad blocking. The remote-route auto-update pair went
/// away with the profiles. They are real settings keys with a real reload
/// story, so they stay one tap from the rule list.
class RouteEngineSettingsPage extends ConsumerWidget {
  const RouteEngineSettingsPage({super.key});

  static const _domainStrategies = ['', 'ipv4_only', 'ipv6_only', 'prefer_ipv4', 'prefer_ipv6'];
  static const _mirrors = [0, 1, 2, 3, 4, 5];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return BoxPage(
      title: 'Routing settings',
      actions: [
        restoreDefaultsAction(context, const [
          'outboundDomainStrategy', 'domainStrategy', 'rulesetMirror', 'adblockEnable',
        ]),
      ],
      children: [
        generateSection(items: [
          SettingChoice<String>('Outbound domain strategy', 'outboundDomainStrategy',
              options: _domainStrategies, text: _strategyName),
          SettingChoice<String>('Domain strategy', 'domainStrategy',
              options: _domainStrategies, text: _strategyName),
          SettingChoice<int>('Rule set mirror', 'rulesetMirror', options: _mirrors, text: _mirrorName),
          SettingToggle('Ad blocking', 'adblockEnable', autoRestart: true),
        ], footer: context.tr('These change how the rules resolve.')),
        const _RuleSetsStatus(),
      ],
    );
  }
}

/// The last rule-set update the kernel worker reported. The core fetches these
/// automatically after a deferred start, and the toolbar's "Update resources"
/// runs one on demand; both land here through the same `ruleSets` event, so this
/// stays a read-only caption. Hidden while the kernel is not running — with no
/// worker there is no status to show.
class _RuleSetsStatus extends ConsumerWidget {
  const _RuleSetsStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(runningProvider);
    final status = ref.watch(ruleSetsProvider);
    if (!running || status.isEmpty) return const SizedBox.shrink();
    final updated = (status['updated'] as num?)?.toInt() ?? 0;
    final error = status['error']?.toString() ?? '';
    final at = (status['at'] as num?)?.toInt() ?? 0;
    final time = at > 0 ? routeDateTime(at ~/ 1000) : '—';
    final caption = error.isEmpty
        ? '${context.tr('Rule sets updated')} · $updated · $time'
        : '${context.tr('Rule sets')}: $updated · $error';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Text(caption, style: context.listCaptionStyle),
    );
  }
}

String _strategyName(String value) => switch (value) {
      '' => 'Automatic', 'ipv4_only' => 'IPv4 only', 'ipv6_only' => 'IPv6 only',
      'prefer_ipv4' => 'Prefer IPv4', _ => 'Prefer IPv6',
    };

String _mirrorName(int value) => switch (value) {
      1 => 'jsDelivr · Cloudflare', 2 => 'jsDelivr', 3 => 'GitHub',
      4 => 'Cloudflare Pages', 5 => 'Throne mirror', _ => 'GitHub raw',
    };

/// Epoch seconds as a short local date and time, Throne's `RouteTexts.dateTime`.
String routeDateTime(int epochSeconds) {
  if (epochSeconds <= 0) return '—';
  final local = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
