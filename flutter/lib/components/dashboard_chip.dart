import '../widgets.dart';

enum DashboardChipTone { idle, ok, warn }

class DashboardChip extends StatelessWidget {
  const DashboardChip({
    super.key,
    required this.label,
    this.tone = DashboardChipTone.idle,
    this.dot = false,
    this.large = false,
  });

  final String label;
  final DashboardChipTone tone;
  final bool dot;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final (background, foreground) = switch (tone) {
      DashboardChipTone.idle => (SurfaceLevel.block.colorOf(colorScheme), colorScheme.onSurfaceVariant),
      DashboardChipTone.ok => (colorScheme.successContainer, colorScheme.onSuccessContainer),
      DashboardChipTone.warn => (colorScheme.warningContainer, colorScheme.onWarningContainer),
    };
    // Tone changes (Starting grey -> Running green) fade instead of jumping;
    // the label cross-fades with them.
    final duration = context.motionDuration(const Duration(milliseconds: 200));
    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeOutCubic,
      height: large ? 28 : 24,
      padding: EdgeInsets.symmetric(horizontal: large ? 12 : 10),
      decoration: ShapeDecoration(color: background, shape: AppShape.full),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          if (dot)
            AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              decoration: ShapeDecoration(
                color: foreground,
                shape: AppShape.circle,
              ),
              child: const SizedBox.square(dimension: 6),
            ),
          Flexible(child: AnimatedSwitcher(
            duration: duration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: Text(
              label,
              key: ValueKey(label),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.caption1
                  .of(context, emphasized: true)
                  .toTabular
                  .copyWith(color: foreground),
            ),
          )),
        ],
      ),
    );
  }
}

