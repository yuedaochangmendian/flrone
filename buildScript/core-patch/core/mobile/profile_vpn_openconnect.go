// OpenConnect stored codec and profile parser (S5 slice: OpenVPN/OpenConnect).
//
// Oracle: app/src/main/java/io/nekohasekai/sagernet/outbound/types/OpenConnect.kt
// (the model, parseFromJson / exportToJson, OpenConnectChecks and the OcImport
// half of vpnFileImport.cpp) plus outbound/Outbound.kt and common/DialFields.kt.
// The JVM test OpenVpnGoParityTest pins the bytes this file has to emit.
//
// OpenConnect is a kernel *endpoint*: the core takes a single HTTPS URL, which
// the stored row keeps split into `server`, `server_port` and `server_path`
// (setServerUrl / composeServer). It has no share link (Outbound.exportToLink
// has no override, so the link is the dial-field query string) and no Clash
// mapping in Kotlin; `openconnect://` and `type: openconnect` in Clash are
// refused with that reason.
//
// The profile form is an AnyConnect XML file, an `openconnect ...` command line
// or a config file of `option[=value]` lines.
package mobile

import (
	"encoding/xml"
	"io"
	"strconv"
	"strings"
)

// profileOpenConnectDefaultPort is kOpenConnectDefaultPort.
const profileOpenConnectDefaultPort = 443

// --- nested stored structures ----------------------------------------------

type profileOpenConnectToken struct {
	Mode       string
	Secret     string
	SecretPath string
	Pin        string
	Password   string
	DeviceID   string
	Counter    int64
}

type profileOpenConnectMobile struct {
	PlatformVersion string
	DeviceType      string
	DeviceUniqueID  string
}

type profileOpenConnectWrapper struct {
	WrapperPath string
}

type profileOpenConnectTNCCCertificate struct {
	Certificate     []string
	CertificatePath string
}

type profileOpenConnectTNCC struct {
	WrapperPath                  string
	DeviceID                     string
	UserAgent                    string
	MachineIdentificationEnabled bool
	Certificates                 []profileOpenConnectTNCCCertificate
}

type profileOpenConnectFortinetHostCheck struct {
	HostCheck           string
	CheckVirtualDesktop string
}

type profileOpenConnectFormEntry struct {
	FormID        string
	SubmissionKey string
	Name          string
	Value         string
	Promote       bool
}

// profileOpenConnectTLS is OpenConnectTls (the endpoint's own TLS block).
type profileOpenConnectTLS struct {
	Insecure                 bool
	ServerName               string
	PeerFingerprint          []string
	SystemTrustDisabled      bool
	CertificateAuthority     []string
	CertificateAuthorityPath string
	ClientCertificate        []string
	ClientCertificatePath    string
	ClientKey                []string
	ClientKeyPath            string
	ClientKeyPassword        string
	MCACertificate           []string
	MCACertificatePath       string
	MCAKey                   []string
	MCAKeyPath               string
	MCAKeyPassword           string
}

// profileOpenConnect is the stored OpenConnect profile with the Kotlin model's
// defaults (only_advertised_routes true, tunnel_dns "prefer", otp_profile_id
// -1).
type profileOpenConnect struct {
	Type   string
	Name   string
	Server string
	Port   int
	Dial   map[string]any

	Flavor               string
	Username             string
	Password             string
	AuthGroup            string
	ServerPath           string
	MTU                  int
	TLS                  profileOpenConnectTLS
	OTPProfileID         int
	OnlyAdvertisedRoutes bool
	TunnelDNS            string

	Cookie                string
	Token                 profileOpenConnectToken
	ReportedOS            string
	UserAgent             string
	Version               string
	LocalHostname         string
	Mobile                profileOpenConnectMobile
	CSD                   profileOpenConnectWrapper
	HIP                   profileOpenConnectWrapper
	TNCC                  profileOpenConnectTNCC
	FortinetHostCheck     profileOpenConnectFortinetHostCheck
	FormEntries           []profileOpenConnectFormEntry
	NoUDP                 bool
	DTLSLocalPort         int
	CompressionDisabled   bool
	CompressionMode       string
	IPv6Disabled          bool
	HTTPKeepaliveDisabled bool
	XMLPostDisabled       bool
	ExternalAuthDisabled  bool
	PasswordAuthDisabled  bool
	TCPKeepAliveEnabled   bool
	PFS                   bool
	BaseMTU               int
	DPDInterval           string
	ReconnectTimeout      string
	TrojanInterval        string
	QueueLength           int
	AllowInsecureCrypto   bool
	System                bool
	InterfaceName         string
	UDPTimeout            string
	UDPMapping            string
	UDPFiltering          string
	UDPNATMax             int
}

var profileOpenConnectFieldKeys = map[string]bool{
	"type": true, "tag": true, "server": true, "server_port": true,
	"reuse_addr": true, "connect_timeout": true, "tcp_fast_open": true,
	"tcp_multi_path": true, "udp_fragment": true, "bind_interface": true,
	"inet4_bind_address": true, "inet6_bind_address": true,
	"server_path": true, "flavor": true, "username": true, "password": true,
	"auth_group": true, "cookie": true, "token": true, "reported_os": true,
	"user_agent": true, "version": true, "local_hostname": true, "mobile": true,
	"csd": true, "hip": true, "tncc": true, "fortinet_host_check": true,
	"form_entries": true, "no_udp": true, "dtls_local_port": true,
	"compression_disabled": true, "compression_mode": true, "ipv6_disabled": true,
	"http_keepalive_disabled": true, "xml_post_disabled": true,
	"external_auth_disabled": true, "password_authentication_disabled": true,
	"tcp_keep_alive_enabled": true, "pfs": true, "mtu": true, "base_mtu": true,
	"dpd_interval": true, "reconnect_timeout": true, "trojan_interval": true,
	"queue_length": true, "allow_insecure_crypto": true, "tls": true, "system": true,
	"name": true, "udp_timeout": true, "udp_mapping": true, "udp_filtering": true,
	"udp_nat_max": true, "otp_profile_id": true, "only_advertised_routes": true,
	"tunnel_dns": true, "block_outside_dns": true, "use_tunnel_dns": true,
}

var profileOpenConnectTLSKeys = map[string]bool{
	"insecure": true, "server_name": true, "peer_fingerprint": true,
	"system_trust_disabled": true, "certificate_authority": true,
	"certificate_authority_path": true, "client_certificate": true,
	"client_certificate_path": true, "client_key": true, "client_key_path": true,
	"client_key_password": true, "mca_certificate": true,
	"mca_certificate_path": true, "mca_key": true, "mca_key_path": true,
	"mca_key_password": true,
}

var profileOpenConnectTokenKeys = map[string]bool{
	"mode": true, "secret": true, "secret_path": true, "pin": true,
	"password": true, "device_id": true, "counter": true,
}

var profileOpenConnectMobileKeys = map[string]bool{
	"platform_version": true, "device_type": true, "device_unique_id": true,
}

var profileOpenConnectWrapperKeys = map[string]bool{"wrapper_path": true}

var profileOpenConnectTNCCKeys = map[string]bool{
	"wrapper_path": true, "device_id": true, "user_agent": true,
	"machine_identification_enabled": true, "certificates": true,
}

var profileOpenConnectTNCCCertificateKeys = map[string]bool{
	"certificate": true, "certificate_path": true,
}

var profileOpenConnectFortinetKeys = map[string]bool{
	"hostcheck": true, "check_virtual_desktop": true,
}

var profileOpenConnectFormEntryKeys = map[string]bool{
	"form_id": true, "submission_key": true, "name": true, "value": true,
	"promote": true,
}

func newProfileOpenConnect() *profileOpenConnect {
	return &profileOpenConnect{
		Type: "openconnect", OTPProfileID: -1, OnlyAdvertisedRoutes: true,
		TunnelDNS: "prefer", Dial: map[string]any{},
	}
}

// profileOpenConnectStoredChecked is ocReadChecked: the trimmed string, kept
// during an import only when the rule accepts it.
func profileOpenConnectStoredChecked(object map[string]any, key string, importing bool, rule func(string) bool) (string, bool, error) {
	value, present, err := profileVpnStoredString(object, key, "openconnect")
	if err != nil {
		return "", false, err
	}
	if !present {
		return "", false, nil
	}
	trimmed := profileVpnTrimmed(value)
	if importing && !rule(trimmed) {
		return "", false, nil
	}
	return trimmed, true, nil
}

