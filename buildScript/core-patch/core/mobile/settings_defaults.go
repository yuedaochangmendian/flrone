// SettingsRegistry's default and decoding table, ported for the settings a
// simple config build reads (log / certificate / mixed / TUN / DNS / route /
// API / cache).
//
// Kotlin owns the settings document (ADR 0006 stage C2): SettingsJsonStore
// stores every row as desktop-encoded text, and SettingsRegistry.Setting.read()
// decodes the row, falling back to the registered default when the row is
// missing or the stored value fails its validator. This file mirrors that
// contract for the subset the Go config input layer consumes. Keys outside the
// table are never read here; a future builder that needs one must add its
// definition and its default here first.
//
// Deliberately not covered by the config-build subset: mux/TLS presets, testing
// and URL-test, subscription, traffic graph settings and every Android-only
// UI/notification key. `enable_warp` decides whether the built-in WARP hop wraps
// the main chain and the warp_* keys are that hop's identity; `mux_default_on`
// is read only so the builder can refuse a config whose mux preset it does not
// reproduce.
package mobile

import (
	"encoding/json"
	"math"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
)

type configSettingKind uint8

const (
	configSettingBool configSettingKind = iota
	configSettingInt
	configSettingLong
	configSettingString
	configSettingStringList
)

// configSettingDefinition is one row of the ported table. Exactly one default
// field and one validator field is meaningful for a given kind; the helpers
// below keep those pairs in sync.
type configSettingDefinition struct {
	key  string
	kind configSettingKind

	boolDefault   bool
	intDefault    int
	longDefault   int64
	stringDefault string
	listDefault   []string

	validInt    func(int) bool
	validLong   func(int64) bool
	validString func(string) bool
	validList   func([]string) bool
}

func configBoolSetting(key string, def bool) configSettingDefinition {
	return configSettingDefinition{key: key, kind: configSettingBool, boolDefault: def}
}

func configIntSetting(key string, def int, valid func(int) bool) configSettingDefinition {
	return configSettingDefinition{key: key, kind: configSettingInt, intDefault: def, validInt: valid}
}

func configLongSetting(key string, def int64, valid func(int64) bool) configSettingDefinition {
	return configSettingDefinition{key: key, kind: configSettingLong, longDefault: def, validLong: valid}
}

func configStringSetting(key string, def string, valid func(string) bool) configSettingDefinition {
	return configSettingDefinition{key: key, kind: configSettingString, stringDefault: def, validString: valid}
}

func configStringListSetting(key string, def []string, valid func([]string) bool) configSettingDefinition {
	return configSettingDefinition{key: key, kind: configSettingStringList, listDefault: def, validList: valid}
}

