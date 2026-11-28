// JSON link import: `throne://add/<base64>` and `json://#<base64url>` carry
// one stored document (Parser::jsonLink in SubscriptionParser.cpp). They are
// what the node page's Copy link/QR emits for the protocols without a share
// URI (direct, custom, chain, autoselector), so the importer must read them
// back through the same normalizer the rest of the profile codec uses.
package mobile

import (
	"fmt"
	"strings"
)

func profileImportJSONLink(link string, throneAdd bool) (*profileImportedNode, error) {
	_, rest, ok := strings.Cut(link, "://")
	if !ok {
		return nil, profileUnsupported("no URL scheme: expected a JSON link")
	}
	var payload string
	if throneAdd {
		if !strings.HasPrefix(strings.ToLower(rest), "add/") {
			return nil, profileUnsupported("a throne JSON link must be throne://add/<base64>")
		}
		payload = rest[len("add/"):]
	} else {
		_, fragment, hasFragment := strings.Cut(rest, "#")
		if !hasFragment {
			return nil, profileUnsupported("a json:// link must carry #<base64url>")
		}
		payload = fragment
	}
	payload = strings.TrimSpace(payload)
	decoded, ok := profileBase64Decode(payload, false)
	if (!ok || len(decoded) == 0) && throneAdd {
		// ExportJsonLink emits the URL-safe alphabet, which the standard decoder
		// rejects whenever '-' or '_' occurs.
		decoded, ok = profileBase64Decode(payload, true)
	}
	if !ok || len(decoded) == 0 {
		return nil, profileUnsupported("the JSON link payload is not valid base64")
	}
	documents := string(decoded)
	object, ok := configDecodeJSONObject(documents)
	if !ok {
		return nil, profileUnsupported("the JSON link payload is not a JSON object")
	}
	if _, legacy := object["protocol"]; legacy {
		conversion := profileXrayConvertOutbound(object)
		if conversion.node != nil {
			return conversion.node, nil
		}
		if conversion.reason != "" {
			return nil, profileUnsupported(conversion.reason)
		}
		return nil, profileUnsupported("the legacy Xray document could not be converted")
	}
	answer, err := handleProfileNormalizeStored(documents)
	if err != nil {
		return nil, err
	}
	normalized, ok := answer.(profileStoredNormalizeResult)
	if !ok || !normalized.Supported {
		return nil, profileUnsupported(normalized.Reason)
	}
	canonical, ok := configDecodeJSONObject(normalized.JSON)
	if !ok {
		return nil, fmt.Errorf("profileImport: the normalizer answered a non-object document")
	}
	nodeType := strings.TrimSpace(configJSONString(canonical, "type"))
	if nodeType == "" {
		return nil, profileUnsupported("the JSON link document has no type")
	}
	dedup := configDecodeJSONObjectOrEmpty(normalized.JSON)
	delete(dedup, "tag")
	name := configJSONString(canonical, "tag")
	if name == "" {
		switch nodeType {
		case "custom", "chain", "autoselector":
			name = configJSONString(canonical, "name")
		}
	}
	return &profileImportedNode{
		Type:     nodeType,
		Name:     name,
		JSON:     normalized.JSON,
		DedupKey: "throne://add/" + profileBase64Encode([]byte(canonicalJSONOf(dedup)), true, false),
	}, nil
}

func configDecodeJSONObjectOrEmpty(document string) map[string]any {
	object, ok := configDecodeJSONObject(document)
	if !ok {
		return map[string]any{}
	}
	return object
}

func canonicalJSONOf(object map[string]any) string {
	encoded, err := MarshalCanonicalJSON(object)
	if err != nil {
		return "{}"
	}
	return string(encoded)
}