// profileOpenConnectStoredCheckedInt is ocReadCheckedInt.
func profileOpenConnectStoredCheckedInt(object map[string]any, key string, importing bool, rule func(string) bool) (int, bool, error) {
	value, present, err := profileVpnStoredNumber(object, key, "openconnect", true)
	if err != nil {
		return 0, false, err
	}
	if !present {
		return 0, false, nil
	}
	text := strconv.Itoa(int(value))
	if importing && !rule(text) {
		return 0, false, nil
	}
	return int(value), true, nil
}

// profileOpenConnectParseStored is OpenConnect.parseFromJson.
func profileOpenConnectParseStored(object map[string]any, mode profileNewMode) (*profileOpenConnect, []string, error) {
	importing := mode == profileNewImportMode
	if configJSONString(object, "type") != "openconnect" {
		return nil, nil, profileUnsupported("stored document is not openconnect")
	}
	model := newProfileOpenConnect()
	var unknown []string
	for key := range object {
		if !profileOpenConnectFieldKeys[key] {
			unknown = append(unknown, key)
		}
	}

	if value, present, err := profileVpnStoredString(object, "tag", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.Name = value
	}
	if value, present, err := profileVpnStoredString(object, "server", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		// super.parseFromJson runs first: Hosts.toAceHost keeps an ASCII host as
		// written, then setServerUrl below normalises it through QUrl.
		model.Server = aceShareHost(value)
	}
	if value, present, err := profileVpnStoredNumber(object, "server_port", "openconnect", true); err != nil {
		return nil, nil, err
	} else if present {
		model.Port = int(value)
	}
	dial, err := profileVpnDialFields(object, "openconnect", importing)
	if err != nil {
		return nil, nil, err
	}
	model.Dial = dial

	// The core takes a single URL: parseFromJson runs setServerUrl over the
	// stored `server`, so the stored port survives only when the URL carries
	// none, and the URL path fills server_path.
	if value, present, err := profileVpnStoredString(object, "server", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		if err := profileOpenConnectSetServerURL(model, value); err != nil {
			return nil, nil, err
		}
	}
	if value, present, err := profileVpnStoredString(object, "server_path", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.ServerPath = value
	}

	if value, present, err := profileVpnStoredString(object, "flavor", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.Flavor = profileVpnTrimmed(value)
	}
	if value, present, err := profileVpnStoredString(object, "username", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.Username = value
	}
	if value, present, err := profileVpnStoredString(object, "password", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.Password = value
	}
	if value, present, err := profileVpnStoredString(object, "auth_group", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.AuthGroup = value
	}
	if value, present, err := profileVpnStoredString(object, "cookie", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.Cookie = value
	}
	if value, present := object["token"]; present {
		block, ok := value.(map[string]any)
		if !ok {
			return nil, nil, profileUnsupported("stored openconnect token is not an object")
		}
		token, tokenUnknown, err := profileOpenConnectParseToken(block)
		if err != nil {
			return nil, nil, err
		}
		model.Token = token
		unknown = append(unknown, tokenUnknown...)
	}
	if value, present, err := profileOpenConnectStoredChecked(object, "reported_os", importing, func(item string) bool {
		return profileOpenConnectReportedOSMessage(model.Flavor, item) == ""
	}); err != nil {
		return nil, nil, err
	} else if present {
		model.ReportedOS = value
	}
	if value, present, err := profileVpnStoredString(object, "user_agent", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.UserAgent = value
	}
	if value, present, err := profileVpnStoredString(object, "version", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.Version = value
	}
	if value, present, err := profileVpnStoredString(object, "local_hostname", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.LocalHostname = value
	}
	if value, present := object["mobile"]; present {
		block, ok := value.(map[string]any)
		if !ok {
			return nil, nil, profileUnsupported("stored openconnect mobile is not an object")
		}
		mobile, mobileUnknown, err := profileOpenConnectParseMobile(block)
		if err != nil {
			return nil, nil, err
		}
		model.Mobile = mobile
		unknown = append(unknown, mobileUnknown...)
	}
	for _, name := range []string{"csd", "hip"} {
		value, present := object[name]
		if !present {
			continue
		}
		block, ok := value.(map[string]any)
		if !ok {
			return nil, nil, profileUnsupported("stored openconnect " + name + " is not an object")
		}
		wrapper, wrapperUnknown, err := profileOpenConnectParseWrapper(block, name)
		if err != nil {
			return nil, nil, err
		}
		if name == "csd" {
			model.CSD = wrapper
		} else {
			model.HIP = wrapper
		}
		unknown = append(unknown, wrapperUnknown...)
	}
	if value, present := object["tncc"]; present {
		block, ok := value.(map[string]any)
		if !ok {
			return nil, nil, profileUnsupported("stored openconnect tncc is not an object")
		}
		tncc, tnccUnknown, err := profileOpenConnectParseTNCC(block)
		if err != nil {
			return nil, nil, err
		}
		model.TNCC = tncc
		unknown = append(unknown, tnccUnknown...)
	}
	if value, present := object["fortinet_host_check"]; present {
		block, ok := value.(map[string]any)
		if !ok {
			return nil, nil, profileUnsupported("stored openconnect fortinet_host_check is not an object")
		}
		fortinet, fortinetUnknown, err := profileOpenConnectParseFortinet(block)
		if err != nil {
			return nil, nil, err
		}
		model.FortinetHostCheck = fortinet
		unknown = append(unknown, fortinetUnknown...)
	}
	if value, present, err := profileVpnStoredBool(object, "no_udp", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.NoUDP = value
	}
	if value, present, err := profileOpenConnectStoredCheckedInt(object, "dtls_local_port", importing, func(item string) bool {
		return item == "0" || profileVpnPortMessage(item) == ""
	}); err != nil {
		return nil, nil, err
	} else if present {
		model.DTLSLocalPort = value
	}
	if value, present, err := profileVpnStoredBool(object, "compression_disabled", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.CompressionDisabled = value
	}
	if value, present, err := profileOpenConnectStoredChecked(object, "compression_mode", importing, func(item string) bool {
		return profileNewOneOf(item, profileOpenConnectCompressionModes, false)
	}); err != nil {
		return nil, nil, err
	} else if present {
		model.CompressionMode = value
	}
	for _, key := range []string{
		"ipv6_disabled", "http_keepalive_disabled", "xml_post_disabled",
		"external_auth_disabled", "password_authentication_disabled",
		"tcp_keep_alive_enabled", "pfs", "allow_insecure_crypto", "system",
	} {
		value, present, err := profileVpnStoredBool(object, key, "openconnect")
		if err != nil {
			return nil, nil, err
		}
		if !present {
			continue
		}
		switch key {
		case "ipv6_disabled":
			model.IPv6Disabled = value
		case "http_keepalive_disabled":
			model.HTTPKeepaliveDisabled = value
		case "xml_post_disabled":
			model.XMLPostDisabled = value
		case "external_auth_disabled":
			model.ExternalAuthDisabled = value
		case "password_authentication_disabled":
			model.PasswordAuthDisabled = value
		case "tcp_keep_alive_enabled":
			model.TCPKeepAliveEnabled = value
		case "pfs":
			model.PFS = value
		case "allow_insecure_crypto":
			model.AllowInsecureCrypto = value
		case "system":
			model.System = value
		}
	}
	if value, present, err := profileOpenConnectStoredCheckedInt(object, "mtu", importing, func(item string) bool {
		return profileVpnIntMessage(item, 0, 65535) == ""
	}); err != nil {
		return nil, nil, err
	} else if present {
		model.MTU = value
	}
	if value, present, err := profileOpenConnectStoredCheckedInt(object, "base_mtu", importing, func(item string) bool {
		return profileVpnIntMessage(item, 0, 65535) == ""
	}); err != nil {
		return nil, nil, err
	} else if present {
		model.BaseMTU = value
	}
	for _, key := range []string{"dpd_interval", "reconnect_timeout", "trojan_interval", "udp_timeout"} {
		value, present, err := profileOpenConnectStoredChecked(object, key, importing, func(item string) bool {
			return profileVpnDurationMessage(item, false, false, -1) == ""
		})
		if err != nil {
			return nil, nil, err
		}
		if !present {
			continue
		}
		switch key {
		case "dpd_interval":
			model.DPDInterval = value
		case "reconnect_timeout":
			model.ReconnectTimeout = value
		case "trojan_interval":
			model.TrojanInterval = value
		case "udp_timeout":
			model.UDPTimeout = value
		}
	}
	if value, present, err := profileVpnStoredNumber(object, "queue_length", "openconnect", true); err != nil {
		return nil, nil, err
	} else if present {
		model.QueueLength = int(value)
	}
	if value, present := object["tls"]; present {
		block, ok := value.(map[string]any)
		if !ok {
			return nil, nil, profileUnsupported("stored openconnect tls block is not an object")
		}
		tls, tlsUnknown, err := profileOpenConnectParseTLS(block)
		if err != nil {
			return nil, nil, err
		}
		model.TLS = tls
		unknown = append(unknown, tlsUnknown...)
	}
	if value, present := object["form_entries"]; present {
		items, ok := value.([]any)
		if !ok {
			return nil, nil, profileUnsupported("stored openconnect form_entries is not an array")
		}
		model.FormEntries = nil
		for _, item := range items {
			entry, ok := item.(map[string]any)
			if !ok || len(entry) == 0 {
				continue
			}
			for key := range entry {
				if !profileOpenConnectFormEntryKeys[key] {
					unknown = append(unknown, "form_entries."+key)
				}
			}
			parsed := profileOpenConnectFormEntry{}
			if value, present, err := profileVpnStoredString(entry, "form_id", "openconnect"); err != nil {
				return nil, nil, err
			} else if present {
				parsed.FormID = value
			}
			if value, present, err := profileVpnStoredString(entry, "submission_key", "openconnect"); err != nil {
				return nil, nil, err
			} else if present {
				parsed.SubmissionKey = value
			}
			if value, present, err := profileVpnStoredString(entry, "name", "openconnect"); err != nil {
				return nil, nil, err
			} else if present {
				parsed.Name = value
			}
			if value, present, err := profileVpnStoredString(entry, "value", "openconnect"); err != nil {
				return nil, nil, err
			} else if present {
				parsed.Value = value
			}
			if value, present, err := profileVpnStoredBool(entry, "promote", "openconnect"); err != nil {
				return nil, nil, err
			} else if present {
				parsed.Promote = value
			}
			model.FormEntries = append(model.FormEntries, parsed)
		}
	}
	if value, present, err := profileVpnStoredString(object, "name", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.InterfaceName = value
	}
	if value, present, err := profileVpnStoredString(object, "udp_mapping", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.UDPMapping = value
	}
	if value, present, err := profileVpnStoredString(object, "udp_filtering", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.UDPFiltering = value
	}
	if value, present, err := profileVpnStoredNumber(object, "udp_nat_max", "openconnect", true); err != nil {
		return nil, nil, err
	} else if present {
		model.UDPNATMax = int(value)
	}
	if value, present, err := profileVpnStoredNumber(object, "otp_profile_id", "openconnect", true); err != nil {
		return nil, nil, err
	} else if present {
		model.OTPProfileID = int(value)
	}
	if value, present, err := profileVpnStoredBool(object, "only_advertised_routes", "openconnect"); err != nil {
		return nil, nil, err
	} else if present {
		model.OnlyAdvertisedRoutes = value
	}
	if _, present := object["tunnel_dns"]; present {
		value, _, err := profileVpnStoredString(object, "tunnel_dns", "openconnect")
		if err != nil {
			return nil, nil, err
		}
		model.TunnelDNS = value
	} else if blockOutside, present, err := profileVpnStoredBool(object, "block_outside_dns", "openconnect"); err != nil {
		return nil, nil, err
	} else if present && blockOutside {
		model.TunnelDNS = "strict"
	} else if useTunnel, present, err := profileVpnStoredBool(object, "use_tunnel_dns", "openconnect"); err != nil {
		return nil, nil, err
	} else if present && !useTunnel {
		model.TunnelDNS = "none"
	}
	return model, unknown, nil
}