// configSettingDefinitions follows SettingsRegistry.kt's declaration order for
// the desktop keys, then the Android-only keys this layer needs. Adding a key
// here is the only way a simple-config input read can mention it.
var configSettingDefinitions = []configSettingDefinition{
	// ------------------------------------------------------------------ log
	// Android "warn" (decision D9; desktop "info").
	configStringSetting("log_level", "warn", configOneOf("trace", "debug", "info", "warn", "error", "fatal", "panic")),

	// ------------------------------------------------------------------ ntp
	configBoolSetting("enable_ntp", false),
	configStringSetting("ntp_server_address", "", nil),
	configIntSetting("ntp_server_port", 0, func(value int) bool { return value >= 0 && value <= 65535 }),
	configStringSetting("ntp_interval", "", configDurationOrEmpty),
	configStringSetting("ntp_outbound", "direct", configOneOf("direct", "proxy")),

	// ---------------------------------------------------------- certificate
	configBoolSetting("skip_cert", false),
	configBoolSetting("use_mozilla_certs", false),

	// -------------------------------------------------------- mixed inbound
	configStringSetting("inbound_address", "127.0.0.1", configNonBlank),
	configIntSetting("inbound_socks_port", 2080, configPort),
	configBoolSetting("disable_mixed_inbound", false),
	configBoolSetting("random_inbound_port", false),
	configBoolSetting("inbound_auth", false),
	configStringSetting("inbound_user", "", nil),
	configStringSetting("inbound_pass", "", nil),
	configStringSetting("custom_inbound", `{"inbounds": []}`, nil),

	// ------------------------------------------------ per-app / HTTP proxy
	// Android-only keys (Constants.kt): the tun inbound's package lists and the
	// opt-in system HTTP proxy handed to VpnService.openTun.
	configBoolSetting("proxyApps", false),
	configBoolSetting("bypassMode", true),
	configStringSetting("individual", "", nil),
	configBoolSetting("appendHttpProxy", false),
	configStringSetting("httpProxyBypass", "", nil),

	// ------------------------------------------------------------------ tun
	// Android 9000 (decision D2; desktop 1500).
	configIntSetting("vpn_mtu", 9000, func(value int) bool { return value >= 1000 && value <= 10000 }),
	configBoolSetting("vpn_ipv6", false),
	configStringSetting("vpn_tun_ipv4_cidr", "172.19.0.1/24", configCIDR(false)),
	configStringSetting("vpn_tun_ipv6_cidr", "fdfe:dcba:9876::1/96", configCIDR(true)),
	configBoolSetting("disable_private_range_bypass", false),
	configStringListSetting("vpn_private_ranges", []string{
		"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4",
		"fc00::/7", "fe80::/10", "ff00::/8",
	}, configAllPrivateRanges),
	configBoolSetting("enable_tun_routing", false),
	configBoolSetting("enable_warp", false),
	configBoolSetting("mux_default_on", false),

	// ------------------------------------------------------------------ dns
	configStringSetting("remote_dns", "https://8.8.8.8/dns-query", nil),
	configBoolSetting("remote_dns_disable_ipv6", false),
	configStringSetting("direct_dns", "localhost", nil),
	configBoolSetting("direct_dns_disable_ipv6", false),
	configStringSetting("core_box_underlying_dns", "", nil),
	configStringSetting("dns_final_out", "remote", configOneOf("remote", "direct")),
	configBoolSetting("enable_dns_routing", true),
	configBoolSetting("fakedns", false),
	configBoolSetting("fakeip_disable_ipv6", false),
	configBoolSetting("dns_use_hosts", false),
	configBoolSetting("dns_predefined_enable", true),
	configStringListSetting("dns_predefined_rules", []string{"127.0.0.1 localhost"}, configPredefinedDNS),
	configIntSetting("dns_cache_capacity", 65536, func(value int) bool { return value >= 0 }),
	configStringSetting("dns_query_timeout", "", configDurationOrEmpty),
	configBoolSetting("dns_optimistic", false),
	configStringSetting("dns_optimistic_timeout", "", configDurationOrEmpty),
	configBoolSetting("dns_disable_cache", false),
	configBoolSetting("dns_disable_expire", false),
	configBoolSetting("dns_persist_cache", false),
	configBoolSetting("dns_reverse_mapping", false),
	configBoolSetting("use_dns_object", false),
	configStringSetting("dns_object", "", nil),

	// ---------------------------------------------------------------- route
	configStringSetting("outbound_domain_strategy", "", configOneOf("", "ipv4_only", "ipv6_only", "prefer_ipv4", "prefer_ipv6")),
	configStringSetting("domain_strategy", "", configOneOf("", "ipv4_only", "ipv6_only", "prefer_ipv4", "prefer_ipv6")),
	// 0 GitHub, 1 jsDelivr, 2 Gcore, 3 Quantil, 4 Fastly, 5 CDN.
	configIntSetting("ruleset_mirror", 0, func(value int) bool { return value >= 0 && value <= 5 }),
	configBoolSetting("adblock_enable", false),

	// --------------------------------------------------------------- presets
	// SettingsRegistry "presets": the sing-box multiplex preset, the TLS
	// fragment / uTLS / tricks globals and the QUIC overrides every outbound
	// build consults through BuildContext.
	configStringSetting("mux_protocol", "smux", configOneOf("h2mux", "smux", "yamux")),
	configStringSetting("mux_mode", "max_streams", configOneOf("max_streams", "max_connections")),
	configIntSetting("mux_concurrency", 8, func(value int) bool { return value >= 0 }),
	configIntSetting("mux_max_connections", 4, func(value int) bool { return value >= 0 }),
	configIntSetting("mux_min_streams", 4, func(value int) bool { return value >= 0 }),
	configBoolSetting("mux_padding", false),
	configBoolSetting("mux_brutal", false),
	configIntSetting("mux_brutal_up_mbps", 0, func(value int) bool { return value >= 0 }),
	configIntSetting("mux_brutal_down_mbps", 0, func(value int) bool { return value >= 0 }),
	configBoolSetting("fragment_default_on", false),
	configStringSetting("fragment_implementation", "built-in", configOneOf("built-in", "custom")),
	configStringSetting("fragment_size", "10-100", configRangeOrEmpty),
	configStringSetting("fragment_sleep", "2-5", configRangeOrEmpty),
	configBoolSetting("tls_tricks_default_on", false),
	configStringSetting("utlsFingerprint", "", nil),
	configStringSetting("h2_idle_timeout", "", configDurationOrEmpty),
	configStringSetting("h2_keep_alive_period", "", configDurationOrEmpty),
	configStringSetting("h2_stream_receive_window", "", nil),
	configStringSetting("h2_connection_receive_window", "", nil),
	configIntSetting("h2_max_concurrent_streams", 0, func(value int) bool { return value >= 0 }),
	configIntSetting("quic_initial_packet_size", 0, func(value int) bool { return value >= 0 }),
	configBoolSetting("quic_disable_path_mtu_discovery", false),

	// ------------------------------------------------------------------ warp
	// WireGuard and MASQUE keep separate key material; warp_mode picks the set
	// the built-in WARP hop reads. enable_warp lives with the tun keys above.
	configStringSetting("warp_mode", "wireguard", configOneOf("wireguard", "masque", "amnezia")),
	configStringSetting("warp_ep", "", nil),
	configStringSetting("warp_private_key", "", nil),
	configStringSetting("warp_public_key", "", nil),
	configStringListSetting("warp_ifc_addrs", []string{}, nil),
	configStringListSetting("warp_reserved", []string{}, nil),
	configStringListSetting("warp_amnezia_packets", []string{}, nil),
	configStringSetting("warp_masque_ep", "", nil),
	configStringSetting("warp_masque_private_key", "", nil),
	configStringSetting("warp_masque_peer_public_key", "", nil),
	configStringListSetting("warp_masque_ifc_addrs", []string{}, nil),
	configStringSetting("warp_masque_sni", "consumer-masque.cloudflareclient.com", nil),
	configIntSetting("warp_masque_http_mode", 0, func(value int) bool { return value >= 0 && value <= 2 }),

	// ------------------------------------------------------------------ api
	// Sign-encoded (at most 0 is off); Android's dashboard default is 9091.
	configIntSetting("core_box_api_port", 9091, func(value int) bool { return value >= -65535 && value <= 65535 }),
	configStringSetting("core_box_api_secret", "", nil),
	configIntSetting("core_box_clash_api", -9090, func(value int) bool { return value >= -65535 && value <= 65535 }),
	configStringSetting("core_box_clash_listen_addr", "127.0.0.1", configNonBlank),
	configStringSetting("core_box_clash_api_secret", "", nil),
	configIntSetting("core_dns_in_port", 5533, configPort),

	// ------------------------------------------------------ Android-only keys
	// Not SettingsRegistry members: DataStore declares them directly, but the
	// build reads them from the same settings.json rows.
	configStringSetting("serviceMode", "vpn", configOneOf("vpn", "proxy")),
	configStringSetting("bbox_outbound_mode", "rule", configOneOf("rule", "global", "direct")),
	configLongSetting("profileId", 0, nil),
	configLongSetting("current_group", 0, func(value int64) bool { return value >= 0 }),
	configLongSetting("startWithoutRuleSets", 0, nil),
}

