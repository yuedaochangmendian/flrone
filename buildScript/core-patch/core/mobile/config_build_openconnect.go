// OpenConnect: the sing-box endpoint whose core takes a single HTTPS URL.
//
// This is the Go counterpart of types/OpenConnect.kt: build() reproduces
// OpenConnect.build (including composeServer and every nested object), and
// parseOpenConnect reproduces OpenConnect.parseFromJson for DB loads. There is
// no ParseDiag scope here, so the import-only checked readers keep every stored
// value exactly as the Kotlin loader does on a DB load.
package mobile

import (
	"fmt"
	"strings"
)

const configOpenConnectDefaultPort = 443

// configOCWrapIPv6Host is OcImport.wrapIpv6Host: bracket an IPv6 literal and
// strip any brackets already present.
func configOCWrapIPv6Host(host string) string {
	if !configHostsIsIPAddress(host) || !strings.Contains(host, ":") {
		return host
	}
	return "[" + strings.ReplaceAll(strings.ReplaceAll(host, "[", ""), "]", "") + "]"
}

// configOCArray is JsonObject.array: only a JSON array yields items; any other
// stored value is ignored by the Kotlin loader and keeps the empty list.
func configOCArray(value any) []any {
	items, _ := value.([]any)
	return items
}

// configOCListable is VpnFileImport.listable: a bare string is split on
// newlines with empty items dropped, an array keeps its string items.
func configOCListable(value any) []string {
	if text, ok := value.(string); ok {
		return configSplitSkipEmpty(text, "\n")
	}
	return configJSONStringListValue(value)
}

// configOCNonEmptyStrings is JsonValues.stringArray: blank items are dropped.
func configOCNonEmptyStrings(items []string) []any {
	out := make([]any, 0, len(items))
	for _, item := range items {
		if strings.TrimSpace(item) == "" {
			continue
		}
		out = append(out, item)
	}
	return out
}

// --- nested structs --------------------------------------------------------

type configOCToken struct {
	mode       string
	secret     string
	secretPath string
	pin        string
	password   string
	deviceID   string
	counter    int64
}

var configOCTokenKeys = configKeysAllowed("mode", "secret", "secret_path", "pin", "password", "device_id", "counter")

func configOCTokenParse(object map[string]any) (configOCToken, error) {
	var token configOCToken
	if object == nil {
		return token, nil
	}
	if err := configCheckKeys(object, configOCTokenKeys, "openconnect.token"); err != nil {
		return token, err
	}
	if _, present := object["mode"]; present {
		token.mode = strings.TrimSpace(configJSONString(object, "mode"))
	}
	if _, present := object["secret"]; present {
		token.secret = configJSONString(object, "secret")
	}
	if _, present := object["secret_path"]; present {
		token.secretPath = configJSONString(object, "secret_path")
	}
	if _, present := object["pin"]; present {
		token.pin = configJSONString(object, "pin")
	}
	if _, present := object["password"]; present {
		token.password = configJSONString(object, "password")
	}
	if _, present := object["device_id"]; present {
		token.deviceID = configJSONString(object, "device_id")
	}
	if _, present := object["counter"]; present {
		token.counter = configJSONInteger(object["counter"])
	}
	return token, nil
}

// configOCTokenBuild is OpenConnectToken::ExportToJson/Build: a token without a
// mode is dropped entirely.
func configOCTokenBuild(token configOCToken) map[string]any {
	object := map[string]any{}
	if token.mode == "" {
		return object
	}
	object["mode"] = token.mode
	if token.secret != "" {
		object["secret"] = token.secret
	}
	if token.secretPath != "" {
		object["secret_path"] = token.secretPath
	}
	if token.pin != "" {
		object["pin"] = token.pin
	}
	if token.password != "" {
		object["password"] = token.password
	}
	if token.deviceID != "" {
		object["device_id"] = token.deviceID
	}
	if token.counter > 0 {
		object["counter"] = token.counter
	}
	return object
}

type configOCMobile struct {
	platformVersion string
	deviceType      string
	deviceUniqueID  string
}