func profileOpenConnectParseToken(block map[string]any) (profileOpenConnectToken, []string, error) {
	token := profileOpenConnectToken{}
	var unknown []string
	for key := range block {
		if !profileOpenConnectTokenKeys[key] {
			unknown = append(unknown, "token."+key)
		}
	}
	for _, key := range []string{"mode", "secret", "secret_path", "pin", "password", "device_id"} {
		value, present, err := profileVpnStoredString(block, key, "openconnect")
		if err != nil {
			return token, nil, err
		}
		if !present {
			continue
		}
		if key == "mode" {
			token.Mode = profileVpnTrimmed(value)
			continue
		}
		switch key {
		case "secret":
			token.Secret = value
		case "secret_path":
			token.SecretPath = value
		case "pin":
			token.Pin = value
		case "password":
			token.Password = value
		case "device_id":
			token.DeviceID = value
		}
	}
	if value, present, err := profileVpnStoredNumber(block, "counter", "openconnect", false); err != nil {
		return token, nil, err
	} else if present {
		token.Counter = value
	}
	return token, unknown, nil
}

func profileOpenConnectParseMobile(block map[string]any) (profileOpenConnectMobile, []string, error) {
	mobile := profileOpenConnectMobile{}
	var unknown []string
	for key := range block {
		if !profileOpenConnectMobileKeys[key] {
			unknown = append(unknown, "mobile."+key)
		}
	}
	for _, key := range []string{"platform_version", "device_type", "device_unique_id"} {
		value, present, err := profileVpnStoredString(block, key, "openconnect")
		if err != nil {
			return mobile, nil, err
		}
		if !present {
			continue
		}
		switch key {
		case "platform_version":
			mobile.PlatformVersion = value
		case "device_type":
			mobile.DeviceType = value
		case "device_unique_id":
			mobile.DeviceUniqueID = value
		}
	}
	return mobile, unknown, nil
}

func profileOpenConnectParseWrapper(block map[string]any, name string) (profileOpenConnectWrapper, []string, error) {
	wrapper := profileOpenConnectWrapper{}
	var unknown []string
	for key := range block {
		if !profileOpenConnectWrapperKeys[key] {
			unknown = append(unknown, name+"."+key)
		}
	}
	if value, present, err := profileVpnStoredString(block, "wrapper_path", "openconnect"); err != nil {
		return wrapper, nil, err
	} else if present {
		wrapper.WrapperPath = value
	}
	return wrapper, unknown, nil
}

func profileOpenConnectParseTNCC(block map[string]any) (profileOpenConnectTNCC, []string, error) {
	tncc := profileOpenConnectTNCC{}
	var unknown []string
	for key := range block {
		if !profileOpenConnectTNCCKeys[key] {
			unknown = append(unknown, "tncc."+key)
		}
	}
	for _, key := range []string{"wrapper_path", "device_id", "user_agent"} {
		value, present, err := profileVpnStoredString(block, key, "openconnect")
		if err != nil {
			return tncc, nil, err
		}
		if !present {
			continue
		}
		switch key {
		case "wrapper_path":
			tncc.WrapperPath = value
		case "device_id":
			tncc.DeviceID = value
		case "user_agent":
			tncc.UserAgent = value
		}
	}
	if value, present, err := profileVpnStoredBool(block, "machine_identification_enabled", "openconnect"); err != nil {
		return tncc, nil, err
	} else if present {
		tncc.MachineIdentificationEnabled = value
	}
	if value, present := block["certificates"]; present {
		items, ok := value.([]any)
		if !ok {
			return tncc, nil, profileUnsupported("stored openconnect tncc.certificates is not an array")
		}
		for _, item := range items {
			entry, ok := item.(map[string]any)
			if !ok || len(entry) == 0 {
				continue
			}
			for key := range entry {
				if !profileOpenConnectTNCCCertificateKeys[key] {
					unknown = append(unknown, "tncc.certificates."+key)
				}
			}
			certificate := profileOpenConnectTNCCCertificate{}
			if value, present, err := profileVpnStoredListable(entry, "certificate", "openconnect"); err != nil {
				return tncc, nil, err
			} else if present {
				certificate.Certificate = value
			}
			if value, present, err := profileVpnStoredString(entry, "certificate_path", "openconnect"); err != nil {
				return tncc, nil, err
			} else if present {
				certificate.CertificatePath = value
			}
			tncc.Certificates = append(tncc.Certificates, certificate)
		}
	}
	return tncc, unknown, nil
}

