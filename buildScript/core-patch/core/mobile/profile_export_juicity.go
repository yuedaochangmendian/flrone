// S5 export slice for juicity, naive, ssh and trusttunnel: the stored-form
// exporter used by the profileExport action (Dart's nodeLink) for the four
// types the import slice added.
//
// Oracle: Juicity.exportToJson/exportToLink/exportIdentity, Naive's, Ssh's and
// TrustTunnel's (outbound/types/{Juicity,Naive,Ssh,TrustTunnel}.kt plus
// common/Tls.kt). The reader is the stored-row gate (no ParseDiag), so the
// values a stored row carries come back rewritten only where those exporters
// rewrite them.
//
// A document carrying a field this slice cannot reproduce byte for byte is
// answered supported:false with the reason, and the caller falls back to the
// Kotlin exporter unchanged -- the same contract as the other export slices.
package mobile

import (
	"strconv"
	"strings"
)

// handleProfileExportS5New exports one stored outbound of the four types.
// `owned` is false when the document is another type (the caller tries the
// advanced slice next).
func handleProfileExportS5New(object map[string]any, nameOverride *string) (profileExportReply, bool, error) {
	rawType := configJSONString(object, "type")
	if !profileS5NewTypes[rawType] {
		return profileExportReply{}, false, nil
	}
	parsed, err := profileS5FromObject(object, rawType, profileNewExportMode)
	if err != nil {
		if refused, ok := profileNewRefusal(err); ok {
			return profileExportReply{Supported: false, Type: rawType, Reason: refused.Reason}, true, nil
		}
		return profileExportReply{}, true, err
	}
	if len(parsed.Unknown) > 0 {
		return profileExportReply{
			Supported: false, Type: rawType,
			Reason: "stored " + rawType + " field not ported yet: " + parsed.Unknown[0],
		}, true, nil
	}
	node := parsed.Node
	if nameOverride != nil {
		node.Name = strings.TrimSpace(*nameOverride)
	}
	imported, err := profileAdvancedNodeWithObject(node, profileS5NewObject(node))
	if err != nil {
		if refused, ok := profileNewRefusal(err); ok {
			return profileExportReply{Supported: false, Type: rawType, Reason: refused.Reason}, true, nil
		}
		return profileExportReply{}, true, err
	}
	return profileExportReply{
		Supported:   true,
		Type:        node.Type,
		Name:        node.Name,
		DisplayType: profileS5NewDisplayType(node.Type),
		JSON:        imported.JSON,
		Link:        imported.Link,
		JSONLink:    "throne://add/" + profileBase64Encode([]byte(imported.JSON), true, false),
		Identity:    imported.Identity,
		DedupKey:    imported.DedupKey,
	}, true, nil
}

