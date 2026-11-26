import '../widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

// The Throne settings pages. The controls they build with live in
// components/settings_controls.dart.

// --------------------------------------------------------------------------------------------- inbound

/// The configuration surfaces behind one row on the settings list: set once,
/// rarely revisited, and noisy enough beside the common entries that they made
/// the list harder to scan.
class AdvancedSettingsPage extends StatelessWidget {
  const AdvancedSettingsPage({super.key});
  @override
  Widget build(BuildContext context) {
    return BoxPage(title: 'Advanced settings', children: [
      generateSection(items: [
        ListItem.open(leading: const GlyphIcon(AppGlyphs.devices), title: Text(context.tr('Inbound')), widget: const InboundPage()),
        ListItem.open(leading: const GlyphIcon(AppGlyphs.sliders), title: Text(context.tr('Node presets')), widget: const PresetsPage()),
        ListItem.open(leading: const GlyphIcon(AppGlyphs.profiles), title: Text(context.tr('Subscriptions')), widget: const SubscriptionPage()),
      ], footer: context.tr('Inbound ports, the node templates new nodes are built from, and the subscription profiles.')),
    ]);
  }
}

class InboundPage extends ConsumerWidget {
  const InboundPage({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) {
    // The capability manifest only knows the API level; whether the system proxy can be
    // written also depends on the service mode, which the dashboard tracks live.
    final box = ref.watchBoxState();
    final vpnMode = box.settings['serviceMode'] != 'proxy';
    return BoxPage(title: 'Inbound', actions: [
      restoreDefaultsAction(context, const [
        'inboundSocksPort', 'randomInboundPort', 'allowLan', 'coreDnsInPort', 'disableMixedInbound',
        'inboundAuth', 'inboundUser', 'inboundPass', 'appendHttpProxy', 'httpProxyBypass', 'customInbound',
      ]),
    ], children: [
      generateSection(items: [
        SettingNumber('Mixed port', 'inboundSocksPort', min: 1, max: 65535, autoRestart: true),
        SettingToggle('Random inbound port', 'randomInboundPort'),
        SettingToggle('Allow LAN access', 'allowLan', autoRestart: true),
        SettingNumber('DNS inbound port', 'coreDnsInPort', min: 1, max: 65535, autoRestart: true),
        SettingToggle('Disable the mixed inbound', 'disableMixedInbound', autoRestart: true),
      ], footer: context.tr('These four listeners must use different ports.')),
      generateSection(title: context.tr('Inbound authentication'), items: [
        SettingToggle('Enable authentication', 'inboundAuth', autoRestart: true),
        SettingText('Username', 'inboundUser'),
        SettingText('Password', 'inboundPass'),
      ], footer: vpnMode ? null : context.tr('Proxy-only service mode always keeps the mixed inbound.')),
      if (box.dashboard['systemProxyAvailable'] == true) generateSection(title: context.tr('System proxy'), items: [
        SettingToggle('Append the HTTP proxy', 'appendHttpProxy', autoRestart: true),
        SettingLines('Proxy bypass', 'httpProxyBypass',
          hint: 'One host or CIDR per line. Empty means the proxy is applied to every connection.'),
      ]),
      generateSection(title: context.tr('Custom inbound'), items: [
        SettingJson('Inbound JSON', 'customInbound',
          hint: 'A JSON object with an "inbounds" array, merged into the generated configuration'),
      ], footer: context.tr('The listeners above are generated; these inbounds are added as they are written.')),
    ]);
  }
}

// ------------------------------------------------------------------------------------------------- tun

class TunPage extends ConsumerWidget {
  const TunPage({super.key});
  // The conditional "Private ranges" row must rebuild when the toggle flips;
  // `ref.read` left it stale until the page was reopened.
  @override Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watchBoxState();
    return BoxPage(title: 'TUN', actions: [
    restoreDefaultsAction(context, const [
      'vpnMtu', 'vpnIpv6', 'vpnTunIpv4Cidr', 'vpnTunIpv6Cidr', 'allowBypass', 'vpnPrivateRanges', 'enableTunRouting', 'vpnAllowBypass',
    ]),
  ], children: [
    generateSection(items: [
      SettingNumber('MTU', 'vpnMtu', min: 1000, max: 10000, autoRestart: true),
      SettingToggle('TUN IPv6', 'vpnIpv6', autoRestart: true),
      SettingText('TUN IPv4 address', 'vpnTunIpv4Cidr'),
      SettingText('TUN IPv6 address', 'vpnTunIpv6Cidr'),
    ]),
    generateSection(title: context.tr('Routing'), items: [
      SettingToggle('Bypass private ranges', 'allowBypass', autoRestart: true),
      if (box.settings['allowBypass'] == true)
        SettingLines('Private ranges', 'vpnPrivateRanges',
          hint: 'One CIDR per line. These are reached directly instead of through the tunnel.'),
      SettingToggle('Route through TUN', 'enableTunRouting'),
      SettingToggle('Allow VPN bypass', 'vpnAllowBypass', autoRestart: true),
    ]),
  ]);
  }
}