func profileOpenConnectParseFortinet(block map[string]any) (profileOpenConnectFortinetHostCheck, []string, error) {
	fortinet := profileOpenConnectFortinetHostCheck{}
	var unknown []string
	for key := range block {
		if !profileOpenConnectFortinetKeys[key] {
			unknown = append(unknown, "fortinet_host_check."+key)
		}
	}
	for _, key := range []string{"hostcheck", "check_virtual_desktop"} {
		value, present, err := profileVpnStoredString(block, key, "openconnect")
		if err != nil {
			return fortinet, nil, err
		}
		if !present {
			continue
		}
		if key == "hostcheck" {
			fortinet.HostCheck = value
		} else {
			fortinet.CheckVirtualDesktop = value
		}
	}
	return fortinet, unknown, nil
}

func profileOpenConnectParseTLS(block map[string]any) (profileOpenConnectTLS, []string, error) {
	tls := profileOpenConnectTLS{}
	var unknown []string
	for key := range block {
		if !profileOpenConnectTLSKeys[key] {
			unknown = append(unknown, "tls."+key)
		}
	}
	for _, key := range []string{"insecure", "system_trust_disabled"} {
		value, present, err := profileVpnStoredBool(block, key, "openconnect")
		if err != nil {
			return tls, nil, err
		}
		if !present {
			continue
		}
		if key == "insecure" {
			tls.Insecure = value
		} else {
			tls.SystemTrustDisabled = value
		}
	}
	for _, key := range []string{
		"server_name", "certificate_authority_path", "client_certificate_path",
		"client_key_path", "client_key_password", "mca_certificate_path",
		"mca_key_path", "mca_key_password",
	} {
		value, present, err := profileVpnStoredString(block, key, "openconnect")
		if err != nil {
			return tls, nil, err
		}
		if !present {
			continue
		}
		switch key {
		case "server_name":
			tls.ServerName = value
		case "certificate_authority_path":
			tls.CertificateAuthorityPath = value
		case "client_certificate_path":
			tls.ClientCertificatePath = value
		case "client_key_path":
			tls.ClientKeyPath = value
		case "client_key_password":
			tls.ClientKeyPassword = value
		case "mca_certificate_path":
			tls.MCACertificatePath = value
		case "mca_key_path":
			tls.MCAKeyPath = value
		case "mca_key_password":
			tls.MCAKeyPassword = value
		}
	}
	for _, key := range []string{
		"peer_fingerprint", "certificate_authority", "client_certificate",
		"client_key", "mca_certificate", "mca_key",
	} {
		value, present, err := profileVpnStoredListable(block, key, "openconnect")
		if err != nil {
			return tls, nil, err
		}
		if !present {
			continue
		}
		switch key {
		case "peer_fingerprint":
			tls.PeerFingerprint = value
		case "certificate_authority":
			tls.CertificateAuthority = value
		case "client_certificate":
			tls.ClientCertificate = value
		case "client_key":
			tls.ClientKey = value
		case "mca_certificate":
			tls.MCACertificate = value
		case "mca_key":
			tls.MCAKey = value
		}
	}
	return tls, unknown, nil
}

// profileOpenConnectWrapIPv6Host is OcImport.wrapIpv6Host.
func profileOpenConnectWrapIPv6Host(host string) string {
	if !configHostsIsIPAddress(host) {
		return host
	}
	return "[" + strings.ReplaceAll(strings.ReplaceAll(host, "[", ""), "]", "") + "]"
}

// profileOpenConnectSetServerURL is openconnect::SetServerUrl: a URL or bare
// host[:port][/path]; an unparsable value leaves the fields alone. A host form
// the Go QUrl port does not normalise the same way is a refusal so the caller
// falls back to Kotlin instead of storing a different host.
func profileOpenConnectSetServerURL(model *profileOpenConnect, url string) error {
	text := profileVpnTrimmed(url)
	if text == "" {
		return nil
	}
	if !strings.Contains(text, "://") {
		text = "https://" + profileOpenConnectWrapIPv6Host(text)
	}
	rawHost := profileOpenConnectRawAuthorityHost(text)
	if rawHost != "" && profileHasUnsupportedHostForm(rawHost) {
		return profileUnsupported("openconnect server host form is not byte-identical to Kotlin's normalization yet: " + rawHost)
	}
	parsed := profileLinkParse(text)
	if !parsed.IsValid() || parsed.Host == "" {
		return nil
	}
	if strings.Contains(parsed.Host, "%") {
		return profileUnsupported("openconnect server host carries a percent-encoded zone")
	}
	model.Server = parsed.Host
	if parsed.Port > 0 {
		model.Port = parsed.Port
	}
	model.ServerPath = parsed.Path
	if model.ServerPath == "/" {
		model.ServerPath = ""
	}
	return nil
}

// profileOpenConnectRawAuthorityHost is the authority host of a URL without
// userinfo or port, before any normalisation.
func profileOpenConnectRawAuthorityHost(url string) string {
	rest := url
	if index := strings.Index(url, "://"); index >= 0 {
		rest = url[index+3:]
	}
	if index := strings.IndexAny(rest, "/?#"); index >= 0 {
		rest = rest[:index]
	}
	if at := strings.LastIndex(rest, "@"); at >= 0 {
		rest = rest[at+1:]
	}
	if strings.HasPrefix(rest, "[") {
		return rest
	}
	if colon := strings.LastIndex(rest, ":"); colon >= 0 {
		rest = rest[:colon]
	}
	return rest
}

// profileOpenConnectCompressionModes is OpenConnectChecks.COMPRESSION_MODES.
var profileOpenConnectCompressionModes = []string{"stateless", "all"}

// profileOpenConnectReportedOSValues is OpenConnectChecks.REPORTED_OS.
var profileOpenConnectReportedOSValues = []string{
	"linux", "linux-64", "win", "mac-intel", "android", "apple-ios",
}

// profileOpenConnectFlavors is OpenConnectChecks.FLAVORS.
var profileOpenConnectFlavors = []string{"anyconnect", "gp", "fortinet", "f5", "pulse", "nc"}

// profileOpenConnectReportedOSMessage is OpenConnectChecks.openConnectReportedOs.
func profileOpenConnectReportedOSMessage(flavor, os string) string {
	if flavor != "" && flavor != "anyconnect" && flavor != "gp" && flavor != "pulse" {
		return ""
	}
	if os == "" || profileNewOneOf(os, profileOpenConnectReportedOSValues, false) {
		return ""
	}
	return "must be one of " + strings.Join(profileOpenConnectReportedOSValues, ", ")
}

// --- export ---------------------------------------------------------------

