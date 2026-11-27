// The Stage-2 protocol emitters: http, socks, vmess, vless and trojan (TCP
// proxies with TLS/transport/multiplex), hysteria/hysteria2 (QUIC + obfs) and
// wireguard (a sing-box endpoint).
//
// Each parser reads the stored profiles.json outbound object with the exact
// field rules of the type's ParseFromJson in src/configs/outbounds/*.cpp (and
// the Throne Kotlin port), and each build function reproduces Build() including
// BuildContext's presets. The key sets are closed: a stored field the Kotlin
// build would carry but this builder does not is an error, never a silent drop.
package mobile

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// configCommonOutboundKeys are the keys Outbound.parseFromJson reads for every
// type (the tag is the display name; `name` is accepted because the chain row
// and Custom carry it).
func configCommonOutboundKeys() []string {
	keys := []string{"type", "tag", "name"}
	for key := range configDialKeys {
		keys = append(keys, key)
	}
	return keys
}

// configHeadersParse is JsonValues.objectToPairList over an arbitrary header
// object: values read as strings, non-strings as "".
func configHeadersParse(value any) map[string]string {
	headers := map[string]string{}
	object := configJSONObjectValue(value)
	if object == nil {
		return headers
	}
	for key, item := range object {
		headers[key] = configJSONVariantToStringValue(item)
	}
	return headers
}

// configOutboundBaseObject is the object part of Outbound.baseBuild: server,
// port and the dial fields.
func configOutboundBaseObject(out configOutbound) map[string]any {
	object := map[string]any{}
	if out.server != "" {
		object["server"] = out.server
	}
	if out.serverPort > 0 {
		object["server_port"] = out.serverPort
	}
	out.dial.apply(object)
	return object
}

// configDialFieldsBuild is DialFields.build: the eight dial keys as stored.
func configDialFieldsBuild(dial configDialFields) map[string]any {
	object := map[string]any{}
	dial.apply(object)
	return object
}

// configDialsTCP is OutboundChecks.dialsTcp for the outbound types this builder
// supports: every non-QUIC dial is TCP; hysteria dials QUIC and wireguard/socks
// send no TLS.
func configDialsTCP(profileType, transportType string) bool {
	if profileType == "hysteria" || profileType == "hysteria2" {
		return false
	}
	if transportType == "quic" {
		return false
	}
	return true
}

// configCustomFragmentApplies is OutboundChecks.customFragmentApplies: whether
// baseBuild emits the dialer-level tls_fragment block (and drops tcp_fast_open).
func configCustomFragmentApplies(profileType, transportType string, tls *configTLSParams, settings simpleConfigSettings) bool {
	if tls == nil || settings.FragmentImplementation != "custom" {
		return false
	}
	if !tls.enabled || !tls.fragmentEffectivelyOn(settings) {
		return false
	}
	return configDialsTCP(profileType, transportType)
}

// configFragmentSettingsError is OutboundChecks.fragmentSettingsError: why the
// global custom fragment settings fail every fragmenting TCP build.
func configFragmentSettingsError(settings simpleConfigSettings) error {
	if settings.FragmentImplementation != "custom" {
		return nil
	}
	size := strings.TrimSpace(settings.FragmentSize)
	if size == "" {
		size = "10-100"
	}
	sleep := strings.TrimSpace(settings.FragmentSleep)
	if sleep == "" {
		sleep = "2-5"
	}
	if !configFragmentSizeValid(size) {
		return fmt.Errorf("fragment_size %q is not a size or range the core accepts", size)
	}
	if !configFragmentSleepValid(sleep) {
		return fmt.Errorf("fragment_sleep %q is not a range the core accepts", sleep)
	}
	return nil
}

// configFragmentSizeValid is tlsFragmentSize leaving out its error text: n or
// min-max bytes, both within 0..1019, a max above 0.
func configFragmentSizeValid(spec string) bool {
	if !configIntOrRangeValid(spec, 0, 1019) {
		return false
	}
	if strings.TrimSpace(spec) != "" && configRangeMaximum(spec) == 0 {
		return false
	}
	return true
}

// configFragmentSleepValid is tlsFragmentSleep: n or min-max, both non-negative.
func configFragmentSleepValid(spec string) bool {
	return configIntOrRangeValid(spec, 0, math.MaxInt64)
}

// configRangeMaximum is the larger bound of a spec that passed intOrRange.
func configRangeMaximum(spec string) int64 {
	trimmed := strings.TrimSpace(spec)
	dash := strings.IndexByte(trimmed, '-')
	part := trimmed
	if dash >= 0 {
		part = trimmed[dash+1:]
	}
	parsed, err := strconv.ParseInt(part, 10, 64)
	if err != nil {
		return 0
	}
	return parsed
}

// configIntOrRangeValid is Validation.intOrRange with Empty.Allowed and no
// reversed ranges: `n` or `min-max`, both integers in [min, max].
func configIntOrRangeValid(text string, minimum, maximum int64) bool {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return true
	}
	negative := minimum < 0
	start := 0
	if negative && strings.HasPrefix(trimmed, "-") {
		start = 1
	}
	dash := -1
	if index := strings.IndexByte(trimmed[start:], '-'); index >= 0 {
		dash = start + index
	}
	first := trimmed
	second := trimmed
	if dash >= 0 {
		first = trimmed[:dash]
		second = trimmed[dash+1:]
	}
	values := [2]int64{}
	for index, part := range []string{first, second} {
		if !configSignedDigits(part) || (!negative && strings.HasPrefix(part, "-")) {
			return false
		}
		value, err := strconv.ParseInt(part, 10, 64)
		if err != nil || value < minimum || value > maximum {
			return false
		}
		values[index] = value
	}
	return values[0] <= values[1]
}

