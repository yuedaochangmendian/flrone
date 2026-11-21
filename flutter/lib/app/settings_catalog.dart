import '../common/log_level.dart';

enum SettingKind { toggle, text, integer, options, lines }

class SettingEntry {
  const SettingEntry.toggle(
    this.key,
    this.label, {
    this.restart = false,
    this.autoRestart = false,
  }) : kind = SettingKind.toggle,
       options = const [],
       validator = null;

  const SettingEntry.text(
    this.key,
    this.label, {
    this.restart = true,
    this.autoRestart = false,
  }) : kind = SettingKind.text,
       options = const [],
       validator = null;

  const SettingEntry.integer(
    this.key,
    this.label, {
    this.restart = true,
    this.autoRestart = false,
  }) : kind = SettingKind.integer,
       options = const [],
       validator = null;

  const SettingEntry.options(
    this.key,
    this.label,
    this.options, {
    this.restart = true,
    this.autoRestart = false,
  }) : kind = SettingKind.options,
       validator = null;

  const SettingEntry.lines(
    this.key,
    this.label, {
    this.restart = true,
    this.autoRestart = false,
  }) : kind = SettingKind.lines,
       options = const [],
       validator = null;

  final String key;
  final String label;
  final SettingKind kind;
  final bool restart;
  final bool autoRestart;
  final List<(String, String)> options;
  final String? Function(String value)? validator;
}

class SettingsSection {
  const SettingsSection({
    required this.title,
    required this.entries,
    this.note,
  });

  final String title;
  final String? note;
  final List<SettingEntry> entries;
}