// profileOpenConnectExportJSON is OpenConnect.exportToJson.
func profileOpenConnectExportJSON(model *profileOpenConnect) map[string]any {
	object := map[string]any{"type": "openconnect"}
	if model.Name != "" {
		object["tag"] = model.Name
	}
	if model.Server != "" {
		object["server"] = model.Server
	}
	if model.Port > 0 {
		object["server_port"] = model.Port
	}
	for key, value := range model.Dial {
		object[key] = value
	}
	if model.ServerPath != "" {
		object["server_path"] = model.ServerPath
	}
	if model.Flavor != "" {
		object["flavor"] = model.Flavor
	}
	if model.Username != "" {
		object["username"] = model.Username
	}
	if model.Password != "" {
		object["password"] = model.Password
	}
	if model.AuthGroup != "" {
		object["auth_group"] = model.AuthGroup
	}
	if model.Cookie != "" {
		object["cookie"] = model.Cookie
	}
	if token := profileOpenConnectTokenJSON(model.Token); len(token) > 0 {
		object["token"] = token
	}
	if model.ReportedOS != "" {
		object["reported_os"] = model.ReportedOS
	}
	if model.UserAgent != "" {
		object["user_agent"] = model.UserAgent
	}
	if model.Version != "" {
		object["version"] = model.Version
	}
	if model.LocalHostname != "" {
		object["local_hostname"] = model.LocalHostname
	}
	if mobile := profileOpenConnectMobileJSON(model.Mobile); len(mobile) > 0 {
		object["mobile"] = mobile
	}
	if wrapper := profileOpenConnectWrapperJSON(model.CSD); len(wrapper) > 0 {
		object["csd"] = wrapper
	}
	if wrapper := profileOpenConnectWrapperJSON(model.HIP); len(wrapper) > 0 {
		object["hip"] = wrapper
	}
	if tncc := profileOpenConnectTNCCJSON(model.TNCC); len(tncc) > 0 {
		object["tncc"] = tncc
	}
	if fortinet := profileOpenConnectFortinetJSON(model.FortinetHostCheck); len(fortinet) > 0 {
		object["fortinet_host_check"] = fortinet
	}
	if model.NoUDP {
		object["no_udp"] = true
	}
	if model.DTLSLocalPort > 0 {
		object["dtls_local_port"] = model.DTLSLocalPort
	}
	if model.CompressionDisabled {
		object["compression_disabled"] = true
	}
	if model.CompressionMode != "" {
		object["compression_mode"] = model.CompressionMode
	}
	for _, key := range []string{
		"ipv6_disabled", "http_keepalive_disabled", "xml_post_disabled",
		"external_auth_disabled", "password_authentication_disabled",
		"tcp_keep_alive_enabled", "pfs", "allow_insecure_crypto", "system",
	} {
		var value bool
		switch key {
		case "ipv6_disabled":
			value = model.IPv6Disabled
		case "http_keepalive_disabled":
			value = model.HTTPKeepaliveDisabled
		case "xml_post_disabled":
			value = model.XMLPostDisabled
		case "external_auth_disabled":
			value = model.ExternalAuthDisabled
		case "password_authentication_disabled":
			value = model.PasswordAuthDisabled
		case "tcp_keep_alive_enabled":
			value = model.TCPKeepAliveEnabled
		case "pfs":
			value = model.PFS
		case "allow_insecure_crypto":
			value = model.AllowInsecureCrypto
		case "system":
			value = model.System
		}
		if value {
			object[key] = true
		}
	}
	if model.MTU > 0 {
		object["mtu"] = model.MTU
	}
	if model.BaseMTU > 0 {
		object["base_mtu"] = model.BaseMTU
	}
	if model.DPDInterval != "" {
		object["dpd_interval"] = model.DPDInterval
	}
	if model.ReconnectTimeout != "" {
		object["reconnect_timeout"] = model.ReconnectTimeout
	}
	if model.TrojanInterval != "" {
		object["trojan_interval"] = model.TrojanInterval
	}
	if model.QueueLength > 0 {
		object["queue_length"] = model.QueueLength
	}
	if tls := profileOpenConnectTLSJSON(model.TLS); len(tls) > 0 {
		object["tls"] = tls
	}
	if len(model.FormEntries) > 0 {
		entries := make([]any, 0, len(model.FormEntries))
		for _, entry := range model.FormEntries {
			item := profileOpenConnectFormEntryJSON(entry)
			if len(item) > 0 {
				entries = append(entries, item)
			}
		}
		if len(entries) > 0 {
			object["form_entries"] = entries
		}
	}
	if model.InterfaceName != "" {
		object["name"] = model.InterfaceName
	}
	if model.UDPTimeout != "" {
		object["udp_timeout"] = model.UDPTimeout
	}
	if model.UDPMapping != "" {
		object["udp_mapping"] = model.UDPMapping
	}
	if model.UDPFiltering != "" {
		object["udp_filtering"] = model.UDPFiltering
	}
	if model.UDPNATMax > 0 {
		object["udp_nat_max"] = model.UDPNATMax
	}
	if model.OTPProfileID >= 0 {
		object["otp_profile_id"] = model.OTPProfileID
	}
	object["only_advertised_routes"] = model.OnlyAdvertisedRoutes
	object["tunnel_dns"] = model.TunnelDNS
	return object
}

// profileOpenConnectTokenJSON is OpenConnectToken::ExportToJson: a token
// without a mode is dropped entirely.
func profileOpenConnectTokenJSON(token profileOpenConnectToken) map[string]any {
	object := map[string]any{}
	if token.Mode == "" {
		return object
	}
	object["mode"] = token.Mode
	if token.Secret != "" {
		object["secret"] = token.Secret
	}
	if token.SecretPath != "" {
		object["secret_path"] = token.SecretPath
	}
	if token.Pin != "" {
		object["pin"] = token.Pin
	}
	if token.Password != "" {
		object["password"] = token.Password
	}
	if token.DeviceID != "" {
		object["device_id"] = token.DeviceID
	}
	if token.Counter > 0 {
		object["counter"] = token.Counter
	}
	return object
}

// profileOpenConnectMobileJSON is OpenConnectMobile::ExportToJson: all three
// keys are written when any is set, because the core refuses a partial block.
func profileOpenConnectMobileJSON(mobile profileOpenConnectMobile) map[string]any {
	object := map[string]any{}
	if mobile.PlatformVersion == "" && mobile.DeviceType == "" && mobile.DeviceUniqueID == "" {
		return object
	}
	object["platform_version"] = mobile.PlatformVersion
	object["device_type"] = mobile.DeviceType
	object["device_unique_id"] = mobile.DeviceUniqueID
	return object
}

// profileOpenConnectWrapperJSON is OpenConnectWrapper::ExportToJson.
func profileOpenConnectWrapperJSON(wrapper profileOpenConnectWrapper) map[string]any {
	object := map[string]any{}
	if wrapper.WrapperPath != "" {
		object["wrapper_path"] = wrapper.WrapperPath
	}
	return object
}

// profileOpenConnectTNCCJSON is OpenConnectTNCC::ExportToJson.
func profileOpenConnectTNCCJSON(tncc profileOpenConnectTNCC) map[string]any {
	object := map[string]any{}
	if tncc.WrapperPath != "" {
		object["wrapper_path"] = tncc.WrapperPath
	}
	if tncc.DeviceID != "" {
		object["device_id"] = tncc.DeviceID
	}
	if tncc.UserAgent != "" {
		object["user_agent"] = tncc.UserAgent
	}
	if tncc.MachineIdentificationEnabled {
		object["machine_identification_enabled"] = true
	}
	if len(tncc.Certificates) > 0 {
		certificates := make([]any, 0, len(tncc.Certificates))
		for _, certificate := range tncc.Certificates {
			item := map[string]any{}
			if len(certificate.Certificate) > 0 {
				item["certificate"] = profileVpnStringArray(certificate.Certificate)
			}
			if certificate.CertificatePath != "" {
				item["certificate_path"] = certificate.CertificatePath
			}
			if len(item) > 0 {
				certificates = append(certificates, item)
			}
		}
		if len(certificates) > 0 {
			object["certificates"] = certificates
		}
	}
	return object
}

// profileOpenConnectFortinetJSON is OpenConnectFortinetHostCheck::ExportToJson:
// an empty hostcheck disables the feature, so the rest is meaningless alone.
func profileOpenConnectFortinetJSON(fortinet profileOpenConnectFortinetHostCheck) map[string]any {
	object := map[string]any{}
	if fortinet.HostCheck == "" {
		return object
	}
	object["hostcheck"] = fortinet.HostCheck
	if fortinet.CheckVirtualDesktop != "" {
		object["check_virtual_desktop"] = fortinet.CheckVirtualDesktop
	}
	return object
}

// profileOpenConnectFormEntryJSON is OpenConnectFormEntry::ExportToJson.
func profileOpenConnectFormEntryJSON(entry profileOpenConnectFormEntry) map[string]any {
	object := map[string]any{}
	if entry.SubmissionKey == "" && (entry.FormID == "" || entry.Name == "") {
		return object
	}
	if entry.FormID != "" {
		object["form_id"] = entry.FormID
	}
	if entry.SubmissionKey != "" {
		object["submission_key"] = entry.SubmissionKey
	}
	if entry.Name != "" {
		object["name"] = entry.Name
	}
	if entry.Value != "" {
		object["value"] = entry.Value
	}
	if entry.Promote {
		object["promote"] = true
	}
	return object
}