var configSettingDefinitionsByKey = func() map[string]configSettingDefinition {
	index := make(map[string]configSettingDefinition, len(configSettingDefinitions))
	for _, definition := range configSettingDefinitions {
		index[definition.key] = definition
	}
	return index
}()

// configSettingDefault returns the registered default in its typed Go form.
// The slice is copied so a caller cannot mutate the table.
func configSettingDefault(key string) (any, bool) {
	definition, ok := configSettingDefinitionsByKey[key]
	if !ok {
		return nil, false
	}
	switch definition.kind {
	case configSettingBool:
		return definition.boolDefault, true
	case configSettingInt:
		return definition.intDefault, true
	case configSettingLong:
		return definition.longDefault, true
	case configSettingString:
		return definition.stringDefault, true
	case configSettingStringList:
		// A copy, and never nil: the Kotlin default is a real empty list and the
		// decoded form of a stored [] is one too.
		return append([]string{}, definition.listDefault...), true
	}
	return nil, false
}

// configSettingEncodedDefault returns the desktop-encoded default, the exact
// value SettingsRegistry.defaultOf(key) answers in Kotlin.
func configSettingEncodedDefault(key string) (string, bool) {
	definition, ok := configSettingDefinitionsByKey[key]
	if !ok {
		return "", false
	}
	switch definition.kind {
	case configSettingBool:
		return strconv.FormatBool(definition.boolDefault), true
	case configSettingInt:
		return strconv.Itoa(definition.intDefault), true
	case configSettingLong:
		return strconv.FormatInt(definition.longDefault, 10), true
	case configSettingString:
		return definition.stringDefault, true
	case configSettingStringList:
		values := definition.listDefault
		if values == nil {
			values = []string{}
		}
		encoded, err := json.Marshal(values)
		if err != nil {
			return "", false
		}
		return string(encoded), true
	}
	return "", false
}

// configSettingDefaults returns every registered key's encoded default as one
// hand-checkable table.
func configSettingDefaults() map[string]string {
	defaults := make(map[string]string, len(configSettingDefinitions))
	for _, definition := range configSettingDefinitions {
		if encoded, ok := configSettingEncodedDefault(definition.key); ok {
			defaults[definition.key] = encoded
		}
	}
	return defaults
}

