import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:prism_ui/prism_ui.dart';

import '../app/l10n.dart';
import '../box.dart';
import '../common/ip_quality.dart';
import '../common/routed_ip_probe.dart';
import '../providers/box_providers.dart';
import '../ui/icons/icons.dart';
import 'dashboard_common.dart';
import 'shape_badge.dart';
import 'start_toggle.dart';

const _spinPeriod = Duration(milliseconds: 1500);

class StatusCard extends ConsumerStatefulWidget {
  const StatusCard({super.key});

  @override
  ConsumerState<StatusCard> createState() => _StatusCardState();
}

class _StatusCardState extends ConsumerState<StatusCard>
    with SingleTickerProviderStateMixin {
  late RoutedIpProbe _probe;
  Json? _info;
  IpQuality? _quality;
  String? _error;
  bool _checking = false;
  int _generation = 0;
  Timer? _qualityExpiry;
  Timer? _startupProbe;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _probe = RoutedIpProbe(ref.read(boxControllerProvider));
    ref.listenManual(runningProvider, (previous, next) {
      if (previous != next) {
        _setClock(next);
        _scheduleRefresh();
      }
    });
    ref.listenManual(boxControllerProvider.select((b) => b.selectedProfileId), (
      previous,
      next,
    ) {
      if (previous != next) _scheduleRefresh();
    });
    _scheduleRefresh();
    _setClock(ref.read(boxControllerProvider).running);
  }

  @override
  void dispose() {
    _startupProbe?.cancel();
    _clock?.cancel();
    _qualityExpiry?.cancel();
    unawaited(_probe.close());
    super.dispose();
  }

  void _setClock(bool running) {
    _clock?.cancel();
    _clock = null;
    if (!running) return;
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _scheduleRefresh() {
    _startupProbe?.cancel();
    _startupProbe = Timer(const Duration(milliseconds: 650), () {
      if (mounted) _refresh();
    });
  }

  Future<void> _refresh() async {
    if (!mounted || _checking) return;
    final generation = ++_generation;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final result = json(await _probe.egress(force: true));
      if (!mounted || generation != _generation) return;
      final ip = result['ip'] as String?;
      setState(() {
        _info = result.isEmpty ? null : result;
        _checking = false;
      });
      if (ip == null || result['direct'] == true) return;
      unawaited(_lookupQuality(ip, generation));
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = BoxController.describe(error);
        _checking = false;
      });
    }
  }

  Future<void> _lookupQuality(String ip, int generation) async {
    try {
      final quality = await lookupIpQuality(_probe, ip);
      if (!mounted || generation != _generation) return;
      setState(() => _quality = quality);
      _qualityExpiry?.cancel();
      _qualityExpiry = Timer(const Duration(minutes: 10), () {
        if (mounted) setState(() => _quality = null);
      });
    } catch (_) {
      // The card still shows the exit address when a quality source is down.
    }
  }

  @override
  Widget build(BuildContext context) {
    final box = ref.watch(boxStateProvider);
    final running = box.running;
    final transitioning = box.transitioning;
    final hasProfile = box.profiles.isNotEmpty;
    final status = transitioning
        ? (running ? 'Stopping' : 'Starting')
        : running
        ? 'Running'
        : 'Not running';
    final profile = box.selectedProfile;
    final startedAt = (box.dashboard['startedAt'] as num?)?.toInt();
    final uptime = startedAt == null || !running
        ? 0
        : math.max(
            0,
            DateTime.now().millisecondsSinceEpoch ~/ 1000 - startedAt,
          );
    final info = _info;
    final ip = info?['ip'] as String?;
    final country = info?['countryCode'] as String?;
    final mobile = MediaQuery.sizeOf(context).width < 640;
    final scheme = context.colorScheme;
    final tone = SurfaceLevel.block.colorOf(scheme);
    return DashboardCard(
      padding: EdgeInsets.zero,
      clipBehavior: Clip.none,
      semanticLabel: context.tr('Status'),
      side: BorderSide.none,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipPath(
              clipper: ShapeBorderClipper(
                shape: AppShape.all(dashboardRadius(context)),
                textDirection: Directionality.of(context),
              ),
              child: Stack(
                children: [
                  PositionedDirectional(
                    end: -58,
                    top: -70,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: running ? 1 : 0),
                      duration: const Duration(milliseconds: 450),
                      curve: Curves.easeOutBack,
                      builder: (_, progress, _) => Transform.rotate(
                        angle: 2 * math.pi / 12 * progress,
                        child: Transform.scale(
                          scale: 1 + 0.12 * progress,
                          child: ShapeBadge(
                            shape: MaterialShapes.cookie12Sided,
                            color: Color.lerp(
                              tone,
                              Color.alphaBlend(
                                scheme.primary.withValues(alpha: 0.1),
                                SurfaceLevel.card.colorOf(scheme),
                              ),
                              progress.clamp(0, 1),
                            )!,
                            size: 240,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: mobile
                ? const EdgeInsets.fromLTRB(20, 18, 16, 18)
                : const EdgeInsets.fromLTRB(22, 20, 22, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DashboardHeader(
                  glyph: AppGlyphs.status,
                  title: context.tr('Status'),
                  leading: [
                    DashboardChip(
                      label: status,
                      tone: running
                          ? DashboardChipTone.ok
                          : transitioning
                          ? DashboardChipTone.warn
                          : DashboardChipTone.idle,
                      dot: running,
                    ),
                  ],
                  trailing: [
                    DashboardIconButton(
                      glyph: AppGlyphs.bolt,
                      tooltip: context.tr('Retry'),
                      onPressed: _checking ? null : _refresh,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  spacing: mobile ? 12 : 18,
                  children: [
                    _CountryBadge(
                      country: country,
                      size: mobile ? 48 : 52,
                      checking: _checking,
                      enabled: !_checking,
                      onRefresh: _refresh,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 4,
                        children: [
                          Text(
                            profile?['name']?.toString() ??
                                profile?['label']?.toString() ??
                                context.tr('No profile'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyle.headline
                                .of(context, emphasized: true)
                                .copyWith(color: scheme.onSurface),
                          ),
                          _IpLine(
                            ip: ip,
                            error: _error,
                            checking: _checking,
                            onTap: ip == null
                                ? null
                                : () => _showIpDetails(context, ip),
                          ),
                          _QualityLine(quality: _quality),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: mobile ? 88 : 104,
                      child: Center(
                        child: StartToggle(
                          size: mobile ? 88 : 104,
                          enabled: hasProfile && !transitioning,
                          running: running,
                          suspended: false,
                          onToggle: () {
                            if (running) {
                              unawaited(box.serviceStop());
                            } else {
                              unawaited(box.serviceStart());
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: mobile ? 16 : 20),
                Row(
                  children: [
                    Expanded(
                      child: DashboardMetric(
                        label: context.tr('Time'),
                        value: formatDuration(uptime),
                      ),
                    ),
                    Expanded(
                      child: DashboardMetric(
                        label: context.tr('Upload'),
                        value: formatBytes(
                          (box.dashboard['uploadTotal'] as num?) ?? 0,
                        ),
                      ),
                    ),
                    Expanded(
                      child: DashboardMetric(
                        label: context.tr('Download'),
                        value: formatBytes(
                          (box.dashboard['downloadTotal'] as num?) ?? 0,
                        ),
                      ),
                    ),
                    Expanded(
                      child: DashboardMetric(
                        label: context.tr('Connections'),
                        value: formatCount(
                          (box.dashboard['connections'] as num?) ?? 0,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showIpDetails(BuildContext context, String ip) {
    final quality = _quality;
    showSheet<void>(
      context: context,
      builder: (context) => Surface(
        color: SurfaceLevel.page.colorOf(context.colorScheme),
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                ip,
                style: AppTextStyle.title2.of(context, emphasized: true),
              ),
              const SizedBox(height: 12),
              if (quality != null) ...[
                _DetailRow(label: 'Type', value: quality.type.label),
                _DetailRow(label: 'Quality', value: quality.level.label),
                if (quality.organization case final organization?)
                  _DetailRow(label: 'Organization', value: organization),
                if (quality.asn case final asn?)
                  _DetailRow(label: 'ASN', value: 'AS$asn'),
                _DetailRow(label: 'Source', value: quality.source.label),
              ] else
                Text('No quality data', style: AppTextStyle.body.of(context)),
            ],
          ),
        ),
      ),
    );
  }
}

class _IpLine extends StatelessWidget {
  const _IpLine({
    required this.ip,
    required this.error,
    required this.checking,
    required this.onTap,
  });

  final String? ip;
  final String? error;
  final bool checking;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    if (error != null) {
      return Text(
        error!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyle.caption1.of(context).copyWith(color: scheme.error),
      );
    }
    if (ip == null) {
      return Text(
        checking ? 'Checking…' : '—',
        style: AppTextStyle.footnote
            .of(context)
            .copyWith(color: scheme.onSurfaceVariant),
      );
    }
    return PressRegion(
      onTap: onTap,
      shape: AppShape.xs,
      overlay: PressRegion.focusOverlay,
      child: Text(
        ip!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyle.title3
            .of(context, emphasized: true)
            .copyWith(
              color: scheme.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
      ),
    );
  }
}

class _QualityLine extends StatelessWidget {
  const _QualityLine({required this.quality});

  final IpQuality? quality;

  @override
  Widget build(BuildContext context) {
    final quality = this.quality;
    if (quality == null) return const SizedBox.shrink();
    return Row(
      spacing: 6,
      children: [
        DashboardChip(label: quality.type.label),
        DashboardChip(
          label: quality.level.label,
          tone: switch (quality.level) {
            IpQualityLevel.good => DashboardChipTone.ok,
            IpQualityLevel.normal => DashboardChipTone.idle,
            IpQualityLevel.risky => DashboardChipTone.warn,
          },
        ),
      ],
    );
  }
}

class _CountryBadge extends StatefulWidget {
  const _CountryBadge({
    required this.country,
    required this.size,
    required this.checking,
    required this.enabled,
    required this.onRefresh,
  });

  final String? country;
  final double size;
  final bool checking;
  final bool enabled;
  final VoidCallback onRefresh;

  @override
  State<_CountryBadge> createState() => _CountryBadgeState();
}

class _CountryBadgeState extends State<_CountryBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turns = AnimationController(
    vsync: this,
    duration: _spinPeriod,
  );
  var _hovered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _spin();
  }

  @override
  void didUpdateWidget(_CountryBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.checking != widget.checking) _spin();
  }

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  void _spin() {
    if (context.disableAnimations) {
      _turns.value = 0;
    } else if (widget.checking) {
      _turns.repeat();
    } else {
      final rest = (_turns.value * 4).ceil() / 4;
      _turns.animateTo(rest, duration: _spinPeriod * (rest - _turns.value));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final code = widget.country?.toUpperCase();
    final color = Color.alphaBlend(
      scheme.onSurface.withValues(alpha: widget.enabled && _hovered ? 0.08 : 0),
      SurfaceLevel.inset.colorOf(scheme),
    );
    return Tooltip(
      message: 'Refresh exit',
      child: Semantics(
        button: true,
        enabled: widget.enabled,
        label: 'Refresh exit',
        child: PressRegion(
          onTap: widget.enabled ? widget.onRefresh : null,
          onHover: (value) => setState(() => _hovered = value),
          child: ElasticPress(
            enabled: widget.enabled,
            child: AnimatedBuilder(
              animation: _turns,
              builder: (_, child) => ShapeBadge(
                shape: MaterialShapes.clover4Leaf,
                color: color,
                size: widget.size,
                rotation: _turns.value * 2 * math.pi,
                child: child,
              ),
              child: code == null || code.length != 2
                  ? GlyphIcon(
                      AppGlyphs.locate,
                      size: widget.size * 0.42,
                      color: scheme.onSurfaceVariant,
                    )
                  : Text(
                      _flagOf(code),
                      style: TextStyle(fontSize: widget.size * 0.42),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

String _flagOf(String code) {
  final first = code.codeUnitAt(0) - 0x41 + 0x1F1E6;
  final second = code.codeUnitAt(1) - 0x41 + 0x1F1E6;
  return String.fromCharCodes([first, second]);
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppTextStyle.footnote.of(context, emphasized: true),
            ),
          ),
        ],
      ),
    );
  }
}
