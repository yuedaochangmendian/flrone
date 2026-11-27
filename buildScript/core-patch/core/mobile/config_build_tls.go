// TLS / uTLS / ECH / Reality for the Stage-2 outbound builder.
//
// The stored `tls` object is parsed with Tls.parseFromJson's field rules (a
// value of the wrong JSON type keeps the default, trimming only where Kotlin
// trims) and rebuilt with Tls.build: BuildContext's skip_cert, uTLS default
// fingerprint, fragment and TLS-tricks presets fill in whatever the profile
// leaves unset. uTLS is suppressed for hysteria ([supported] false) exactly
// like hysteria.h:52-55.
package mobile

import (
	"encoding/base64"
	"errors"
	"fmt"
	"regexp"
	"strings"
)

// configTLSFragmentShortID is REALITY_SHORT_ID: the core hex-decodes short_id
// into at most 8 bytes.
var configTLSRealityShortID = regexp.MustCompile(`^(?:[0-9a-fA-F]{2}){0,8}$`)

const configTLSUnsafeFingerprint = "unsafe"

const configMLDSA65VerifySize = 1952

type configECHParams struct {
	enabled    bool
	config     []string
	configPath string
	serverName string
	resolver   string
}

type configUTLSParams struct {
	supported   bool
	enabled     bool
	fingerprint string
}

type configRealityParams struct {
	enabled       bool
	publicKey     string
	shortID       string
	mldsa65Verify string
}

type configTLSParams struct {
	enabled                    bool
	disableSNI                 bool
	serverName                 string
	insecure                   bool
	alpn                       []string
	minVersion                 string
	maxVersion                 string
	cipherSuites               []string
	curvePreferences           []string
	certificate                []string
	certificatePath            string
	certificateSHA256          []string
	certificatePublicKeySHA256 []string
	clientCertificate          []string
	clientCertificatePath      string
	clientKey                  []string
	clientKeyPath              string
	fragment                   bool
	fragmentUnspecified        bool
	fragmentFallbackDelay      string
	recordFragment             bool
	spoof                      string
	spoofMethod                string
	spoofEnabled               bool
	spoofUnspecified           bool
	tlsTricks                  bool
	tlsTricksUnspecified       bool
	ech                        configECHParams
	utls                       configUTLSParams
	reality                    configRealityParams
}

// configTLSDefault is a fresh Tls() (the three tri-states are Keep Default).
func configTLSDefault() configTLSParams {
	return configTLSParams{
		fragmentUnspecified:  true,
		spoofUnspecified:     true,
		tlsTricksUnspecified: true,
		utls:                 configUTLSParams{supported: true},
	}
}

