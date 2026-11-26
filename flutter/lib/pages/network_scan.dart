// One-shot network check, wired to the core's ScanCheckNetwork through the
// action bus (scan_actions.go). This is intentionally a CHECK, not a scan
// session: there is no progress bar, no live event list and no Stop button,
// because the fork cannot build the ScanProbe/QueryScan/StopScan engine chain
// (see the deferred note in scan_actions.go). A run is idle -> running -> done
// or error, and the only result numbers shown are the ones the core returned.
//
// The page is a ConsumerStatefulWidget so a run is one action invocation whose
// Future lives in the widget's state; after the answer arrives, the widgets
// below simply render [NetworkCheckResult]. [NetworkScanPage.runnerOverride] is
// settable in tests so the running/done/error states are exercised without a
// kernel.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../components/form.dart';
import '../providers/box_providers.dart';
import '../widgets.dart';

enum _CheckState { idle, running, done, error }

class NetworkScanPage extends ConsumerStatefulWidget {
  const NetworkScanPage({super.key});

  /// Test seam: replaces the BoxController facade call. It receives the mode,
  /// the raw input text and the timeout, returning exactly what the facade
  /// returns. Production leaves it null and uses [BoxController.checkNetwork] /
  /// [checkNetworkDNS].
  static Future<NetworkCheckResult> Function(bool dns, String input, int timeoutMs)?
      runnerOverride;

  @override
  ConsumerState<NetworkScanPage> createState() => _NetworkScanPageState();
}

class _NetworkScanPageState extends ConsumerState<NetworkScanPage> {
  final _targets = TextEditingController();
  final _mode = ValueNotifier<bool>(false); // false = TCP targets, true = DNS resolvers
  final _timeout = ValueNotifier<int>(3000);
  _CheckState _state = _CheckState.idle;
  NetworkCheckResult? _result;
  String _error = '';

  @override
  void dispose() {
    _targets.dispose();
    _mode.dispose();
    _timeout.dispose();
    super.dispose();
  }

  List<String> get _entries => _targets.text
      .split(RegExp(r'[,\n]'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();

  Future<void> _run() async {
    final entries = _entries;
    if (entries.isEmpty) {
      setState(() {
        _state = _CheckState.error;
        _error = 'Enter at least one target';
        _result = null;
      });
      return;
    }
    final dns = _mode.value;
    setState(() {
      _state = _CheckState.running;
      _error = '';
      _result = null;
    });
    try {
      final runner = NetworkScanPage.runnerOverride;
      final result = runner != null
          ? await runner(dns, entries.join(','), _timeout.value)
          : dns
              ? await ref.read(boxControllerProvider).checkNetworkDNS(entries,
                  timeoutMs: _timeout.value)
              : await ref.read(boxControllerProvider).checkNetwork(entries,
                  timeoutMs: _timeout.value);
      if (!mounted) return;
      setState(() {
        _result = result;
        _state = _CheckState.done;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = _CheckState.error;
        _error = BoxController.describe(error);
        _result = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _state == _CheckState.running;
    final result = _result;
    return BoxPage(
      title: 'Network check',
      loading: running,
      children: [
        generateSection(title: context.tr('Check targets'), items: [
          ListItem(
            title: Text(context.tr('Targets')),
            subtitle: Text(context.tr('TCP targets or DNS resolvers, separated by commas')),
            trailing: SizedBox(
              width: 180,
              child: FormRowTextField(
                controller: _targets,
                hintText: '1.1.1.1:53, example.com:443',
              ),
            ),
          ),
          ListItem.toggle(
            title: Text(context.tr('DNS resolver check')),
            subtitle: Text(context.tr('Ask the resolvers for the root NS record instead of dialing targets')),
            value: _mode.value,
            onChanged: (value) => setState(() => _mode.value = value),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: FilledButton(
            onPressed: running ? null : _run,
            child: Text(context.tr(running ? 'Checking…' : 'Run check')),
          ),
        ),
        if (_state == _CheckState.error)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              context.tr('Check failed') + (_error.isEmpty ? '' : ': $_error'),
              style: TextStyle(color: context.colorScheme.error),
            ),
          ),
        if (result != null)
          generateSection(title: context.tr('Result'), items: [
            ListItem(
              title: Text(context.tr('Reachable')),
              subtitle: Text(result.up ? context.tr('Yes') : context.tr('No')),
            ),
            if (result.error.isNotEmpty)
              ListItem(
                title: Text(context.tr('Detail')),
                subtitle: Text(result.error),
              ),
            if (result.systemResolvers.isNotEmpty)
              ListItem(
                title: Text(context.tr('Resolvers asked')),
                subtitle: Text(result.systemResolvers.join(', ')),
              ),
          ]),
      ],
    );
  }
}
