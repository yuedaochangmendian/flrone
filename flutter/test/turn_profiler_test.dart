import 'package:flrone/core/turn_profiler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives a [TurnProfiler] from a real [TickerProvider] so the test exercises
/// the same path the card uses: ticks on vsync timestamps, a gap the size of a
/// skipped frame, and the delayed report.
class _Host extends StatefulWidget {
  const _Host({super.key, required this.onReport});
  final void Function(String) onReport;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final TurnProfiler profiler;

  @override
  void initState() {
    super.initState();
    profiler = TurnProfiler.start('test', widget.onReport, vsync: this);
  }

  @override
  void dispose() {
    profiler.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  testWidgets('reports frames, the skipped-frame gap and the min/max cadence', (
    tester,
  ) async {
    final reports = <String>[];
    final key = GlobalKey<_HostState>();
    await tester.pumpWidget(_Host(key: key, onReport: reports.add));

    // Five intervals: four vsync gaps and one double gap (a dropped frame).
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump(const Duration(milliseconds: 16));
    key.currentState!.profiler.stop();
    // The report is delayed to catch the turn's last frames.
    await tester.pump(const Duration(milliseconds: 300));

    expect(reports, hasLength(1));
    final line = reports.single;
    expect(line, startsWith('test turn: '));
    // The first tick only seeds the baseline.
    expect(line, contains('4 frames'));
    expect(line, contains('max gap 32.0ms'));
    expect(line, contains('slow>25ms=1'));
    expect(line, contains('bad>50ms=0'));
    expect(line, contains('@60Hz'));
  });

  testWidgets('cancel() reports nothing and leaves no timer behind', (
    tester,
  ) async {
    final reports = <String>[];
    final key = GlobalKey<_HostState>();
    await tester.pumpWidget(_Host(key: key, onReport: reports.add));
    await tester.pump(const Duration(milliseconds: 16));
    key.currentState!.profiler.stop();
    key.currentState!.profiler.cancel();
    await tester.pump(const Duration(milliseconds: 300));
    expect(reports, isEmpty);
  });
}