// profileOpenConnectTLSJSON is OpenConnectTls.exportToJson: the server name is
// stored ACE-normalised.
func profileOpenConnectTLSJSON(tls profileOpenConnectTLS) map[string]any {
	object := map[string]any{}
	if tls.Insecure {
		object["insecure"] = true
	}
	if tls.ServerName != "" {
		object["server_name"] = aceShareHost(tls.ServerName)
	}
	if len(tls.PeerFingerprint) > 0 {
		object["peer_fingerprint"] = profileVpnStringArray(tls.PeerFingerprint)
	}
	if tls.SystemTrustDisabled {
		object["system_trust_disabled"] = true
	}
	if len(tls.CertificateAuthority) > 0 {
		object["certificate_authority"] = profileVpnStringArray(tls.CertificateAuthority)
	}
	if tls.CertificateAuthorityPath != "" {
		object["certificate_authority_path"] = tls.CertificateAuthorityPath
	}
	if len(tls.ClientCertificate) > 0 {
		object["client_certificate"] = profileVpnStringArray(tls.ClientCertificate)
	}
	if tls.ClientCertificatePath != "" {
		object["client_certificate_path"] = tls.ClientCertificatePath
	}
	if len(tls.ClientKey) > 0 {
		object["client_key"] = profileVpnStringArray(tls.ClientKey)
	}
	if tls.ClientKeyPath != "" {
		object["client_key_path"] = tls.ClientKeyPath
	}
	if tls.ClientKeyPassword != "" {
		object["client_key_password"] = tls.ClientKeyPassword
	}
	if len(tls.MCACertificate) > 0 {
		object["mca_certificate"] = profileVpnStringArray(tls.MCACertificate)
	}
	if tls.MCACertificatePath != "" {
		object["mca_certificate_path"] = tls.MCACertificatePath
	}
	if len(tls.MCAKey) > 0 {
		object["mca_key"] = profileVpnStringArray(tls.MCAKey)
	}
	if tls.MCAKeyPath != "" {
		object["mca_key_path"] = tls.MCAKeyPath
	}
	if tls.MCAKeyPassword != "" {
		object["mca_key_password"] = tls.MCAKeyPassword
	}
	return object
}

// profileOpenConnectNode builds the action's imported node.
func profileOpenConnectNode(model *profileOpenConnect) (*profileImportedNode, error) {
	stored, err := MarshalCanonicalJSON(profileOpenConnectExportJSON(model))
	if err != nil {
		return nil, err
	}
	withoutTag := *model
	withoutTag.Name = ""
	dedup, err := MarshalCanonicalJSON(profileOpenConnectExportJSON(&withoutTag))
	if err != nil {
		return nil, err
	}
	identity := string(stored)
	if model.Server != "" {
		encoded, encodeErr := MarshalCanonicalJSON(map[string]any{
			"server": model.Server, "server_port": model.Port,
		})
		if encodeErr != nil {
			return nil, encodeErr
		}
		identity = string(encoded)
	}
	return &profileImportedNode{
		Type:     "openconnect",
		Name:     model.Name,
		JSON:     string(stored),
		Link:     profileOpenConnectDialQueryLink(model),
		Identity: identity,
		DedupKey: "throne://add/" + profileBase64Encode(dedup, true, false),
	}, nil
}

// profileOpenConnectDialQueryLink is Outbound.exportToLink with no override.
func profileOpenConnectDialQueryLink(model *profileOpenConnect) string {
	query := []profileStoredQueryItem{}
	if configJSONBool(model.Dial, "reuse_addr") {
		query = append(query, profileStoredQueryItem{key: "reuse_addr", value: "true"})
	}
	if value := configJSONString(model.Dial, "connect_timeout"); value != "" {
		query = append(query, profileStoredQueryItem{key: "connect_timeout", value: value})
	}
	for _, key := range []string{"tcp_fast_open", "tcp_multi_path", "udp_fragment"} {
		if configJSONBool(model.Dial, key) {
			query = append(query, profileStoredQueryItem{key: key, value: "true"})
		}
	}
	for _, key := range []string{"bind_interface", "inet4_bind_address", "inet6_bind_address"} {
		if value := configJSONString(model.Dial, key); value != "" {
			query = append(query, profileStoredQueryItem{key: key, value: value})
		}
	}
	return profileStoredFormatQuery(query)
}

// --- profile parser (ParseOpenConnectProfile) -----------------------------

// profileOpenConnectHostEntry is OcImport.HostEntry.
type profileOpenConnectHostEntry struct {
	Name         string
	Address      string
	Group        string
	Protocol     string
	Fingerprints []string
}

// profileOpenConnectOptionHasValue is vpnfiOcOptionHasValue.
var profileOpenConnectOptionHasValue = map[string]bool{
	"authgroup": true, "base-mtu": true, "cafile": true, "cert-expire-warning": true,
	"certificate": true, "compression": true, "config": true, "cookie": true,
	"csd-user": true, "csd-wrapper": true, "dpd": true, "dtls-local-port": true,
	"force-dpd": true, "force-trojan": true, "form-entry": true,
	"gnutls-priority": true, "http-auth": true, "interface": true,
	"key-password": true, "key-type": true, "local-hostname": true,
	"localname": true, "mca-certificate": true, "mca-key": true,
	"mca-key-password": true, "mtu": true, "os": true, "pid-file": true,
	"protocol": true, "proxy": true, "proxy-auth": true, "queue-len": true,
	"reconnect-timeout": true, "resolve": true, "script": true, "server": true,
	"servercert": true, "setuid": true, "sni": true, "sslkey": true,
	"token-mode": true, "token-secret": true, "user": true, "useragent": true,
	"user-agent": true, "usergroup": true, "version-string": true,
	"xmlconfig": true,
}

// profileOpenConnectIgnoredOptions is vpnfiOcIgnored.
var profileOpenConnectIgnoredOptions = map[string]bool{
	"authenticate": true, "background": true, "cert-expire-warning": true,
	"config": true, "cookie-on-stdin": true, "cookieonly": true,
	"csd-user": true, "deflate": true, "dump-http-traffic": true,
	"gnutls-debug": true, "gnutls-priority": true, "help": true,
	"interface": true, "key-password-from-fsid": true, "key-type": true,
	"libproxy": true, "no-deflate": true, "no-proxy": true, "non-inter": true,
	"passtos": true, "passwd-on-stdin": true, "pid-file": true,
	"printcookie": true, "quiet": true, "resolve": true, "script": true,
	"script-tun": true, "setuid": true, "syslog": true, "timestamp": true,
	"verbose": true, "version": true, "xmlconfig": true,
}

// profileOpenConnectFlags is vpnfiOcFlags: kept apart so only an unknown option
// may swallow a detached argument.
var profileOpenConnectFlags = map[string]bool{
	"allow-insecure-crypto": true, "disable-ipv6": true, "juniper": true,
	"no-compression": true, "no-dtls": true, "no-external-auth": true,
	"no-http-keepalive": true, "no-passwd": true, "no-system-trust": true,
	"no-xmlpost": true, "pfs": true,
}

// profileOpenConnectLongName is vpnfiOcLongName.
func profileOpenConnectLongName(short rune) string {
	switch short {
	case 'b':
		return "background"
	case 'C':
		return "cookie"
	case 'c':
		return "certificate"
	case 'e':
		return "cert-expire-warning"
	case 'F':
		return "form-entry"
	case 'g':
		return "usergroup"
	case 'h':
		return "help"
	case 'i':
		return "interface"
	case 'k':
		return "sslkey"
	case 'l':
		return "syslog"
	case 'm':
		return "mtu"
	case 'p':
		return "key-password"
	case 'P':
		return "proxy"
	case 'Q':
		return "queue-len"
	case 'q':
		return "quiet"
	case 'S':
		return "script-tun"
	case 's':
		return "script"
	case 't':
		return "token-mode"
	case 'U':
		return "setuid"
	case 'u':
		return "user"
	case 'V':
		return "version"
	case 'v':
		return "verbose"
	case 'x':
		return "xmlconfig"
	}
	return ""
}

