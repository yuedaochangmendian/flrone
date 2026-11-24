import 'dart:async';
import '../widgets.dart';

// FlClash v0.9.3/0.9.4 profile rows, using only the metadata the host puts on
// the profile wire. Two lines like FlClash's card: a title row with the expiry
// chip and a `used / total` subtitle.
double configurationCardHeight(BuildContext context) {
  final measure = MeasureScope.of(context);
  return measure.textHeight(AppTextStyle.headline) + 4 +
      measure.textHeight(AppTextStyle.footnote) + 2 * listRowVerticalPadding;
}

/// FlClash's traffic label: one decimal, no trailing `.0`, no space before the
/// unit (`175.5GB`, `200GB`).
String trafficText(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  var value = size.toStringAsFixed(1);
  if (value.contains('.')) {
    value = value.replaceAll(RegExp(r'0+$'), '');
    if (value.endsWith('.')) value = value.substring(0, value.length - 1);
  }
  return '$value${units[unit]}';
}

/// The subscription quota and expiry a profile can show.
///
/// The host sends raw bytes and epoch seconds (`trafficUsed`/`trafficTotal`/
/// `expiryAt`); the details page derives the **remaining** traffic and the
/// expiry from those. The preformatted `traffic`/`expiry` strings are only a
/// fallback for a host from before the raw fields existed — parsing localized
/// text back into numbers loses precision and depends on the device locale.
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

  /// The expiry date (`YYYY-MM-DD`), without the `Until`/`Expired` word.
  final String? expires;

  /// Whether [expires] is already in the past (`Expired <date>` on the wire).
  final bool expired;

  /// A dated subscription always carries an expiry; a remote one without a date
  /// is permanent. A local profile is never called permanent.
  final bool permanent;

  bool get isEmpty => traffic == null && expires == null && !permanent;

  static SubscriptionQuota of(Json profile) {
    final used = _int(profile['trafficUsed']);
    final total = _int(profile['trafficTotal']);
    final expiryAt = _int(profile['expiryAt']);
    if (used != null || total != null || expiryAt != null) {
      final usedBytes = used ?? 0;
      final totalBytes = total ?? 0;
      final remaining = totalBytes > usedBytes ? totalBytes - usedBytes : 0;
      final traffic = totalBytes > 0
          ? _spacedTraffic(remaining)
          : (usedBytes > 0 ? 'Unlimited' : null);
      final expiry = expiryAt != null && expiryAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(expiryAt * 1000)
          : null;
      return SubscriptionQuota._(
        traffic: traffic,
        expires: expiry?.toLocal().toString().substring(0, 10),
        expired: expiry != null && expiry.isBefore(DateTime.now()),
        permanent: profile['remote'] == true && expiry == null && traffic != null,
      );
    }
    final expiry = _expiry(profile['expiry']);
    final traffic = _traffic(profile['traffic']);
    return SubscriptionQuota._(
      traffic: traffic,
      expires: expiry?.$1,
      expired: expiry?.$2 ?? false,
      permanent: profile['remote'] == true && expiry == null && traffic != null,
    );
  }

  static int? _int(Object? raw) => raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');

  /// The details row keeps the space before the unit (`87.7 GB`), while the
  /// card's FlClash line does not (`87.7GB`).
  static String _spacedTraffic(int bytes) {
    final text = trafficText(bytes);
    final unit = text.indexOf(RegExp(r'[A-Za-z]'));
    return unit <= 0 ? text : '${text.substring(0, unit)} ${text.substring(unit)}';
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

/// FlClash's expiry chip: the date in the primary tint, the error tint once it
/// has passed.
class ExpireChip extends StatelessWidget {
  const ExpireChip({super.key, required this.expire});
  final DateTime expire;

  static const _padding = EdgeInsets.symmetric(horizontal: 8, vertical: 2);

  static String labelOf(DateTime expire) => expire.toLocal().toString().substring(0, 10);

  /// FlClash's `ExpireChip.widthOf`: the title row uses this to decide whether
  /// the chip would squeeze the title below half the row.
  static double widthOf(BuildContext context, DateTime expire) =>
      MeasureScope.of(context)
          .computeTextSize(
            Text(labelOf(expire), style: AppTextStyle.caption1.of(context, emphasized: true)),
          )
          .width +
      _padding.horizontal;

  @override
  Widget build(BuildContext context) {
    final color = expire.isBefore(DateTime.now())
        ? context.colorScheme.error
        : context.colorScheme.primary;
    return Tooltip(
      message: context.tr('Expire time'),
      child: DecoratedBox(
        decoration: ShapeDecoration(color: color.opacity15, shape: AppShape.full),
        child: Padding(
          padding: _padding,
          child: Text(
            labelOf(expire),
            maxLines: 1,
            style: AppTextStyle.caption1.of(context, emphasized: true).copyWith(color: color),
          ),
        ),
      ),
    );
  }
}

/// FlClash's `ChipTitle._fitsExpire`: the expiry chip gives way before it would
/// squeeze the title below half the row. Measuring the real title and chip
/// widths keeps the rule right at any text scale, unlike a fixed width cutoff.
bool _fitsExpire(
  BuildContext context,
  double maxWidth,
  String title,
  TextStyle titleStyle,
  DateTime expire,
) {
  if (!maxWidth.isFinite) return true;
  final titleWidth = MeasureScope.of(context)
      .computeTextSize(
        Text(title, style: DefaultTextStyle.of(context).style.merge(titleStyle)),
      )
      .width;
  const gap = 8.0;
  final available = maxWidth - (ExpireChip.widthOf(context, expire) + gap);
  return available >= (titleWidth < maxWidth / 2 ? titleWidth : maxWidth / 2);
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
    final remote = profile['remote'] == true;
    final used = (profile['trafficUsed'] as num?)?.toInt() ?? 0;
    final total = (profile['trafficTotal'] as num?)?.toInt() ?? 0;
    final expiryAt = (profile['expiryAt'] as num?)?.toInt() ?? 0;
    final subtitle = total > 0
        ? '${trafficText(used)} / ${trafficText(total)}'
        : context.tr(remote ? 'Remote' : 'Local');
    return ContextMenuRegion(
      menuItems: updating ? null : menuItems,
      child: Card(radius: AppCorner.xl, isSelected: selected, enterActionsOnRight: true,
        onPressed: onPressed,
        child: ListItem(
          minTileHeight: configurationCardHeight(context), minVerticalPadding: listRowVerticalPadding,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            LayoutBuilder(builder: (context, constraints) {
              final title = profile['name'].toString();
              final expire = expiryAt > 0
                  ? DateTime.fromMillisecondsSinceEpoch(expiryAt * 1000)
                  : null;
              // FlClash's ChipTitle: the expiry chip gives way before it would
              // squeeze the title below half the row.
              final showExpire = expire != null &&
                  _fitsExpire(context, constraints.maxWidth, title, titleStyle, expire);
              return Row(spacing: 8, children: [
                Flexible(child: Text(title, style: titleStyle,
                  strutStyle: StrutStyle.fromTextStyle(DefaultTextStyle.of(context).style.merge(titleStyle), forceStrutHeight: true),
                  maxLines: 1, overflow: TextOverflow.ellipsis, textWidthBasis: TextWidthBasis.longestLine)),
                if (showExpire) ExpireChip(expire: expire),
              ]);
            }),
            const SizedBox(height: 4),
            Text(subtitle,
              style: AppTextStyle.footnote.of(context).toLighter, maxLines: 1, overflow: TextOverflow.ellipsis),
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