// decodeConfigSetting mirrors SettingsRegistry.Setting.decode: the typed value,
// or false when the raw desktop-encoded row is not acceptable for this key.
func decodeConfigSetting(key, raw string) (any, bool) {
	definition, ok := configSettingDefinitionsByKey[key]
	if !ok {
		return nil, false
	}
	switch definition.kind {
	case configSettingBool:
		switch raw {
		case "true", "1":
			return true, true
		case "false", "0":
			return false, true
		}
		return nil, false
	case configSettingInt:
		parsed, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 32)
		if err != nil {
			return nil, false
		}
		value := int(parsed)
		if definition.validInt != nil && !definition.validInt(value) {
			return nil, false
		}
		return value, true
	case configSettingLong:
		parsed, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
		if err != nil {
			return nil, false
		}
		if definition.validLong != nil && !definition.validLong(parsed) {
			return nil, false
		}
		return parsed, true
	case configSettingString:
		if definition.validString != nil && !definition.validString(raw) {
			return nil, false
		}
		return raw, true
	case configSettingStringList:
		values, ok := decodeConfigStringList(raw)
		if !ok {
			return nil, false
		}
		if definition.validList != nil && !definition.validList(values) {
			return nil, false
		}
		return values, true
	}
	return nil, false
}

// decodeConfigStringList is SettingsStore.decodeList: a JSON array, where each
// non-string element becomes "" (JsonValues.toStringValue). Anything else is
// invalid and the caller keeps the default.
func decodeConfigStringList(raw string) ([]string, bool) {
	var values []any
	if err := json.Unmarshal([]byte(raw), &values); err != nil {
		return nil, false
	}
	if values == nil && strings.TrimSpace(raw) == "null" {
		return nil, false
	}
	result := make([]string, 0, len(values))
	for _, value := range values {
		text, _ := value.(string)
		result = append(result, text)
	}
	return result, true
}

// settingsRowsByKey folds the settings document's rows exactly like
// SettingsJsonStore.readRows: a later duplicate key wins, an empty key is
// skipped, and a non-string JSON value is read as its text form.
func settingsRowsByKey(rows []row) map[string]string {
	values := make(map[string]string, len(rows))
	for _, settingsRow := range rows {
		key := rowString(settingsRow, "key")
		if key == "" {
			continue
		}
		values[key] = settingsRowText(settingsRow["value"])
	}
	return values
}

func settingsRowText(value any) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case string:
		return typed
	case bool:
		if typed {
			return "true"
		}
		return "false"
	case float64:
		if math.IsNaN(typed) || math.IsInf(typed, 0) {
			return ""
		}
		if typed == math.Trunc(typed) && typed >= math.MinInt64 && typed <= math.MaxInt64 {
			return strconv.FormatInt(int64(typed), 10)
		}
		return strconv.FormatFloat(typed, 'g', -1, 64)
	case int:
		return strconv.Itoa(typed)
	case int64:
		return strconv.FormatInt(typed, 10)
	default:
		return ""
	}
}

func configSettingBoolValue(values map[string]string, key string) bool {
	if decoded, ok := decodeStoredSetting(values, key); ok {
		if value, typed := decoded.(bool); typed {
			return value
		}
	}
	if value, ok := configSettingDefault(key); ok {
		if typed, ok := value.(bool); ok {
			return typed
		}
	}
	return false
}

func configSettingIntValue(values map[string]string, key string) int {
	if decoded, ok := decodeStoredSetting(values, key); ok {
		if value, typed := decoded.(int); typed {
			return value
		}
	}
	if value, ok := configSettingDefault(key); ok {
		if typed, ok := value.(int); ok {
			return typed
		}
	}
	return 0
}

func configSettingLongValue(values map[string]string, key string) int64 {
	if decoded, ok := decodeStoredSetting(values, key); ok {
		if value, typed := decoded.(int64); typed {
			return value
		}
	}
	if value, ok := configSettingDefault(key); ok {
		if typed, ok := value.(int64); ok {
			return typed
		}
	}
	return 0
}

func configSettingStringValue(values map[string]string, key string) string {
	if decoded, ok := decodeStoredSetting(values, key); ok {
		if value, typed := decoded.(string); typed {
			return value
		}
	}
	if value, ok := configSettingDefault(key); ok {
		if typed, ok := value.(string); ok {
			return typed
		}
	}
	return ""
}

func configSettingStringListValue(values map[string]string, key string) []string {
	if decoded, ok := decodeStoredSetting(values, key); ok {
		if value, typed := decoded.([]string); typed {
			return value
		}
	}
	if value, ok := configSettingDefault(key); ok {
		if typed, ok := value.([]string); ok {
			return append([]string{}, typed...)
		}
	}
	return nil
}

// decodeStoredSetting reads one row and applies the SettingsRegistry fallback:
// missing or invalid both leave ok false so the caller uses the default.
func decodeStoredSetting(values map[string]string, key string) (any, bool) {
	raw, present := values[key]
	if !present {
		return nil, false
	}
	return decodeConfigSetting(key, raw)
}