var configOCMobileKeys = configKeysAllowed("platform_version", "device_type", "device_unique_id")

func configOCMobileParse(object map[string]any) (configOCMobile, error) {
	var mobile configOCMobile
	if object == nil {
		return mobile, nil
	}
	if err := configCheckKeys(object, configOCMobileKeys, "openconnect.mobile"); err != nil {
		return mobile, err
	}
	if _, present := object["platform_version"]; present {
		mobile.platformVersion = configJSONString(object, "platform_version")
	}
	if _, present := object["device_type"]; present {
		mobile.deviceType = configJSONString(object, "device_type")
	}
	if _, present := object["device_unique_id"]; present {
		mobile.deviceUniqueID = configJSONString(object, "device_unique_id")
	}
	return mobile, nil
}

// configOCMobileBuild is OpenConnectMobile::ExportToJson: all three fields are
// emitted together, or none when all are empty.
func configOCMobileBuild(mobile configOCMobile) map[string]any {
	object := map[string]any{}
	if mobile.platformVersion == "" && mobile.deviceType == "" && mobile.deviceUniqueID == "" {
		return object
	}
	object["platform_version"] = mobile.platformVersion
	object["device_type"] = mobile.deviceType
	object["device_unique_id"] = mobile.deviceUniqueID
	return object
}

type configOCWrapper struct {
	wrapperPath string
}

var configOCWrapperKeys = configKeysAllowed("wrapper_path")

func configOCWrapperParse(object map[string]any) (configOCWrapper, error) {
	var wrapper configOCWrapper
	if object == nil {
		return wrapper, nil
	}
	if err := configCheckKeys(object, configOCWrapperKeys, "openconnect.wrapper"); err != nil {
		return wrapper, err
	}
	if _, present := object["wrapper_path"]; present {
		wrapper.wrapperPath = configJSONString(object, "wrapper_path")
	}
	return wrapper, nil
}

func configOCWrapperBuild(wrapper configOCWrapper) map[string]any {
	object := map[string]any{}
	if wrapper.wrapperPath != "" {
		object["wrapper_path"] = wrapper.wrapperPath
	}
	return object
}

type configOCTnccCertificate struct {
	certificate     []string
	certificatePath string
}

var configOCTnccCertificateKeys = configKeysAllowed("certificate", "certificate_path")

func configOCTnccCertificateParse(object map[string]any) (configOCTnccCertificate, error) {
	var cert configOCTnccCertificate
	if object == nil {
		return cert, nil
	}
	if err := configCheckKeys(object, configOCTnccCertificateKeys, "openconnect.tncc.certificate"); err != nil {
		return cert, err
	}
	if _, present := object["certificate"]; present {
		cert.certificate = configOCListable(object["certificate"])
	}
	if _, present := object["certificate_path"]; present {
		cert.certificatePath = configJSONString(object, "certificate_path")
	}
	return cert, nil
}

func configOCTnccCertificateBuild(cert configOCTnccCertificate) map[string]any {
	object := map[string]any{}
	if len(cert.certificate) > 0 {
		object["certificate"] = configOCNonEmptyStrings(cert.certificate)
	}
	if cert.certificatePath != "" {
		object["certificate_path"] = cert.certificatePath
	}
	return object
}

type configOCTncc struct {
	wrapperPath                  string
	deviceID                     string
	userAgent                    string
	machineIdentificationEnabled bool
	certificates                 []configOCTnccCertificate
}

var configOCTnccKeys = configKeysAllowed("wrapper_path", "device_id", "user_agent", "machine_identification_enabled", "certificates")

