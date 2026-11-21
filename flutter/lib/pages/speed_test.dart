import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../box.dart';
import '../components/dashboard_common.dart';
import '../providers/box_providers.dart';
import '../ui/icons/icons.dart';
import '../ui/scaffold/scaffold.dart';

class SpeedTestPage extends ConsumerStatefulWidget {
  const SpeedTestPage({super.key});

  @override
  ConsumerState<SpeedTestPage> createState() => _SpeedTestPageState();
}

class _SpeedTestPageState extends ConsumerState<SpeedTestPage> {
  var _starting = false;
  var _mode = 0;
  BoxController? _box;

  static const _modes = [
    (0, 'Full'),
    (1, 'Download only'),
    (2, 'Upload only'),
    (3, 'Simple download'),
  ];

  @override
  void initState() {
    super.initState();
    final box = ref.read(boxControllerProvider);
    _box = box;
    box.setDataVisible(BoxData.testSession, this, true);
    final stored = box.settings['speedTestMode'];
    _mode = stored is num ? stored.toInt() : 0;
  }

  @override
  void dispose() {
    _box?.setDataVisible(BoxData.testSession, this, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(testSessionProvider);
    final resultRows = rows(session['rows']);
    final running = session['running'] == true;
    final scheme = context.colorScheme;
    return Scaffold(
      title: 'Speed test',
      iconActions: [
        IconButtonData(
          glyph: running ? AppGlyphs.block : AppGlyphs.bolt,
          tooltip: running ? 'Stop' : 'Start',
          onPressed: _starting
              ? null
              : running
              ? _stop
              : _start,
        ),
      ],
      menuItems: [
        for (final (value, label) in _modes)
          PopupMenuItem(
            label: label,
            checked: value == _mode,
            onPressed: () {
              setState(() => _mode = value);
              ref
                  .read(boxControllerProvider)
                  .setSetting('speedTestMode', value, restart: false);
            },
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
          Container(
            padding: const EdgeInsets.all(16),
            decoration: ShapeDecoration(
              color: SurfaceLevel.card.colorOf(scheme),
              shape: AppShape.all(AppCorner.xl),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Row(
                  spacing: 10,
                  children: [
                    GlyphIcon(AppGlyphs.speed, size: 22, color: scheme.primary),
                    Expanded(
                      child: Text(
                        running ? 'Testing…' : 'Ready',
                        style: AppTextStyle.headline.of(
                          context,
                          emphasized: true,
                        ),
                      ),
                    ),
                    Text(
                      _modes.firstWhere((item) => item.$1 == _mode).$2,
                      style: AppTextStyle.caption1
                          .of(context)
                          .copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                Text(
                  'A full run measures download and upload through the selected outbound.',
                  style: AppTextStyle.caption1
                      .of(context)
                      .copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (resultRows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  running ? 'Waiting for samples…' : 'No results yet',
                  style: AppTextStyle.body
                      .of(context)
                      .copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            )
          else
            for (final row in resultRows)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ResultRow(row: row),
              ),
        ],
      ),
    );
  }

  Future<void> _start() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      await ref.read(boxControllerProvider).groupTestSessionStartChecked({
        'kind': 2,
        'profileIds': [
          if (ref.read(boxControllerProvider).selectedProfileId > 0)
            ref.read(boxControllerProvider).selectedProfileId,
        ],
        'testCurrent': true,
        'speedMode': _mode,
      });
    } catch (error) {
      ref.read(boxControllerProvider).report(error);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stop() async {
    try {
      await ref.read(boxControllerProvider).groupTestSessionStop();
    } catch (error) {
      ref.read(boxControllerProvider).report(error);
    }
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.row});

  final Json row;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final failed = row['failed'] == true;
    final error = row['error']?.toString();
    final latency = (row['latency'] as num?)?.toInt();
    final down =
        (row['download'] as num?)?.toDouble() ??
        (row['dlBps'] as num?)?.toDouble();
    final up =
        (row['upload'] as num?)?.toDouble() ??
        (row['ulBps'] as num?)?.toDouble();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: ShapeDecoration(
        color: SurfaceLevel.card.colorOf(scheme),
        shape: AppShape.all(AppCorner.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Row(
            spacing: 8,
            children: [
              Expanded(
                child: Text(
                  row['tag']?.toString() ?? row['name']?.toString() ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.subheadline.of(context, emphasized: true),
                ),
              ),
              if (failed)
                DashboardChip(label: 'Failed', tone: DashboardChipTone.error)
              else if (latency != null)
                DashboardChip(
                  label: '$latency ms',
                  tone: latency < 100
                      ? DashboardChipTone.ok
                      : DashboardChipTone.idle,
                ),
            ],
          ),
          if (failed && error != null)
            Text(
              error,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.caption1
                  .of(context)
                  .copyWith(color: scheme.error),
            )
          else
            Row(
              spacing: 16,
              children: [
                Text(
                  '↓ ${formatRate(down ?? 0)}',
                  style: AppTextStyle.caption1
                      .of(context)
                      .copyWith(color: scheme.primary),
                ),
                Text(
                  '↑ ${formatRate(up ?? 0)}',
                  style: AppTextStyle.caption1
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