// simpleConfigSettings is the typed settings subset a simple config build
// reads. Every field is named after its Kotlin DataStore property; the comment
// above each group names the SettingsRegistry keys behind it.
type simpleConfigSettings struct {
	// log: log_level
	LogLevel string

	// ntp: enable_ntp, ntp_server_address, ntp_server_port, ntp_interval,
	// ntp_outbound
	NTPEnabled    bool
	NTPServer     string
	NTPServerPort int
	NTPInterval   string
	NTPOutbound   string

	// certificate: skip_cert (BuildContext), use_mozilla_certs
	SkipCert        bool
	UseMozillaCerts bool

	// mixed inbound: inbound_address, inbound_socks_port, disable_mixed_inbound,
	// random_inbound_port, inbound_auth, inbound_user, inbound_pass, custom_inbound
	InboundAddress      string
	InboundSocksPort    int
	DisableMixedInbound bool
	RandomInboundPort   bool
	InboundAuth         bool
	InboundUser         string
	InboundPass         string
	CustomInbound       string

	// per-app / system HTTP proxy: proxyApps, bypassMode, individual,
	// appendHttpProxy, httpProxyBypass
	ProxyApps       bool
	PerAppBypass    bool
	Individual      string
	AppendHTTPProxy bool
	HTTPProxyBypass string

	// tun: vpn_mtu, vpn_ipv6, vpn_tun_ipv4_cidr, vpn_tun_ipv6_cidr,
	// disable_private_range_bypass, vpn_private_ranges, enable_tun_routing,
	// enable_warp, mux_default_on
	VPNMtu                    int
	VPNIPv6                   bool
	VPNTunIPv4CIDR            string
	VPNTunIPv6CIDR            string
	DisablePrivateRangeBypass bool
	VPNPrivateRanges          []string
	EnableTunRouting          bool
	EnableWarp                bool
	MuxDefaultOn              bool

	// dns: remote_dns, remote_dns_disable_ipv6, direct_dns,
	// direct_dns_disable_ipv6, core_box_underlying_dns, dns_final_out,
	// enable_dns_routing, fakedns, fakeip_disable_ipv6, dns_use_hosts,
	// dns_predefined_enable, dns_predefined_rules, dns_cache_capacity,
	// dns_query_timeout, dns_optimistic, dns_optimistic_timeout,
	// dns_disable_cache, dns_disable_expire, dns_persist_cache,
	// dns_reverse_mapping, use_dns_object, dns_object
	RemoteDNS            string
	RemoteDNSDisableIPv6 bool
	DirectDNS            string
	DirectDNSDisableIPv6 bool
	CoreBoxUnderlyingDNS string
	DNSFinalOut          string
	EnableDNSRouting     bool
	FakeDNS              bool
	FakeIPDisableIPv6    bool
	DNSUseHosts          bool
	DNSPredefinedEnable  bool
	DNSPredefinedRules   []string
	DNSCacheCapacity     int
	DNSQueryTimeout      string
	DNSOptimistic        bool
	DNSOptimisticTimeout string
	DNSDisableCache      bool
	DNSDisableExpire     bool
	DNSPersistCache      bool
	DNSReverseMapping    bool
	UseDNSObject         bool
	DNSObject            string

	// route: outbound_domain_strategy, domain_strategy, ruleset_mirror,
	// adblock_enable
	OutboundDomainStrategy string
	DomainStrategy         string
	RuleSetMirror          int
	AdblockEnable          bool

	// presets: mux_protocol, mux_mode, mux_concurrency, mux_max_connections,
	// mux_min_streams, mux_padding, mux_brutal, mux_brutal_up_mbps,
	// mux_brutal_down_mbps, mux_default_on, fragment_default_on,
	// fragment_implementation, fragment_size, fragment_sleep,
	// tls_tricks_default_on, utlsFingerprint, h2_idle_timeout,
	// h2_keep_alive_period, h2_stream_receive_window,
	// h2_connection_receive_window, h2_max_concurrent_streams,
	// quic_initial_packet_size, quic_disable_path_mtu_discovery
	MuxProtocol                 string
	MuxMode                     string
	MuxConcurrency              int
	MuxMaxConnections           int
	MuxMinStreams               int
	MuxPadding                  bool
	MuxBrutal                   bool
	MuxBrutalUpMbps             int
	MuxBrutalDownMbps           int
	FragmentDefaultOn           bool
	FragmentImplementation      string
	FragmentSize                string
	FragmentSleep               string
	TLSTricksDefaultOn          bool
	UtlsFingerprint             string
	H2IdleTimeout               string
	H2KeepAlivePeriod           string
	H2StreamReceiveWindow       string
	H2ConnectionReceiveWindow   string
	H2MaxConcurrentStreams      int
	QuicInitialPacketSize       int
	QuicDisablePathMTUDiscovery bool

	// warp: warp_mode, warp_ep, warp_private_key, warp_public_key,
	// warp_ifc_addrs, warp_reserved, warp_amnezia_packets, warp_masque_ep,
	// warp_masque_private_key, warp_masque_peer_public_key,
	// warp_masque_ifc_addrs, warp_masque_sni, warp_masque_http_mode
	WarpMode                string
	WarpEp                  string
	WarpPrivateKey          string
	WarpPublicKey           string
	WarpIfcAddrs            []string
	WarpReserved            []string
	WarpAmneziaPackets      []string
	WarpMasqueEp            string
	WarpMasquePrivateKey    string
	WarpMasquePeerPublicKey string
	WarpMasqueIfcAddrs      []string
	WarpMasqueSni           string
	WarpMasqueHTTPMode      int

	// api: core_box_api_port, core_box_api_secret, core_box_clash_api,
	// core_box_clash_listen_addr, core_box_clash_api_secret, core_dns_in_port
	CoreBoxAPIPort         int
	CoreBoxAPISecret       string
	CoreBoxClashAPI        int
	CoreBoxClashListenAddr string
	CoreBoxClashAPISecret  string
	CoreDNSInPort          int
}