func configSignedDigits(text string) bool {
	digits := text
	if strings.HasPrefix(digits, "+") || strings.HasPrefix(digits, "-") {
		digits = digits[1:]
	}
	if digits == "" {
		return false
	}
	for index := 0; index < len(digits); index++ {
		if digits[index] < '0' || digits[index] > '9' {
			return false
		}
	}
	return true
}

// configApplyCustomFragment is the dialer-level custom fragment of
// Outbound.baseBuild.
func configApplyCustomFragment(object map[string]any, profileType, transportType string, tls *configTLSParams, settings simpleConfigSettings) error {
	if !configCustomFragmentApplies(profileType, transportType, tls, settings) {
		return nil
	}
	if err := configFragmentSettingsError(settings); err != nil {
		return err
	}
	delete(object, "tcp_fast_open")
	size := strings.TrimSpace(settings.FragmentSize)
	if size == "" {
		size = "10-100"
	}
	sleep := strings.TrimSpace(settings.FragmentSleep)
	if sleep == "" {
		sleep = "2-5"
	}
	object["tls_fragment"] = map[string]any{"enabled": true, "size": size, "sleep": sleep}
	return nil
}

// --- http ---------------------------------------------------------------------

type configHTTPParams struct {
	username string
	password string
	path     string
	headers  map[string]string
	tls      configTLSParams
}

func configParseHTTP(object map[string]any) (configHTTPParams, error) {
	params := configHTTPParams{headers: map[string]string{}, tls: configTLSDefault()}
	if _, present := object["username"]; present {
		params.username = configJSONString(object, "username")
	}
	if _, present := object["password"]; present {
		params.password = configJSONString(object, "password")
	}
	if _, present := object["path"]; present {
		params.path = configJSONString(object, "path")
	}
	params.headers = configHeadersParse(object["headers"])
	if _, present := object["tls"]; present {
		tls, err := configTLSParse(configJSONObjectValue(object["tls"]))
		if err != nil {
			return params, err
		}
		params.tls = tls
	}
	return params, nil
}

func configBuildHTTP(out configOutbound, params configHTTPParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "http"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	if err := configApplyCustomFragment(object, out.profileType, "", &params.tls, settings); err != nil {
		return nil, err
	}
	if params.username != "" {
		object["username"] = params.username
	}
	if params.password != "" {
		object["password"] = params.password
	}
	if params.path != "" {
		object["path"] = params.path
	}
	if len(params.headers) > 0 {
		object["headers"] = configHeadersObject(params.headers)
	}
	customFragment := configCustomFragmentApplies(out.profileType, "", &params.tls, settings)
	tls, err := configTLSBuild(params.tls, settings, customFragment)
	if err != nil {
		return nil, err
	}
	if len(tls) > 0 {
		object["tls"] = tls
	}
	return object, nil
}

// --- socks --------------------------------------------------------------------

type configSocksParams struct {
	username string
	password string
	version  int
	socks4a  bool
	uot      bool
}

func configSocksParseVersion(text string) (version int, socks4a bool) {
	value := strings.ToLower(strings.TrimSpace(text))
	if value == "4a" || value == "4" {
		return 4, value == "4a"
	}
	return 5, false
}

func configParseSocks(object map[string]any) (configSocksParams, error) {
	params := configSocksParams{version: 5}
	if _, present := object["username"]; present {
		params.username = configJSONString(object, "username")
	}
	if _, present := object["password"]; present {
		params.password = configJSONString(object, "password")
	}
	if _, present := object["version"]; present {
		params.version, params.socks4a = configSocksParseVersion(configJSONVariantString(object["version"]))
	}
	if _, present := object["uot"]; present {
		params.uot = configJSONBoolValue(object["uot"])
	}
	if udp, present := object["udp_over_tcp"]; present {
		if boolean, ok := udp.(bool); ok {
			params.uot = boolean
		} else if nested := configJSONObjectValue(udp); nested != nil {
			params.uot = configJSONBoolValue(nested["enabled"])
		}
	}
	return params, nil
}

func configBuildSocks(out configOutbound, params configSocksParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "socks"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	if params.username != "" {
		object["username"] = params.username
	}
	if params.password != "" {
		object["password"] = params.password
	}
	if params.version == 4 {
		if params.socks4a {
			object["version"] = "4a"
		} else {
			object["version"] = "4"
		}
	}
	if params.uot {
		object["udp_over_tcp"] = true
	}
	return object, nil
}

// --- vmess / vless ------------------------------------------------------------

type configVMessParams struct {
	uuid                string
	security            string
	alterID             int
	globalPadding       bool
	authenticatedLength bool
	packetEncoding      string
	tls                 configTLSParams
	transport           configTransportParams
	multiplex           configMultiplexParams
}

func configParseVMess(object map[string]any) (configVMessParams, error) {
	params := configVMessParams{
		security:       "auto",
		packetEncoding: "xudp",
		tls:            configTLSDefault(),
		multiplex:      configMultiplexDefault(),
	}
	if _, present := object["uuid"]; present {
		params.uuid = configJSONString(object, "uuid")
	}
	if _, present := object["security"]; present {
		params.security = configJSONString(object, "security")
	}
	if _, present := object["alter_id"]; present {
		params.alterID = configJSONInt(object["alter_id"])
	}
	if _, present := object["alter-id"]; present {
		params.alterID = configJSONInt(object["alter-id"])
	}
	if _, present := object["global_padding"]; present {
		params.globalPadding = configJSONBoolValue(object["global_padding"])
	}
	if _, present := object["global-padding"]; present {
		params.globalPadding = configJSONBoolValue(object["global-padding"])
	}
	if _, present := object["authenticated_length"]; present {
		params.authenticatedLength = configJSONBoolValue(object["authenticated_length"])
	}
	if _, present := object["packet_encoding"]; present {
		params.packetEncoding = configJSONString(object, "packet_encoding")
	}
	if _, present := object["tls"]; present {
		tls, err := configTLSParse(configJSONObjectValue(object["tls"]))
		if err != nil {
			return params, err
		}
		params.tls = tls
	}
	if _, present := object["transport"]; present {
		transport, err := configTransportParse(configJSONObjectValue(object["transport"]))
		if err != nil {
			return params, err
		}
		params.transport = transport
	}
	if _, present := object["multiplex"]; present {
		multiplex, err := configMultiplexParse(configJSONObjectValue(object["multiplex"]))
		if err != nil {
			return params, err
		}
		params.multiplex = multiplex
	}
	return params, nil
}

