// S5 export slice for WireGuard and MASQUE: the stored-form exporter used by
// the profileExport action (Dart's nodeLink / identityOfStoredNode).
//
// Oracle: WireGuard.exportToJson/exportToLink/exportIdentity and
// Masque.exportToJson/exportIdentity (outbound/types/{WireGuard,Masque}.kt plus
// outbound/Outbound.kt's base identity). The reader is the stored-row gate (no
// ParseDiag), so the values a stored row carries come back rewritten only where
// those exporters rewrite them (FixAddress/HostPrefixed, WriteKeepalive, the
// Amnezia zero-value filter, the TLS canonical form).
//
// A document carrying a field this slice cannot reproduce byte for byte is
// answered supported:false with the reason, and the caller falls back to the
// Kotlin exporter unchanged -- the same contract as the other export slices.
package mobile

import "strings"

// handleProfileExportWg exports one stored wireguard/masque outbound.
// `owned` is false when the document is another type.
func handleProfileExportWg(object map[string]any, nameOverride *string) (profileExportReply, bool, error) {
	rawType := configJSONString(object, "type")
	if !profileWgTypes[rawType] {
		return profileExportReply{}, false, nil
	}
	var (
		node *profileImportedNode
		err  error
	)
	if rawType == "wireguard" {
		parsed, parseErr := profileWgFromObject(object, profileNewExportMode)
		if parseErr != nil {
			err = parseErr
		} else if len(parsed.Unknown) > 0 {
			return profileExportReply{
				Supported: false, Type: rawType,
				Reason: "stored wireguard field not ported yet: " + parsed.Unknown[0],
			}, true, nil
		} else {
			parsed.Node.Name = wgNameOverride(parsed.Node.Name, nameOverride)
			node, err = profileWgNode(parsed.Node)
		}
	} else {
		parsed, parseErr := profileMasqueFromObject(object, profileNewExportMode)
		if parseErr != nil {
			err = parseErr
		} else if len(parsed.Unknown) > 0 {
			return profileExportReply{
				Supported: false, Type: rawType,
				Reason: "stored masque field not ported yet: " + parsed.Unknown[0],
			}, true, nil
		} else {
			parsed.Node.Name = wgNameOverride(parsed.Node.Name, nameOverride)
			node, err = profileMasqueNode(parsed.Node)
		}
	}
	if err != nil {
		if refused, ok := profileWgRefusal(err); ok {
			return profileExportReply{Supported: false, Type: rawType, Reason: refused.Reason}, true, nil
		}
		return profileExportReply{}, true, err
	}
	return profileExportReply{
		Supported:   true,
		Type:        node.Type,
		Name:        node.Name,
		DisplayType: profileWgMasqueDisplayType(node.Type),
		JSON:        node.JSON,
		Link:        node.Link,
		JSONLink:    "throne://add/" + profileBase64Encode([]byte(node.JSON), true, false),
		Identity:    node.Identity,
		DedupKey:    node.DedupKey,
	}, true, nil
}

func wgNameOverride(current string, nameOverride *string) string {
	if nameOverride == nil {
		return current
	}
	return strings.TrimSpace(*nameOverride)
}

// profileStoredNormalizeWireGuard is the editor save path's canonicalisation:
// the same stored-row gate the exporter uses.
func profileStoredNormalizeWireGuard(object map[string]any) (string, string, error) {
	parsed, err := profileWgFromObject(object, profileNewExportMode)
	if err != nil {
		if refused, ok := profileWgRefusal(err); ok {
			return "", refused.Reason, nil
		}
		return "", "", err
	}
	if len(parsed.Unknown) > 0 {
		return "", "stored wireguard field not ported yet: " + parsed.Unknown[0], nil
	}
	encoded, err := MarshalCanonicalJSON(profileWgObject(parsed.Node))
	return string(encoded), "", err
}

// profileStoredNormalizeMasque is the masque counterpart.
func profileStoredNormalizeMasque(object map[string]any) (string, string, error) {
	parsed, err := profileMasqueFromObject(object, profileNewExportMode)
	if err != nil {
		if refused, ok := profileWgRefusal(err); ok {
			return "", refused.Reason, nil
		}
		return "", "", err
	}
	if len(parsed.Unknown) > 0 {
		return "", "stored masque field not ported yet: " + parsed.Unknown[0], nil
	}
	encoded, err := MarshalCanonicalJSON(profileMasqueObject(parsed.Node))
	return string(encoded), "", err
}