// MixedInboundEnabled mirrors DataStore.mixedInboundDisabled: disabling the
// mixed inbound applies only in VPN mode; the proxy-only service mode needs it.
func (settings simpleConfigSettings) MixedInboundEnabled(mode serviceMode) bool {
	return !settings.DisableMixedInbound || mode == serviceModeProxy
}

// BypassLan mirrors GeneratorSettings.bypassLan: !disable_private_range_bypass.
func (settings simpleConfigSettings) BypassLan() bool {
	return !settings.DisablePrivateRangeBypass
}

// ClashAPIEnabled mirrors GeneratorSettings.clashApiEnabled: a positive
// core_box_clash_api turns the API on.
func (settings simpleConfigSettings) ClashAPIEnabled() bool {
	return settings.CoreBoxClashAPI > 0
}

// ClashAPIPort mirrors SettingsMapper: the magnitude of the sign-encoded row.
func (settings simpleConfigSettings) ClashAPIPort() int {
	if settings.CoreBoxClashAPI > 0 {
		return settings.CoreBoxClashAPI
	}
	return -settings.CoreBoxClashAPI
}

// loadSimpleConfigSettings turns the settings document rows into the typed
// subset. Missing rows and rows that fail their validator both take the
// registered default, exactly like SettingsRegistry.Setting.read.
func loadSimpleConfigSettings(rows []row) simpleConfigSettings {
	return loadSimpleConfigSettingsFromValues(settingsRowsByKey(rows))
}

