// S5 export slice for mieru, snell and shadowtls: the stored-form exporter
// used by the profileExport action (Dart's nodeLink) for the three types the
// import slice added.
//
// Oracle: Mieru.exportToJson/exportToLink/exportIdentity, Snell's and
// ShadowTls' (outbound/types/{Mieru,Snell,ShadowTls}.kt plus common/Tls.kt).
// The reader is the stored-row gate (no ParseDiag), so the values a stored row
// carries come back rewritten only where those exporters rewrite them.
//
// A document carrying a field this slice cannot reproduce byte for byte is
// answered supported:false with the reason, and the caller falls back to the
// Kotlin exporter unchanged -- the same contract as the other export slices.
package mobile

import "strings"

// handleProfileExportNew exports one stored outbound of the three new types.
// `owned` is false when the document is another type (the caller tries the
// advanced slice next).
func handleProfileExportNew(object map[string]any, nameOverride *string) (profileExportReply, bool, error) {
	rawType := configJSONString(object, "type")
	if !profileNewoutMieruTypes[rawType] {
		return profileExportReply{}, false, nil
	}
	parsed, err := profileNewFromObject(object, rawType, profileNewExportMode)
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
	imported, err := profileAdvancedNode(node)
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
		DisplayType: profileNewOutboundDisplayType(node.Type),
		JSON:        imported.JSON,
		Link:        imported.Link,
		JSONLink:    "throne://add/" + profileBase64Encode([]byte(imported.JSON), true, false),
		Identity:    imported.Identity,
		DedupKey:    imported.DedupKey,
	}, true, nil
}
