import 'dart:convert' as convert;

import 'package:flutter/services.dart';

import '../widgets.dart';
import '../components/form.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

/// The typed protocol forms: one schema per protocol, fields at sing-box JSON paths, rendered by a
/// generic engine and saved through the `nodeUpdate` platform duty (Kotlin parses and model-validates the
/// document, the native editor's save gate). Blocks mirror the native screens' shared blocks: tls,
/// transport and quic. Field lists follow the native *SettingsActivity bindings.
///
/// Synthetic keys (`__state`, `__must`) carry menu state the JSON has no room for; they are stripped
/// before the document is saved.
class ProtocolFormPage extends ConsumerStatefulWidget {
  const ProtocolFormPage({super.key, required this.id, this.draft});
  final int id;
  final Json? draft;
  @override
  ConsumerState<ProtocolFormPage> createState() => _ProtocolFormPageState();
}

class _ProtocolFormPageState extends ConsumerState<ProtocolFormPage> {
  Json? _root;
  String? _error;
  bool _loading = true, _saving = false, _attempted = false;
  // The sheet's dismiss guard asks before discarding edits.
  bool _dirty = false;
  late final TextEditingController _name = TextEditingController();
  final _controllers = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  TextEditingController _controller(String path, {required String text}) {
    final controller = _controllers.putIfAbsent(
      path,
      () => TextEditingController(text: text),
    );
    return controller;
  }

