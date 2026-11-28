// The profileImport action: one share link in, one Throne stored node out.
//
// Wire shape (the Dart ActionMethod member IS the wire name):
//
//	profileImport {"text":"ss://…#Name"}
//	  → {"supported":true,"nodes":[{"type":"shadowsocks","name":"Name",
//	       "json":"…","link":"…","identity":"…","dedupKey":"…"}]}
//	  → {"supported":false,"reason":"https/security=tls is not ported yet …"}
//
// The reply shape deliberately carries `nodes` even though this slice accepts
// exactly one link: a future corpus/import slice can add more nodes to the
// same reply without changing the wire, and a caller that only handles one
// node simply reads nodes[0]. A refusal never emits a node, so a partially
// normalized link cannot reach the document store.
//
// Remaining work (protocols whose Kotlin parser depends on Tls.kt /
// Transport.kt / Multiplex.kt and which are therefore left supported:false):
//
//   - vmess: V2RayN base64 JSON and URL forms; security/packet-encoding
//     normalization, alterId, transport.type/host/path, Tls (SNI/ALPN/uTLS/
//     Reality/ECH) and Multiplex all have to agree byte for byte.
//   - vless: flow/encryption/packet-encoding normalization plus the same
//     TLS/transport/multiplex blocks; the extended kernel's `encryption`
//     field has no Go stored-form counterpart yet.
//   - trojan: TLS is mandatory in practice and the transport/multiplex blocks
//     use the same shared parsers.
//   - hysteria/hysteria2/hy2: protocol-version, obfs, auth, port lists,
//     bandwidth windows, gecko/salamander obfs and QUIC-specific TLS fields.
//
// None of those fields are approximated here: a partial port would change the
// bytes the Kotlin importer writes for links this slice cannot yet prove.
package mobile

import (
	"encoding/json"
	"errors"
	"strings"
)

const profileImportMethod Method = "profileImport"

func init() {
	register(profileImportMethod, handleProfileImport)
}

type profileImportRequest struct {
	Text string `json:"text"`
}

type profileImportReply struct {
	Supported bool                  `json:"supported"`
	Nodes     []profileImportedNode `json:"nodes,omitempty"`
	Reason    string                `json:"reason,omitempty"`
}

func handleProfileImport(raw json.RawMessage) (any, error) {
	var request profileImportRequest
	if len(strings.TrimSpace(string(raw))) > 0 {
		if err := json.Unmarshal(raw, &request); err != nil {
			return nil, err
		}
	}
	if request.Text == "" {
		return nil, errors.New("profileImport requires a text field")
	}
	node, err := profileImportOneLink(request.Text)
	if err != nil {
		var refused profileImportUnsupported
		if errors.As(err, &refused) {
			return profileImportReply{Supported: false, Reason: refused.Reason}, nil
		}
		return nil, err
	}
	return profileImportReply{Supported: true, Nodes: []profileImportedNode{*node}}, nil
}