// configTLSForTransport is tlsForTransport: a QUIC dial uses the core's std TLS
// stack, which refuses a uTLS client, so uTLS is dropped there (REALITY keeps
// it, since it cannot run without).
func configTLSForTransport(tls map[string]any, transportType string) map[string]any {
	if transportType != "quic" {
		return tls
	}
	if _, hasReality := tls["reality"]; hasReality {
		return tls
	}
	if _, hasUTLS := tls["utls"]; !hasUTLS {
		return tls
	}
	copied := make(map[string]any, len(tls))
	for key, value := range tls {
		if key == "utls" {
			continue
		}
		copied[key] = value
	}
	return copied
}

func configBuildVMess(out configOutbound, params configVMessParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "vmess"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	if err := configApplyCustomFragment(object, out.profileType, params.transport.typeName, &params.tls, settings); err != nil {
		return nil, err
	}
	if params.uuid != "" {
		object["uuid"] = params.uuid
	}
	if params.security != "auto" {
		object["security"] = params.security
	}
	if params.alterID > 0 {
		object["alter_id"] = params.alterID
	}
	if params.globalPadding {
		object["global_padding"] = true
	}
	if params.authenticatedLength {
		object["authenticated_length"] = true
	}
	object["packet_encoding"] = params.packetEncoding
	customFragment := configCustomFragmentApplies(out.profileType, params.transport.typeName, &params.tls, settings)
	tls, err := configTLSBuild(params.tls, settings, customFragment)
	if err != nil {
		return nil, err
	}
	if len(tls) > 0 {
		object["tls"] = configTLSForTransport(tls, params.transport.typeName)
	}
	transport, err := configTransportBuild(params.transport)
	if err != nil {
		return nil, err
	}
	if len(transport) > 0 {
		object["transport"] = transport
	}
	if multiplex := configMultiplexBuild(params.multiplex, settings); len(multiplex) > 0 {
		object["multiplex"] = multiplex
	}
	return object, nil
}

type configVlessParams struct {
	uuid           string
	flow           string
	encryption     string
	packetEncoding string
	tls            configTLSParams
	transport      configTransportParams
	multiplex      configMultiplexParams
}

func configParseVless(object map[string]any) (configVlessParams, error) {
	params := configVlessParams{
		encryption:     "none",
		packetEncoding: "xudp",
		tls:            configTLSDefault(),
		multiplex:      configMultiplexDefault(),
	}
	if _, present := object["uuid"]; present {
		params.uuid = configJSONString(object, "uuid")
	}
	if _, present := object["flow"]; present {
		params.flow = configJSONString(object, "flow")
	}
	if _, present := object["encryption"]; present {
		// vlessImportEncryption runs on every load, not only on import.
		value := strings.TrimSpace(configJSONString(object, "encryption"))
		if value == "" || strings.EqualFold(value, "none") {
			params.encryption = "none"
		} else {
			params.encryption = value
		}
	}
	if _, present := object["packet_encoding"]; present {
		params.packetEncoding = configJSONString(object, "packet_encoding")
	}
	if _, present := object["tls"]; present {
		tls, err := configTLSParse(configJSONObjectValue(object["tls"]))
		if err != nil {
			return params, err
		}
		params.tls = tls
	}
	if _, present := object["transport"]; present {
		transport, err := configTransportParse(configJSONObjectValue(object["transport"]))
		if err != nil {
			return params, err
		}
		params.transport = transport
	}
	if _, present := object["multiplex"]; present {
		multiplex, err := configMultiplexParse(configJSONObjectValue(object["multiplex"]))
		if err != nil {
			return params, err
		}
		params.multiplex = multiplex
	}
	return params, nil
}

func configBuildVless(out configOutbound, params configVlessParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "vless"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	if err := configApplyCustomFragment(object, out.profileType, params.transport.typeName, &params.tls, settings); err != nil {
		return nil, err
	}
	if params.uuid != "" {
		object["uuid"] = params.uuid
	}
	if params.flow != "" {
		object["flow"] = params.flow
	}
	if params.encryption != "" {
		object["encryption"] = params.encryption
	}
	object["packet_encoding"] = params.packetEncoding
	customFragment := configCustomFragmentApplies(out.profileType, params.transport.typeName, &params.tls, settings)
	tls, err := configTLSBuild(params.tls, settings, customFragment)
	if err != nil {
		return nil, err
	}
	if len(tls) > 0 {
		object["tls"] = configTLSForTransport(tls, params.transport.typeName)
	}
	transport, err := configTransportBuild(params.transport)
	if err != nil {
		return nil, err
	}
	if len(transport) > 0 {
		object["transport"] = transport
	}
	if multiplex := configMultiplexBuild(params.multiplex, settings); len(multiplex) > 0 {
		object["multiplex"] = multiplex
	}
	return object, nil
}

// --- trojan -------------------------------------------------------------------

type configTrojanParams struct {
	password  string
	tls       configTLSParams
	transport configTransportParams
	multiplex configMultiplexParams
}

