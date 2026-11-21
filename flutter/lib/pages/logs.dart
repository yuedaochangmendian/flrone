import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../app/l10n.dart';
import '../box.dart';
import '../common/log_level.dart';
import '../providers/box_providers.dart';
import '../ui/icons/icons.dart';
import '../ui/scaffold/scaffold.dart';

enum _LogSource { all, kernel, android, previous }

class LogsPage extends ConsumerStatefulWidget {
  const LogsPage({super.key});

  @override
  ConsumerState<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends ConsumerState<LogsPage> {
  final _scroll = ScrollController();
  var _follow = true;
  var _query = '';
  var _source = _LogSource.all;
  String? _level;
  List<Json>? _previous;
  var _loadingPrevious = false;
  BoxController? _box;
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    final box = ref.read(boxControllerProvider);
    _box = box;
    box.setDataVisible(BoxData.logs, this, true);
    box.setDataVisible(BoxData.logcat, this, true);
    _scroll.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_handleScroll);
    _scroll.dispose();
    _box?.setDataVisible(BoxData.logs, this, false);
    _box?.setDataVisible(BoxData.logcat, this, false);
    super.dispose();
  }

  void _handleScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final atEnd = position.pixels >= position.maxScrollExtent - 24;
    if (_follow != atEnd) setState(() => _follow = atEnd);
  }

  List<Json> _rows(BoxController box) {
    final rows = switch (_source) {
      _LogSource.kernel => box.logs,
      _LogSource.android => box.logcat,
      _LogSource.previous => _previous ?? const <Json>[],
      _LogSource.all => [...box.logs, ...box.logcat],
    };
    final query = _query.toLowerCase();
    return rows.where((row) {
      if (_level != null &&
          logLevelName(row['level']).toLowerCase() != _level!.toLowerCase()) {
        return false;
      }
      if (query.isEmpty) return true;
      return '${row['level']} ${row['message']}'.toLowerCase().contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final box = ref.watch(boxStateProvider);
    final rows = _rows(box);
    final selectable = MediaQuery.sizeOf(context).width >= 640;
    if (_follow && rows.length != _lastCount) {
      _lastCount = rows.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
    return Scaffold(
      title: context.tr('Logs'),
      searchState: AppBarSearchState(
        onSearch: (query) => setState(() => _query = query),
      ),
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.clearAll,
          tooltip: context.tr('Clear'),
          onPressed: () {
            box.logsClear();
            if (_source == _LogSource.android) box.logcatClear();
          },
        ),
        IconButtonData(
          glyph: _follow ? AppGlyphs.arrowDown : AppGlyphs.clock,
          tooltip: _follow ? 'Following' : 'Resume',
          onPressed: () {
            setState(() => _follow = true);
            if (_scroll.hasClients) {
              _scroll.jumpTo(_scroll.position.maxScrollExtent);
            }
          },
        ),
      ],
      menuItems: [
        for (final source in _LogSource.values)
          PopupMenuItem(
            label: switch (source) {
              _LogSource.all => 'All sources',
              _LogSource.kernel => 'Kernel',
              _LogSource.android => 'Android',
              _LogSource.previous => 'Previous session',
            },
            checked: source == _source,
            onPressed: () {
              setState(() => _source = source);
              if (source == _LogSource.previous && _previous == null) {
                _loadPrevious();
              }
            },
          ),
        for (final level in coreLogLevels)
          PopupMenuItem(
            label: level,
            checked: level == _level,
            onPressed: () =>
                setState(() => _level = _level == level ? null : level),
          ),
      ],
      body: ListView.builder(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          24 + context.bottomInset,
        ),
        itemCount: rows.length,
        itemBuilder: (context, index) {
          final row = rows[index];
          final level = logLevelName(row['level']);
          final scheme = context.colorScheme;
          final tone = switch (level.toLowerCase()) {
            'error' => scheme.error,
            'warning' || 'warn' => scheme.warning,
            _ => scheme.onSurfaceVariant,
          };
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Row(
                  spacing: 8,
                  children: [
                    Text(
                      _time(row['receivedAt']),
                      style: AppTextStyle.caption2
                          .of(context)
                          .copyWith(color: scheme.onSurfaceVariant),
                    ),
                    Text(
                      level.toUpperCase(),
                      style: AppTextStyle.caption2
                          .of(context, emphasized: true)
                          .copyWith(color: tone),
                    ),
                  ],
                ),
                Builder(
                  builder: (context) {
                    final text =
                        row['message']?.toString() ??
                        row['payload']?.toString() ??
                        '';
                    final style = AppTextStyle.caption1
                        .of(context)
                        .copyWith(
                          color: scheme.onSurface,
                          fontFamily: 'monospace',
                        );
                    return selectable
                        ? SelectableText(text, style: style)
                        : Text(text, style: style);
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _loadPrevious() async {
    if (_loadingPrevious) return;
    setState(() => _loadingPrevious = true);
    try {
      final batch = json(await ref.read(boxControllerProvider).logsPrevious());
      if (mounted) {
        setState(() => _previous = rows(batch['entries']));
      }
    } catch (error) {
      ref.read(boxControllerProvider).report(error);
    } finally {
      if (mounted) setState(() => _loadingPrevious = false);
    }
  }

  String _time(Object? value) {
    final millis = (value as num?)?.toInt() ?? 0;
    if (millis == 0) return '--:--:--';
    final date = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}:'
        '${date.second.toString().padLeft(2, '0')}';
  }
}