// ------------------------------------------------------------------------------------------------- dns

const dnsFinalOuts = ['remote', 'direct'];

class DnsPage extends ConsumerWidget {
  const DnsPage({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watchBoxState();
    // The DNS object replaces every structured setting on this page while it is on, the way the
    // native DNS screen disables its own categories; the toggle itself stays reachable either way.
    final useObject = box.settings['useDnsObject'] == true;
    return BoxPage(title: 'DNS', actions: [
      restoreDefaultsAction(context, const [
        'remoteDns', 'remoteDnsDisableIpv6', 'directDns', 'directDnsDisableIpv6', 'dnsFinalOut',
        'enableDnsRouting', 'fakeDns', 'fakeipDisableIpv6', 'dnsUseHosts', 'dnsPredefinedEnable',
        'dnsPredefinedRules', 'coreBoxUnderlyingDns', 'dnsReverseMapping', 'dnsDisableCache',
        'dnsDisableExpire', 'dnsCacheCapacity', 'dnsPersistCache', 'dnsOptimistic', 'dnsOptimisticTimeout',
        'dnsQueryTimeout', 'useDnsObject', 'dnsObject',
      ]),
    ], children: [
      generateSection(items: [
        SettingToggle('Use the DNS object', 'useDnsObject', autoRestart: true),
      ], footer: useObject ? context.tr('The structured settings are ignored while the DNS object is in use.') : null),
      if (useObject)
        SettingJson('DNS object', 'dnsObject',
          hint: 'The sing-box DNS object as JSON; it replaces every structured setting on this page')
      else ...[
        generateSection(title: context.tr('Remote DNS'), items: [
          SettingDnsServer('Remote DNS', 'remoteDns', hint: 'https://1.1.1.1/dns-query', kind: 'remote'),
          SettingToggle('Disable IPv6 answers', 'remoteDnsDisableIpv6'),
        ]),
        generateSection(title: context.tr('Direct DNS'), items: [
          SettingDnsServer('Direct DNS', 'directDns', kind: 'direct'),
          SettingToggle('Disable IPv6 answers', 'directDnsDisableIpv6'),
        ]),
        generateSection(items: [
          SettingChoice<String>('Default DNS server', 'dnsFinalOut', options: dnsFinalOuts, text: (value) => value == 'remote' ? 'Remote DNS' : 'Direct DNS'),
          SettingToggle('DNS routing', 'enableDnsRouting'),
          SettingToggle('FakeDNS', 'fakeDns', autoRestart: true),
          SettingToggle('Disable IPv6 for FakeIP', 'fakeipDisableIpv6'),
          SettingToggle('Use system hosts', 'dnsUseHosts'),
          SettingToggle('Predefined hosts', 'dnsPredefinedEnable'),
          if (box.settings['dnsPredefinedEnable'] == true)
            SettingLines('Predefined hosts entries', 'dnsPredefinedRules',
              hint: 'One entry per line, in hosts format: "address hostname".'),
          SettingText('Underlying DNS', 'coreBoxUnderlyingDns', hint: 'empty means the system resolver'),
          SettingToggle('Reverse mapping', 'dnsReverseMapping'),
        ]),
        generateSection(title: context.tr('Cache'), items: [
          SettingToggle('Disable DNS cache', 'dnsDisableCache'),
          SettingToggle('Disable cache expiration', 'dnsDisableExpire'),
          SettingNumber('Cache capacity', 'dnsCacheCapacity', min: 0),
          SettingToggle('Persist the cache', 'dnsPersistCache'),
          SettingToggle('Optimistic cache', 'dnsOptimistic'),
          if (box.settings['dnsOptimistic'] == true)
            SettingText('Optimistic cache timeout', 'dnsOptimisticTimeout', hint: 'e.g. 3m'),
          SettingText('Query timeout', 'dnsQueryTimeout', hint: 'e.g. 5s, empty to use the core default'),
        ]),
      ],
    ]);
  }
}

// --------------------------------------------------------------------------------------------- routing
//
// The routing screens live in pages/route_fragment_page.dart and the editor
// pages beside it; this file keeps the non-route settings surfaces.

// ------------------------------------------------------------------------------------------------ core

const ntpOutbounds = ['direct', 'proxy'];

class CorePage extends ConsumerWidget {
  const CorePage({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watchBoxState();
    final clashApi = box.settings['clashApiEnabled'] == true;
    final boxApi = box.settings['boxApiEnabled'] == true;
    return BoxPage(title: 'Core', actions: [
      restoreDefaultsAction(context, const [
        'skipCert',
        'useMozillaCerts', 'clashApiEnabled', 'clashApiPort',
        'clashApiListenAddr', 'clashApiSecret', 'boxApiEnabled', 'boxApiPort', 'boxApiSecret',
        'enableNtp', 'ntpServerAddress', 'ntpServerPort', 'ntpInterval', 'ntpOutbound',
      ]),
    ], children: [
      // The log level and the log buffer are not settings here any more: the log screen's
      // recording-level control owns the level, and the buffer keeps the host default. The
      // categories and their order are otherwise Throne's settings_core.
      generateSection(title: context.tr('Version'), items: [
        ListItem(title: Text(context.tr('Core version')),
          subtitle: Text([box.coreVersion, box.coreRefShort].where((part) => part.isNotEmpty).join(' · '))),
      ]),
      generateSection(title: context.tr('Clash API'), items: [
        SettingToggle('Enable Clash API', 'clashApiEnabled', autoRestart: true),
        if (clashApi) ...[
          SettingNumber('Port', 'clashApiPort', min: 1, max: 65535, autoRestart: true),
          SettingText('Listen address', 'clashApiListenAddr'),
          // The host generates and persists a secret when this is cleared while the API is on
          // (ControllerSecret: an open controller always has one). The save answers with the whole
          // settings wire, so the generated value appears here without a second read.
          SettingText('Secret', 'clashApiSecret', hint: 'Generated when empty'),
        ],
      ]),
      generateSection(title: context.tr('API dashboard'), items: [
        SettingToggle('Enable core API', 'boxApiEnabled', autoRestart: true),
        if (boxApi) ...[
          SettingNumber('Port', 'boxApiPort', min: 1, max: 65535, autoRestart: true),
          SettingText('Secret', 'boxApiSecret'),
        ],
      ]),
      generateSection(title: context.tr('Security'), items: [
        SettingToggle('Skip certificate verification', 'skipCert'),
        SettingToggle('Use the Mozilla root store', 'useMozillaCerts'),
      ]),
      generateSection(title: context.tr('NTP'), items: [
        SettingToggle('Enable NTP', 'enableNtp', autoRestart: true),
        SettingText('NTP server', 'ntpServerAddress'),
        SettingNumber('NTP port', 'ntpServerPort', min: 0, max: 65535),
        SettingText('NTP interval', 'ntpInterval', hint: 'e.g. 30m, empty to use the core default'),
        SettingChoice<String>('NTP outbound', 'ntpOutbound', options: ntpOutbounds, text: (value) => value),
      ]),
    ]);
  }
}

// ---------------------------------------------------------------------------------------------- testing
//
// The testing parameters (and the node/speed/traffic/exit controls behind them) are the network
// toolbox now (pages/network_toolbox.dart). The speed-test modes stay here because the test panel
// reaches them through widgets.dart.

const speedTestModes = [0, 1, 2, 3, 4];

String speedTestModeName(int value) => switch (value) {
  1 => 'Download', 2 => 'Upload', 3 => 'Simple download', 4 => 'Country', _ => 'Download and upload',
};

// ------------------------------------------------------------------------------------------ node presets

const muxProtocols = ['h2mux', 'smux', 'yamux'];
const muxModes = ['max_streams', 'max_connections'];
const fragmentImplementations = ['built-in', 'custom'];
const utlsFingerprints = [
  '', 'chrome', 'firefox', 'edge', 'safari', '360', 'qq', 'ios', 'android',
  'random', 'randomized', 'unsafe',
];

/// The defaults the importer stamps on the nodes it builds — Mux, fragment, TLS tricks,
/// HTTP/2 tuning and the QUIC dialer. A running configuration is never rebuilt from these;
/// they apply to the next import or creation, exactly as the native preset screen does.
class PresetsPage extends ConsumerWidget {
  const PresetsPage({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watchBoxState();
    final settings = box.settings;
    final brutal = settings['muxBrutal'] == true;
    final muxMode = settings['muxMode']?.toString() ?? 'max_streams';
    final brutalReady = (settings['muxBrutalUpMbps'] as num? ?? 0) > 0 &&
        (settings['muxBrutalDownMbps'] as num? ?? 0) > 0;
    final fragmentCustom = settings['fragmentImplementation'] == 'custom';
    final fingerprint = settings['utlsFingerprint']?.toString() ?? '';
    final fingerprints = utlsFingerprints.contains(fingerprint)
        ? utlsFingerprints
        : [fingerprint, ...utlsFingerprints];
    return BoxPage(title: 'Node presets', actions: [
      restoreDefaultsAction(context, const [
        'muxProtocol', 'muxMode', 'muxConcurrency', 'muxMaxConnections', 'muxMinStreams', 'muxPadding',
        'muxBrutal', 'muxBrutalUpMbps', 'muxBrutalDownMbps', 'muxDefaultOn',
        'fragmentDefaultOn', 'fragmentImplementation', 'fragmentSize', 'fragmentSleep', 'tlsTricksDefaultOn',
        'utlsFingerprint', 'h2IdleTimeout', 'h2KeepAlivePeriod',
        'h2StreamReceiveWindow', 'h2ConnectionReceiveWindow', 'h2MaxConcurrentStreams',
        'quicInitialPacketSize', 'quicDisablePathMtuDiscovery',
      ]),
    ], children: [
      generateSection(title: context.tr('Mux'), items: [
        SettingChoice<String>('Mux protocol', 'muxProtocol', options: muxProtocols, text: (value) => value),
        SettingChoice<String>('Mux mode', 'muxMode', options: muxModes, text: _muxModeName, enabled: !brutal),
        if (muxMode == 'max_connections')
          SettingNumber('Mux max connections', 'muxMaxConnections', min: 1, enabled: !brutal)
        else
          SettingNumber('Mux concurrency', 'muxConcurrency', min: 1, enabled: !brutal),
        if (muxMode == 'max_connections')
          SettingNumber('Mux min streams', 'muxMinStreams', min: 0, enabled: !brutal),
        SettingToggle('Mux padding', 'muxPadding'),
        SettingToggle('Brutal congestion', 'muxBrutal', enabled: brutal || brutalReady),
        SettingNumber('Brutal upload', 'muxBrutalUpMbps', min: 0, unit: 'Mbps'),
        SettingNumber('Brutal download', 'muxBrutalDownMbps', min: 0, unit: 'Mbps'),
        SettingToggle('Enable Mux by default', 'muxDefaultOn'),
      ], footer: context.tr('Applied when a node is imported, not to nodes already saved.')),
      generateSection(title: context.tr('Fragment'), items: [
        SettingChoice<String>('Fragment implementation', 'fragmentImplementation',
          options: fragmentImplementations, text: _fragmentImplementationName),
        SettingText('Fragment size', 'fragmentSize', enabled: fragmentCustom,
          hint: 'custom only: e.g. 10-100, empty uses the built-in range'),
        SettingText('Fragment sleep', 'fragmentSleep', enabled: fragmentCustom,
          hint: 'custom only: e.g. 2-5, empty uses the built-in range'),
        SettingToggle('Fragment by default', 'fragmentDefaultOn'),
      ]),
      generateSection(title: context.tr('TLS tricks'), items: [
        SettingToggle('TLS tricks by default', 'tlsTricksDefaultOn'),
      ]),
      generateSection(title: context.tr('uTLS'), items: [
        SettingChoice<String>('uTLS fingerprint', 'utlsFingerprint', options: fingerprints, text: _utlsFingerprintName),
      ]),
      generateSection(title: context.tr('HTTP/2 and QUIC'), items: [
        SettingText('Idle timeout', 'h2IdleTimeout', hint: 'e.g. 5m, empty to use the core default'),
        SettingText('Keep-alive period', 'h2KeepAlivePeriod', hint: 'e.g. 30s, empty to use the core default'),
        SettingText('Stream receive window', 'h2StreamReceiveWindow'),
        SettingText('Connection receive window', 'h2ConnectionReceiveWindow'),
        SettingNumber('Max concurrent streams', 'h2MaxConcurrentStreams', min: 0),
        SettingNumber('Initial packet size', 'quicInitialPacketSize', min: 0, unit: 'B'),
        SettingToggle('Disable path MTU discovery', 'quicDisablePathMtuDiscovery'),
      ], footer: context.tr('Used by Hysteria, Hysteria2, TUIC and MASQUE profiles that leave a field empty. Empty keeps the core default.')),
    ]);
  }
}

String _muxModeName(String value) => value == 'max_connections' ? 'Max connections' : 'Max streams';

String _fragmentImplementationName(String value) =>
    value == 'custom' ? 'Custom (dialer)' : 'Built-in (sing-box)';

String _utlsFingerprintName(String value) => value.isEmpty ? 'Default' : value;

// ---------------------------------------------------------------------------------------- subscriptions

const subscriptionTlsVersions = [0, 1, 2];
const subscriptionHttpVersions = [0, 1];

class SubscriptionPage extends ConsumerWidget {
  const SubscriptionPage({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watchBoxState();
    final autoUpdate = box.settings['subAutoUpdateEnabled'] == true;
    return BoxPage(title: 'Subscriptions', actions: [
      restoreDefaultsAction(context, const [
        'userAgent', 'netUseProxy', 'netInsecure', 'subTlsVersion', 'subHttpVersion', 'subSendHwid',
        'subCustomHwidParams', 'subAutoUpdateEnabled', 'subAutoUpdateMinutes', 'subRespectServerInterval',
        'subClear', 'subShowChangePopup', 'allowStoppingActiveProfile',
      ]),
    ], children: [
      generateSection(title: context.tr('Request'), items: [
        SettingText('User agent', 'userAgent', hint: 'empty means the built-in user agent'),
        SettingToggle('Fetch through the proxy', 'netUseProxy'),
        SettingToggle('Allow insecure TLS', 'netInsecure'),
        SettingChoice<int>('TLS version', 'subTlsVersion', options: subscriptionTlsVersions, text: _tlsVersionName),
        SettingChoice<int>('HTTP version', 'subHttpVersion', options: subscriptionHttpVersions, text: _httpVersionName),
        SettingToggle('Send device identifier', 'subSendHwid'),
        if (box.settings['subSendHwid'] == true)
          SettingText('Custom HWID parameters', 'subCustomHwidParams',
            hint: 'key=value pairs separated by commas, sent alongside the identifier'),
      ]),
      generateSection(title: context.tr('Automatic updates'), items: [
        SettingToggle('Update subscriptions', 'subAutoUpdateEnabled'),
        if (autoUpdate) SettingNumber('Update interval', 'subAutoUpdateMinutes', min: 30, unit: 'min'),
        SettingToggle('Respect the server interval', 'subRespectServerInterval'),
      ]),
      generateSection(title: context.tr('Updating'), items: [
        SettingToggle('Clear on failure', 'subClear'),
        SettingToggle('Show the change report', 'subShowChangePopup'),
        SettingToggle('Allow stopping the running profile', 'allowStoppingActiveProfile'),
      ]),
    ]);
  }
}

String _tlsVersionName(int value) => switch (value) { 1 => 'TLS 1.2', 2 => 'TLS 1.3', _ => 'Automatic' };
String _httpVersionName(int value) => switch (value) { 1 => 'HTTP/1.1', _ => 'Automatic' };

// Update settings moved to the About page (pages/about.dart), beside the
// version badge; there is no longer a separate Updates settings page.
