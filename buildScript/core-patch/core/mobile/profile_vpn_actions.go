// Dispatch for the OpenVPN/OpenConnect slice: the whole-file import paths, the
// stored-JSON import case, the stored exporter and their body detection.
//
// These two types have no share-link scheme and no Clash mapping in Kotlin
// (OutboundFactory's PROTOCOLS table lists neither), so their only import forms
// are the profile files ParseOvpnConfig / ParseOpenConnectProfile accept, a
// stored JSON object, and a Clash entry Kotlin would report as unsupported.
package mobile

import (
	"regexp"
	"strings"
)

// profileVpnOpenConnectCLI is OPENCONNECT_CLI in SubscriptionParser.cpp.
var profileVpnOpenConnectCLI = regexp.MustCompile(`(?:^|\s)--protocol[= ](?:anyconnect|nc|gp|pulse|f5|fortinet)\b`)

// profileVpnOpenConnectFile is OPENCONNECT_FILE: a config-file line.
var profileVpnOpenConnectFile = regexp.MustCompile(`[ \t]*protocol[ \t]*=[ \t]*(?:anyconnect|nc|gp|pulse|f5|fortinet)[ \t]*$`)

// profileLooksLikeOVPNConfig is looksLikeOvpnConfig (SubscriptionParser.cpp):
// a `remote ` line or an inline block, plus a client marker.
func profileLooksLikeOVPNConfig(text string) bool {
	hasRemote := false
	hasClientMarker := false
	for _, raw := range strings.Split(text, "\n") {
		line := profileVpnTrimmed(strings.ReplaceAll(raw, "\r", ""))
		if line == "" || line[0] == '#' || line[0] == ';' {
			continue
		}
		if strings.HasPrefix(line, "remote ") || line == "<ca>" || line == "<tls-auth>" ||
			line == "<tls-crypt>" || line == "<tls-crypt-v2>" || line == "<secret>" {
			hasRemote = true
		}
		if line == "client" || line == "tls-client" || strings.HasPrefix(line, "dev ") ||
			strings.HasPrefix(line, "dev-type ") || strings.HasPrefix(line, "proto ") {
			hasClientMarker = true
		}
		if hasRemote && hasClientMarker {
			return true
		}
	}
	return false
}

// profileLooksLikeOpenConnectProfile is looksLikeOpenConnectProfile.
func profileLooksLikeOpenConnectProfile(text string) bool {
	if strings.Contains(text, "<AnyConnectProfile") || strings.Contains(text, "<ServerList") {
		return true
	}
	if strings.Contains(text, "protocol") {
		for _, raw := range strings.Split(text, "\n") {
			if !strings.Contains(raw, "protocol") {
				continue
			}
			// The config-file form is matched against the whole line, the
			// command-line form anywhere in it.
			if profileVpnOpenConnectCLI.MatchString(strings.ReplaceAll(raw, "\r", "")) ||
				profileVpnOpenConnectFile.MatchString(strings.ReplaceAll(raw, "\r", "")) {
				return true
			}
		}
	}
	for _, raw := range strings.Split(text, "\n") {
		line := profileVpnTrimmed(strings.ReplaceAll(raw, "\r", ""))
		if line == "" || line[0] == '#' {
			continue
		}
		return strings.HasPrefix(line, "openconnect ")
	}
	return false
}

// profileImportVpnFileBody converts an `.ovpn` or OpenConnect profile body.
// handled=false means neither detector matched.
func profileImportVpnFileBody(text string) ([]profileImportedNode, bool, error) {
	if profileLooksLikeOVPNConfig(text) {
		nodes, err := profileImportOVPNFileBody(text)
		return nodes, true, err
	}
	if profileLooksLikeOpenConnectProfile(text) {
		nodes, err := profileImportOpenConnectFileBody(text)
		return nodes, true, err
	}
	return nil, false, nil
}

// profileImportOVPNFileBody is Parser::openVpnFile.
func profileImportOVPNFileBody(text string) ([]profileImportedNode, error) {
	model := newProfileOpenVPN()
	var notes []string
	if !profileOpenVPNParseConfig(model, text, &notes) {
		return nil, profileUnsupported("openvpn: " + profileVpnLastNote(notes))
	}
	node, err := profileOpenVPNNode(model)
	if err != nil {
		return nil, err
	}
	return []profileImportedNode{*node}, nil
}

// profileImportOpenConnectFileBody is Parser::openConnectProfile: an AnyConnect
// XML profile with markers yields one profile per usable host entry; anything
// else is one command line or config file.
func profileImportOpenConnectFileBody(text string) ([]profileImportedNode, error) {
	if strings.Contains(text, "<AnyConnectProfile") || strings.Contains(text, "<ServerList") {
		var notes []string
		models, ok := profileOpenConnectParseConfigAll(text, &notes)
		if !ok {
			reason := profileVpnLastNote(notes)
			if reason == "" {
				reason = "the AnyConnect profile has no usable host"
			}
			return nil, profileUnsupported("openconnect: " + reason)
		}
		nodes := make([]profileImportedNode, 0, len(models))
		for _, model := range models {
			node, err := profileOpenConnectNode(model)
			if err != nil {
				return nil, err
			}
			nodes = append(nodes, *node)
		}
		return nodes, nil
	}
	model := newProfileOpenConnect()
	var notes []string
	ok, err := profileOpenConnectParseConfig(model, text, &notes)
	if err != nil {
		if refused, isRefusal := profileNewRefusal(err); isRefusal {
			return nil, refused
		}
		return nil, err
	}
	if !ok {
		return nil, profileUnsupported("openconnect: " + profileVpnLastNote(notes))
	}
	node, err := profileOpenConnectNode(model)
	if err != nil {
		return nil, err
	}
	return []profileImportedNode{*node}, nil
}