// profileS5NewLink is the type's exportToLink over the stored node.
func profileS5NewLink(node *profileStoredAdvanced) (string, error) {
	fields := node.Fields
	builder := profileStoredLinkBuilder{
		host:           node.Server,
		port:           node.Port,
		fragment:       node.Name,
		hasFragment:    node.Name != "",
		allowEmptyHost: true,
	}
	var query []profileStoredQueryItem
	switch node.Type {
	case "juicity":
		// Juicity.exportToLink: uuid as the user name, the password slot, the
		// authority port always, then the TLS block (nothing while TLS is off)
		// and the dial fields.
		builder.scheme = "juicity"
		if uuid := configJSONString(fields, "uuid"); uuid != "" {
			builder.username, builder.hasUsername = uuid, true
		}
		if password := configJSONString(fields, "password"); password != "" {
			builder.password, builder.hasPassword = password, true
		}
		query = append(query, profileExportTLSQuery(node.TLS)...)
		query = append(query, profileAdvancedDialQuery(node)...)
	case "naive":
		// Naive.exportToLink: only the TLS fields the model proves, the
		// percent-encoded header block, and the authority port only when set.
		if configJSONBool(fields, "quic") {
			builder.scheme = "naive+quic"
		} else {
			builder.scheme = "naive+https"
		}
		builder.port = -1
		if node.Port > 0 {
			builder.port = node.Port
		}
		if username := configJSONString(fields, "username"); username != "" {
			builder.username, builder.hasUsername = username, true
		}
		if password := configJSONString(fields, "password"); password != "" {
			builder.password, builder.hasPassword = password, true
		}
		tls := node.TLS
		if serverName := configJSONString(tls, "server_name"); serverName != "" {
			query = append(query, profileStoredQueryItem{key: "sni", value: serverName})
		}
		if headers, ok := fields["extra_headers"].(map[string]any); ok && len(headers) > 0 {
			encoded := profileNaiveExportExtraHeaders(profileNaivePairsFromObject(headers))
			query = append(query, profileStoredQueryItem{key: "extra-headers", value: encoded, encoded: true})
		}
		if concurrency := configJSONInt(fields["insecure_concurrency"]); concurrency > 0 {
			query = append(query, profileStoredQueryItem{key: "insecure-concurrency", value: strconv.Itoa(concurrency)})
		}
		if configJSONBool(fields, "udp_over_tcp") {
			query = append(query, profileStoredQueryItem{key: "uot", value: "1"})
		}
		if configJSONBool(fields, "quic") {
			if congestion := configJSONString(fields, "quic_congestion_control"); congestion != "" {
				query = append(query, profileStoredQueryItem{key: "congestion_control", value: congestion})
			}
		}
		if certificate := configJSONStringListValue(tls["certificate"]); len(certificate) > 0 {
			query = append(query, profileStoredQueryItem{key: "tls_certificate", value: strings.Join(certificate, ",")})
		}
		if path := configJSONString(tls, "certificate_path"); path != "" {
			query = append(query, profileStoredQueryItem{key: "tls_certificate_path", value: path})
		}
		if value, present := tls["fragment"]; present {
			enabled, _ := value.(bool)
			query = append(query, profileStoredQueryItem{key: "tls_fragment", value: strconv.FormatBool(enabled)})
		}
		if ech, ok := tls["ech"].(map[string]any); ok && configJSONBool(ech, "enabled") {
			query = append(query, profileExportECHQuery(ech)...)
		}
		query = append(query, profileAdvancedDialQuery(node)...)
	case "ssh":
		// Ssh.exportToLink: user/password in the query (not the user-info), keys
		// base64 without padding, list items joined by '-', the authority port
		// always, then the dial fields.
		builder.scheme = "ssh"
		if user := configJSONString(fields, "user"); user != "" {
			query = append(query, profileStoredQueryItem{key: "user", value: user})
		}
		if password := configJSONString(fields, "password"); password != "" {
			query = append(query, profileStoredQueryItem{key: "password", value: password})
		}
		if privateKey := configJSONString(fields, "private_key"); privateKey != "" {
			query = append(query, profileStoredQueryItem{key: "private_key", value: profileBase64Encode([]byte(privateKey), false, false)})
		}
		if path := configJSONString(fields, "private_key_path"); path != "" {
			query = append(query, profileStoredQueryItem{key: "private_key_path", value: path})
		}
		if passphrase := configJSONString(fields, "private_key_passphrase"); passphrase != "" {
			query = append(query, profileStoredQueryItem{key: "private_key_passphrase", value: passphrase})
		}
		if items := configJSONStringListValue(fields["host_key"]); len(items) > 0 {
			query = append(query, profileStoredQueryItem{key: "host_key", value: profileSSHLinkList(items)})
		}
		if items := configJSONStringListValue(fields["host_key_algorithms"]); len(items) > 0 {
			query = append(query, profileStoredQueryItem{key: "host_key_algorithms", value: profileSSHLinkList(items)})
		}
		if clientVersion := configJSONString(fields, "client_version"); clientVersion != "" {
			query = append(query, profileStoredQueryItem{key: "client_version", value: clientVersion})
		}
		query = append(query, profileAdvancedDialQuery(node)...)
	case "trusttunnel":
		// TrustTunnel.exportToLink: credentials, health_check, QUIC implied by
		// congestion_control ("bbr" when the stored name is empty), the two SNI
		// fields, then TLS and the dial fields.
		builder.scheme = "tt"
		if username := configJSONString(fields, "username"); username != "" {
			builder.username, builder.hasUsername = username, true
		}
		if password := configJSONString(fields, "password"); password != "" {
			builder.password, builder.hasPassword = password, true
		}
		if configJSONBool(fields, "health_check") {
			query = append(query, profileStoredQueryItem{key: "health_check", value: "true"})
		}
		if configJSONBool(fields, "quic") {
			congestion := configJSONString(fields, "quic_congestion_control")
			if congestion == "" {
				congestion = "bbr"
			}
			query = append(query, profileStoredQueryItem{key: "congestion_control", value: congestion})
		}
		if customSNI := configJSONString(fields, "custom_sni"); customSNI != "" {
			query = append(query, profileStoredQueryItem{key: "custom_sni", value: customSNI})
		}
		if clientRandom := configJSONString(fields, "client_random"); clientRandom != "" {
			query = append(query, profileStoredQueryItem{key: "client_random", value: clientRandom})
		}
		query = append(query, profileExportTLSQuery(node.TLS)...)
		query = append(query, profileAdvancedDialQuery(node)...)
	default:
		return "", nil
	}
	builder.query = query
	return builder.build(), nil
}

// profileSSHLinkList is Ssh.exportToLink's list rendering: each item as its own
// unpadded standard-base64 text, joined by '-'.
func profileSSHLinkList(items []string) string {
	encoded := make([]string, 0, len(items))
	for _, item := range items {
		encoded = append(encoded, profileBase64Encode([]byte(item), false, false))
	}
	return strings.Join(encoded, "-")
}