func configOCTnccParse(object map[string]any) (configOCTncc, error) {
	var tncc configOCTncc
	if object == nil {
		return tncc, nil
	}
	if err := configCheckKeys(object, configOCTnccKeys, "openconnect.tncc"); err != nil {
		return tncc, err
	}
	if _, present := object["wrapper_path"]; present {
		tncc.wrapperPath = configJSONString(object, "wrapper_path")
	}
	if _, present := object["device_id"]; present {
		tncc.deviceID = configJSONString(object, "device_id")
	}
	if _, present := object["user_agent"]; present {
		tncc.userAgent = configJSONString(object, "user_agent")
	}
	if _, present := object["machine_identification_enabled"]; present {
		tncc.machineIdentificationEnabled = configJSONBoolValue(object["machine_identification_enabled"])
	}
	if items, present := object["certificates"]; present {
		tncc.certificates = make([]configOCTnccCertificate, 0)
		for _, item := range configOCArray(items) {
			cert, err := configOCTnccCertificateParse(configJSONObjectValue(item))
			if err != nil {
				return tncc, err
			}
			tncc.certificates = append(tncc.certificates, cert)
		}
	}
	return tncc, nil
}

func configOCTnccBuild(tncc configOCTncc) map[string]any {
	object := map[string]any{}
	if tncc.wrapperPath != "" {
		object["wrapper_path"] = tncc.wrapperPath
	}
	if tncc.deviceID != "" {
		object["device_id"] = tncc.deviceID
	}
	if tncc.userAgent != "" {
		object["user_agent"] = tncc.userAgent
	}
	if tncc.machineIdentificationEnabled {
		object["machine_identification_enabled"] = true
	}
	if len(tncc.certificates) > 0 {
		certs := make([]any, 0, len(tncc.certificates))
		for _, cert := range tncc.certificates {
			item := configOCTnccCertificateBuild(cert)
			if len(item) > 0 {
				certs = append(certs, item)
			}
		}
		if len(certs) > 0 {
			object["certificates"] = certs
		}
	}
	return object
}

type configOCFortinetHostCheck struct {
	hostcheck           string
	checkVirtualDesktop string
}

var configOCFortinetHostCheckKeys = configKeysAllowed("hostcheck", "check_virtual_desktop")

func configOCFortinetHostCheckParse(object map[string]any) (configOCFortinetHostCheck, error) {
	var check configOCFortinetHostCheck
	if object == nil {
		return check, nil
	}
	if err := configCheckKeys(object, configOCFortinetHostCheckKeys, "openconnect.fortinet_host_check"); err != nil {
		return check, err
	}
	if _, present := object["hostcheck"]; present {
		check.hostcheck = configJSONString(object, "hostcheck")
	}
	if _, present := object["check_virtual_desktop"]; present {
		check.checkVirtualDesktop = configJSONString(object, "check_virtual_desktop")
	}
	return check, nil
}

// configOCFortinetHostCheckBuild: an empty hostcheck disables the feature, so
// check_virtual_desktop alone never reaches the core.
func configOCFortinetHostCheckBuild(check configOCFortinetHostCheck) map[string]any {
	object := map[string]any{}
	if check.hostcheck == "" {
		return object
	}
	object["hostcheck"] = check.hostcheck
	if check.checkVirtualDesktop != "" {
		object["check_virtual_desktop"] = check.checkVirtualDesktop
	}
	return object
}

type configOCFormEntry struct {
	formID        string
	submissionKey string
	name          string
	value         string
	promote       bool
}

var configOCFormEntryKeys = configKeysAllowed("form_id", "submission_key", "name", "value", "promote")

func configOCFormEntryParse(object map[string]any) (configOCFormEntry, error) {
	var entry configOCFormEntry
	if object == nil {
		return entry, nil
	}
	if err := configCheckKeys(object, configOCFormEntryKeys, "openconnect.form_entry"); err != nil {
		return entry, err
	}
	if _, present := object["form_id"]; present {
		entry.formID = configJSONString(object, "form_id")
	}
	if _, present := object["submission_key"]; present {
		entry.submissionKey = configJSONString(object, "submission_key")
	}
	if _, present := object["name"]; present {
		entry.name = configJSONString(object, "name")
	}
	if _, present := object["value"]; present {
		entry.value = configJSONString(object, "value")
	}
	if _, present := object["promote"]; present {
		entry.promote = configJSONBoolValue(object["promote"])
	}
	return entry, nil
}