func configParseTrojan(object map[string]any) (configTrojanParams, error) {
	params := configTrojanParams{
		tls:       configTLSDefault(),
		multiplex: configMultiplexDefault(),
	}
	if _, present := object["password"]; present {
		params.password = configJSONString(object, "password")
	}
	if _, present := object["tls"]; present {
		tls, err := configTLSParse(configJSONObjectValue(object["tls"]))
		if err != nil {
			return params, err
		}
		params.tls = tls
	}
	if _, present := object["transport"]; present {
		transport, err := configTransportParse(configJSONObjectValue(object["transport"]))
		if err != nil {
			return params, err
		}
		params.transport = transport
	}
	if _, present := object["multiplex"]; present {
		multiplex, err := configMultiplexParse(configJSONObjectValue(object["multiplex"]))
		if err != nil {
			return params, err
		}
		params.multiplex = multiplex
	}
	return params, nil
}

func configBuildTrojan(out configOutbound, params configTrojanParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "trojan"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	if err := configApplyCustomFragment(object, out.profileType, params.transport.typeName, &params.tls, settings); err != nil {
		return nil, err
	}
	if params.password != "" {
		object["password"] = params.password
	}
	customFragment := configCustomFragmentApplies(out.profileType, params.transport.typeName, &params.tls, settings)
	tls, err := configTLSBuild(params.tls, settings, customFragment)
	if err != nil {
		return nil, err
	}
	if len(tls) > 0 {
		object["tls"] = configTLSForTransport(tls, params.transport.typeName)
	}
	transport, err := configTransportBuild(params.transport)
	if err != nil {
		return nil, err
	}
	if len(transport) > 0 {
		object["transport"] = transport
	}
	if multiplex := configMultiplexBuild(params.multiplex, settings); len(multiplex) > 0 {
		object["multiplex"] = multiplex
	}
	return object, nil
}

// --- hysteria / hysteria2 -----------------------------------------------------

var configHysteriaBBRProfiles = []string{"standard", "conservative", "aggressive"}

var configHysteriaObfsTypes = []string{"salamander", "gecko"}

const (
	configHysteriaV1DefaultUpMbps   = 10
	configHysteriaV1DefaultDownMbps = 50
)

// configHysteriaRealm is the hysteria2 realm block.
type configHysteriaRealm struct {
	enabled             bool
	serverURL           string
	token               string
	id                  string
	stunServers         []string
	ipVersion           int
	portMapping         bool
	portMappingTimeout  string
	portMappingLifetime string
	httpClient          map[string]any
}

type configHysteriaParams struct {
	version        int
	serverPorts    []string
	hopInterval    string
	hopIntervalMax string
	upMbps         int
	downMbps       int

	// Hysteria v1
	obfs                string
	authType            string
	auth                string
	recvWindowConn      int
	recvWindow          int
	disableMTUDiscovery bool

	// Hysteria2
	password            string
	minPacketSize       int
	maxPacketSize       int
	obfsType            string
	bbrProfile          string
	disableChromeParrot bool
	realm               configHysteriaRealm

	tls  configTLSParams
	quic configQUICParams
}

func configHysteriaHopDuration(value string) string {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return value
	}
	for index := 0; index < len(trimmed); index++ {
		if trimmed[index] < '0' || trimmed[index] > '9' {
			return value
		}
	}
	return trimmed + "s"
}

// configHysteriaPortsToPorts is portsToPorts: "a-b" and "a:b" become "a:b",
// anything else "v:v"; blank items are dropped.
func configHysteriaPortsToPorts(ports []string) []string {
	result := make([]string, 0, len(ports))
	for _, raw := range ports {
		value := strings.TrimSpace(raw)
		if value == "" {
			continue
		}
		parts := strings.FieldsFunc(value, func(r rune) bool { return r == ':' || r == '-' })
		if len(parts) == 2 {
			result = append(result, parts[0]+":"+parts[1])
		} else {
			result = append(result, value+":"+value)
		}
	}
	return result
}

// configHysteriaSpeedUnit is hysteriaSpeedUnit: only "<prefix>bps" counts bits.
func configHysteriaSpeedUnit(unit string) float64 {
	if unit == "Bps" {
		return 1
	}
	if len(unit) == 4 && strings.HasSuffix(unit, "ps") {
		prefixes := "KMGTPE"
		if index := strings.IndexByte(prefixes, unit[0]); index >= 0 {
			scale := math.Pow(1000, float64(index+1))
			if unit[1] == 'B' {
				return scale
			}
			if unit[1] == 'b' {
				return scale / 8
			}
		}
	}
	lower := strings.ToLower(unit)
	if lower == "b" {
		return 1
	}
	power := 0
	if lower != "" {
		power = strings.IndexByte("KMGTPE", byte(strings.ToUpper(lower)[0])) + 1
	}
	if power == 0 {
		return 0
	}
	rest := lower[1:]
	if rest == "" || rest == "b" {
		return math.Pow(1000, float64(power))
	}
	if rest == "i" || rest == "ib" {
		return math.Pow(1024, float64(power))
	}
	return 0
}

// configHysteriaJSONSpeedMbps is jsonSpeedMbps: a JSON number is bytes per
// second, a string is digits followed by a unit; the result is Mbps.
func configHysteriaJSONSpeedMbps(value any) (int, bool) {
	var bytesPerSecond float64
	switch typed := value.(type) {
	case float64:
		if typed < 0 || typed != math.Floor(typed) {
			return 0, false
		}
		bytesPerSecond = typed
	case string:
		digits := 0
		for digits < len(typed) && typed[digits] >= '0' && typed[digits] <= '9' {
			digits++
		}
		if digits == 0 || digits == len(typed) {
			return 0, false
		}
		number, err := strconv.ParseUint(typed[:digits], 10, 64)
		if err != nil {
			return 0, false
		}
		unit := configHysteriaSpeedUnit(strings.TrimSpace(typed[digits:]))
		if unit == 0 {
			return 0, false
		}
		bytesPerSecond = float64(number) * unit
	default:
		return 0, false
	}
	if bytesPerSecond <= 0 {
		return 0, true
	}
	mbps := bytesPerSecond / 125000
	if mbps > math.MaxInt32 {
		mbps = math.MaxInt32
	}
	rounded := int64(math.Floor(mbps + 0.5))
	if rounded < 1 {
		rounded = 1
	}
	return int(rounded), true
}