// configTLSParse is Tls.parseFromJson. The object is optional (a non-object
// `tls` value is ignored by the Kotlin loader), but every key inside it is
// checked so no stored field can be dropped.
func configTLSParse(object map[string]any) (configTLSParams, error) {
	tls := configTLSDefault()
	if object == nil {
		return tls, nil
	}
	allowed := configKeysAllowed(
		"enabled", "disable_sni", "server_name", "insecure", "alpn", "min_version", "max_version",
		"cipher_suites", "curve_preferences", "certificate", "certificate_path", "certificate_sha256",
		"certificate_public_key_sha256", "client_certificate", "client_certificate_path", "client_key",
		"client_key_path", "fragment", "fragment_fallback_delay", "record_fragment", "spoof",
		"spoof_method", "spoof_enabled", "tls_tricks", "ech", "utls", "reality",
	)
	if err := configCheckKeys(object, allowed, "tls"); err != nil {
		return tls, err
	}
	if _, present := object["enabled"]; present {
		tls.enabled = configJSONBoolValue(object["enabled"])
	}
	if _, present := object["disable_sni"]; present {
		tls.disableSNI = configJSONBoolValue(object["disable_sni"])
	}
	if _, present := object["server_name"]; present {
		tls.serverName = configJSONString(object, "server_name")
	}
	if _, present := object["insecure"]; present {
		tls.insecure = configJSONBoolValue(object["insecure"])
	}
	if _, present := object["alpn"]; present {
		tls.alpn = configJSONStringListValue(object["alpn"])
	}
	if _, present := object["min_version"]; present {
		tls.minVersion = strings.TrimSpace(configJSONString(object, "min_version"))
	}
	if _, present := object["max_version"]; present {
		tls.maxVersion = strings.TrimSpace(configJSONString(object, "max_version"))
	}
	if _, present := object["cipher_suites"]; present {
		tls.cipherSuites = configJSONStringListValue(object["cipher_suites"])
	}
	if _, present := object["curve_preferences"]; present {
		tls.curvePreferences = configJSONStringListValue(object["curve_preferences"])
	}
	if _, present := object["certificate"]; present {
		tls.certificate = configTLSPemLines(object["certificate"])
	}
	if _, present := object["certificate_path"]; present {
		tls.certificatePath = configJSONString(object, "certificate_path")
	}
	if _, present := object["certificate_sha256"]; present {
		tls.certificateSHA256 = configJSONStringListValue(object["certificate_sha256"])
	}
	if _, present := object["certificate_public_key_sha256"]; present {
		tls.certificatePublicKeySHA256 = configJSONStringListValue(object["certificate_public_key_sha256"])
	}
	if _, present := object["client_certificate"]; present {
		tls.clientCertificate = configTLSPemLines(object["client_certificate"])
	}
	if _, present := object["client_certificate_path"]; present {
		tls.clientCertificatePath = configJSONString(object, "client_certificate_path")
	}
	if _, present := object["client_key"]; present {
		tls.clientKey = configTLSPemLines(object["client_key"])
	}
	if _, present := object["client_key_path"]; present {
		tls.clientKeyPath = configJSONString(object, "client_key_path")
	}
	if _, present := object["fragment"]; present {
		tls.fragment = configJSONBoolValue(object["fragment"])
		tls.fragmentUnspecified = false
	}
	if _, present := object["fragment_fallback_delay"]; present {
		tls.fragmentFallbackDelay = strings.TrimSpace(configJSONString(object, "fragment_fallback_delay"))
	}
	if _, present := object["record_fragment"]; present {
		tls.recordFragment = configJSONBoolValue(object["record_fragment"])
	}
	if _, present := object["spoof"]; present {
		tls.spoof = configJSONString(object, "spoof")
	}
	if _, present := object["spoof_method"]; present {
		tls.spoofMethod = strings.TrimSpace(configJSONString(object, "spoof_method"))
	}
	if _, present := object["spoof_enabled"]; present {
		tls.spoofEnabled = configJSONBoolValue(object["spoof_enabled"])
		tls.spoofUnspecified = false
	}
	if _, present := object["tls_tricks"]; present {
		if nested := configJSONObjectValue(object["tls_tricks"]); nested != nil {
			if err := configCheckKeys(nested, configKeysAllowed("mixedcase_sni"), "tls.tls_tricks"); err != nil {
				return tls, err
			}
			tls.tlsTricks = configJSONBoolValue(nested["mixedcase_sni"])
		}
		tls.tlsTricksUnspecified = false
	}
	if nested := configJSONObjectValue(object["ech"]); nested != nil {
		if err := configCheckKeys(nested, configKeysAllowed("enabled", "config", "config_path", "query_server_name", "resolver"), "tls.ech"); err != nil {
			return tls, err
		}
		if _, present := nested["enabled"]; present {
			tls.ech.enabled = configJSONBoolValue(nested["enabled"])
		}
		if _, present := nested["config"]; present {
			tls.ech.config = configECHNormalize(configTLSPemLines(nested["config"]))
		}
		if _, present := nested["config_path"]; present {
			tls.ech.configPath = configJSONString(nested, "config_path")
		}
		if _, present := nested["query_server_name"]; present {
			tls.ech.serverName = configJSONString(nested, "query_server_name")
		}
		if _, present := nested["resolver"]; present {
			tls.ech.resolver = configJSONString(nested, "resolver")
		}
	}
	if nested := configJSONObjectValue(object["utls"]); nested != nil {
		if err := configCheckKeys(nested, configKeysAllowed("enabled", "fingerprint"), "tls.utls"); err != nil {
			return tls, err
		}
		if _, present := nested["enabled"]; present {
			tls.utls.enabled = configJSONBoolValue(nested["enabled"])
		}
		if _, present := nested["fingerprint"]; present {
			tls.utls.fingerprint = configJSONString(nested, "fingerprint")
		}
	}
	if nested := configJSONObjectValue(object["reality"]); nested != nil {
		if err := configCheckKeys(nested, configKeysAllowed("enabled", "public_key", "short_id", "mldsa65_verify", "mldsa65Verify"), "tls.reality"); err != nil {
			return tls, err
		}
		if _, present := nested["enabled"]; present {
			tls.reality.enabled = configJSONBoolValue(nested["enabled"])
		}
		if _, present := nested["public_key"]; present {
			tls.reality.publicKey = strings.TrimSpace(configJSONString(nested, "public_key"))
		}
		if _, present := nested["short_id"]; present {
			tls.reality.shortID = strings.TrimSpace(configJSONString(nested, "short_id"))
		}
		verify := ""
		if _, present := nested["mldsa65_verify"]; present {
			verify = configJSONString(nested, "mldsa65_verify")
		} else if _, present := nested["mldsa65Verify"]; present {
			verify = configJSONString(nested, "mldsa65Verify")
		}
		if strings.TrimSpace(verify) != "" {
			tls.reality.mldsa65Verify = strings.TrimSpace(verify)
		}
	}
	if tls.reality.publicKey != "" {
		tls.enabled = true
	}
	return tls, nil
}