func configOCFormEntryBuild(entry configOCFormEntry) map[string]any {
	object := map[string]any{}
	if entry.submissionKey == "" && (entry.formID == "" || entry.name == "") {
		return object
	}
	if entry.formID != "" {
		object["form_id"] = entry.formID
	}
	if entry.submissionKey != "" {
		object["submission_key"] = entry.submissionKey
	}
	if entry.name != "" {
		object["name"] = entry.name
	}
	if entry.value != "" {
		object["value"] = entry.value
	}
	if entry.promote {
		object["promote"] = true
	}
	return object
}

// configOCTLS is OpenConnect.Tls, not the sing-box TLS block: it has no
// `enabled` / `alpn` keys and never feeds configOutboundTLS.
type configOCTLS struct {
	insecure                 bool
	serverName               string
	peerFingerprint          []string
	systemTrustDisabled      bool
	certificateAuthority     []string
	certificateAuthorityPath string
	clientCertificate        []string
	clientCertificatePath    string
	clientKey                []string
	clientKeyPath            string
	clientKeyPassword        string
	mcaCertificate           []string
	mcaCertificatePath       string
	mcaKey                   []string
	mcaKeyPath               string
	mcaKeyPassword           string
}

var configOCTLSKeys = configKeysAllowed(
	"insecure", "server_name", "peer_fingerprint", "system_trust_disabled",
	"certificate_authority", "certificate_authority_path",
	"client_certificate", "client_certificate_path",
	"client_key", "client_key_path", "client_key_password",
	"mca_certificate", "mca_certificate_path",
	"mca_key", "mca_key_path", "mca_key_password",
)

func configOCTLSParse(object map[string]any) (configOCTLS, error) {
	var tls configOCTLS
	if object == nil {
		return tls, nil
	}
	if err := configCheckKeys(object, configOCTLSKeys, "openconnect.tls"); err != nil {
		return tls, err
	}
	if _, present := object["insecure"]; present {
		tls.insecure = configJSONBoolValue(object["insecure"])
	}
	if _, present := object["server_name"]; present {
		tls.serverName = configJSONString(object, "server_name")
	}
	if _, present := object["peer_fingerprint"]; present {
		tls.peerFingerprint = configOCListable(object["peer_fingerprint"])
	}
	if _, present := object["system_trust_disabled"]; present {
		tls.systemTrustDisabled = configJSONBoolValue(object["system_trust_disabled"])
	}
	if _, present := object["certificate_authority"]; present {
		tls.certificateAuthority = configOCListable(object["certificate_authority"])
	}
	if _, present := object["certificate_authority_path"]; present {
		tls.certificateAuthorityPath = configJSONString(object, "certificate_authority_path")
	}
	if _, present := object["client_certificate"]; present {
		tls.clientCertificate = configOCListable(object["client_certificate"])
	}
	if _, present := object["client_certificate_path"]; present {
		tls.clientCertificatePath = configJSONString(object, "client_certificate_path")
	}
	if _, present := object["client_key"]; present {
		tls.clientKey = configOCListable(object["client_key"])
	}
	if _, present := object["client_key_path"]; present {
		tls.clientKeyPath = configJSONString(object, "client_key_path")
	}
	if _, present := object["client_key_password"]; present {
		tls.clientKeyPassword = configJSONString(object, "client_key_password")
	}
	if _, present := object["mca_certificate"]; present {
		tls.mcaCertificate = configOCListable(object["mca_certificate"])
	}
	if _, present := object["mca_certificate_path"]; present {
		tls.mcaCertificatePath = configJSONString(object, "mca_certificate_path")
	}
	if _, present := object["mca_key"]; present {
		tls.mcaKey = configOCListable(object["mca_key"])
	}
	if _, present := object["mca_key_path"]; present {
		tls.mcaKeyPath = configJSONString(object, "mca_key_path")
	}
	if _, present := object["mca_key_password"]; present {
		tls.mcaKeyPassword = configJSONString(object, "mca_key_password")
	}
	return tls, nil
}