// configHysteriaAmneziaRange is amneziaRange for the hysteria realm and the
// wireguard block: a string stays, a number becomes its digits.
func configNumericRangeString(value any) string {
	if text, ok := value.(string); ok {
		return text
	}
	return strconv.FormatInt(int64(configJSONInt(value)), 10)
}

func configParseHysteria(object map[string]any, version int) (configHysteriaParams, error) {
	params := configHysteriaParams{
		version:  version,
		obfsType: "salamander",
		tls:      configTLSDefault(),
		quic:     configQUICDefault(),
	}
	// hysteria.h:52-55: uTLS is never emitted.
	params.tls.utls.supported = false
	if _, present := object["server_ports"]; present {
		params.serverPorts = configJSONStringListValue(object["server_ports"])
	}
	if _, present := object["hop_interval"]; present {
		params.hopInterval = configHysteriaHopDuration(configJSONVariantString(object["hop_interval"]))
	}
	if _, present := object["up_mbps"]; present {
		params.upMbps = configJSONInt(object["up_mbps"])
	}
	if _, present := object["down_mbps"]; present {
		params.downMbps = configJSONInt(object["down_mbps"])
	}
	if version == 1 {
		if _, present := object["up"]; present {
			if mbps, ok := configHysteriaJSONSpeedMbps(object["up"]); ok && mbps > 0 {
				params.upMbps = mbps
			}
		}
		if _, present := object["down"]; present {
			if mbps, ok := configHysteriaJSONSpeedMbps(object["down"]); ok && mbps > 0 {
				params.downMbps = mbps
			}
		}
		if _, present := object["obfs"]; present {
			params.obfs = configJSONString(object, "obfs")
		}
		if _, present := object["auth"]; present {
			params.auth = configJSONString(object, "auth")
			params.authType = "BASE64"
		}
		if _, present := object["auth_str"]; present {
			params.auth = configJSONString(object, "auth_str")
			params.authType = "STRING"
		}
		if _, present := object["recv_window_conn"]; present {
			params.recvWindowConn = configJSONInt(object["recv_window_conn"])
		}
		if _, present := object["recv_window"]; present {
			params.recvWindow = configJSONInt(object["recv_window"])
		}
		if _, present := object["disable_mtu_discovery"]; present {
			params.disableMTUDiscovery = configJSONBoolValue(object["disable_mtu_discovery"])
		}
	} else {
		if _, present := object["obfs"]; present {
			if obfs := configJSONObjectValue(object["obfs"]); obfs != nil {
				if err := configCheckKeys(obfs, configKeysAllowed("type", "password", "min_packet_size", "max_packet_size"), "obfs"); err != nil {
					return params, err
				}
				if _, present := obfs["password"]; present {
					params.obfs = configJSONString(obfs, "password")
				}
				if _, present := obfs["type"]; present {
					params.obfsType = strings.ToLower(strings.TrimSpace(configJSONString(obfs, "type")))
				} else {
					params.obfsType = "salamander"
				}
				if _, present := obfs["min_packet_size"]; present {
					params.minPacketSize = configJSONInt(obfs["min_packet_size"])
				}
				if _, present := obfs["max_packet_size"]; present {
					params.maxPacketSize = configJSONInt(obfs["max_packet_size"])
				}
			}
		}
		if _, present := object["obfsPassword"]; present {
			params.obfs = configJSONString(object, "obfsPassword")
		}
		if _, present := object["password"]; present {
			params.password = configJSONString(object, "password")
		}
		if _, present := object["hop_interval_max"]; present {
			params.hopIntervalMax = configHysteriaHopDuration(configJSONVariantString(object["hop_interval_max"]))
		}
		if _, present := object["bbr_profile"]; present {
			params.bbrProfile = strings.TrimSpace(configJSONString(object, "bbr_profile"))
		}
		if _, present := object["disable_chrome_parrot"]; present {
			params.disableChromeParrot = configJSONBoolValue(object["disable_chrome_parrot"])
		}
		if realm := configJSONObjectValue(object["realm"]); realm != nil {
			if err := configCheckKeys(realm, configKeysAllowed(
				"server_url", "token", "realm_id", "stun_servers", "ip_version", "port_mapping", "http_client",
			), "realm"); err != nil {
				return params, err
			}
			params.realm.enabled = true
			params.realm.serverURL = strings.TrimSpace(configJSONString(realm, "server_url"))
			params.realm.token = configJSONString(realm, "token")
			params.realm.id = configJSONString(realm, "realm_id")
			if items, ok := realm["stun_servers"].([]any); ok {
				servers := make([]string, 0, len(items))
				for _, item := range items {
					text, _ := item.(string)
					servers = append(servers, text)
				}
				params.realm.stunServers = servers
			} else if _, present := realm["stun_servers"]; present {
				params.realm.stunServers = []string{configJSONString(realm, "stun_servers")}
			}
			for index := range params.realm.stunServers {
				params.realm.stunServers[index] = strings.TrimSpace(params.realm.stunServers[index])
			}
			if _, present := realm["ip_version"]; present {
				params.realm.ipVersion = configJSONInt(realm["ip_version"])
			}
			if portMapping := configJSONObjectValue(realm["port_mapping"]); portMapping != nil {
				if err := configCheckKeys(portMapping, configKeysAllowed("enabled", "timeout", "lifetime"), "realm.port_mapping"); err != nil {
					return params, err
				}
				params.realm.portMapping = configJSONBoolValue(portMapping["enabled"])
				params.realm.portMappingTimeout = strings.TrimSpace(configJSONString(portMapping, "timeout"))
				params.realm.portMappingLifetime = strings.TrimSpace(configJSONString(portMapping, "lifetime"))
			}
			if httpClient := configJSONObjectValue(realm["http_client"]); httpClient != nil {
				params.realm.httpClient = configCopyJSONValue(httpClient).(map[string]any)
			}
		}
	}
	if _, present := object["tls"]; present {
		tls, err := configTLSParse(configJSONObjectValue(object["tls"]))
		if err != nil {
			return params, err
		}
		tls.utls.supported = false
		params.tls = tls
	}
	quic, err := configQUICParse(object)
	if err != nil {
		return params, err
	}
	params.quic = quic
	return params, nil
}

