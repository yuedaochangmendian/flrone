import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../app/l10n.dart';
import '../app/navigation.dart';
import '../box.dart';
import '../components/dashboard_cards.dart';
import '../components/status_card.dart';
import '../providers/box_providers.dart';
import '../ui/icons/icons.dart';
import '../ui/scaffold/scaffold.dart';
import 'logs.dart';

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(boxStateProvider);
    return Scaffold(
      title: context.tr('Dashboard'),
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.logs,
          tooltip: context.tr('Logs'),
          onPressed: () => showLogs(context),
        ),
      ],
      body: LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 900;
          final side = desktop
              ? (constraints.maxWidth - 820)
                        .clamp(0.0, double.infinity)
                        .toDouble() /
                    2
              : 16.0;
          final cards = <Widget>[
            const StatusCard(),
            const TrafficCard(),
            const ModeCard(),
            const ProfileCard(),
            const ProxyGroupsCard(),
            const MemoryCard(),
            const LanCard(),
          ];
          return ListView(
            padding: EdgeInsets.fromLTRB(
              side,
              context.contentTopPadding,
              side,
              24 + context.bottomInset,
            ),
            children: [
              if (box.remote)
                _Notice(
                  title: box.dashboard['remote']?.toString() ?? 'Remote',
                  subtitle: 'Remote control',
                  action: TextButton(
                    onPressed: box.remoteDisconnect,
                    child: Text(context.tr('Disconnect')),
                  ),
                ),
              if (box.remote) const SizedBox(height: 12),
              if (box.applyRequired != null)
                _Notice(
                  title: box.applyRequired!,
                  subtitle: 'Restart required',
                  action: TextButton(
                    onPressed: box.serviceReload,
                    child: Text(context.tr('Retry')),
                  ),
                ),
              if (box.applyRequired != null) const SizedBox(height: 12),
              ..._layout(cards, desktop),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _layout(List<Widget> cards, bool desktop) {
    if (!desktop) {
      return [
        for (final card in cards) ...[card, const SizedBox(height: 12)],
      ];
    }
    final status = cards.first;
    final rest = cards.skip(1).toList();
    final rows = <Widget>[status, const SizedBox(height: 12)];
    for (var i = 0; i < rest.length; i += 2) {
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Expanded(child: rest[i]),
            Expanded(
              child: i + 1 < rest.length
                  ? rest[i + 1]
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      );
      rows.add(const SizedBox(height: 12));
    }
    return rows;
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.title,
    required this.subtitle,
    required this.action,
  });

  final String title;
  final String subtitle;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      decoration: ShapeDecoration(
        color: scheme.warningContainer,
        shape: AppShape.all(AppCorner.md),
      ),
      child: Row(
        children: [
          GlyphIcon(
            AppGlyphs.warning,
            size: 18,
            color: scheme.onWarningContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.footnote
                      .of(context, emphasized: true)
                      .copyWith(color: scheme.onWarningContainer),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.caption1
                      .of(context)
                      .copyWith(
                        color: scheme.onWarningContainer.withValues(alpha: 0.8),
                      ),
                ),
              ],
            ),
          ),
          action,
        ],
      ),
    );
  }
}

Future<void> showLogs(BuildContext context) {
  return openPage<void>(context, const LogsPage());
}