// configOCTLSBuild is OpenConnectTLS::ExportToJson + Build: the server name
// goes through toAceHost, and peer fingerprints are trimmed with blank lines
// removed (the core reads each line verbatim).
func configOCTLSBuild(tls configOCTLS) map[string]any {
	object := map[string]any{}
	if tls.insecure {
		object["insecure"] = true
	}
	if tls.serverName != "" {
		object["server_name"] = configACEHost(tls.serverName)
	}
	if len(tls.peerFingerprint) > 0 {
		fingerprints := make([]string, 0, len(tls.peerFingerprint))
		for _, line := range tls.peerFingerprint {
			trimmed := strings.TrimSpace(line)
			if trimmed != "" {
				fingerprints = append(fingerprints, trimmed)
			}
		}
		if len(fingerprints) > 0 {
			object["peer_fingerprint"] = configOCNonEmptyStrings(fingerprints)
		}
	}
	if tls.systemTrustDisabled {
		object["system_trust_disabled"] = true
	}
	if len(tls.certificateAuthority) > 0 {
		object["certificate_authority"] = configOCNonEmptyStrings(tls.certificateAuthority)
	}
	if tls.certificateAuthorityPath != "" {
		object["certificate_authority_path"] = tls.certificateAuthorityPath
	}
	if len(tls.clientCertificate) > 0 {
		object["client_certificate"] = configOCNonEmptyStrings(tls.clientCertificate)
	}
	if tls.clientCertificatePath != "" {
		object["client_certificate_path"] = tls.clientCertificatePath
	}
	if len(tls.clientKey) > 0 {
		object["client_key"] = configOCNonEmptyStrings(tls.clientKey)
	}
	if tls.clientKeyPath != "" {
		object["client_key_path"] = tls.clientKeyPath
	}
	if tls.clientKeyPassword != "" {
		object["client_key_password"] = tls.clientKeyPassword
	}
	if len(tls.mcaCertificate) > 0 {
		object["mca_certificate"] = configOCNonEmptyStrings(tls.mcaCertificate)
	}
	if tls.mcaCertificatePath != "" {
		object["mca_certificate_path"] = tls.mcaCertificatePath
	}
	if len(tls.mcaKey) > 0 {
		object["mca_key"] = configOCNonEmptyStrings(tls.mcaKey)
	}
	if tls.mcaKeyPath != "" {
		object["mca_key_path"] = tls.mcaKeyPath
	}
	if tls.mcaKeyPassword != "" {
		object["mca_key_password"] = tls.mcaKeyPassword
	}
	return object
}

// --- top-level params ------------------------------------------------------

type configOpenConnectParams struct {
	serverPath                     string
	flavor                         string
	username                       string
	password                       string
	authGroup                      string
	cookie                         string
	token                          configOCToken
	reportedOS                     string
	userAgent                      string
	version                        string
	localHostname                  string
	mobile                         configOCMobile
	csd                            configOCWrapper
	hip                            configOCWrapper
	tncc                           configOCTncc
	fortinetHostCheck              configOCFortinetHostCheck
	formEntries                    []configOCFormEntry
	noUDP                          bool
	dtlsLocalPort                  int
	compressionDisabled            bool
	compressionMode                string
	ipv6Disabled                   bool
	httpKeepaliveDisabled          bool
	xmlPostDisabled                bool
	externalAuthDisabled           bool
	passwordAuthenticationDisabled bool
	tcpKeepAliveEnabled            bool
	pfs                            bool
	mtu                            int
	baseMTU                        int
	dpdInterval                    string
	reconnectTimeout               string
	trojanInterval                 string
	queueLength                    int
	allowInsecureCrypto            bool
	tls                            configOCTLS
	system                         bool
	interfaceName                  string
	udpTimeout                     string
	udpMapping                     string
	udpFiltering                   string
	udpNATMax                      int
	// Throne-only fields (never sent to the core) but read by ParseFromJson so
	// a stored row cannot silently drop them.
	otpProfileID         int
	onlyAdvertisedRoutes bool
	tunnelDNS            string
}