// profileVpnLastNote is the failed import's reason: the importer's notes end
// with the fatal one.
func profileVpnLastNote(notes []string) string {
	for index := len(notes) - 1; index >= 0; index-- {
		if profileVpnTrimmed(notes[index]) != "" {
			return notes[index]
		}
	}
	return "the profile could not be read"
}

// profileImportStoredVpn converts a stored openvpn/openvpn-client/openconnect
// object from a JSON body. importMode keeps Kotlin's import-time drops.
func profileImportStoredVpn(object map[string]any, rawType string) (*profileImportedNode, error) {
	if rawType == "openvpn" || rawType == "openvpn-client" {
		model, unknown, err := profileOpenVPNParseStored(object, profileNewImportMode)
		if err != nil {
			if refused, ok := profileNewRefusal(err); ok {
				return nil, refused
			}
			return nil, err
		}
		if len(unknown) > 0 {
			return nil, profileUnsupported("stored openvpn field not ported yet: " + unknown[0])
		}
		if model.Server == "" && len(model.Servers) == 0 {
			return nil, profileUnsupported("stored openvpn has no valid server")
		}
		if len(model.Servers) == 0 && model.Port <= 0 {
			return nil, profileUnsupported("stored openvpn has no valid server_port")
		}
		return profileOpenVPNNode(model)
	}
	model, unknown, err := profileOpenConnectParseStored(object, profileNewImportMode)
	if err != nil {
		if refused, ok := profileNewRefusal(err); ok {
			return nil, refused
		}
		return nil, err
	}
	if len(unknown) > 0 {
		return nil, profileUnsupported("stored openconnect field not ported yet: " + unknown[0])
	}
	if model.Server == "" {
		return nil, profileUnsupported("stored openconnect has no valid server")
	}
	return profileOpenConnectNode(model)
}

// handleProfileExportVpn exports one stored openvpn/openvpn-client/openconnect
// document. owned=false means another type.
func handleProfileExportVpn(object map[string]any, nameOverride *string) (profileExportReply, bool, error) {
	rawType := configJSONString(object, "type")
	if rawType != "openvpn" && rawType != "openvpn-client" && rawType != "openconnect" {
		return profileExportReply{}, false, nil
	}
	storageType := rawType
	if storageType == "openvpn-client" {
		storageType = "openvpn"
	}

	var node *profileImportedNode
	if storageType == "openvpn" {
		parsed, unknown, err := profileOpenVPNParseStored(object, profileNewExportMode)
		if err != nil {
			if refused, ok := profileNewRefusal(err); ok {
				return profileExportReply{Supported: false, Type: storageType, Reason: refused.Reason}, true, nil
			}
			return profileExportReply{}, true, err
		}
		if len(unknown) > 0 {
			return profileExportReply{
				Supported: false, Type: storageType,
				Reason: "stored openvpn field not ported yet: " + unknown[0],
			}, true, nil
		}
		if nameOverride != nil {
			parsed.Name = strings.TrimSpace(*nameOverride)
		}
		node, err = profileOpenVPNNode(parsed)
		if err != nil {
			if refused, ok := profileNewRefusal(err); ok {
				return profileExportReply{Supported: false, Type: storageType, Reason: refused.Reason}, true, nil
			}
			return profileExportReply{}, true, err
		}
	} else {
		parsed, unknown, err := profileOpenConnectParseStored(object, profileNewExportMode)
		if err != nil {
			if refused, ok := profileNewRefusal(err); ok {
				return profileExportReply{Supported: false, Type: storageType, Reason: refused.Reason}, true, nil
			}
			return profileExportReply{}, true, err
		}
		if len(unknown) > 0 {
			return profileExportReply{
				Supported: false, Type: storageType,
				Reason: "stored openconnect field not ported yet: " + unknown[0],
			}, true, nil
		}
		if nameOverride != nil {
			parsed.Name = strings.TrimSpace(*nameOverride)
		}
		node, err = profileOpenConnectNode(parsed)
		if err != nil {
			if refused, ok := profileNewRefusal(err); ok {
				return profileExportReply{Supported: false, Type: storageType, Reason: refused.Reason}, true, nil
			}
			return profileExportReply{}, true, err
		}
	}
	return profileExportReply{
		Supported:   true,
		Type:        node.Type,
		Name:        node.Name,
		DisplayType: profileVpnDisplayType(node.Type),
		JSON:        node.JSON,
		Link:        node.Link,
		JSONLink:    "throne://add/" + profileBase64Encode([]byte(node.JSON), true, false),
		Identity:    node.Identity,
		DedupKey:    node.DedupKey,
	}, true, nil
}

// profileVpnDisplayType is OpenVpn.displayType / OpenConnect.displayType.
func profileVpnDisplayType(profileType string) string {
	switch profileType {
	case "openvpn":
		return "OpenVPN"
	case "openconnect":
		return "OpenConnect"
	}
	return profileType
}