// configTLSPemLines is tlsPemLines: a string or string list, then each item
// split at newlines with the empty lines dropped.
func configTLSPemLines(value any) []string {
	items := configJSONStringListValue(value)
	out := make([]string, 0, len(items))
	for _, item := range items {
		for _, line := range strings.Split(item, "\n") {
			if line != "" {
				out = append(out, line)
			}
		}
	}
	return out
}

// configECHNormalize is Ech.NormalizeConfig: a bare base64 list becomes one PEM
// block; a list already carrying BEGIN lines is kept.
func configECHNormalize(items []string) []string {
	for _, item := range items {
		if strings.Contains(item, "-----BEGIN") {
			return append([]string(nil), items...)
		}
	}
	joined := strings.TrimSpace(strings.Join(items, ""))
	if joined == "" {
		return []string{}
	}
	return []string{"-----BEGIN ECH CONFIGS-----", joined, "-----END ECH CONFIGS-----"}
}

// configNonBlankStrings is JsonValues.stringArray: blank items dropped.
func configNonBlankStrings(values []string) []any {
	out := make([]any, 0, len(values))
	for _, value := range values {
		if strings.TrimSpace(value) == "" {
			continue
		}
		out = append(out, value)
	}
	return out
}

// configFragmentEffectivelyOn is TLS::FragmentEffectivelyOn.
func (tls configTLSParams) fragmentEffectivelyOn(settings simpleConfigSettings) bool {
	if tls.fragment {
		return true
	}
	if tls.fragmentUnspecified {
		return settings.FragmentDefaultOn
	}
	return false
}

// configTLSTricksEffectivelyOn is TLS::TlsTricksEffectivelyOn.
func (tls configTLSParams) tlsTricksEffectivelyOn(settings simpleConfigSettings) bool {
	if tls.tlsTricks {
		return true
	}
	if tls.tlsTricksUnspecified {
		return settings.TLSTricksDefaultOn
	}
	return false
}

// configUTLSBuild is UTls::Build: the global fingerprint fills in whenever the
// profile has no usable one, and "unsafe" turns uTLS off.
func configUTLSBuild(utls configUTLSParams, settings simpleConfigSettings) map[string]any {
	if !utls.supported {
		return map[string]any{}
	}
	object := map[string]any{}
	if utls.enabled {
		object["enabled"] = true
		if utls.fingerprint != "" {
			object["fingerprint"] = utls.fingerprint
		}
	}
	_, enabled := object["enabled"]
	fingerprint := configJSONString(object, "fingerprint")
	if (!enabled || fingerprint == "") && settings.UtlsFingerprint != "" {
		object["enabled"] = true
		object["fingerprint"] = settings.UtlsFingerprint
	}
	if configJSONString(object, "fingerprint") == configTLSUnsafeFingerprint {
		return map[string]any{}
	}
	return object
}

// configECHBuild is Ech::Build: the stored exporter minus the Throne-only
// resolver.
func configECHBuild(ech configECHParams) (map[string]any, error) {
	object := map[string]any{}
	if !ech.enabled {
		return object, nil
	}
	object["enabled"] = true
	if len(ech.config) > 0 {
		object["config"] = configNonBlankStrings(ech.config)
	}
	if ech.configPath != "" {
		object["config_path"] = ech.configPath
	}
	if ech.serverName != "" {
		ace, err := configACEHost(ech.serverName)
		if err != nil {
			return nil, fmt.Errorf("tls.ech.query_server_name: %w", err)
		}
		object["query_server_name"] = ace
	}
	return object, nil
}