// realmActive is Hysteria.realmActive.
func (params configHysteriaParams) realmActive() bool {
	return params.realm.enabled && params.version == 2
}

func configHysteriaRealmBuild(realm configHysteriaRealm) map[string]any {
	object := map[string]any{}
	object["server_url"] = realm.serverURL
	if realm.token != "" {
		object["token"] = realm.token
	}
	object["realm_id"] = realm.id
	if len(realm.stunServers) > 0 {
		object["stun_servers"] = configNonBlankStrings(realm.stunServers)
	}
	if realm.ipVersion == 4 || realm.ipVersion == 6 {
		object["ip_version"] = realm.ipVersion
	}
	// Hole punching over IPv6 has no gateway mapping to make; the core rejects the pair.
	if realm.portMapping && realm.ipVersion != 6 {
		portMapping := map[string]any{"enabled": true}
		if realm.portMappingTimeout != "" {
			portMapping["timeout"] = realm.portMappingTimeout
		}
		if realm.portMappingLifetime != "" {
			portMapping["lifetime"] = realm.portMappingLifetime
		}
		object["port_mapping"] = portMapping
	}
	if len(realm.httpClient) > 0 {
		object["http_client"] = configCopyJSONValue(realm.httpClient)
	}
	return object
}

func configBuildHysteria(out configOutbound, params configHysteriaParams, settings simpleConfigSettings) (map[string]any, error) {
	if params.version == 1 {
		return configBuildHysteriaV1(out, params, settings)
	}
	return configBuildHysteriaV2(out, params, settings)
}

func configBuildHysteriaV1(out configOutbound, params configHysteriaParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "hysteria"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	if len(params.serverPorts) > 0 {
		object["server_ports"] = configNonBlankStrings(configHysteriaPortsToPorts(params.serverPorts))
	}
	if params.hopInterval != "" {
		object["hop_interval"] = params.hopInterval
	}
	if params.upMbps > 0 {
		object["up_mbps"] = params.upMbps
	} else {
		object["up_mbps"] = configHysteriaV1DefaultUpMbps
	}
	if params.downMbps > 0 {
		object["down_mbps"] = params.downMbps
	} else {
		object["down_mbps"] = configHysteriaV1DefaultDownMbps
	}
	if params.obfs != "" {
		object["obfs"] = params.obfs
	}
	if params.auth != "" {
		if params.authType == "BASE64" {
			object["auth"] = params.auth
		}
		if params.authType == "STRING" {
			object["auth_str"] = params.auth
		}
	}
	if params.recvWindowConn > 0 {
		object["recv_window_conn"] = params.recvWindowConn
	}
	if params.recvWindow > 0 {
		object["recv_window"] = params.recvWindow
	}
	if params.disableMTUDiscovery {
		object["disable_mtu_discovery"] = true
	}
	tls, err := configTLSBuild(params.tls, settings, false)
	if err != nil {
		return nil, err
	}
	object["tls"] = tls
	for key, value := range configQUICBuild(params.quic, settings) {
		object[key] = value
	}
	return object, nil
}

func configBuildHysteriaV2(out configOutbound, params configHysteriaParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "hysteria2"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	realm := params.realmActive()
	if len(params.serverPorts) > 0 {
		object["server_ports"] = configNonBlankStrings(configHysteriaPortsToPorts(params.serverPorts))
	}
	if params.hopInterval != "" && !realm {
		object["hop_interval"] = params.hopInterval
	}
	if params.upMbps > 0 {
		object["up_mbps"] = params.upMbps
	}
	if params.downMbps > 0 {
		object["down_mbps"] = params.downMbps
	}
	if params.obfs != "" {
		obfsType := strings.ToLower(strings.TrimSpace(params.obfsType))
		switch obfsType {
		case "salamander":
			object["obfs"] = map[string]any{"type": obfsType, "password": params.obfs}
		case "gecko":
			object["obfs"] = map[string]any{
				"type": obfsType, "password": params.obfs,
				"min_packet_size": params.minPacketSize, "max_packet_size": params.maxPacketSize,
			}
		default:
			object["obfs"] = map[string]any{"type": "salamander", "password": params.obfs}
		}
	}
	if params.password != "" {
		object["password"] = params.password
	}
	// sing-box randomizes the hop interval within [hop_interval, hop_interval_max];
	// it rejects a max without a min.
	if params.hopIntervalMax != "" && params.hopInterval != "" && !realm {
		object["hop_interval_max"] = params.hopIntervalMax
	}
	if configStringInList(params.bbrProfile, configHysteriaBBRProfiles) {
		object["bbr_profile"] = params.bbrProfile
	}
	if params.disableChromeParrot {
		object["disable_chrome_parrot"] = true
	}
	if realm {
		delete(object, "server")
		delete(object, "server_port")
		delete(object, "server_ports")
		object["realm"] = configHysteriaRealmBuild(params.realm)
	}
	tls, err := configTLSBuild(params.tls, settings, false)
	if err != nil {
		return nil, err
	}
	object["tls"] = tls
	for key, value := range configQUICBuild(params.quic, settings) {
		object[key] = value
	}
	return object, nil
}

func configStringInList(value string, list []string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}

// --- wireguard ----------------------------------------------------------------