func loadSimpleConfigSettingsFromValues(values map[string]string) simpleConfigSettings {
	return simpleConfigSettings{
		LogLevel: configSettingStringValue(values, "log_level"),

		NTPEnabled:    configSettingBoolValue(values, "enable_ntp"),
		NTPServer:     configSettingStringValue(values, "ntp_server_address"),
		NTPServerPort: configSettingIntValue(values, "ntp_server_port"),
		NTPInterval:   configSettingStringValue(values, "ntp_interval"),
		NTPOutbound:   configSettingStringValue(values, "ntp_outbound"),

		SkipCert:        configSettingBoolValue(values, "skip_cert"),
		UseMozillaCerts: configSettingBoolValue(values, "use_mozilla_certs"),

		InboundAddress:      configSettingStringValue(values, "inbound_address"),
		InboundSocksPort:    configSettingIntValue(values, "inbound_socks_port"),
		DisableMixedInbound: configSettingBoolValue(values, "disable_mixed_inbound"),
		RandomInboundPort:   configSettingBoolValue(values, "random_inbound_port"),
		InboundAuth:         configSettingBoolValue(values, "inbound_auth"),
		InboundUser:         configSettingStringValue(values, "inbound_user"),
		InboundPass:         configSettingStringValue(values, "inbound_pass"),
		CustomInbound:       configSettingStringValue(values, "custom_inbound"),

		ProxyApps:       configSettingBoolValue(values, "proxyApps"),
		PerAppBypass:    configSettingBoolValue(values, "bypassMode"),
		Individual:      configSettingStringValue(values, "individual"),
		AppendHTTPProxy: configSettingBoolValue(values, "appendHttpProxy"),
		HTTPProxyBypass: configSettingStringValue(values, "httpProxyBypass"),

		VPNMtu:                    configSettingIntValue(values, "vpn_mtu"),
		VPNIPv6:                   configSettingBoolValue(values, "vpn_ipv6"),
		VPNTunIPv4CIDR:            configSettingStringValue(values, "vpn_tun_ipv4_cidr"),
		VPNTunIPv6CIDR:            configSettingStringValue(values, "vpn_tun_ipv6_cidr"),
		DisablePrivateRangeBypass: configSettingBoolValue(values, "disable_private_range_bypass"),
		VPNPrivateRanges:          configSettingStringListValue(values, "vpn_private_ranges"),
		EnableTunRouting:          configSettingBoolValue(values, "enable_tun_routing"),
		EnableWarp:                configSettingBoolValue(values, "enable_warp"),
		MuxDefaultOn:              configSettingBoolValue(values, "mux_default_on"),

		RemoteDNS:            configSettingStringValue(values, "remote_dns"),
		RemoteDNSDisableIPv6: configSettingBoolValue(values, "remote_dns_disable_ipv6"),
		DirectDNS:            configSettingStringValue(values, "direct_dns"),
		DirectDNSDisableIPv6: configSettingBoolValue(values, "direct_dns_disable_ipv6"),
		CoreBoxUnderlyingDNS: configSettingStringValue(values, "core_box_underlying_dns"),
		DNSFinalOut:          configSettingStringValue(values, "dns_final_out"),
		EnableDNSRouting:     configSettingBoolValue(values, "enable_dns_routing"),
		FakeDNS:              configSettingBoolValue(values, "fakedns"),
		FakeIPDisableIPv6:    configSettingBoolValue(values, "fakeip_disable_ipv6"),
		DNSUseHosts:          configSettingBoolValue(values, "dns_use_hosts"),
		DNSPredefinedEnable:  configSettingBoolValue(values, "dns_predefined_enable"),
		DNSPredefinedRules:   configSettingStringListValue(values, "dns_predefined_rules"),
		DNSCacheCapacity:     configSettingIntValue(values, "dns_cache_capacity"),
		DNSQueryTimeout:      configSettingStringValue(values, "dns_query_timeout"),
		DNSOptimistic:        configSettingBoolValue(values, "dns_optimistic"),
		DNSOptimisticTimeout: configSettingStringValue(values, "dns_optimistic_timeout"),
		DNSDisableCache:      configSettingBoolValue(values, "dns_disable_cache"),
		DNSDisableExpire:     configSettingBoolValue(values, "dns_disable_expire"),
		DNSPersistCache:      configSettingBoolValue(values, "dns_persist_cache"),
		DNSReverseMapping:    configSettingBoolValue(values, "dns_reverse_mapping"),
		UseDNSObject:         configSettingBoolValue(values, "use_dns_object"),
		DNSObject:            configSettingStringValue(values, "dns_object"),

		OutboundDomainStrategy: configSettingStringValue(values, "outbound_domain_strategy"),
		DomainStrategy:         configSettingStringValue(values, "domain_strategy"),
		RuleSetMirror:          configSettingIntValue(values, "ruleset_mirror"),
		AdblockEnable:          configSettingBoolValue(values, "adblock_enable"),

		MuxProtocol:                 configSettingStringValue(values, "mux_protocol"),
		MuxMode:                     configSettingStringValue(values, "mux_mode"),
		MuxConcurrency:              configSettingIntValue(values, "mux_concurrency"),
		MuxMaxConnections:           configSettingIntValue(values, "mux_max_connections"),
		MuxMinStreams:               configSettingIntValue(values, "mux_min_streams"),
		MuxPadding:                  configSettingBoolValue(values, "mux_padding"),
		MuxBrutal:                   configSettingBoolValue(values, "mux_brutal"),
		MuxBrutalUpMbps:             configSettingIntValue(values, "mux_brutal_up_mbps"),
		MuxBrutalDownMbps:           configSettingIntValue(values, "mux_brutal_down_mbps"),
		FragmentDefaultOn:           configSettingBoolValue(values, "fragment_default_on"),
		FragmentImplementation:      configSettingStringValue(values, "fragment_implementation"),
		FragmentSize:                configSettingStringValue(values, "fragment_size"),
		FragmentSleep:               configSettingStringValue(values, "fragment_sleep"),
		TLSTricksDefaultOn:          configSettingBoolValue(values, "tls_tricks_default_on"),
		UtlsFingerprint:             configSettingStringValue(values, "utlsFingerprint"),
		H2IdleTimeout:               configSettingStringValue(values, "h2_idle_timeout"),
		H2KeepAlivePeriod:           configSettingStringValue(values, "h2_keep_alive_period"),
		H2StreamReceiveWindow:       configSettingStringValue(values, "h2_stream_receive_window"),
		H2ConnectionReceiveWindow:   configSettingStringValue(values, "h2_connection_receive_window"),
		H2MaxConcurrentStreams:      configSettingIntValue(values, "h2_max_concurrent_streams"),
		QuicInitialPacketSize:       configSettingIntValue(values, "quic_initial_packet_size"),
		QuicDisablePathMTUDiscovery: configSettingBoolValue(values, "quic_disable_path_mtu_discovery"),

		WarpMode:                configSettingStringValue(values, "warp_mode"),
		WarpEp:                  configSettingStringValue(values, "warp_ep"),
		WarpPrivateKey:          configSettingStringValue(values, "warp_private_key"),
		WarpPublicKey:           configSettingStringValue(values, "warp_public_key"),
		WarpIfcAddrs:            configSettingStringListValue(values, "warp_ifc_addrs"),
		WarpReserved:            configSettingStringListValue(values, "warp_reserved"),
		WarpAmneziaPackets:      configSettingStringListValue(values, "warp_amnezia_packets"),
		WarpMasqueEp:            configSettingStringValue(values, "warp_masque_ep"),
		WarpMasquePrivateKey:    configSettingStringValue(values, "warp_masque_private_key"),
		WarpMasquePeerPublicKey: configSettingStringValue(values, "warp_masque_peer_public_key"),
		WarpMasqueIfcAddrs:      configSettingStringListValue(values, "warp_masque_ifc_addrs"),
		WarpMasqueSni:           configSettingStringValue(values, "warp_masque_sni"),
		WarpMasqueHTTPMode:      configSettingIntValue(values, "warp_masque_http_mode"),

		CoreBoxAPIPort:         configSettingIntValue(values, "core_box_api_port"),
		CoreBoxAPISecret:       configSettingStringValue(values, "core_box_api_secret"),
		CoreBoxClashAPI:        configSettingIntValue(values, "core_box_clash_api"),
		CoreBoxClashListenAddr: configSettingStringValue(values, "core_box_clash_listen_addr"),
		CoreBoxClashAPISecret:  configSettingStringValue(values, "core_box_clash_api_secret"),
		CoreDNSInPort:          configSettingIntValue(values, "core_dns_in_port"),
	}
}