// profileOpenConnectApplyOption is vpnfiApplyOcOption.
func profileOpenConnectApplyOption(model *profileOpenConnect, name, value string, hasValue bool, notes *[]string) error {
	switch name {
	case "protocol":
		flavor, _ := profileNewASCIILower(value)
		known := false
		for _, candidate := range profileOpenConnectFlavors {
			if candidate == flavor {
				known = true
			}
		}
		if known {
			model.Flavor = flavor
		} else {
			profileVpnNotef(notes, "protocol %q is not supported", value)
		}
	case "juniper":
		model.Flavor = "nc"
	case "server":
		if err := profileOpenConnectSetServerURL(model, value); err != nil {
			return err
		}
	case "user":
		model.Username = value
	case "authgroup":
		model.AuthGroup = value
	case "usergroup":
		model.ServerPath = value
	case "cookie":
		model.Cookie = value
	case "certificate":
		model.TLS.ClientCertificatePath = value
	case "sslkey":
		model.TLS.ClientKeyPath = value
	case "key-password":
		model.TLS.ClientKeyPassword = value
	case "mca-certificate":
		model.TLS.MCACertificatePath = value
	case "mca-key":
		model.TLS.MCAKeyPath = value
	case "mca-key-password":
		model.TLS.MCAKeyPassword = value
	case "cafile":
		model.TLS.CertificateAuthorityPath = value
	case "servercert":
		if value != "" {
			model.TLS.PeerFingerprint = append(model.TLS.PeerFingerprint, value)
		}
	case "no-system-trust":
		model.TLS.SystemTrustDisabled = true
	case "sni":
		model.TLS.ServerName = value
	case "no-dtls":
		model.NoUDP = true
	case "dtls-local-port":
		if profileVpnAccept(notes, name, value, profileVpnPortMessage(value)) {
			model.DTLSLocalPort = profileVpnQtToInt(value)
		}
	case "compression":
		mode, _ := profileNewASCIILower(value)
		switch mode {
		case "none":
			model.CompressionDisabled = true
		case "stateless", "all":
			model.CompressionMode = mode
		default:
			profileVpnNotef(notes, "compression %q is not known", value)
		}
	case "no-compression":
		model.CompressionDisabled = true
	case "disable-ipv6":
		model.IPv6Disabled = true
	case "no-http-keepalive":
		model.HTTPKeepaliveDisabled = true
	case "no-xmlpost":
		model.XMLPostDisabled = true
	case "no-external-auth":
		model.ExternalAuthDisabled = true
	case "no-passwd":
		model.PasswordAuthDisabled = true
	case "pfs":
		model.PFS = true
	case "allow-insecure-crypto":
		model.AllowInsecureCrypto = true
	case "mtu":
		if profileVpnAccept(notes, name, value, profileVpnIntMessage(value, 0, 65535)) {
			model.MTU = profileVpnQtToInt(value)
		}
	case "base-mtu":
		if profileVpnAccept(notes, name, value, profileVpnIntMessage(value, 0, 65535)) {
			model.BaseMTU = profileVpnQtToInt(value)
		}
	case "dpd", "force-dpd":
		interval := profileVpnDuration(notes, name, value)
		// The core raises a shorter interval to 2s itself.
		ns, ok := profileVpnDurationNs(interval)
		if !ok {
			ns = 0
		}
		if ns > 0 && ns < 2000000000 {
			profileVpnNotef(notes, "%s %q was raised to 2s", name, value)
			model.DPDInterval = "2s"
		} else {
			model.DPDInterval = interval
		}
	case "reconnect-timeout":
		model.ReconnectTimeout = profileVpnDuration(notes, name, value)
	case "force-trojan":
		model.TrojanInterval = profileVpnDuration(notes, name, value)
	case "queue-len":
		if profileVpnAccept(notes, name, value, profileVpnIntMessage(value, 0, 2147483647)) {
			model.QueueLength = profileVpnQtToInt(value)
		}
	case "useragent", "user-agent":
		model.UserAgent = value
	case "version-string":
		model.Version = value
	case "local-hostname", "localname":
		model.LocalHostname = value
	case "os":
		osValue, _ := profileNewASCIILower(value)
		known := false
		for _, candidate := range profileOpenConnectReportedOSValues {
			if candidate == osValue {
				known = true
			}
		}
		if known {
			model.ReportedOS = osValue
		} else {
			profileVpnNotef(notes, "os %q is not known", value)
		}
	case "csd-wrapper":
		model.CSD.WrapperPath = value
	case "token-mode":
		// OpenConnect's `rsa` is the endpoint's `stoken`.
		mode, _ := profileNewASCIILower(value)
		switch mode {
		case "rsa", "stoken":
			model.Token.Mode = "stoken"
		case "totp", "hotp", "oidc":
			model.Token.Mode = mode
		default:
			profileVpnNotef(notes, "token-mode %q is not supported", value)
		}
	case "token-secret":
		if strings.HasPrefix(value, "@") {
			model.Token.SecretPath = value[1:]
		} else {
			model.Token.Secret = value
		}
	case "form-entry":
		colon := strings.Index(value, ":")
		if colon < 0 {
			profileVpnNotef(notes, "form-entry %q needs the form-id:name=value form", value)
			return nil
		}
		equals := strings.Index(value[colon+1:], "=")
		if equals < 0 {
			profileVpnNotef(notes, "form-entry %q needs the form-id:name=value form", value)
			return nil
		}
		equals += colon + 1
		model.FormEntries = append(model.FormEntries, profileOpenConnectFormEntry{
			FormID: value[:colon], Name: value[colon+1 : equals], Value: value[equals+1:],
		})
	case "proxy", "proxy-auth", "http-auth":
		profileVpnNotef(notes, "%s is not supported", name)
	default:
		if profileOpenConnectIgnoredOptions[name] {
			return nil
		}
		if hasValue {
			profileVpnNotef(notes, "the option %s=%s is not known", name, value)
		} else {
			profileVpnNotef(notes, "the option %s is not known", name)
		}
	}
	return nil
}

// profileOpenConnectWalkArgs is vpnfiWalkOcArgs: GNU long options, bundled
// short options and the positional server.
func profileOpenConnectWalkArgs(model *profileOpenConnect, argv []string, notes *[]string) error {
	index := 0
	for index < len(argv) {
		token := argv[index]
		if index == 0 && (token == "openconnect" || strings.HasSuffix(token, "/openconnect") ||
			strings.HasSuffix(token, "openconnect.exe")) {
			index++
			continue
		}
		if strings.HasPrefix(token, "--") {
			name := token[2:]
			value := ""
			hasValue := false
			if equals := strings.Index(name, "="); equals >= 0 {
				value = name[equals+1:]
				name = name[:equals]
				hasValue = true
			} else if profileOpenConnectOptionHasValue[name] && index+1 < len(argv) {
				index++
				value = argv[index]
				hasValue = true
			} else if !profileOpenConnectFlags[name] && !profileOpenConnectIgnoredOptions[name] &&
				index+2 < len(argv) && !strings.HasPrefix(argv[index+1], "-") {
				// Swallow a detached value only while a trailing positional is left.
				index++
				value = argv[index]
				hasValue = true
			}
			if err := profileOpenConnectApplyOption(model, name, value, hasValue, notes); err != nil {
				return err
			}
			index++
			continue
		}
		if len(token) > 1 && strings.HasPrefix(token, "-") {
			runes := []rune(token)
			for position := 1; position < len(runes); position++ {
				name := profileOpenConnectLongName(runes[position])
				if name == "" {
					profileVpnNotef(notes, "the option -%c is not known", runes[position])
					break
				}
				if !profileOpenConnectOptionHasValue[name] {
					if err := profileOpenConnectApplyOption(model, name, "", false, notes); err != nil {
						return err
					}
					continue
				}
				value := ""
				if position+1 < len(runes) {
					value = string(runes[position+1:])
				} else if index+1 < len(argv) {
					index++
					value = argv[index]
				}
				if err := profileOpenConnectApplyOption(model, name, value, true, notes); err != nil {
					return err
				}
				break
			}
			index++
			continue
		}
		// `--usergroup` outranks the URL path whichever came first.
		group := model.ServerPath
		if err := profileOpenConnectSetServerURL(model, token); err != nil {
			return err
		}
		if group != "" {
			model.ServerPath = group
		}
		index++
	}
	return nil
}

// profileOpenConnectLooksLikeXML is vpnfiLooksLikeXml.
func profileOpenConnectLooksLikeXML(text string) bool {
	return strings.HasPrefix(text, "<?xml") || strings.Contains(text, "<AnyConnectProfile") ||
		strings.Contains(text, "<ServerList")
}