func configOCParseOpenConnect(object map[string]any) (configOpenConnectParams, error) {
	params := configOpenConnectParams{onlyAdvertisedRoutes: true, tunnelDNS: "prefer"}
	if object == nil {
		return params, nil
	}
	// The top-level parser already checked every key against
	// configCommonOutboundKeys + configOutboundTypeKeys("openconnect").

	if _, present := object["server_path"]; present {
		params.serverPath = configJSONString(object, "server_path")
	}
	if _, present := object["flavor"]; present {
		params.flavor = strings.TrimSpace(configJSONString(object, "flavor"))
	}
	if _, present := object["username"]; present {
		params.username = configJSONString(object, "username")
	}
	if _, present := object["password"]; present {
		params.password = configJSONString(object, "password")
	}
	if _, present := object["auth_group"]; present {
		params.authGroup = configJSONString(object, "auth_group")
	}
	if _, present := object["cookie"]; present {
		params.cookie = configJSONString(object, "cookie")
	}
	if _, present := object["token"]; present {
		token, err := configOCTokenParse(configJSONObjectValue(object["token"]))
		if err != nil {
			return params, err
		}
		params.token = token
	}
	if _, present := object["reported_os"]; present {
		params.reportedOS = strings.TrimSpace(configJSONString(object, "reported_os"))
	}
	if _, present := object["user_agent"]; present {
		params.userAgent = configJSONString(object, "user_agent")
	}
	if _, present := object["version"]; present {
		params.version = configJSONString(object, "version")
	}
	if _, present := object["local_hostname"]; present {
		params.localHostname = configJSONString(object, "local_hostname")
	}
	if _, present := object["mobile"]; present {
		mobile, err := configOCMobileParse(configJSONObjectValue(object["mobile"]))
		if err != nil {
			return params, err
		}
		params.mobile = mobile
	}
	if _, present := object["csd"]; present {
		csd, err := configOCWrapperParse(configJSONObjectValue(object["csd"]))
		if err != nil {
			return params, err
		}
		params.csd = csd
	}
	if _, present := object["hip"]; present {
		hip, err := configOCWrapperParse(configJSONObjectValue(object["hip"]))
		if err != nil {
			return params, err
		}
		params.hip = hip
	}
	if _, present := object["tncc"]; present {
		tncc, err := configOCTnccParse(configJSONObjectValue(object["tncc"]))
		if err != nil {
			return params, err
		}
		params.tncc = tncc
	}
	if _, present := object["fortinet_host_check"]; present {
		check, err := configOCFortinetHostCheckParse(configJSONObjectValue(object["fortinet_host_check"]))
		if err != nil {
			return params, err
		}
		params.fortinetHostCheck = check
	}
	if _, present := object["no_udp"]; present {
		params.noUDP = configJSONBoolValue(object["no_udp"])
	}
	if _, present := object["dtls_local_port"]; present {
		params.dtlsLocalPort = configJSONInt(object["dtls_local_port"])
	}
	if _, present := object["compression_disabled"]; present {
		params.compressionDisabled = configJSONBoolValue(object["compression_disabled"])
	}
	if _, present := object["compression_mode"]; present {
		params.compressionMode = strings.TrimSpace(configJSONString(object, "compression_mode"))
	}
	if _, present := object["ipv6_disabled"]; present {
		params.ipv6Disabled = configJSONBoolValue(object["ipv6_disabled"])
	}
	if _, present := object["http_keepalive_disabled"]; present {
		params.httpKeepaliveDisabled = configJSONBoolValue(object["http_keepalive_disabled"])
	}
	if _, present := object["xml_post_disabled"]; present {
		params.xmlPostDisabled = configJSONBoolValue(object["xml_post_disabled"])
	}
	if _, present := object["external_auth_disabled"]; present {
		params.externalAuthDisabled = configJSONBoolValue(object["external_auth_disabled"])
	}
	if _, present := object["password_authentication_disabled"]; present {
		params.passwordAuthenticationDisabled = configJSONBoolValue(object["password_authentication_disabled"])
	}
	if _, present := object["tcp_keep_alive_enabled"]; present {
		params.tcpKeepAliveEnabled = configJSONBoolValue(object["tcp_keep_alive_enabled"])
	}
	if _, present := object["pfs"]; present {
		params.pfs = configJSONBoolValue(object["pfs"])
	}
	if _, present := object["mtu"]; present {
		mtu := configJSONInt(object["mtu"])
		if mtu < 0 || mtu > 65535 {
			mtu = 0
		}
		params.mtu = mtu
	}
	if _, present := object["base_mtu"]; present {
		mtu := configJSONInt(object["base_mtu"])
		if mtu < 0 || mtu > 65535 {
			mtu = 0
		}
		params.baseMTU = mtu
	}
	for key, target := range map[string]*string{
		"dpd_interval":      &params.dpdInterval,
		"reconnect_timeout": &params.reconnectTimeout,
		"trojan_interval":   &params.trojanInterval,
		"udp_timeout":       &params.udpTimeout,
	} {
		if _, present := object[key]; present {
			*target = strings.TrimSpace(configJSONString(object, key))
		}
	}
	if _, present := object["queue_length"]; present {
		params.queueLength = configJSONInt(object["queue_length"])
	}
	if _, present := object["allow_insecure_crypto"]; present {
		params.allowInsecureCrypto = configJSONBoolValue(object["allow_insecure_crypto"])
	}
	if _, present := object["tls"]; present {
		tls, err := configOCTLSParse(configJSONObjectValue(object["tls"]))
		if err != nil {
			return params, err
		}
		params.tls = tls
	}
	if items, present := object["form_entries"]; present {
		params.formEntries = make([]configOCFormEntry, 0)
		for _, item := range configOCArray(items) {
			entry, err := configOCFormEntryParse(configJSONObjectValue(item))
			if err != nil {
				return params, err
			}
			params.formEntries = append(params.formEntries, entry)
		}
	}
	if _, present := object["system"]; present {
		params.system = configJSONBoolValue(object["system"])
	}
	if _, present := object["name"]; present {
		params.interfaceName = configJSONString(object, "name")
	}
	if _, present := object["udp_mapping"]; present {
		params.udpMapping = configJSONString(object, "udp_mapping")
	}
	if _, present := object["udp_filtering"]; present {
		params.udpFiltering = configJSONString(object, "udp_filtering")
	}
	if _, present := object["udp_nat_max"]; present {
		params.udpNATMax = configJSONInt(object["udp_nat_max"])
	}

	if _, present := object["otp_profile_id"]; present {
		params.otpProfileID = configJSONInt(object["otp_profile_id"])
	}
	if _, present := object["only_advertised_routes"]; present {
		params.onlyAdvertisedRoutes = configJSONBoolValue(object["only_advertised_routes"])
	}
	// Profiles saved before the mode existed carry the two checkboxes it replaced.
	if _, present := object["tunnel_dns"]; present {
		params.tunnelDNS = configJSONString(object, "tunnel_dns")
	} else if configJSONBool(object, "block_outside_dns") {
		params.tunnelDNS = "strict"
	} else if _, present := object["use_tunnel_dns"]; present && !configJSONBool(object, "use_tunnel_dns") {
		params.tunnelDNS = "none"
	}
	return params, nil
}