  @override
  void dispose() {
    _name.dispose();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _draft => widget.draft != null;

  Future<void> _load() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final data = _draft
          ? json(widget.draft!)
          : json(await ref.read(boxControllerProvider).profileNodeConfig(widget.id));
      if (!mounted) return;
      _name.text = data['name']?.toString() ?? '';
      for (final controller in _controllers.values) {
        controller.dispose();
      }
      _controllers.clear();
      final decoded = convert.jsonDecode(data['json']?.toString() ?? '{}');
      setState(() {
        _root = json(decoded);
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = BoxController.describe(error);
          _loading = false;
        });
      }
    }
  }

  String get _type => _root?['type']?.toString() ?? '';

  /// The form reads a dotted path; missing segments read as null (and as '' in text fields).
  Object? _get(String path) {
    Object? current = _root;
    for (final segment in path.split('.')) {
      if (current is Json) {
        current = current[segment];
      } else {
        return null;
      }
    }
    return current;
  }

  void _set(String path, Object? value) {
    final root = _root;
    if (root == null) return;
    _dirty = true;
    final segments = path.split('.');
    Json current = root;
    for (final segment in segments.take(segments.length - 1)) {
      final next = current[segment];
      current[segment] = next is Json ? next : <String, dynamic>{};
      current = current[segment] as Json;
    }
    if (value == null) {
      current.remove(segments.last);
    } else {
      current[segments.last] = value;
    }
  }

  String _text(String path) => _get(path)?.toString() ?? '';
  int _int(String path) => (_get(path) as num?)?.toInt() ?? 0;
  bool _bool(String path) => _get(path) == true;
  List<String> _lines(String path) =>
      (_get(path) as List? ?? const []).map((e) => '$e').toList();

  /// A raw JSON object at [path] shown as compact text; empty when absent or not an object.
  String _jsonText(String path) {
    final value = _get(path);
    return value is Json ? convert.jsonEncode(value) : '';
  }

  // ------------------------------------------------------------------------------------------------ blocks

  List<_Field> _chainBlock() => [
    _Field('name', 'Name', 'name'),
    _Field('list', 'Proxy chain', 'chain'),
  ];

  List<_Field> _tlsBlock({required bool mustTls}) => [
    // The must-TLS screens hide the switch; the save keeps the block on regardless.
    if (!mustTls) _Field('tls.enabled', 'Enabled', 'bool'),
    _Field('tls.server_name', 'Server name', 'text'),
    _Field('tls.insecure', 'Allow insecure', 'bool'),
    _Field('tls.alpn', 'ALPN', 'lines', hint: 'One protocol per line'),
    _Field('tls.utls.enabled', 'uTLS', 'bool'),
    _Field(
      'tls.utls.fingerprint',
      'uTLS fingerprint',
      'choice',
      choices: _utlsChoices,
      showIf: ('tls.utls.enabled', 'true'),
    ),
    _Field('tls.reality.enabled', 'Reality', 'bool'),
    _Field(
      'tls.reality.public_key',
      'Reality public key',
      'text',
      showIf: ('tls.reality.enabled', 'true'),
    ),
    _Field(
      'tls.reality.short_id',
      'Reality short ID',
      'text',
      showIf: ('tls.reality.enabled', 'true'),
    ),
    _Field(
      'tls.reality.mldsa65_verify',
      'Reality ML-DSA-65 verify',
      'text',
      showIf: ('tls.reality.enabled', 'true'),
    ),
    _Field('tls.ech.enabled', 'ECH', 'bool'),
    _Field(
      'tls.ech.config',
      'ECH config',
      'lines',
      showIf: ('tls.ech.enabled', 'true'),
    ),
  ];

  List<_Field> _transportBlock() => [
    _Field(
      'transport.type',
      'Transport',
      'choice',
      choices: const [
        ('tcp', 'TCP'),
        ('ws', 'WebSocket'),
        ('http', 'HTTP'),
        ('grpc', 'gRPC'),
        ('httpupgrade', 'HTTPUpgrade'),
        ('xhttp', 'XHTTP'),
        ('mkcp', 'mKCP'),
      ],
    ),
    _Field(
      'transport.host',
      'Host',
      'text',
      showIf: ('transport.type', 'ws,http,httpupgrade,xhttp'),
    ),
    _Field(
      'transport.path',
      'Path',
      'text',
      showIf: ('transport.type', 'ws,http,httpupgrade,xhttp'),
    ),
    _Field(
      'transport.method',
      'Method',
      'text',
      showIf: ('transport.type', 'http'),
    ),
    _Field(
      'transport.headers',
      'Headers',
      'headers',
      showIf: ('transport.type', 'ws,http,httpupgrade,xhttp'),
    ),
    _Field(
      'transport.service_name',
      'Service name',
      'text',
      showIf: ('transport.type', 'grpc'),
    ),
    _Field(
      'transport.idle_timeout',
      'Idle timeout',
      'text',
      showIf: ('transport.type', 'http,grpc'),
    ),
    _Field(
      'transport.ping_timeout',
      'Ping timeout',
      'text',
      showIf: ('transport.type', 'http,grpc'),
    ),
    _Field(
      'transport.max_early_data',
      'Max early data',
      'int',
      showIf: ('transport.type', 'ws'),
    ),
    _Field(
      'transport.early_data_header_name',
      'Early data header',
      'text',
      showIf: ('transport.type', 'ws'),
    ),
    // XHTTP (sing-box V2RayXHTTPOptions). The form leaves x_padding_bytes empty for the native
    // Transport model to supply its 100-1000 default (the core refuses a zero range); every
    // other key is left out when empty for the core defaults.
    _Field(
      'transport.mode',
      'Mode',
      'choice',
      choices: const [
        ('', 'Default'),
        ('auto', 'auto'),
        ('packet-up', 'packet-up'),
        ('stream-up', 'stream-up'),
        ('stream-one', 'stream-one'),
      ],
      showIf: ('transport.type', 'xhttp'),
    ),
    _Field(
      'transport.x_padding_bytes',
      'X-Padding bytes',
      'text',
      hint: 'Range, e.g. 100-1000',
      showIf: ('transport.type', 'xhttp'),
    ),
    _Field(
      'transport.no_grpc_header',
      'No gRPC header',
      'bool',
      showIf: ('transport.type', 'xhttp'),
    ),
    _Field(
      'transport.no_sse_header',
      'No SSE header',
      'bool',
      showIf: ('transport.type', 'xhttp'),
    ),
    _Field(
      'transport.congestion_controller',
      'Congestion controller',
      'choice',
      choices: const [
        ('', 'Default'),
        ('bbr', 'bbr'),
        ('cubic', 'cubic'),
        ('reno', 'reno'),
      ],
      showIf: ('transport.type', 'xhttp'),
    ),
    _Field(
      'transport.xmux',
      'XHTTP extra JSON (xmux)',
      'json',
      hint: '{"maxConnections":"4-8"}',
      showIf: ('transport.type', 'xhttp'),
    ),
    // mKCP (sing-box V2RayKCPOptions); zero values are the core defaults, so leaving a field empty
    // omits it from the document.
    _Field(
      'transport.mtu',
      'MTU',
      'int',
      showIf: ('transport.type', 'mkcp'),
    ),
    _Field(
      'transport.tti',
      'TTI',
      'int',
      showIf: ('transport.type', 'mkcp'),
    ),
    _Field(
      'transport.uplink_capacity',
      'Uplink capacity',
      'int',
      showIf: ('transport.type', 'mkcp'),
    ),
    _Field(
      'transport.downlink_capacity',
      'Downlink capacity',
      'int',
      showIf: ('transport.type', 'mkcp'),
    ),
    _Field(
      'transport.congestion',
      'Congestion',
      'bool',
      showIf: ('transport.type', 'mkcp'),
    ),
    _Field(
      'transport.read_buffer_size',
      'Read buffer size',
      'int',
      showIf: ('transport.type', 'mkcp'),
    ),
    _Field(
      'transport.write_buffer_size',
      'Write buffer size',
      'int',
      showIf: ('transport.type', 'mkcp'),
    ),
    _Field(
      'transport.header_type',
      'Header type',
      'choice',
      choices: const [
        ('', 'Default'),
        ('none', 'none'),
        ('srtp', 'srtp'),
        ('utp', 'utp'),
        ('wechat-video', 'wechat-video'),
        ('dtls', 'dtls'),
        ('wireguard', 'wireguard'),
      ],
      showIf: ('transport.type', 'mkcp'),
    ),
    _Field(
      'transport.seed',
      'Seed',
      'text',
      showIf: ('transport.type', 'mkcp'),
    ),
  ];

  /// The dial fields every outbound carries, flat at the document root (DialFields export).
  List<_Field> _dialBlock() => [
    _Field('bind_interface', 'Bind interface', 'text'),
    _Field('inet4_bind_address', 'IPv4 bind address', 'text'),
    _Field('inet6_bind_address', 'IPv6 bind address', 'text'),
    _Field('connect_timeout', 'Connect timeout', 'text'),
    _Field('tcp_fast_open', 'TCP fast open', 'bool'),
    _Field('tcp_multi_path', 'Multipath TCP', 'bool'),
    _Field('udp_fragment', 'UDP fragment', 'bool'),
    _Field('reuse_addr', 'Reuse address', 'bool'),
  ];

  List<_Field> _quicBlock() => [
    _Field('quic.idle_timeout', 'Idle timeout', 'text'),
    _Field('quic.keep_alive_period', 'Keep alive period', 'text'),
    _Field('quic.stream_receive_window', 'Stream receive window', 'text'),
    _Field(
      'quic.connection_receive_window',
      'Connection receive window',
      'text',
    ),
    _Field('quic.max_concurrent_streams', 'Max concurrent streams', 'int'),
    _Field('quic.initial_packet_size', 'Initial packet size', 'int'),
  ];

  /// The utls fingerprint menu's "Default" is the empty fingerprint (the native derive rule).
  List<(String, String)> get _utlsChoices => const [
    ('', 'Default'),
    ('chrome', 'chrome'),
    ('firefox', 'firefox'),
    ('edge', 'edge'),
    ('safari', 'safari'),
    ('360', '360'),
    ('qq', 'qq'),
    ('ios', 'ios'),
    ('android', 'android'),
    ('random', 'random'),
    ('randomized', 'randomized'),
    ('unsafe', 'unsafe'),
  ];

  // ------------------------------------------------------------------------------------------------ schemas

  bool get _supported =>
      _type == 'chain' ||
      const [
        'shadowsocks',
        'vmess',
        'vless',
        'trojan',
        'tuic',
        'hysteria',
        'wireguard',
        'direct',
        'socks',
        'http',
        'anytls',
        'shadowtls',
        'snell',
        'naive',
        'juicity',
        'mieru',
        'masque',
        'ssh',
        'trusttunnel',
        'openconnect',
        'openvpn',
      ].contains(_type);

  List<_Section> _schemas() => switch (_type) {
    'chain' => [_Section(null, _chainBlock())],
    'shadowsocks' => [
      ..._basic(),
      _Section(null, [
        _Field(
          'method',
          'Method',
          'choice',
          choices: [
            for (final method in const [
              'none',
              '2022-blake3-aes-128-gcm',
              '2022-blake3-aes-256-gcm',
              '2022-blake3-chacha20-poly1305',
              'aes-128-gcm',
              'aes-192-gcm',
              'aes-256-gcm',
              'chacha20-ietf-poly1305',
              'xchacha20-ietf-poly1305',
              'aes-128-ctr',
              'aes-192-ctr',
              'aes-256-ctr',
              'aes-128-cfb',
              'aes-192-cfb',
              'aes-256-cfb',
              'rc4-md5',
              'chacha20-ietf',
              'xchacha20',
            ])
              (method, method),
          ],
        ),
        _Field('password', 'Password', 'password'),
        _Field('plugin', 'Plugin', 'text'),
        _Field('plugin_opts', 'Plugin options', 'text'),
        _Field('uot', 'UDP over TCP', 'bool'),
      ]),
    ],
    'vmess' => [
      ..._basic(),
      _Section(null, [
        _Field('uuid', 'UUID', 'text', required: true),
        _Field(
          'security',
          'Encryption',
          'choice',
          choices: const [
            ('auto', 'auto'),
            ('none', 'none'),
            ('zero', 'zero'),
            ('aes-128-gcm', 'aes-128-gcm'),
            ('chacha20-poly1305', 'chacha20-poly1305'),
          ],
        ),
        _Field('alter_id', 'Alter ID', 'int'),
        _Field(
          'packet_encoding',
          'Packet encoding',
          'choice',
          choices: const [
            ('', 'Default'),
            ('packetaddr', 'packetaddr'),
            ('xudp', 'xudp'),
          ],
        ),
        _Field('global_padding', 'Global padding', 'bool'),
        _Field('authenticated_length', 'Authenticated length', 'bool'),
      ]),
      _Section('Transport', _transportBlock()),
      _Section('TLS', _tlsBlock(mustTls: false)),
    ],
    'vless' => [
      ..._basic(),
      _Section(null, [
        _Field('uuid', 'UUID', 'text', required: true),
        _Field(
          'flow',
          'Flow',
          'choice',
          choices: const [
            ('none', 'none'),
            ('xtls-rprx-vision', 'xtls-rprx-vision'),
          ],
        ),
      ]),
      _Section('Transport', _transportBlock()),
      _Section('TLS', _tlsBlock(mustTls: false)),
    ],
    'trojan' => [
      ..._basic(),
      _Section(null, [
        _Field('password', 'Password', 'password', required: true),
      ]),
      _Section('Transport', _transportBlock()),
      _Section('TLS', _tlsBlock(mustTls: true)),
    ],
    'tuic' => [
      ..._basic(),
      _Section(null, [
        _Field('uuid', 'UUID', 'text', required: true),
        _Field('password', 'Password', 'password'),
        _Field(
          'congestion_control',
          'Congestion control',
          'choice',
          choices: const [
            ('', 'Default'),
            ('cubic', 'cubic'),
            ('new_reno', 'new_reno'),
            ('bbr', 'bbr'),
          ],
        ),
        _Field(
          'udp_relay_mode',
          'UDP relay mode',
          'choice',
          choices: const [
            ('', 'Default'),
            ('native', 'native'),
            ('quic', 'quic'),
          ],
        ),
        _Field('udp_over_stream', 'UDP over stream', 'bool'),
        _Field('zero_rtt_handshake', 'Zero RTT handshake', 'bool'),
        _Field('heartbeat', 'Heartbeat', 'text'),
      ]),
      _Section('TLS', _tlsBlock(mustTls: true)),
      _Section('QUIC', _quicBlock()),
    ],
    'hysteria' => [
      ..._basic(),
      _Section(null, [
        _Field(
          'protocol_version',
          'Protocol version',
          'choice',
          choices: const [('1', 'Hysteria 1'), ('2', 'Hysteria 2')],
        ),
        _Field(
          'auth_type',
          'Auth type',
          'choice',
          choices: const [
            ('', 'Default'),
            ('base64', 'base64'),
            ('string', 'string'),
          ],
          showIf: ('protocol_version', '1'),
        ),
        _Field('auth', 'Auth', 'password', showIf: ('protocol_version', '1')),
        _Field(
          'password',
          'Password',
          'password',
          showIf: ('protocol_version', '2'),
        ),
        _Field(
          'obfs_type',
          'Obfuscation',
          'choice',
          choices: const [
            ('', 'None'),
            ('salamander', 'salamander'),
            ('gecko', 'gecko'),
          ],
          showIf: ('protocol_version', '2'),
        ),
        _Field(
          'obfs',
          'Obfuscation password',
          'password',
          showIf: ('protocol_version', '2'),
        ),
        _Field(
          'up_mbps',
          'Up (Mbps)',
          'int',
          showIf: ('protocol_version', '2'),
        ),
        _Field(
          'down_mbps',
          'Down (Mbps)',
          'int',
          showIf: ('protocol_version', '2'),
        ),
        _Field(
          'server_ports',
          'Server ports',
          'lines',
          showIf: ('protocol_version', '2'),
        ),
        _Field(
          'hop_interval',
          'Hop interval',
          'text',
          showIf: ('protocol_version', '2'),
        ),
      ]),
      _Section('TLS', _tlsBlock(mustTls: true)),
      _Section('QUIC', _quicBlock()),
    ],
    'wireguard' => [
      _Section(null, [
        _Field('name', 'Name', 'name'),
        _Field('peer.address', 'Endpoint address', 'text', required: true),
        _Field('peer.port', 'Endpoint port', 'int', required: true),
        _Field('address', 'Local addresses', 'list'),
        _Field('private_key', 'Private key', 'password', required: true),
        _Field('peer.public_key', 'Peer public key', 'text', required: true),
        _Field('peer.pre_shared_key', 'Pre-shared key', 'password'),
        _Field('peer.reserved', 'Reserved', 'list'),
        _Field('peer.persistent_keepalive', 'Persistent keepalive', 'int'),
        _Field('mtu', 'MTU', 'int'),
        _Field('system', 'System interface', 'bool'),
      ]),
    ],
    'direct' => [..._basic(), _Section('Dial', _dialBlock())],
    'socks' => [
      ..._basic(),
      _Section(null, [
        _Field('username', 'Username', 'text'),
        _Field('password', 'Password', 'password'),
        _Field('uot', 'UDP over TCP', 'bool'),
      ]),
    ],
    'http' => [
      ..._basic(),
      _Section(null, [
        _Field('username', 'Username', 'text'),
        _Field('password', 'Password', 'password'),
        _Field('path', 'Path', 'text'),
        _Field('headers', 'Headers', 'headers'),
      ]),
    ],
    'anytls' => [
      ..._basic(),
      _Section(null, [
        _Field('password', 'Password', 'password'),
        _Field(
          'idle_session_check_interval',
          'Idle session check interval',
          'text',
        ),
        _Field('idle_session_timeout', 'Idle session timeout', 'text'),
        _Field('min_idle_session', 'Min idle session', 'int'),
      ]),
    ],
    'shadowtls' => [
      ..._basic(),
      _Section(null, [
        _Field('version', 'Version', 'int'),
        _Field('password', 'Password', 'password'),
      ]),
    ],
    'snell' => [
      ..._basic(),
      _Section(null, [
        _Field('version', 'Version', 'int'),
        _Field('psk', 'PSK', 'password'),
        _Field('userkey', 'User key', 'password'),
        _Field('network', 'Network', 'text'),
        _Field('obfs_mode', 'Obfuscation mode', 'text'),
        _Field('obfs_host', 'Obfuscation host', 'text'),
        _Field('mode', 'Mode', 'text'),
        _Field('reuse', 'Reuse connections', 'bool'),
      ]),
    ],
    'naive' => [
      ..._basic(),
      _Section(null, [
        _Field('username', 'Username', 'text'),
        _Field('password', 'Password', 'password'),
        _Field('quic', 'QUIC', 'bool'),
        _Field(
          'congestion_control',
          'Congestion control',
          'choice',
          choices: const [
            ('', 'Default'),
            ('cubic', 'cubic'),
            ('new_reno', 'new_reno'),
            ('bbr', 'bbr'),
          ],
        ),
        _Field('insecure_concurrency', 'Insecure concurrency', 'int'),
        _Field('uot', 'UDP over TCP', 'bool'),
      ]),
      _Section('TLS', [
        _Field('tls.server_name', 'Server name', 'text'),
        _Field('tls.certificate', 'Certificate', 'lines'),
        _Field('tls.fragment', 'TLS fragment', 'bool'),
        _Field('tls.ech.enabled', 'ECH', 'bool'),
        _Field(
          'tls.ech.config',
          'ECH config',
          'lines',
          showIf: ('tls.ech.enabled', 'true'),
        ),
      ]),
    ],
    'juicity' => [
      ..._basic(),
      _Section(null, [
        _Field('uuid', 'UUID', 'text', required: true),
        _Field('password', 'Password', 'password'),
      ]),
      _Section('TLS', _tlsBlock(mustTls: true)),
    ],
    'mieru' => [
      ..._basic(),
      _Section(null, [
        _Field('server_ports', 'Server ports', 'lines'),
        _Field(
          'transport',
          'Transport',
          'choice',
          choices: const [('', 'Default'), ('TCP', 'TCP'), ('UDP', 'UDP')],
        ),
        _Field('username', 'Username', 'text'),
        _Field('password', 'Password', 'password'),
        _Field(
          'multiplexing',
          'Multiplexing',
          'choice',
          choices: const [
            ('', 'Default'),
            ('MULTIPLEXING_OFF', 'Off'),
            ('MULTIPLEXING_LOW', 'Low'),
            ('MULTIPLEXING_MIDDLE', 'Middle'),
            ('MULTIPLEXING_HIGH', 'High'),
          ],
        ),
        _Field('traffic_pattern', 'Traffic pattern', 'text'),
      ]),
    ],
    'masque' => [
      ..._basic(),
      _Section(null, [
        _Field('private_key', 'Private key', 'password', required: true),
        _Field('peer_public_key', 'Peer public key', 'text', required: true),
        _Field('address', 'Local addresses', 'list'),
        _Field('mtu', 'MTU', 'int'),
        _Field('http_version', 'HTTP version', 'int'),
        _Field('disable_version_fallback', 'Disable version fallback', 'bool'),
      ]),
    ],
    'ssh' => [
      ..._basic(),
      _Section(null, [
        _Field('user', 'User', 'text'),
        _Field('password', 'Password', 'password'),
        _Field('private_key', 'Private key', 'password'),
        _Field('private_key_passphrase', 'Private key passphrase', 'password'),
        _Field('host_key', 'Host key', 'text'),
        _Field('host_key_algorithms', 'Host key algorithms', 'text'),
        _Field('client_version', 'Client version', 'text'),
      ]),
    ],
    'trusttunnel' => [
      ..._basic(),
      _Section(null, [
        _Field('username', 'Username', 'text'),
        _Field('password', 'Password', 'password'),
        _Field('quic', 'QUIC', 'bool'),
        _Field(
          'congestion_control',
          'Congestion control',
          'choice',
          choices: const [
            ('', 'Default'),
            ('cubic', 'cubic'),
            ('new_reno', 'new_reno'),
            ('bbr', 'bbr'),
          ],
        ),
        _Field('custom_sni', 'Custom SNI', 'text'),
        _Field('client_random', 'Client random', 'text'),
        _Field('health_check', 'Health check', 'bool'),
      ]),
    ],
    'openconnect' => [
      ..._basic(),
      _Section(null, [
        _Field('server_path', 'Server path', 'text'),
        _Field('flavor', 'Flavor', 'text'),
        _Field('username', 'Username', 'text'),
        _Field('password', 'Password', 'password'),
        _Field('auth_group', 'Auth group', 'text'),
        _Field('mtu', 'MTU', 'int'),
      ]),
      _Section('TLS', [
        _Field('tls.server_name', 'Server name', 'text'),
        _Field('tls.insecure', 'Allow insecure', 'bool'),
        _Field('tls.certificate_authority', 'Certificate authority', 'lines'),
        _Field('tls.client_certificate', 'Client certificate', 'lines'),
        _Field('tls.client_key', 'Client key', 'password'),
      ]),
    ],
    'openvpn' => [
      ..._basic(),
      _Section(null, [
        _Field('network', 'Network', 'text'),
        _Field('username', 'Username', 'text'),
        _Field('password', 'Password', 'password'),
        _Field('static_challenge', 'Static challenge', 'text'),
        _Field('mtu', 'MTU', 'int'),
      ]),
      _Section('TLS', [
        _Field('tls.server_name', 'Server name', 'text'),
        _Field('tls.certificate', 'Certificate', 'lines'),
        _Field('tls.client_certificate', 'Client certificate', 'lines'),
        _Field('tls.client_key', 'Client key', 'password'),
      ]),
    ],
    _ => [],
  };

  List<_Section> _basic() => [
    _Section(null, [
      _Field('name', 'Name', 'name'),
      _Field('server', 'Server', 'text', required: true),
      _Field('server_port', 'Server port', 'int', required: true),
    ]),
  ];

  // ------------------------------------------------------------------------------------------------ validation

  ({String path, String message})? get _issue {
    for (final section in _schemas()) {
      for (final field in section.fields) {
        if (field.kind == 'name' || field.kind == 'chain') continue;
        final visible = _visible(field);
        if (!visible) continue;
        if (field.required) {
          final empty = switch (field.kind) {
            'bool' => false,
            'int' => _int(field.path) == 0,
            _ => _text(field.path).trim().isEmpty,
          };
          if (empty) {
            return (
              path: field.path,
              message: '${context.tr(field.label)}: ${context.tr('Required')}',
            );
          }
        }
        if (field.kind == 'int' &&
            (field.path == 'server_port' || field.path == 'settings.port')) {
          final port = _int(field.path);
          if (port < 1 || port > 65535) {
            return (
              path: field.path,
              message: context.tr('Must be a port number'),
            );
          }
        }
      }
    }
    return null;
  }

  bool _visible(_Field field) {
    final showIf = field.showIf;
    if (showIf == null) return true;
    final (path, values) = showIf;
    final current = _get(path)?.toString() ?? '';
    return values.split(',').contains(current);
  }

  void _changed(String _) {
    _dirty = true;
    if (_attempted) setState(() {});
  }

  // ------------------------------------------------------------------------------------------------ save

  Future<void> _save() async {
    if (_saving || _loading) return;
    if (_issue != null) {
      setState(() => _attempted = true);
      return;
    }
    final root = _root;
    if (root == null) return;
    final box = ref.read(boxControllerProvider);
    final draft = widget.draft;
    setState(() => _saving = true);
    try {
      // The must-TLS protocols keep the block on; the synthetic keys never reach storage.
      if (const ['trojan', 'tuic', 'hysteria'].contains(_type)) {
        _set('tls.enabled', true);
      }
      void strip(Json node) {
        for (final key in node.keys.toList()) {
          if (key.startsWith('__')) {
            node.remove(key);
            continue;
          }
          if (node[key] is Json) strip(node[key] as Json);
        }
      }

      strip(root);
      if (draft != null) {
        await box.profileNodeCreate({
          'groupId': draft['groupId'],
          'name': _name.text.trim(),
          'content': convert.jsonEncode(root),
        });
      } else {
        await box.profileNodeUpdate(
          widget.id,
          _name.text.trim(),
          convert.jsonEncode(root),
        );
      }
      if (mounted) context.safeNestedPop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _attempted = true;
          _error = BoxController.describe(error);
        });
      }
    }
  }

  // ------------------------------------------------------------------------------------------------ build

  Widget _fieldRow(_Field field) {
    final invalid = _attempted && _issue?.path == field.path;
    switch (field.kind) {
      case 'name':
        return FormRow(
          title: context.tr(field.label),
          invalid: invalid,
          trailing: FormRowTextField(controller: _name, onChanged: _changed),
        );
      case 'bool':
        return FormRow(
          title: context.tr(field.label),
          onPressed: () {
            _set(field.path, !_bool(field.path));
            _changed('');
          },
          trailing: Switch(
            value: _bool(field.path),
            onChanged: (value) {
              _set(field.path, value);
              _changed('');
            },
          ),
        );
      case 'choice':
        final choices = field.choices ?? const <(String, String)>[];
        final current = _text(field.path);
        // A config can carry a value the form's option list predates (a flow
        // or transport type written by a newer build, for one). Keep it as a
        // selectable current value instead of offering a sheet that can only
        // overwrite it, and show it ellipsized in the row.
        final known = choices.any((choice) => choice.$1 == current);
        final effective = current.isNotEmpty && !known
            ? <(String, String)>[...choices, (current, current)]
            : choices;
        final label = effective
            .firstWhere(
              (choice) => choice.$1 == current,
              orElse: () => (current, current),
            )
            .$2;
        return ListItem(
          title: Text(context.tr(field.label)),
          // Cap the value so an unbreakable token (a long encryption string, a
          // URL) ellipsizes instead of measuring at the whole row and
          // squeezing the label into a vertical column.
          trailing: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * .5,
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.listValueStyle,
            ),
          ),
          onTap: () async {
            final picked = await showOptionSheet<String>(
              context: context,
              title: context.tr(field.label),
              options: effective,
              selected: current,
            );
            if (picked == null || !mounted) return;
            setState(() {
              switch (field.path) {
                case 'tls.utls.fingerprint':
                  _set('tls.utls.fingerprint', picked.isEmpty ? null : picked);
                  _set('tls.utls.enabled', picked.isNotEmpty ? true : null);
                default:
                  _set(field.path, picked.isEmpty ? null : picked);
              }
              _changed('');
            });
          },
        );
      case 'int':
        final controller = _controller(
          field.path,
          text: _int(field.path) > 0 ? '${_int(field.path)}' : '',
        );
        return FormRow(
          title: context.tr(field.label),
          invalid: invalid,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              Flexible(
                child: FormRowTextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (value) {
                    _set(field.path, int.tryParse(value.trim()));
                    _changed(value);
                  },
                ),
              ),
            ],
          ),
        );
      case 'lines':
        final controller = _controller(
          field.path,
          text: _lines(field.path).join('\n'),
        );
        return FormRow(
          title: context.tr(field.label),
          invalid: invalid,
          trailing: FormRowTextField(
            controller: controller,
            hintText: field.hint,
            onChanged: (value) {
              _set(
                field.path,
                value
                    .split('\n')
                    .map((line) => line.trim())
                    .where((line) => line.isNotEmpty)
                    .toList(),
              );
              _changed(value);
            },
          ),
        );
      case 'list':
        final controller = _controller(
          field.path,
          text: _lines(field.path).join(','),
        );
        return FormRow(
          title: context.tr(field.label),
          invalid: invalid,
          trailing: FormRowTextField(
            controller: controller,
            onChanged: (value) {
              _set(
                field.path,
                value
                    .split(',')
                    .map((item) => item.trim())
                    .where((item) => item.isNotEmpty)
                    .toList(),
              );
              _changed(value);
            },
          ),
        );
      case 'chain':
        return ListItem(
          title: Text(context.tr(field.label)),
          subtitle: Text(
            context.tr('Choose proxy hops from the current group'),
          ),
          onTap: () async {
            List<Json> nodes;
            try {
              nodes = await ref.read(boxControllerProvider).groupNodes();
            } catch (error) {
              if (mounted) ref.read(boxControllerProvider).report(error);
              return;
            }
            if (!mounted) return;
            final selected = <int>[
              for (final value in (_get(field.path) as List? ?? const []))
                if (value is num) value.toInt(),
            ];
            // A hop has to be a fixed server: a selector resolves to a different
            // member over time, and ChainBuilder refuses chain-in-chain, so both
            // stay out of the list. The profile being edited is out too.
            final hops = [
              for (final node in nodes)
                if (node['isSelector'] != true &&
                    node['type'] != 'Chain Proxy' &&
                    (node['id'] as num?)?.toInt() != widget.id)
                  node,
            ];
            final picked = await showAppDialog<List<int>>(
              context,
              child: StatefulBuilder(
                builder: (dialogContext, setDialogState) => AlertDialog(
                  title: dialogContext.tr('Proxy chain'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: Text(dialogContext.tr('Cancel')),
                    ),
                    TextButton(
                      onPressed: () =>
                          Navigator.pop(dialogContext, List<int>.of(selected)),
                      child: Text(dialogContext.tr('Save')),
                    ),
                  ],
                  // Prism's own checkbox row, consistent with the app's
                  // ListItem primitives.
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      if (hops.isEmpty)
                        ListItem(title: Text(dialogContext.tr('No results')))
                      else
                        for (final node in hops)
                          ListItem.checkbox(
                            value: selected.contains(
                              (node['id'] as num?)?.toInt(),
                            ),
                            title: Text(node['tag'].toString()),
                            subtitle:
                                selected.contains(
                                  (node['id'] as num?)?.toInt(),
                                )
                                ? Text(
                                    '#${selected.indexOf((node['id'] as num).toInt()) + 1}',
                                  )
                                : null,
                            onChanged: (value) => setDialogState(() {
                              final id = (node['id'] as num).toInt();
                              selected.remove(id);
                              if (value == true) selected.add(id);
                            }),
                          ),
                    ],
                  ),
                ),
              ),
            );
            if (picked == null || !mounted) return;
            setState(() {
              _set(field.path, picked);
              _changed('');
            });
          },
        );
      case 'json':
        // A raw JSON object (the XHTTP xmux block): kept as the object the model parses, the text
        // only updates it when it decodes to one.
        final controller = _controller(field.path, text: _jsonText(field.path));
        return FormRow(
          title: context.tr(field.label),
          invalid: invalid,
          trailing: FormRowTextField(
            controller: controller,
            hintText: field.hint,
            onChanged: (value) {
              final trimmed = value.trim();
              if (trimmed.isEmpty) {
                _set(field.path, null);
              } else {
                try {
                  final decoded = convert.jsonDecode(trimmed);
                  if (decoded is Json) _set(field.path, decoded);
                } on FormatException {
                  // Keep the last decoded object until the text parses.
                }
              }
              _changed(value);
            },
          ),
        );
      case 'headers':
        final map = _get(field.path);
        final text = map is Json
            ? map.entries.map((e) => '${e.key}: ${e.value}').join('\n')
            : '';
        final controller = _controller(field.path, text: text);
        return FormRow(
          title: context.tr(field.label),
          invalid: invalid,
          trailing: FormRowTextField(
            controller: controller,
            onChanged: (value) {
              final headers = <String, dynamic>{};
              for (final line in value.split('\n')) {
                final separator = line.indexOf(':');
                if (separator <= 0) continue;
                headers[line.substring(0, separator).trim()] = line
                    .substring(separator + 1)
                    .trim();
              }
              _set(field.path, headers.isEmpty ? null : headers);
              _changed(value);
            },
          ),
        );
      default:
        final isPassword = field.kind == 'password';
        final controller = _controller(field.path, text: _text(field.path));
        return FormRow(
          title: context.tr(field.label),
          invalid: invalid,
          trailing: FormRowTextField(
            controller: controller,
            hintText: field.hint,
            obscureText: isPassword,
            autocorrect: false,
            enableSuggestions: !isPassword,
            onChanged: (value) {
              _set(field.path, value.trim().isEmpty ? null : value);
              _changed(value);
            },
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        title: context.tr('Edit settings'),
        isLoading: true,
        body: const SizedBox.shrink(),
      );
    }
    if (!_supported) {
      return Scaffold(
        title: context.tr('Edit settings'),
        body: NullStatus(
          label: context.tr('No typed form for this protocol'),
          description: context.tr(
            'Use the node editor to change the configuration text.',
          ),
          illustration: NullStatusIllustration.rules,
        ),
      );
    }
    final issue = _attempted ? _issue : null;
    final schemas = _schemas();
    return BoxEditGuard(
      dirty: _dirty && !_saving,
      busy: _saving,
      child: BoxPage(
      title: _draft ? 'New node' : 'Edit settings',
      confirmationAction: IconButtonData(glyph: AppGlyphs.check, tooltip: context.tr('Save'), isLoading: _saving, onPressed: _saving ? null : _save),
      error: _error ?? issue?.message,
      loading: _saving,
      absorbing: _saving,
      children: [
        for (final section in schemas) ...[
          if (section.fields.any(_visible))
            generateSection(
              title: section.title == null ? null : context.tr(section.title!),
              items: [
                for (final field in section.fields)
                  if (_visible(field)) _fieldRow(field),
              ],
            ),
        ],
      ],
    ),
    );
  }
}

/// One typed field at a sing-box JSON [path]; [showIf] keeps the row for the listed values of
/// another path (comma separated), mirroring the native screens' visibility wiring.
class _Field {
  const _Field(
    this.path,
    this.label,
    this.kind, {
    this.choices,
    this.required = false,
    this.hint,
    this.showIf,
  });
  final String path;
  final String label;
  final String kind;
  final List<(String, String)>? choices;
  final bool required;
  final String? hint;
  final (String, String)? showIf;
}

class _Section {
  const _Section(this.title, this.fields);
  final String? title;
  final List<_Field> fields;
}