// profileOpenConnectIsCommandLine is vpnfiIsOcCommandLine.
func profileOpenConnectIsCommandLine(text string) bool {
	for _, line := range strings.Split(text, "\n") {
		item := profileVpnTrimmed(line)
		if item == "" || strings.HasPrefix(item, "#") {
			continue
		}
		return strings.HasPrefix(item, "openconnect") || strings.HasPrefix(item, "-")
	}
	return false
}

// profileOpenConnectReadElementText is
// QXmlStreamReader::readElementText(IncludeChildElements): every character run
// below the current element, through its end tag.
func profileOpenConnectReadElementText(decoder *xml.Decoder) (string, error) {
	var out strings.Builder
	depth := 1
	for depth > 0 {
		token, err := decoder.Token()
		if err != nil {
			return "", err
		}
		switch typed := token.(type) {
		case xml.StartElement:
			depth++
		case xml.EndElement:
			depth--
		case xml.CharData:
			out.Write(typed)
		}
	}
	return out.String(), nil
}

// profileOpenConnectReadAnyConnectHosts is vpnfiReadAnyConnectHosts. Untrusted
// input: a DTD is the only place entities are declared, so it is refused.
func profileOpenConnectReadAnyConnectHosts(text string, notes *[]string) ([]profileOpenConnectHostEntry, bool) {
	if strings.Contains(text, "<!DOCTYPE") {
		profileVpnNote(notes, "the AnyConnect profile declares a DTD, which is not accepted")
		return nil, false
	}
	decoder := xml.NewDecoder(strings.NewReader(text))
	var entries []profileOpenConnectHostEntry
	current := profileOpenConnectHostEntry{}
	inEntry := false
	for {
		token, err := decoder.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			profileVpnNotef(notes, "the AnyConnect profile is malformed: %s", err.Error())
			return nil, false
		}
		switch typed := token.(type) {
		case xml.StartElement:
			element := typed.Name.Local
			if strings.EqualFold(element, "HostEntry") {
				current = profileOpenConnectHostEntry{}
				inEntry = true
				continue
			}
			if !inEntry {
				continue
			}
			inner, err := profileOpenConnectReadElementText(decoder)
			if err != nil {
				profileVpnNotef(notes, "the AnyConnect profile is malformed: %s", err.Error())
				return nil, false
			}
			value := profileVpnTrimmed(inner)
			if value == "" {
				continue
			}
			switch {
			case strings.EqualFold(element, "HostName"):
				current.Name = value
			case strings.EqualFold(element, "HostAddress"):
				current.Address = value
			case strings.EqualFold(element, "UserGroup"):
				current.Group = value
			case strings.EqualFold(element, "PrimaryProtocol"):
				current.Protocol = value
			case strings.HasSuffix(strings.ToLower(element), "certificatehash"):
				current.Fingerprints = append(current.Fingerprints, value)
			}
		case xml.EndElement:
			if inEntry && strings.EqualFold(typed.Name.Local, "HostEntry") {
				entries = append(entries, current)
				current = profileOpenConnectHostEntry{}
				inEntry = false
			}
		}
	}
	if len(entries) == 0 {
		profileVpnNote(notes, "the AnyConnect profile has no HostEntry")
		return nil, false
	}
	return entries, true
}

// profileOpenConnectApplyHostEntry is vpnfiApplyHostEntry.
func profileOpenConnectApplyHostEntry(entry profileOpenConnectHostEntry, model *profileOpenConnect, notes *[]string) (bool, error) {
	address := entry.Address
	if address == "" {
		address = entry.Name
	}
	if address == "" {
		profileVpnNote(notes, "a HostEntry has no address")
		return false, nil
	}
	if strings.EqualFold(entry.Protocol, "IPsec") {
		profileVpnNotef(notes, "the host %s uses IPsec, which the endpoint cannot speak", address)
		return false, nil
	}
	model.Flavor = "anyconnect"
	if err := profileOpenConnectSetServerURL(model, address); err != nil {
		return false, err
	}
	if model.Server == "" {
		profileVpnNotef(notes, "the host %s cannot be read", address)
		return false, nil
	}
	if entry.Group != "" {
		model.ServerPath = entry.Group
	}
	if entry.Name == "" {
		model.Name = address
	} else {
		model.Name = entry.Name
	}
	model.TLS.PeerFingerprint = append(model.TLS.PeerFingerprint, entry.Fingerprints...)
	return true, nil
}

// profileOpenConnectParseConfig is ParseOpenConnectProfile applied to [model].
func profileOpenConnectParseConfig(model *profileOpenConnect, text string, notes *[]string) (bool, error) {
	body := profileVpnTrimmed(text)
	if body == "" {
		profileVpnNote(notes, "the OpenConnect profile is empty")
		return false, nil
	}

	if profileOpenConnectLooksLikeXML(body) {
		entries, ok := profileOpenConnectReadAnyConnectHosts(body, notes)
		if !ok {
			return false, nil
		}
		// One profile per usable entry: the caller keeps the ones that worked.
		for _, entry := range entries {
			applied, err := profileOpenConnectApplyHostEntry(entry, model, notes)
			if err != nil {
				return false, err
			}
			if applied {
				return true, nil
			}
		}
		profileVpnNote(notes, "the AnyConnect profile has no usable host")
		return false, nil
	}

	model.TLS.PeerFingerprint = nil
	model.FormEntries = nil

	argv := []string{}
	if profileOpenConnectIsCommandLine(body) {
		var joined strings.Builder
		for _, line := range strings.Split(body, "\n") {
			item := strings.ReplaceAll(profileVpnTrimmed(line), "\r", "")
			if strings.HasSuffix(item, "\\") {
				item = item[:len(item)-1]
			}
			joined.WriteString(item)
			joined.WriteByte(' ')
		}
		argv = append(argv, profileVpnTokenize(joined.String())...)
	} else {
		for _, line := range strings.Split(body, "\n") {
			tokens := profileVpnTokenize(line)
			if len(tokens) == 0 {
				continue
			}
			switch {
			case strings.Contains(tokens[0], "="):
				argv = append(argv, "--"+tokens[0])
			case len(tokens) > 1:
				argv = append(argv, "--"+tokens[0]+"="+strings.Join(tokens[1:], " "))
			case profileOpenConnectOptionHasValue[tokens[0]] || profileOpenConnectFlags[tokens[0]] ||
				profileOpenConnectIgnoredOptions[tokens[0]]:
				argv = append(argv, "--"+tokens[0])
			default:
				// A lone word that names no option is the bare server address.
				argv = append(argv, tokens[0])
			}
		}
	}
	if len(argv) == 0 {
		profileVpnNote(notes, "the OpenConnect profile has no options")
		return false, nil
	}
	if err := profileOpenConnectWalkArgs(model, argv, notes); err != nil {
		return false, err
	}
	if model.Server == "" {
		profileVpnNote(notes, "the OpenConnect profile has no server")
		return false, nil
	}
	if model.Name == "" {
		model.Name = model.Server
	}
	if len(model.TLS.ClientCertificate) > 0 {
		model.TLS.ClientCertificatePath = ""
	}
	if len(model.TLS.ClientKey) > 0 {
		model.TLS.ClientKeyPath = ""
	}
	if len(model.TLS.CertificateAuthority) > 0 {
		model.TLS.CertificateAuthorityPath = ""
	}
	if model.Token.Secret != "" {
		model.Token.SecretPath = ""
	}
	return true, nil
}

// profileOpenConnectParseConfigAll is ParseAnyConnectXml: one profile per
// usable host entry, for a body whose XML lists more than one host.
func profileOpenConnectParseConfigAll(text string, notes *[]string) ([]*profileOpenConnect, bool) {
	body := profileVpnTrimmed(text)
	if !profileOpenConnectLooksLikeXML(body) {
		return nil, false
	}
	entries, ok := profileOpenConnectReadAnyConnectHosts(body, notes)
	if !ok {
		return nil, false
	}
	models := make([]*profileOpenConnect, 0, len(entries))
	for _, entry := range entries {
		model := newProfileOpenConnect()
		applied, err := profileOpenConnectApplyHostEntry(entry, model, notes)
		if err != nil {
			profileVpnNote(notes, err.Error())
			return nil, false
		}
		if applied {
			models = append(models, model)
		}
	}
	return models, len(models) > 0
}
