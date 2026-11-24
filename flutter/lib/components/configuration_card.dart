import 'dart:async';
import '../widgets.dart';

// FlClash v0.9.2 profile rows, using only the metadata the host puts on the
// profile wire. The quota line is reserved on every card so the grid can size
// each cell from this one measurement.
double configurationCardHeight(BuildContext context) {
  final measure = MeasureScope.of(context);
  return measure.textHeight(AppTextStyle.headline) + 4 +
      measure.textHeight(AppTextStyle.footnote) * 2 + 2 + 2 * listRowVerticalPadding;
}

/// The subscription quota and expiry a profile can show.
///
/// Both arrive preformatted from the host (`BboxCatalog.trafficOf`/`expiryOf`):
/// `12.3 GB / 100 GB` (used / total, the total omitted when the provider
/// reported no quota) and `Until Nov 30, 2026` or `Expired Nov 30, 2026`. This
/// turns them back into the facts the card shows: the **remaining** traffic, a
/// localized expiry label, and "Permanent" for a subscription the provider did
/// not date. A provider without a quota is unlimited while it reports usage.
class SubscriptionQuota {
  const SubscriptionQuota._({
    this.traffic,
    this.expires,
    this.expired = false,
    this.permanent = false,
  });

  /// The remaining quota (`87.7 GB`), `Unlimited` when no total was reported,
  /// or an unfamiliar wire shape shown verbatim.
  final String? traffic;

  /// The host's formatted expiry date, without the `Until`/`Expired` word.
  final String? expires;

  /// Whether [expires] is already in the past (`Expired <date>` on the wire).
  final bool expired;

  /// A dated subscription always carries an expiry; a remote one without a date
  /// is permanent. A local profile is never called permanent.
  final bool permanent;

  bool get isEmpty => traffic == null && expires == null && !permanent;

  static SubscriptionQuota of(Json profile) {
    final expiry = _expiry(profile['expiry']);
    final traffic = _traffic(profile['traffic']);
    return SubscriptionQuota._(
      traffic: traffic,
      expires: expiry?.$1,
      expired: expiry?.$2 ?? false,
      permanent: profile['remote'] == true && expiry == null && traffic != null,
    );
  }

  static String? _traffic(Object? raw) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final parts = text.split('/');
    final used = _bytes(parts.first);
    // An unfamiliar shape is shown verbatim rather than guessed at.
    if (used == null) return text;
    final total = parts.length > 1 ? _bytes(parts[1]) : null;
    if (total != null && total > 0) {
      final remaining = total - used;
      // A quota the provider gave stays visible even at zero remaining.
      return bytes(remaining > 0 ? remaining : 0);
    }
    // No quota reported: a provider that reports usage is unlimited; zero
    // usage has nothing to say.
    return used > 0 ? 'Unlimited' : null;
  }

  static (String, bool)? _expiry(Object? raw) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    if (text.startsWith('Expired ')) {
      final date = text.substring(8).trim();
      return date.isEmpty ? null : (date, true);
    }
    if (text.startsWith('Until ')) {
      final date = text.substring(6).trim();
      return date.isEmpty ? null : (date, false);
    }
    return (text, false);
  }

  /// Parses one `12.3 GB` figure back to bytes; null when the shape is unknown
  /// (the host formats with the device locale, so the decimal may be a comma).
  static int? _bytes(String raw) {
    final match = RegExp(r'^([0-9]+(?:[.,][0-9]+)?)\s*(B|KB|MB|GB|TB|PB)$')
        .firstMatch(raw.trim());
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!.replaceAll(',', '.'));
    if (value == null) return null;
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    var factor = 1;
    for (var i = 0; i < units.indexOf(match.group(2)!); i++) {
      factor *= 1024;
    }
    return (value * factor).round();
  }
}

/// The compact quota/expiry line under a profile name:
/// `Remaining 87.7 GB · Expires Nov 30, 2026`, or
/// `Remaining 87.7 GB · Permanent`. Renders nothing when neither field carries
/// a figure worth showing.
class SubscriptionQuotaLine extends StatelessWidget {
  const SubscriptionQuotaLine({super.key, required this.quota, this.style});
  final SubscriptionQuota quota;
  final TextStyle? style;

  @override Widget build(BuildContext context) {
    final text = [
      if (quota.traffic != null)
        '${context.tr('Remaining')} ${context.tr(quota.traffic!)}',
      if (quota.expires != null)
        '${context.tr(quota.expired ? 'Expired' : 'Expires')} ${quota.expires}'
      else if (quota.permanent)
        context.tr('Permanent'),
    ].join(' · ');
    if (text.isEmpty) return const SizedBox.shrink();
    // The card keeps one line at every text scale: the whole line shrinks to
    // fit instead of clipping the trailing date on a narrow grid cell.
    return FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerStart,
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: style ?? AppTextStyle.footnote.of(context).toLighter,
        textWidthBasis: TextWidthBasis.longestLine));
  }
}

