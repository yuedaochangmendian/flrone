import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../app/l10n.dart';
import '../app/navigation.dart';
import '../box.dart';
import '../components/dashboard_common.dart';
import '../providers/box_providers.dart';
import '../ui/icons/icons.dart';
import '../ui/list_item.dart';
import '../ui/scaffold/scaffold.dart';

String endpointName(String kind) => switch (kind) {
  'tailscale' => 'Tailscale',
  'openconnect' => 'OpenConnect',
  'openvpn' => 'OpenVPN',
  'usbip' => 'USB/IP',
  _ => kind,
};

String peerName(Json peer) {
  final dns = peer['dnsName'] as String? ?? '';
  if (dns.isNotEmpty) return dns.replaceFirst(RegExp(r'\.$'), '');
  return (peer['hostName'] ?? peer['id'] ?? '').toString();
}

List<Json> endpointPeers(Json endpoint) =>
    rows(endpoint['userGroups'])
        .expand((group) => rows(group['peers']))
        .toList();

class EndpointsPage extends ConsumerWidget {
  const EndpointsPage({super.key, required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(boxStateProvider);
    final endpoints = rows(box.toolState[kind]);
    return Scaffold(
      title: endpointName(kind),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          24 + context.bottomInset,
        ),
        children: [
          if (endpoints.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  'No endpoints',
                  style: AppTextStyle.body
                      .of(context)
                      .copyWith(color: context.colorScheme.onSurfaceVariant),
                ),
              ),
            )
          else
            for (final endpoint in endpoints)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _EndpointCard(
                  kind: kind,
                  endpoint: endpoint,
                  onTap: () => openPage<void>(
                    context,
                    EndpointDetailPage(kind: kind, endpoint: endpoint),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _EndpointCard extends StatelessWidget {
  const _EndpointCard({
    required this.kind,
    required this.endpoint,
    required this.onTap,
  });

  final String kind;
  final Json endpoint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final tag = (endpoint['endpointTag'] ?? endpoint['serverTag'] ?? '')
        .toString();
    final state = endpoint['stateText']?.toString() ?? '';
    return PressSurface(
      fill: SurfaceLevel.card.colorOf(scheme),
      shape: AppShape.all(AppCorner.lg),
      onPressed: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          spacing: 12,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: ShapeDecoration(
                color: SurfaceLevel.inset.colorOf(scheme),
                shape: AppShape.all(AppCorner.md),
              ),
              child: Center(
                child: GlyphIcon(
                  AppGlyphs.devices,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(
                    tag,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.subheadline.of(
                      context,
                      emphasized: true,
                    ),
                  ),
                  Text(
                    state.isEmpty ? 'Disconnected' : state,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.caption1
                        .of(context)
                        .copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            GlyphIcon(
              AppGlyphs.chevronForward,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class EndpointDetailPage extends ConsumerWidget {
  const EndpointDetailPage({
    super.key,
    required this.kind,
    required this.endpoint,
  });

  final String kind;
  final Json endpoint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tag = (endpoint['endpointTag'] ?? endpoint['serverTag']).toString();
    final box = ref.watch(boxStateProvider);
    final self = json(endpoint['selfPeer']);
    final addresses = (self['tailscaleIPs'] as List? ?? const [])
        .whereType<String>()
        .toList();
    final scheme = context.colorScheme;
    return Scaffold(
      title: tag,
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          24 + context.bottomInset,
        ),
        children: [
          _Section(
            title: 'Status',
            children: [
              ListItem(
                title: const Text('State'),
                trailing: Text(endpoint['stateText']?.toString() ?? '—'),
              ),
              if ((endpoint['error']?.toString() ?? '').isNotEmpty)
                ListItem(
                  title: const Text('Error'),
                  subtitle: Text(
                    endpoint['error'].toString(),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              if (addresses.isNotEmpty)
                ListItem(
                  title: const Text('Address'),
                  subtitle: Text(addresses.join('\n')),
                ),
              if ((endpoint['authURL']?.toString() ?? '').isNotEmpty)
                ListItem(
                  title: Text(context.tr('Sign in')),
                  trailing: const GlyphIcon(AppGlyphs.openExternal),
                  onTap: () => box.openUrl(endpoint['authURL'].toString()),
                ),
            ],
          ),
          if (kind == 'tailscale') ...[
            const SizedBox(height: 14),
            _Section(
              title: 'Peers',
              children: [
                for (final group in rows(endpoint['userGroups']))
                  for (final peer in rows(group['peers']))
                    ListItem(
                      leading: GlyphIcon(
                        AppGlyphs.devices,
                        color: peer['online'] == true
                            ? scheme.primary
                            : scheme.outline,
                      ),
                      title: Text(peerName(peer)),
                      subtitle: Text(
                        (peer['tailscaleIPs'] as List? ?? const []).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
              ],
            ),
            if (endpoint['canShareFiles'] == true) ...[
              const SizedBox(height: 14),
              _Section(
                title: 'Taildrop',
                children: [
                  ListItem(
                    title: const Text('Received files'),
                    subtitle: Text(
                      '${endpoint['waitingFileCount'] ?? 0} waiting',
                    ),
                    onTap: () =>
                        openPage<void>(context, InboxPage(endpoint: tag)),
                  ),
                  ListItem(
                    title: const Text('Transfers'),
                    onTap: () => openPage<void>(context, const TransfersPage()),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            _Section(
              title: 'Account',
              children: [
                ListItem(
                  title: const Text('Sign out'),
                  onTap: () async {
                    final confirmed = await showFloatingDialog<bool>(
                      context: context,
                      child: AlertDialog(
                        title: 'Sign out',
                        destructive: true,
                        child: Text(tag),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: Text(context.tr('Cancel')),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: Text(context.tr('Sign out')),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) await box.tailscaleLogout(tag);
                  },
                ),
              ],
            ),
          ],
          if (kind == 'usbip') ...[
            const SizedBox(height: 14),
            _Section(
              title: 'Devices',
              children: [
                for (final device in rows(endpoint['devices']))
                  ListItem(
                    title: Text(
                      (device['product'] ?? device['busId']).toString(),
                    ),
                    subtitle: Text(device['state']?.toString() ?? ''),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class InboxPage extends ConsumerStatefulWidget {
  const InboxPage({super.key, required this.endpoint});

  final String endpoint;

  @override
  ConsumerState<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends ConsumerState<InboxPage> {
  BoxController? _box;

  @override
  void initState() {
    super.initState();
    final box = ref.read(boxControllerProvider);
    _box = box;
    box.taildropSubscribe(widget.endpoint);
  }

  @override
  void dispose() {
    _box?.taildropUnsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = ref.watch(boxStateProvider);
    final state = box.inbox;
    final files = rows(state['files']);
    final receiving = rows(state['receiving']);
    return Scaffold(
      title: 'Received files',
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          24 + context.bottomInset,
        ),
        children: [
          if (files.isEmpty && receiving.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  'No received files',
                  style: AppTextStyle.body
                      .of(context)
                      .copyWith(color: context.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          for (final file in receiving)
            ListItem(
              title: Text(file['name'].toString()),
              subtitle: Text(
                '${formatBytes((file['receivedBytes'] as num?) ?? 0)} / '
                '${formatBytes((file['size'] as num?) ?? 0)}',
              ),
              trailing: IconButton(
                icon: const GlyphIcon(AppGlyphs.close),
                onPressed: () => box.taildropCancelReceive(
                  widget.endpoint,
                  file['name'],
                  file['senderID'],
                ),
              ),
            ),
          for (final file in files)
            ListItem(
              title: Text(file['name'].toString()),
              subtitle: Text(
                '${formatBytes((file['size'] as num?) ?? 0)} · ${file['senderName']}',
              ),
              onTap: () => box.taildropSave(widget.endpoint, file['name']),
              trailing: IconButton(
                icon: const GlyphIcon(AppGlyphs.delete),
                onPressed: () =>
                    box.taildropDelete(widget.endpoint, file['name']),
              ),
            ),
        ],
      ),
    );
  }
}

class TransfersPage extends ConsumerWidget {
  const TransfersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers = ref.watch(transfersProvider);
    return Scaffold(
      title: 'Transfers',
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          24 + context.bottomInset,
        ),
        children: [
          if (transfers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  'No transfers',
                  style: AppTextStyle.body
                      .of(context)
                      .copyWith(color: context.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          for (final transfer in transfers) ...[
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 6),
              child: Text(
                transfer['peerName']?.toString() ?? '',
                style: AppTextStyle.subheadline.of(context, emphasized: true),
              ),
            ),
            for (final file in rows(transfer['files']))
              ListItem(
                title: Text(file['name'].toString()),
                subtitle: Text(
                  '${formatBytes((file['sentBytes'] as num?) ?? 0)} / '
                  '${formatBytes((file['size'] as num?) ?? 0)}',
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            title,
            style: AppTextStyle.caption1
                .of(context)
                .copyWith(
                  color: context.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: ShapeDecoration(
            color: SurfaceLevel.card.colorOf(context.colorScheme),
            shape: AppShape.all(AppCorner.xl),
          ),
          child: Column(
            children: [
              for (final (index, child) in children.indexed) ...[
                child,
                if (index != children.length - 1) const Divider(height: 1),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