// configOCComposeServer is OpenConnect.composeServer:
// host[:port unless 443][/path], with an IPv6 host bracketed.
func configOCComposeServer(out configOutbound) string {
	if out.server == "" {
		return ""
	}
	server := configOCWrapIPv6Host(out.server)
	if out.serverPort > 0 && out.serverPort != configOpenConnectDefaultPort {
		server += fmt.Sprintf(":%d", out.serverPort)
	}
	if path := out.params.(configOpenConnectParams).serverPath; path != "" {
		if !strings.HasPrefix(path, "/") {
			path = "/" + path
		}
		server += path
	}
	return server
}

// configBuildOpenConnect is OpenConnect.build. The caller (configBuildChain)
// supplies the tag; name/tag handling is identical to every other outbound.
func configBuildOpenConnect(out configOutbound, params configOpenConnectParams) map[string]any {
	object := map[string]any{"type": "openconnect"}
	out.dial.apply(object)
	if url := configOCComposeServer(out); url != "" {
		object["server"] = url
	}
	if params.username != "" {
		object["username"] = params.username
	}
	if params.password != "" {
		object["password"] = params.password
	}
	if params.flavor != "" {
		object["flavor"] = params.flavor
	}
	if params.authGroup != "" {
		object["auth_group"] = params.authGroup
	}
	if params.cookie != "" {
		object["cookie"] = params.cookie
	}
	if token := configOCTokenBuild(params.token); len(token) > 0 {
		object["token"] = token
	}
	if params.reportedOS != "" {
		object["reported_os"] = params.reportedOS
	}
	if params.userAgent != "" {
		object["user_agent"] = params.userAgent
	}
	if params.version != "" {
		object["version"] = params.version
	}
	if params.localHostname != "" {
		object["local_hostname"] = params.localHostname
	}
	if mobile := configOCMobileBuild(params.mobile); len(mobile) > 0 {
		object["mobile"] = mobile
	}
	if csd := configOCWrapperBuild(params.csd); len(csd) > 0 {
		object["csd"] = csd
	}
	if hip := configOCWrapperBuild(params.hip); len(hip) > 0 {
		object["hip"] = hip
	}
	if tncc := configOCTnccBuild(params.tncc); len(tncc) > 0 {
		object["tncc"] = tncc
	}
	if check := configOCFortinetHostCheckBuild(params.fortinetHostCheck); len(check) > 0 {
		object["fortinet_host_check"] = check
	}
	if params.noUDP {
		object["no_udp"] = true
	}
	if params.dtlsLocalPort > 0 {
		object["dtls_local_port"] = params.dtlsLocalPort
	}
	if params.compressionDisabled {
		object["compression_disabled"] = true
	}
	if params.compressionMode != "" {
		object["compression_mode"] = params.compressionMode
	}
	if params.ipv6Disabled {
		object["ipv6_disabled"] = true
	}
	if params.httpKeepaliveDisabled {
		object["http_keepalive_disabled"] = true
	}
	if params.xmlPostDisabled {
		object["xml_post_disabled"] = true
	}
	if params.externalAuthDisabled {
		object["external_auth_disabled"] = true
	}
	if params.passwordAuthenticationDisabled {
		object["password_authentication_disabled"] = true
	}
	if params.tcpKeepAliveEnabled {
		object["tcp_keep_alive_enabled"] = true
	}
	if params.pfs {
		object["pfs"] = true
	}
	if params.mtu > 0 {
		object["mtu"] = params.mtu
	}
	if params.baseMTU > 0 {
		object["base_mtu"] = params.baseMTU
	}
	if params.dpdInterval != "" {
		object["dpd_interval"] = params.dpdInterval
	}
	if params.reconnectTimeout != "" {
		object["reconnect_timeout"] = params.reconnectTimeout
	}
	if params.trojanInterval != "" {
		object["trojan_interval"] = params.trojanInterval
	}
	if params.queueLength > 0 {
		object["queue_length"] = params.queueLength
	}
	if params.allowInsecureCrypto {
		object["allow_insecure_crypto"] = true
	}
	if tls := configOCTLSBuild(params.tls); len(tls) > 0 {
		object["tls"] = tls
	}
	if len(params.formEntries) > 0 {
		entries := make([]any, 0, len(params.formEntries))
		for _, entry := range params.formEntries {
			item := configOCFormEntryBuild(entry)
			if len(item) > 0 {
				entries = append(entries, item)
			}
		}
		if len(entries) > 0 {
			object["form_entries"] = entries
		}
	}
	if params.system {
		object["system"] = true
	}
	if params.interfaceName != "" {
		object["name"] = params.interfaceName
	}
	if params.udpTimeout != "" {
		object["udp_timeout"] = params.udpTimeout
	}
	if params.udpMapping != "" {
		object["udp_mapping"] = params.udpMapping
	}
	if params.udpFiltering != "" {
		object["udp_filtering"] = params.udpFiltering
	}
	if params.udpNATMax > 0 {
		object["udp_nat_max"] = params.udpNATMax
	}
	return object
}
