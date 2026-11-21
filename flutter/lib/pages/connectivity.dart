import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../box.dart';
import '../common/routed_ip_probe.dart';
import '../components/dashboard_common.dart';
import '../providers/box_providers.dart';
import '../ui/icons/icons.dart';
import '../ui/scaffold/scaffold.dart';

class ConnectivityPage extends ConsumerStatefulWidget {
  const ConnectivityPage({super.key});

  @override
  ConsumerState<ConnectivityPage> createState() => _ConnectivityPageState();
}

class _ConnectivityPageState extends ConsumerState<ConnectivityPage> {
  static const _targets = [
    ('Google', 'https://www.google.com/generate_204'),
    ('GitHub', 'https://github.com'),
    ('Cloudflare', 'https://1.1.1.1/cdn-cgi/trace'),
    ('IP echo', 'https://api.ipify.org'),
  ];

  final _results = <String, ({int? status, int? ms, String? error})>{};
  var _testing = false;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return Scaffold(
      title: 'Connectivity',
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: 'Test again',
          onPressed: _testing ? null : _testAll,
        ),
      ],
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          24 + context.bottomInset,
        ),
        children: [
          Text(
            'These requests go through the same routed probe as the home exit card. '
            'A 204 or 2xx means the endpoint answered.',
            style: AppTextStyle.caption1
                .of(context)
                .copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          for (final (name, url) in _targets)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _TargetRow(name: name, url: url, result: _results[url]),
            ),
          const SizedBox(height: 12),
          TonalButton(
            label: _testing ? 'Testing…' : 'Test all',
            glyph: AppGlyphs.speed,
            onPressed: _testing ? null : _testAll,
          ),
        ],
      ),
    );
  }

  Future<void> _testAll() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _results.clear();
    });
    final box = ref.read(boxControllerProvider);
    final probe = RoutedIpProbe(box);
    try {
      await probe.open();
      for (final (_, url) in _targets) {
        final watch = Stopwatch()..start();
        try {
          final response = await probe.get(url, const Duration(seconds: 6));
          if (mounted) {
            setState(() {
              _results[url] = (
                status: response.status,
                ms: watch.elapsedMilliseconds,
                error: null,
              );
            });
          }
        } catch (error) {
          if (mounted) {
            setState(() {
              _results[url] = (
                status: null,
                ms: watch.elapsedMilliseconds,
                error: BoxController.describe(error),
              );
            });
          }
        }
      }
    } catch (error) {
      if (mounted) {
        BannerHost.maybeOf(context)?.show(BoxController.describe(error));
      }
    } finally {
      await probe.close();
      if (mounted) setState(() => _testing = false);
    }
  }
}

class _TargetRow extends StatelessWidget {
  const _TargetRow({
    required this.name,
    required this.url,
    required this.result,
  });

  final String name;
  final String url;
  final ({int? status, int? ms, String? error})? result;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final ok =
        result?.status != null &&
        result!.status! >= 200 &&
        result!.status! < 400;
    final tone = result == null
        ? DashboardChipTone.idle
        : ok
        ? DashboardChipTone.ok
        : DashboardChipTone.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: ShapeDecoration(
        color: SurfaceLevel.card.colorOf(scheme),
        shape: AppShape.all(AppCorner.lg),
      ),
      child: Row(
        spacing: 12,
        children: [
          GlyphIcon(AppGlyphs.link, size: 20, color: scheme.onSurfaceVariant),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(
                  name,
                  style: AppTextStyle.subheadline.of(context, emphasized: true),
                ),
                Text(
                  url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.caption2
                      .of(context)
                      .copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (result == null)
            const DashboardChip(label: 'Not tested')
          else if (result!.error != null)
            DashboardChip(label: 'Failed', tone: DashboardChipTone.error)
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              spacing: 2,
              children: [
                DashboardChip(label: '${result!.status}', tone: tone),
                Text(
                  '${result!.ms} ms',
                  style: AppTextStyle.caption2
                      .of(context)
                      .copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