final settingsSections = <SettingsSection>[
  SettingsSection(
    title: 'General',
    note: 'Changes marked reload apply on the next core reload.',
    entries: [
      SettingEntry.options('serviceMode', 'Service mode', [
        ('vpn', 'VPN'),
        ('proxy', 'Proxy only'),
      ], restart: true),
      SettingEntry.toggle('rememberEnable', 'Connect after reboot'),
      SettingEntry.toggle('hideFromRecentApps', 'Hide from recent apps'),
      SettingEntry.toggle(
        'meteredNetwork',
        'Treat the VPN as metered',
        restart: true,
        autoRestart: true,
      ),
      SettingEntry.toggle(
        'networkChangeResetConnections',
        'Reset connections on network change',
      ),
      SettingEntry.toggle('wakeResetConnections', 'Reset connections on wake'),
      SettingEntry.toggle('skipDeleteConfirmation', 'Skip delete confirmation'),
      SettingEntry.toggle('updateCheckAuto', 'Check for updates automatically'),
      SettingEntry.toggle('allowBetaUpdate', 'Allow preview updates'),
      SettingEntry.toggle('startWithoutRuleSets', 'Start without rule sets'),
      SettingEntry.toggle(
        'allowStoppingActiveProfile',
        'Allow stopping the active profile',
      ),
      SettingEntry.toggle('batteryExempt', 'Battery optimization exempt'),
    ],
  ),
  SettingsSection(
    title: 'Inbound',
    entries: [
      SettingEntry.integer('inboundSocksPort', 'SOCKS port'),
      SettingEntry.toggle(
        'disableMixedInbound',
        'Disable mixed inbound',
        restart: true,
        autoRestart: true,
      ),
      SettingEntry.toggle('randomInboundPort', 'Random inbound port'),
      SettingEntry.toggle(
        'inboundAuth',
        'Authentication',
        restart: true,
        autoRestart: true,
      ),
      SettingEntry.text('inboundUser', 'Username'),
      SettingEntry.text('inboundPass', 'Password'),
      SettingEntry.integer('coreDnsInPort', 'DNS inbound port'),
      SettingEntry.toggle(
        'allowLan',
        'Allow LAN access',
        restart: true,
        autoRestart: true,
      ),
      SettingEntry.toggle(
        'appendHttpProxy',
        'Append HTTP proxy',
        restart: true,
        autoRestart: true,
      ),
      SettingEntry.lines('httpProxyBypass', 'HTTP proxy bypass'),
      SettingEntry.text('customInbound', 'Custom inbound JSON'),
    ],
  ),
  SettingsSection(
    title: 'TUN',
    entries: [
      SettingEntry.integer('vpnMtu', 'MTU'),
      SettingEntry.toggle('vpnIpv6', 'IPv6', restart: true, autoRestart: true),
      SettingEntry.text('vpnTunIpv4Cidr', 'IPv4 CIDR'),
      SettingEntry.text('vpnTunIpv6Cidr', 'IPv6 CIDR'),
      SettingEntry.toggle('enableTunRouting', 'TUN routing'),
      SettingEntry.lines('vpnPrivateRanges', 'Private ranges'),
      SettingEntry.toggle(
        'vpnAllowBypass',
        'Allow app bypass',
        restart: true,
        autoRestart: true,
      ),
    ],
  ),
  SettingsSection(
    title: 'DNS',
    note: 'The DNS object replaces the structured servers while enabled.',
    entries: [
      SettingEntry.text('remoteDns', 'Remote DNS'),
      SettingEntry.toggle('remoteDnsDisableIpv6', 'Remote DNS: disable IPv6'),
      SettingEntry.text('directDns', 'Direct DNS'),
      SettingEntry.toggle('directDnsDisableIpv6', 'Direct DNS: disable IPv6'),
      SettingEntry.text('dnsFinalOut', 'Final outbound'),
      SettingEntry.toggle('enableDnsRouting', 'DNS routing'),
      SettingEntry.toggle(
        'fakeDns',
        'Fake DNS',
        restart: true,
        autoRestart: true,
      ),
      SettingEntry.toggle('fakeipDisableIpv6', 'Fake IP: disable IPv6'),
      SettingEntry.toggle('dnsUseHosts', 'Use hosts'),
      SettingEntry.toggle('dnsPredefinedEnable', 'Predefined entries'),
      SettingEntry.lines('dnsPredefinedRules', 'Predefined host entries'),
      SettingEntry.toggle('dnsPersistCache', 'Persist cache'),
      SettingEntry.toggle('dnsReverseMapping', 'Reverse mapping'),
      SettingEntry.toggle('useDnsObject', 'Use DNS object'),
      SettingEntry.text('dnsObject', 'DNS object JSON'),
      SettingEntry.text('coreBoxUnderlyingDns', 'Underlying DNS'),
      SettingEntry.text('dnsQueryTimeout', 'Query timeout'),
      SettingEntry.toggle('dnsOptimistic', 'Optimistic cache'),
      SettingEntry.text('dnsOptimisticTimeout', 'Optimistic timeout'),
      SettingEntry.toggle('dnsDisableCache', 'Disable cache'),
      SettingEntry.toggle('dnsDisableExpire', 'Disable expiry'),
      SettingEntry.integer('dnsCacheCapacity', 'Cache capacity'),
    ],
  ),
  SettingsSection(
    title: 'Core',
    entries: [
      SettingEntry.options('logLevel', 'Log level', [
        for (final level in coreLogLevels) (level, level),
      ]),
      SettingEntry.toggle(
        'enableStats',
        'Enable statistics',
        restart: true,
        autoRestart: true,
      ),
      SettingEntry.toggle(
        'disableTrafficStats',
        'Disable traffic statistics',
        restart: true,
        autoRestart: true,
      ),
      SettingEntry.integer('logBufSize', 'Log buffer size', restart: false),
      SettingEntry.toggle('skipCert', 'Skip certificate verification'),
      SettingEntry.toggle('enableNtp', 'NTP', restart: true, autoRestart: true),
      SettingEntry.text('ntpServerAddress', 'NTP server'),
      SettingEntry.integer('ntpServerPort', 'NTP port'),
      SettingEntry.text('ntpInterval', 'NTP interval'),
      SettingEntry.text('ntpOutbound', 'NTP outbound'),
      SettingEntry.text('xrayLogLevel', 'Xray log level'),
      SettingEntry.toggle('useMozillaCerts', 'Use Mozilla certificates'),
      SettingEntry.toggle('xrayUseSystemCa', 'Xray: use system CA'),
      SettingEntry.text('boxApiSecret', 'Box API secret'),
      SettingEntry.toggle('clashApiEnabled', 'Clash API'),
      SettingEntry.integer('clashApiPort', 'Clash API port'),
      SettingEntry.text('clashApiListenAddr', 'Clash API listen address'),
      SettingEntry.text('clashApiSecret', 'Clash API secret'),
      SettingEntry.toggle('boxApiEnabled', 'Box API'),
      SettingEntry.integer('boxApiPort', 'Box API port'),
      SettingEntry.toggle('netInsecure', 'Allow insecure connections'),
      SettingEntry.toggle('netUseProxy', 'Use a proxy for updates'),
      SettingEntry.toggle('fragmentDefaultOn', 'TLS fragment by default'),
      SettingEntry.text('fragmentImplementation', 'Fragment implementation'),
      SettingEntry.text('fragmentSize', 'Fragment size'),
      SettingEntry.text('fragmentSleep', 'Fragment sleep'),
      SettingEntry.toggle('tlsTricksDefaultOn', 'TLS tricks by default'),
      SettingEntry.text('utlsFingerprint', 'uTLS fingerprint'),
      SettingEntry.text('userAgent', 'User agent'),
      SettingEntry.integer(
        'h2ConnectionReceiveWindow',
        'HTTP/2 connection receive window',
      ),
      SettingEntry.integer('h2IdleTimeout', 'HTTP/2 idle timeout'),
      SettingEntry.integer('h2KeepAlivePeriod', 'HTTP/2 keep-alive period'),
      SettingEntry.integer(
        'h2MaxConcurrentStreams',
        'HTTP/2 max concurrent streams',
      ),
      SettingEntry.integer(
        'h2StreamReceiveWindow',
        'HTTP/2 stream receive window',
      ),
      SettingEntry.toggle(
        'quicDisablePathMtuDiscovery',
        'QUIC: disable path MTU discovery',
      ),
      SettingEntry.integer('quicInitialPacketSize', 'QUIC initial packet size'),
      SettingEntry.integer('xrayMuxConcurrency', 'Xray mux concurrency'),
      SettingEntry.toggle('xrayMuxDefaultOn', 'Xray mux by default'),
      SettingEntry.integer('xrayMuxMaxConnections', 'Xray mux max connections'),
      SettingEntry.integer('xrayMuxXudpConcurrency', 'Xray XUDP concurrency'),
      SettingEntry.text('xrayMuxXudpProxyUdp443', 'Xray XUDP proxy UDP/443'),
      SettingEntry.toggle('muxDefaultOn', 'Mux by default'),
      SettingEntry.integer('muxBrutalUpMbps', 'Mux brutal upload Mbps'),
      SettingEntry.integer('muxBrutalDownMbps', 'Mux brutal download Mbps'),
    ],
  ),
  SettingsSection(
    title: 'Notification',
    entries: [
      SettingEntry.toggle('showProxySpeed', 'Show proxy speed'),
      SettingEntry.toggle('showDirectSpeed', 'Show direct speed'),
      SettingEntry.toggle('showGroupInNotification', 'Show group name'),
      SettingEntry.toggle('showTrafficTotal', 'Show traffic total'),
      SettingEntry.text('notificationTitleTemplate', 'Title template'),
      SettingEntry.text('notificationContentTemplate', 'Content template'),
      SettingEntry.lines('notificationActions', 'Notification actions'),
    ],
  ),
  SettingsSection(
    title: 'WARP',
    entries: [
      SettingEntry.toggle('enableWarp', 'Enable WARP'),
      SettingEntry.text('warpMode', 'WARP mode'),
      SettingEntry.text('warpEndpoint', 'WireGuard endpoint'),
      SettingEntry.text('warpPrivateKey', 'WireGuard private key'),
      SettingEntry.text('warpPublicKey', 'WireGuard public key'),
      SettingEntry.lines('warpIfcAddrs', 'Interface addresses'),
      SettingEntry.lines('warpReserved', 'Reserved bytes'),
      SettingEntry.text('warpMasqueEndpoint', 'MASQUE endpoint'),
      SettingEntry.text('warpMasquePrivateKey', 'MASQUE private key'),
      SettingEntry.text('warpMasquePeerPublicKey', 'MASQUE peer public key'),
      SettingEntry.text('warpMasqueSni', 'MASQUE SNI'),
      SettingEntry.integer('warpMasqueHttpMode', 'MASQUE HTTP mode'),
      SettingEntry.lines('warpApiHosts', 'WARP API hosts'),
    ],
  ),
  SettingsSection(
    title: 'Testing',
    entries: [
      SettingEntry.text('testUrl', 'Latency test URL', restart: false),
      SettingEntry.integer(
        'urlTestTimeoutMs',
        'Latency timeout (ms)',
        restart: false,
      ),
      SettingEntry.integer(
        'testConcurrent',
        'Concurrent tests',
        restart: false,
      ),
      SettingEntry.text('directTestUrl', 'Direct test URL', restart: false),
      SettingEntry.toggle(
        'exitCountryLookup',
        'Look up exit country',
        restart: false,
      ),
      SettingEntry.text(
        'exitLookupProvider',
        'Exit lookup provider',
        restart: false,
      ),
      SettingEntry.integer('speedTestMode', 'Speed test mode', restart: false),
      SettingEntry.integer(
        'speedTestTimeoutMs',
        'Speed test timeout (ms)',
        restart: false,
      ),
      SettingEntry.text('simpleDlUrl', 'Simple download URL', restart: false),
    ],
  ),
  SettingsSection(
    title: 'Routing',
    entries: [
      SettingEntry.toggle('adblockEnable', 'Ad blocking'),
      SettingEntry.toggle('allowBypass', 'Allow app bypass'),
      SettingEntry.text('domainStrategy', 'Domain strategy'),
      SettingEntry.text('outboundDomainStrategy', 'Outbound domain strategy'),
      SettingEntry.integer('rulesetMirror', 'Rule-set mirror'),
      SettingEntry.toggle(
        'routeAutoUpdateEnabled',
        'Auto-update route profiles',
      ),
      SettingEntry.integer(
        'routeAutoUpdateMinutes',
        'Route update interval (minutes)',
      ),
    ],
  ),
  SettingsSection(
    title: 'Subscriptions',
    entries: [
      SettingEntry.toggle('subAutoUpdateEnabled', 'Auto-update subscriptions'),
      SettingEntry.integer(
        'subAutoUpdateMinutes',
        'Subscription update interval (minutes)',
      ),
      SettingEntry.toggle('subClear', 'Clear unavailable nodes after update'),
      SettingEntry.text('subCustomHwidParams', 'Custom HWID parameters'),
      SettingEntry.text('subHttpVersion', 'Subscription HTTP version'),
      SettingEntry.toggle(
        'subRespectServerInterval',
        'Respect server update interval',
      ),
      SettingEntry.toggle('subSendHwid', 'Send HWID'),
      SettingEntry.toggle(
        'subShowChangePopup',
        'Show subscription change report',
      ),
      SettingEntry.text('subTlsVersion', 'Subscription TLS version'),
    ],
  ),
  SettingsSection(
    title: 'Node presets',
    note: 'Applied to nodes created by the importer.',
    entries: [
      SettingEntry.text('muxProtocol', 'Mux protocol', restart: false),
      SettingEntry.text('muxMode', 'Mux mode', restart: false),
      SettingEntry.integer('muxConcurrency', 'Mux concurrency', restart: false),
      SettingEntry.integer(
        'muxMaxConnections',
        'Mux max connections',
        restart: false,
      ),
      SettingEntry.integer('muxMinStreams', 'Mux min streams', restart: false),
      SettingEntry.toggle('muxPadding', 'Mux padding', restart: false),
      SettingEntry.toggle('muxBrutal', 'Mux brutal', restart: false),
    ],
  ),
];