type configWireGuardPeer struct {
	address             string
	port                int
	publicKey           string
	preSharedKey        string
	reserved            []int
	persistentKeepalive string
}

type configWireGuardParams struct {
	privateKey  string
	address     []string
	mtu         int
	system      bool
	workerCount int
	udpTimeout  string
	peer        configWireGuardPeer
	amnezia     configWireGuardAmnezia
}

type configWireGuardAmnezia struct {
	enabled                bool
	jc                     int
	jmin                   int
	jmax                   int
	s1                     int
	s2                     int
	s3                     int
	s4                     int
	h1                     string
	h2                     string
	h3                     string
	h4                     string
	i1                     string
	i2                     string
	i3                     string
	i4                     string
	i5                     string
	headerProtectionKey    string
	contentPaddingAddition string
	rekeyAfterTime         string
	rekeyTimeout           string
	rejectAfterTime        string
	keepaliveTimeout       string
	maxHandshakeAttempts   string
	randomTrailers         bool
	disableCookies         bool
}

func configParseWireGuardPeer(object map[string]any) (configWireGuardPeer, error) {
	peer := configWireGuardPeer{}
	if object == nil {
		return peer, nil
	}
	if err := configCheckKeys(object, configKeysAllowed(
		"address", "port", "public_key", "pre_shared_key", "reserved", "persistent_keepalive_interval",
	), "peers[0]"); err != nil {
		return peer, err
	}
	if _, present := object["address"]; present {
		peer.address = configJSONString(object, "address")
	}
	if _, present := object["port"]; present {
		peer.port = configJSONInt(object["port"])
	}
	if _, present := object["public_key"]; present {
		peer.publicKey = configJSONString(object, "public_key")
	}
	if _, present := object["pre_shared_key"]; present {
		peer.preSharedKey = configJSONString(object, "pre_shared_key")
	}
	if reserved, present := object["reserved"]; present {
		if text, isString := reserved.(string); isString {
			// Go decodes a JSON string into []uint8 as base64; a valid 3-byte
			// base64 value is not decoded by the Kotlin loader, which drops it.
			if !configBase64KeyValid(text, 3) {
				decoded := configBase64Lenient(text, false)
				peer.reserved = make([]int, 0, len(decoded))
				for _, value := range decoded {
					peer.reserved = append(peer.reserved, int(value))
				}
			}
		} else if items, isArray := reserved.([]any); isArray {
			peer.reserved = make([]int, 0, len(items))
			for _, item := range items {
				peer.reserved = append(peer.reserved, configJSONInt(item))
			}
		}
	}
	if _, present := object["persistent_keepalive_interval"]; present {
		if text, ok := object["persistent_keepalive_interval"].(string); ok {
			peer.persistentKeepalive = text
		} else {
			peer.persistentKeepalive = strconv.Itoa(configJSONInt(object["persistent_keepalive_interval"]))
		}
	}
	return peer, nil
}

func configParseAmneziaBlock(object map[string]any) (configWireGuardAmnezia, error) {
	amnezia := configWireGuardAmnezia{}
	if object == nil {
		return amnezia, nil
	}
	if err := configCheckKeys(object, configKeysAllowed(
		"jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5",
		"header_protection_key", "content_padding_addition", "rekey_after_time", "rekey_timeout",
		"reject_after_time", "keepalive_timeout", "max_handshake_attempts", "random_trailers", "disable_cookies",
	), "amnezia_wg"); err != nil {
		return amnezia, err
	}
	amnezia.enabled = len(object) > 0
	intKeys := map[string]*int{
		"jc": &amnezia.jc, "jmin": &amnezia.jmin, "jmax": &amnezia.jmax,
		"s1": &amnezia.s1, "s2": &amnezia.s2, "s3": &amnezia.s3, "s4": &amnezia.s4,
	}
	for key, target := range intKeys {
		if _, present := object[key]; present {
			*target = configJSONInt(object[key])
		}
	}
	stringKeys := map[string]*string{
		"h1": &amnezia.h1, "h2": &amnezia.h2, "h3": &amnezia.h3, "h4": &amnezia.h4,
		"i1": &amnezia.i1, "i2": &amnezia.i2, "i3": &amnezia.i3, "i4": &amnezia.i4, "i5": &amnezia.i5,
	}
	for key, target := range stringKeys {
		if _, present := object[key]; present {
			*target = strings.TrimSpace(configJSONString(object, key))
		}
	}
	if _, present := object["header_protection_key"]; present {
		amnezia.headerProtectionKey = configJSONString(object, "header_protection_key")
	}
	for key, target := range map[string]*string{
		"content_padding_addition": &amnezia.contentPaddingAddition,
		"rekey_after_time":         &amnezia.rekeyAfterTime,
		"rekey_timeout":            &amnezia.rekeyTimeout,
		"reject_after_time":        &amnezia.rejectAfterTime,
		"keepalive_timeout":        &amnezia.keepaliveTimeout,
		"max_handshake_attempts":   &amnezia.maxHandshakeAttempts,
	} {
		if _, present := object[key]; present {
			*target = configNumericRangeString(object[key])
		}
	}
	if _, present := object["random_trailers"]; present {
		amnezia.randomTrailers = configJSONBoolValue(object["random_trailers"])
	}
	if _, present := object["disable_cookies"]; present {
		amnezia.disableCookies = configJSONBoolValue(object["disable_cookies"])
	}
	return amnezia, nil
}