// ---------------------------------------------------------------------------
// Validators (SettingValidators.kt / SettingsRegistry.kt).
// ---------------------------------------------------------------------------

func configOneOf(values ...string) func(string) bool {
	allowed := make(map[string]struct{}, len(values))
	for _, value := range values {
		allowed[value] = struct{}{}
	}
	return func(text string) bool {
		_, ok := allowed[text]
		return ok
	}
}

func configNonBlank(text string) bool {
	return strings.TrimSpace(text) != ""
}

func configPort(port int) bool {
	return port >= 1 && port <= 65535
}

// configCIDR mirrors SettingValidators.isCidr: address/prefix of exactly the
// requested family. netip rejects zones and leading-zero IPv4 octets, as the
// Kotlin Hosts parser does.
func configCIDR(ipv6 bool) func(string) bool {
	return func(text string) bool {
		parts := strings.Split(strings.TrimSpace(text), "/")
		if len(parts) != 2 {
			return false
		}
		prefix, err := strconv.Atoi(strings.TrimSpace(parts[1]))
		if err != nil {
			return false
		}
		address := strings.TrimSpace(parts[0])
		if ipv6 {
			if !strings.Contains(address, ":") || prefix < 0 || prefix > 128 {
				return false
			}
			parsed, err := netip.ParseAddr(address)
			return err == nil && parsed.Is6() && parsed.Zone() == ""
		}
		if strings.Contains(address, ":") || !strings.Contains(address, ".") || prefix < 0 || prefix > 32 {
			return false
		}
		parsed, err := netip.ParseAddr(address)
		return err == nil && parsed.Is4()
	}
}

// configIsPrivateRange mirrors SettingValidators.isPrivateRange: an address or
// CIDR of either family that does not cover every address (/0 is refused).
func configIsPrivateRange(text string) bool {
	value := strings.TrimSpace(text)
	if !strings.ContainsAny(value, ".:") {
		return false
	}
	parts := strings.Split(value, "/")
	if len(parts) > 2 {
		return false
	}
	ipv6 := strings.Contains(parts[0], ":")
	if len(parts) == 1 {
		parsed, err := netip.ParseAddr(parts[0])
		return err == nil && parsed.Zone() == ""
	}
	if !configCIDR(ipv6)(value) {
		return false
	}
	prefix, err := strconv.Atoi(strings.TrimSpace(parts[1]))
	return err == nil && prefix > 0
}

func configAllPrivateRanges(ranges []string) bool {
	for _, value := range ranges {
		if !configIsPrivateRange(value) {
			return false
		}
	}
	return true
}

var (
	configDurationPattern = regexp.MustCompile(`^([0-9]+([.][0-9]+)?(ns|us|ms|s|m|h|d))+$`)
	configRangePattern    = regexp.MustCompile(`^[0-9]+(-[0-9]+)?$`)
)

func configDurationOrEmpty(text string) bool {
	return text == "" || configDurationPattern.MatchString(text)
}

func configRangeOrEmpty(text string) bool {
	return text == "" || configRangePattern.MatchString(text)
}

// configPredefinedDNS mirrors PredefinedDns.parse's acceptance rule: every
// non-empty line is an address followed by at least one domain, with `#`
// starting a comment. The address is parsed by netip; empty lines are skipped.
func configPredefinedDNS(lines []string) bool {
	for _, rawLine := range lines {
		line := rawLine
		if hash := strings.IndexByte(line, '#'); hash >= 0 {
			line = line[:hash]
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		if len(fields) < 2 {
			return false
		}
		address := fields[0]
		address = strings.TrimPrefix(address, "[")
		address = strings.TrimSuffix(address, "]")
		if percent := strings.IndexByte(address, '%'); percent >= 0 {
			address = address[:percent]
		}
		if _, err := netip.ParseAddr(address); err != nil {
			return false
		}
		for _, domain := range fields[1:] {
			domain = strings.ToLower(strings.TrimRight(domain, "."))
			if domain == "" {
				return false
			}
		}
	}
	return true
}
