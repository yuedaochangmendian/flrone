import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../ui/icons/icons.dart';

double dashboardRadius(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 640 ? 30 : 30;

EdgeInsets dashboardPadding(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 640
    ? const EdgeInsets.fromLTRB(18, 16, 16, 16)
    : const EdgeInsets.fromLTRB(22, 20, 22, 20);

class DashboardCard extends StatelessWidget {
  const DashboardCard({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
    this.side = BorderSide.none,
    this.clipBehavior = Clip.none,
    this.semanticLabel,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final BorderSide side;
  final Clip clipBehavior;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final shape = AppShape.all(dashboardRadius(context));
    final content = Padding(
      padding: padding ?? dashboardPadding(context),
      child: child,
    );
    final card = Container(
      clipBehavior: clipBehavior,
      decoration: ShapeDecoration(
        color: SurfaceLevel.card.colorOf(context.colorScheme),
        shape: shape,
        shadows: [
          BoxShadow(
            color: const Color(0x14000000),
            offset: const Offset(0, 10),
            blurRadius: 28,
            spreadRadius: -10,
          ),
        ],
      ),
      foregroundDecoration: side == BorderSide.none
          ? null
          : ShapeDecoration(shape: shape.copyWith(side: side)),
      child: onTap == null
          ? content
          : PressSurface(
              fill: Colors.transparent,
              shape: shape,
              onPressed: onTap,
              childFills: true,
              child: content,
            ),
    );
    return Semantics(container: true, label: semanticLabel, child: card);
  }
}

class DashboardHeader extends StatelessWidget {
  const DashboardHeader({
    super.key,
    this.glyph,
    required this.title,
    this.leading = const [],
    this.trailing = const [],
  });

  final Glyph? glyph;
  final String title;
  final List<Widget> leading;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final style = AppTextStyle.subheadline
        .of(context, emphasized: true)
        .copyWith(color: context.colorScheme.onSurfaceVariant);
    return Row(
      spacing: 8,
      children: [
        if (glyph case final glyph?)
          GlyphIcon(
            glyph,
            size: 18,
            color: context.colorScheme.onSurfaceVariant,
          ),
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        ...leading,
        const Spacer(),
        ...trailing,
      ],
    );
  }
}

enum DashboardChipTone { idle, ok, warn, error }

class DashboardChip extends StatelessWidget {
  const DashboardChip({
    super.key,
    required this.label,
    this.tone = DashboardChipTone.idle,
    this.dot = false,
  });

  final String label;
  final DashboardChipTone tone;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final (fill, ink) = switch (tone) {
      DashboardChipTone.ok => (
        scheme.successContainer,
        scheme.onSuccessContainer,
      ),
      DashboardChipTone.warn => (
        scheme.warningContainer,
        scheme.onWarningContainer,
      ),
      DashboardChipTone.error => (
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      DashboardChipTone.idle => (
        SurfaceLevel.inset.colorOf(scheme),
        scheme.onSurfaceVariant,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: ShapeDecoration(
        color: fill,
        shape: AppShape.all(AppCorner.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 5,
        children: [
          if (dot)
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: ink, shape: BoxShape.circle),
            ),
          Text(
            label,
            maxLines: 1,
            style: AppTextStyle.caption1
                .of(context, emphasized: true)
                .copyWith(color: ink),
          ),
        ],
      ),
    );
  }
}

class DashboardMetric extends StatelessWidget {
  const DashboardMetric({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyle.caption1
              .of(context)
              .copyWith(color: context.colorScheme.onSurfaceVariant),
        ),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyle.callout
              .of(context, emphasized: true)
              .copyWith(
                color: context.colorScheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
        ),
      ],
    );
  }
}

class DashboardIconButton extends StatelessWidget {
  const DashboardIconButton({
    super.key,
    required this.glyph,
    required this.tooltip,
    this.onPressed,
  });

  final Glyph glyph;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: PressSurface(
        shape: AppShape.circle,
        fill: Colors.transparent,
        onPressed: onPressed,
        child: SizedBox.square(
          dimension: 32,
          child: Center(
            child: GlyphIcon(
              glyph,
              size: 18,
              color: context.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

String formatBytes(num bytes, {int decimals = 1}) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(decimals);
  return '$text ${units[unit]}';
}

String formatRate(num bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';

String formatCount(num value) {
  if (value < 1000) return value.toStringAsFixed(0);
  if (value < 1000000) return '${(value / 1000).toStringAsFixed(1)}K';
  return '${(value / 1000000).toStringAsFixed(1)}M';
}

String formatDuration(num seconds) {
  final total = math.max(0, seconds.toInt());
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
  if (m > 0) return '${m}m ${s.toString().padLeft(2, '0')}s';
  return '${s}s';
}