class ConfigurationCard extends StatelessWidget {
  const ConfigurationCard({super.key, required this.profile, required this.selected,
    required this.updating, required this.onPressed, required this.menuItems});
  final Json profile;
  final bool selected, updating;
  final VoidCallback? onPressed;
  final List<PopupMenuItem> menuItems;

  @override Widget build(BuildContext context) {
    final titleStyle = AppTextStyle.headline.of(context);
    final quota = SubscriptionQuota.of(profile);
    return ContextMenuRegion(
      menuItems: updating ? null : menuItems,
      child: Card(radius: AppCorner.xl, isSelected: selected, enterActionsOnRight: true,
        onPressed: onPressed,
        child: ListItem(
          minTileHeight: configurationCardHeight(context), minVerticalPadding: listRowVerticalPadding,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(profile['name'].toString(), style: titleStyle,
              strutStyle: StrutStyle.fromTextStyle(DefaultTextStyle.of(context).style.merge(titleStyle), forceStrutHeight: true),
              maxLines: 1, overflow: TextOverflow.ellipsis, textWidthBasis: TextWidthBasis.longestLine),
            const SizedBox(height: 4),
            Text(context.tr(profile['remote'] == true ? 'Remote' : 'Local'),
              style: AppTextStyle.footnote.of(context).toLighter, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (!quota.isEmpty) ...[
              const SizedBox(height: 2),
              SubscriptionQuotaLine(quota: quota, style: AppTextStyle.footnote.of(context).toLighter),
            ],
          ]),
          trailing: Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: [
            // The row caps the trailing slot at half the card; without a
            // flexible child a large text scale overflowed it (the update age
            // is the one part that can ellipsize here).
            Flexible(child: AnimatedSwitcher(
              duration: context.motionDuration(commonDuration),
              layoutBuilder: (currentChild, previousChildren) => Stack(
                alignment: AlignmentDirectional.centerEnd, children: [...previousChildren, ?currentChild]),
              child: updating ? const ActivityIndicator(key: ValueKey('updating'), size: 24)
                : ConfigurationUpdateTime(key: const ValueKey('lastUpdate'), milliseconds: (profile['updatedAt'] as num?)?.toInt()),
            )),
            if (selected) const SelectionBadge(size: 24),
          ]),
        ),
      ),
    );
  }
}

/// Uses the reference's 365-day years and 30-day months for compact ages.
String configurationUpdateLabel(int? milliseconds, DateTime now, {required bool chinese}) {
  if (milliseconds == null || milliseconds <= 0) return chinese ? '未知' : 'Unknown';
  final elapsed = now.difference(DateTime.fromMillisecondsSinceEpoch(milliseconds));
  for (final (count, en, zh) in [
    (elapsed.inDays ~/ 365, 'y', '年'), (elapsed.inDays ~/ 30, 'mo', '个月'),
    (elapsed.inDays, 'd', '天'), (elapsed.inHours, 'h', '小时'), (elapsed.inMinutes, 'm', '分钟'),
  ]) {
    if (count > 0) return chinese ? '$count $zh前' : '$count$en ago';
  }
  return chinese ? '刚刚' : 'Just now';
}

class ConfigurationUpdateTime extends StatefulWidget {
  const ConfigurationUpdateTime({super.key, required this.milliseconds, this.style, this.showLabel = false});
  final int? milliseconds;
  final TextStyle? style;
  final bool showLabel;
  @override State<ConfigurationUpdateTime> createState() => _ConfigurationUpdateTimeState();
}

class _ConfigurationUpdateTimeState extends State<ConfigurationUpdateTime> with WidgetsBindingObserver {
  Timer? _timer;
  bool _active = false;
  @override void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); }
  @override void didChangeDependencies() {
    super.didChangeDependencies();
    _active = PageActivityScope.isActiveOf(context) && TickerMode.valuesOf(context).enabled;
    _schedule();
  }
  void _schedule() {
    _timer?.cancel();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (_active && (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
      _timer = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
    }
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    _schedule();
    if (state == AppLifecycleState.resumed && _active) setState(() {});
  }
  @override void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  @override Widget build(BuildContext context) {
    final age = configurationUpdateLabel(widget.milliseconds, DateTime.now(),
      chinese: Localizations.localeOf(context).languageCode == 'zh');
    final date = (widget.milliseconds ?? 0) <= 0 ? context.tr('Unknown') : localDate(widget.milliseconds);
    return Tooltip(
      message: '${context.tr('Last updated')}: $date',
      child: Text(widget.showLabel ? '${context.tr('Last updated')} $age' : age,
        maxLines: 1, overflow: TextOverflow.ellipsis,
        style: widget.style ?? AppTextStyle.footnote.of(context).toLighter),
    );
  }
}