// configRealityBuild is Reality::Build: public_key is always written, a
// short_id the core would refuse is left out, and buildError refuses the
// profile instead of emitting a config that cannot start.
func configRealityBuild(reality configRealityParams) (map[string]any, error) {
	object := map[string]any{}
	if reality.publicKey == "" && !reality.enabled {
		return object, nil
	}
	if reality.mldsa65Verify != "" && !configIsMLDSA65VerifyKey(reality.mldsa65Verify) {
		return nil, errors.New("tls.reality.mldsa65_verify is not a base64url ML-DSA-65 verification key")
	}
	if !configTLSRealityShortID.MatchString(reality.shortID) {
		return nil, errors.New("tls.reality.short_id is not 0-16 hex digits")
	}
	object["enabled"] = true
	object["public_key"] = reality.publicKey
	if reality.shortID != "" {
		object["short_id"] = reality.shortID
	}
	if reality.mldsa65Verify != "" {
		object["mldsa65_verify"] = reality.mldsa65Verify
	}
	return object, nil
}

// configIsMLDSA65VerifyKey is isMldsa65VerifyKey: unpadded base64url of a
// 1952-byte key.
func configIsMLDSA65VerifyKey(value string) bool {
	key := strings.TrimSpace(value)
	if key == "" || strings.Contains(key, "=") {
		return false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(key)
	return err == nil && len(decoded) == configMLDSA65VerifySize
}

// configTLSBuild is Tls.build. [customFragment] tells it the dialer-level
// fragment already covers this outbound (Outbound.baseBuild), in which case the
// TLS block leaves `fragment` out.
func configTLSBuild(tls configTLSParams, settings simpleConfigSettings, customFragment bool) (map[string]any, error) {
	object := map[string]any{}
	if !tls.enabled {
		return object, nil
	}
	object["enabled"] = true
	if tls.disableSNI {
		object["disable_sni"] = true
	}
	if tls.serverName != "" {
		ace, err := configACEHost(tls.serverName)
		if err != nil {
			return nil, fmt.Errorf("tls.server_name: %w", err)
		}
		object["server_name"] = ace
	}
	if tls.insecure || settings.SkipCert {
		object["insecure"] = true
	}
	if len(tls.alpn) > 0 {
		object["alpn"] = configNonBlankStrings(tls.alpn)
	}
	if tls.minVersion != "" {
		object["min_version"] = tls.minVersion
	}
	if tls.maxVersion != "" {
		object["max_version"] = tls.maxVersion
	}
	if len(tls.cipherSuites) > 0 {
		object["cipher_suites"] = configNonBlankStrings(tls.cipherSuites)
	}
	if len(tls.curvePreferences) > 0 {
		object["curve_preferences"] = configNonBlankStrings(tls.curvePreferences)
	}
	if len(tls.certificate) > 0 {
		object["certificate"] = configNonBlankStrings(tls.certificate)
	}
	if tls.certificatePath != "" {
		object["certificate_path"] = tls.certificatePath
	}
	if len(tls.certificateSHA256) > 0 {
		object["certificate_sha256"] = configNonBlankStrings(tls.certificateSHA256)
	}
	if len(tls.certificatePublicKeySHA256) > 0 {
		object["certificate_public_key_sha256"] = configNonBlankStrings(tls.certificatePublicKeySHA256)
	}
	if len(tls.clientCertificate) > 0 {
		object["client_certificate"] = configNonBlankStrings(tls.clientCertificate)
	}
	if tls.clientCertificatePath != "" {
		object["client_certificate_path"] = tls.clientCertificatePath
	}
	if len(tls.clientKey) > 0 {
		object["client_key"] = configNonBlankStrings(tls.clientKey)
	}
	if tls.clientKeyPath != "" {
		object["client_key_path"] = tls.clientKeyPath
	}
	if tls.fragmentEffectivelyOn(settings) && settings.FragmentImplementation != "custom" {
		object["fragment"] = true
		if tls.fragmentFallbackDelay != "" {
			object["fragment_fallback_delay"] = tls.fragmentFallbackDelay
		}
	}
	if tls.recordFragment {
		object["record_fragment"] = true
	}
	if tls.tlsTricksEffectivelyOn(settings) {
		object["tls_tricks"] = map[string]any{"mixedcase_sni": true}
	}
	ech, err := configECHBuild(tls.ech)
	if err != nil {
		return nil, err
	}
	if len(ech) > 0 {
		object["ech"] = ech
	}
	utls := configUTLSBuild(tls.utls, settings)
	if len(utls) > 0 {
		object["utls"] = utls
	} else if tls.reality.enabled {
		object["utls"] = map[string]any{"enabled": true, "fingerprint": "random"}
	}
	reality, err := configRealityBuild(tls.reality)
	if err != nil {
		return nil, err
	}
	if len(reality) > 0 {
		object["reality"] = reality
	}
	return object, nil
}