func configParseWireGuard(object map[string]any) (configWireGuardParams, error) {
	params := configWireGuardParams{mtu: 1420}
	if _, present := object["private_key"]; present {
		params.privateKey = configJSONString(object, "private_key")
	}
	if peers, ok := object["peers"].([]any); ok {
		if len(peers) > 0 {
			peer, err := configParseWireGuardPeer(configJSONObjectValue(peers[0]))
			if err != nil {
				return params, err
			}
			params.peer = peer
		}
	}
	if _, present := object["address"]; present {
		params.address = configJSONStringListValue(object["address"])
	}
	if _, present := object["mtu"]; present {
		params.mtu = configJSONInt(object["mtu"])
	}
	if _, present := object["system"]; present {
		params.system = configJSONBoolValue(object["system"])
	}
	if _, present := object["workers"]; present {
		params.workerCount = configJSONInt(object["workers"])
	} else if _, present := object["worker_count"]; present {
		params.workerCount = configJSONInt(object["worker_count"])
	}
	if _, present := object["udp_timeout"]; present {
		params.udpTimeout = strings.TrimSpace(configJSONString(object, "udp_timeout"))
	}
	if amnezia := configJSONObjectValue(object["amnezia_wg"]); amnezia != nil {
		parsed, err := configParseAmneziaBlock(amnezia)
		if err != nil {
			return params, err
		}
		params.amnezia = parsed
	}
	params.address = configWireGuardFixAddress(params.address)
	return params, nil
}

// configWireGuardFixAddress is FixAddress: bare IPs get /32 or /128, empty
// items are dropped.
func configWireGuardFixAddress(addresses []string) []string {
	fixed := make([]string, 0, len(addresses))
	for _, address := range addresses {
		trimmed := strings.TrimSpace(address)
		if trimmed == "" {
			continue
		}
		if !strings.Contains(trimmed, "/") {
			if strings.Contains(trimmed, ":") {
				trimmed += "/128"
			} else {
				trimmed += "/32"
			}
		}
		fixed = append(fixed, trimmed)
	}
	return fixed
}

// configWireGuardKeepaliveJSON is Peer::WriteKeepalive: a range stays a string,
// a plain interval a number; anything else is dropped.
func configWireGuardWriteKeepalive(object map[string]any, keepalive string) {
	if keepalive == "" {
		return
	}
	if seconds, ok := configQtToIntOrNull(keepalive); ok {
		if seconds > 0 {
			object["persistent_keepalive_interval"] = seconds
		}
		return
	}
	if configWireGuardKeepaliveRange(keepalive) {
		object["persistent_keepalive_interval"] = keepalive
	}
}

func configWireGuardKeepaliveRange(text string) bool {
	dash := strings.IndexByte(text, '-')
	if dash <= 0 || dash == len(text)-1 {
		return false
	}
	for index := 0; index < len(text); index++ {
		if index == dash {
			continue
		}
		if text[index] < '0' || text[index] > '9' {
			return false
		}
	}
	return true
}

func configBuildWireGuardPeer(peer configWireGuardPeer) map[string]any {
	object := map[string]any{}
	if peer.address != "" {
		object["address"] = peer.address
	}
	if peer.port > 0 {
		object["port"] = peer.port
	}
	if peer.publicKey != "" {
		object["public_key"] = peer.publicKey
	}
	if peer.preSharedKey != "" {
		object["pre_shared_key"] = peer.preSharedKey
	}
	if len(peer.reserved) > 0 {
		items := make([]any, 0, len(peer.reserved))
		for _, value := range peer.reserved {
			items = append(items, value)
		}
		object["reserved"] = items
	}
	configWireGuardWriteKeepalive(object, peer.persistentKeepalive)
	object["allowed_ips"] = []any{"0.0.0.0/0", "::/0"}
	return object
}

// configWireGuardAmneziaBuild is AmneziaToJson.
func configWireGuardAmneziaBuild(amnezia configWireGuardAmnezia) map[string]any {
	object := map[string]any{}
	if !amnezia.enabled {
		return object
	}
	for key, value := range map[string]int{
		"jc": amnezia.jc, "jmin": amnezia.jmin, "jmax": amnezia.jmax,
		"s1": amnezia.s1, "s2": amnezia.s2, "s3": amnezia.s3, "s4": amnezia.s4,
	} {
		if value > 0 {
			object[key] = value
		}
	}
	for key, value := range map[string]string{
		"h1": amnezia.h1, "h2": amnezia.h2, "h3": amnezia.h3, "h4": amnezia.h4,
		"i1": amnezia.i1, "i2": amnezia.i2, "i3": amnezia.i3, "i4": amnezia.i4, "i5": amnezia.i5,
		"header_protection_key":    amnezia.headerProtectionKey,
		"content_padding_addition": amnezia.contentPaddingAddition,
		"rekey_after_time":         amnezia.rekeyAfterTime, "rekey_timeout": amnezia.rekeyTimeout,
		"reject_after_time": amnezia.rejectAfterTime, "keepalive_timeout": amnezia.keepaliveTimeout,
		"max_handshake_attempts": amnezia.maxHandshakeAttempts,
	} {
		if value != "" {
			object[key] = value
		}
	}
	if amnezia.randomTrailers {
		object["random_trailers"] = true
	}
	if amnezia.disableCookies {
		object["disable_cookies"] = true
	}
	return object
}

func configBuildWireGuard(out configOutbound, params configWireGuardParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "wireguard"}
	if out.name != "" {
		object["tag"] = out.name
	}
	for key, value := range configDialFieldsBuild(out.dial) {
		object[key] = value
	}
	if params.privateKey != "" {
		object["private_key"] = params.privateKey
	}
	if len(params.address) > 0 {
		object["address"] = configNonBlankStrings(params.address)
	}
	if params.mtu > 0 {
		object["mtu"] = params.mtu
	}
	if params.system {
		object["system"] = true
	}
	if params.workerCount > 0 {
		object["workers"] = params.workerCount
	}
	if params.udpTimeout != "" {
		object["udp_timeout"] = params.udpTimeout
	}
	if amnezia := configWireGuardAmneziaBuild(params.amnezia); len(amnezia) > 0 {
		object["amnezia_wg"] = amnezia
	}
	object["peers"] = []any{configBuildWireGuardPeer(params.peer)}
	return object, nil
}
