import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../app/l10n.dart';
import '../box.dart';
import '../providers/box_providers.dart';
import '../ui/icons/icons.dart';
import '../ui/list_item.dart';
import '../ui/scaffold/scaffold.dart';
import 'endpoints.dart';

class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({super.key});

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  var _loading = true;
  String? _error;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final box = ref.read(boxControllerProvider);
      box.terminal = json(await box.sshSnapshot());
      if (mounted) setState(() => _loading = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = BoxController.describe(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final box = ref.watch(boxStateProvider);
    final snapshot = box.terminal;
    final sessions = rows(snapshot['sessions']);
    Json? active;
    for (final session in sessions) {
      if (session['id'] == snapshot['activeId']) active = session;
    }
    return Scaffold(
      title: active?['name']?.toString() ?? 'Terminal',
      isLoading: _loading,
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.add,
          tooltip: 'New session',
          onPressed: () => _newSession(context),
        ),
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: 'Sessions',
          onPressed: _load,
        ),
      ],
      body: active == null
          ? ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                context.contentTopPadding,
                16,
                24 + context.bottomInset,
              ),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      _error!,
                      style: AppTextStyle.caption1
                          .of(context)
                          .copyWith(color: context.colorScheme.error),
                    ),
                  ),
                for (final session in sessions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ListItem(
                      leading: const GlyphIcon(AppGlyphs.code),
                      title: Text(session['name']?.toString() ?? 'Session'),
                      subtitle: Text(session['phase']?.toString() ?? ''),
                      onTap: () => ref.read(boxControllerProvider).act(
                        'ssh.select',
                        {'id': session['id']},
                      ),
                    ),
                  ),
                if (sessions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Column(
                      spacing: 12,
                      children: [
                        GlyphIcon(
                          AppGlyphs.code,
                          size: 40,
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                        Text(
                          'No terminal sessions',
                          style: AppTextStyle.body
                              .of(context)
                              .copyWith(
                                color: context.colorScheme.onSurfaceVariant,
                              ),
                        ),
                        TonalButton(
                          label: 'New session',
                          glyph: AppGlyphs.add,
                          onPressed: () => _newSession(context),
                        ),
                      ],
                    ),
                  ),
              ],
            )
          : _TerminalSurface(
              session: active,
              revision: _revision,
              onClose: () =>
                  ref.read(boxControllerProvider).sshClose(active!['id']),
            ),
    );
  }

  Future<void> _newSession(BuildContext context) async {
    final box = ref.read(boxControllerProvider);
    final peers = <({String endpoint, String id, String name})>[];
    for (final endpoint in rows(box.toolState['tailscale'])) {
      final tag = endpoint['endpointTag']?.toString() ?? '';
      for (final peer in endpointPeers(endpoint)) {
        if ((peer['sshHostKeys'] as List? ?? const []).isEmpty) continue;
        peers.add((
          endpoint: tag,
          id: peer['id'].toString(),
          name: peerName(peer),
        ));
      }
    }
    if (peers.isEmpty) {
      BannerHost.maybeOf(context)?.show('No SSH-capable Tailscale peer');
      return;
    }
    final picked = await showSheet<({String endpoint, String id, String name})>(
      context: context,
      builder: (context) => Surface(
        color: SurfaceLevel.page.colorOf(context.colorScheme),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'New SSH session',
                  style: AppTextStyle.title3.of(context, emphasized: true),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final peer in peers)
                        ListItem(
                          title: Text(peer.name),
                          subtitle: Text(peer.endpoint),
                          onTap: () => Navigator.pop(context, peer),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      box.terminal = json(
        await box.sshStart(
          picked.endpoint,
          picked.id,
          username: 'root',
          terminalType: 'xterm-256color',
        ),
      );
      if (mounted) setState(() => _revision++);
    } catch (error) {
      box.report(error);
    }
  }
}

class _TerminalSurface extends ConsumerStatefulWidget {
  const _TerminalSurface({
    required this.session,
    required this.revision,
    required this.onClose,
  });

  final Json session;
  final int revision;
  final VoidCallback onClose;

  @override
  ConsumerState<_TerminalSurface> createState() => _TerminalSurfaceState();
}

class _TerminalSurfaceState extends ConsumerState<_TerminalSurface> {
  MethodChannel? _channel;
  Json _modifiers = const {};

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  void _created(int id) {
    _channel = MethodChannel('io.flrone/terminal/$id')
      ..setMethodCallHandler((call) async {
        if (!mounted) return null;
        if (call.method == 'modifiers') {
          setState(() => _modifiers = json(call.arguments));
        }
        return null;
      });
    _update();
    setState(() {});
  }

  Future<void> _update() async {
    try {
      await _channel?.invokeMethod('update', {
        'id': widget.session['id'],
        'dark': context.colorScheme.brightness == Brightness.dark,
      });
    } catch (error) {
      ref.read(boxControllerProvider).report(error);
    }
  }

  Future<void> _key(String key) async {
    try {
      await _channel?.invokeMethod('key', {'key': key});
    } catch (error) {
      ref.read(boxControllerProvider).report(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Center(
        child: Text(
          'Terminal is available on Android only',
          style: AppTextStyle.body.of(context),
        ),
      );
    }
    final phase = widget.session['phase']?.toString() ?? '';
    return Column(
      children: [
        if (phase == 'CONNECTING') const LinearProgressIndicator(),
        Expanded(
          child: AndroidView(
            viewType: 'io.flrone/ghostty',
            creationParams: {
              'id': widget.session['id'],
              'dark': context.colorScheme.brightness == Brightness.dark,
            },
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _created,
          ),
        ),
        SafeArea(
          top: false,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final key in const [
                  'Esc',
                  'Tab',
                  'Ctrl',
                  'Alt',
                  '↑',
                  '↓',
                  '←',
                  '→',
                  'Home',
                  'End',
                  'PgUp',
                  'PgDn',
                  'Paste',
                  'Keyboard',
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: TextButton(
                      onPressed: _channel == null ? null : () => _key(key),
                      child: Text(
                        key +
                            (_modifiers[key.toLowerCase()] == 'LOCKED'
                                ? ' •'
                                : ''),
                      ),
                    ),
                  ),
                TextButton(
                  onPressed: widget.onClose,
                  child: Text(context.tr('Close')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
