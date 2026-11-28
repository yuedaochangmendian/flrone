// The profileImport action: a share link or a subscription body in, one or
// more Throne stored nodes out.
//
// Wire shape (the Dart ActionMethod member IS the wire name):
//
//	profileImport {"text":"ss://…#Name"}
//	  → {"supported":true,"nodes":[{"type":"shadowsocks","name":"Name",
//	       "json":"…","link":"…","identity":"…","dedupKey":"…"}]}
//	  → {"supported":false,"reason":"https/security=tls is not ported yet …"}
//
// A multi-line / base64 / JSON subscription body returns one node per entry
// in the same `nodes` array, in input order, deduplicated by dedupKey. The
// whole body is refused (no nodes) if any entry is unsupported or malformed.
// A caller that only handles one node simply reads nodes[0]. A refusal never
// emits a node, so a partially normalized link or body cannot reach the
// document store.
//
// Supported protocols (all byte-pinned against Kotlin exportToJson in the
// JVM ProfileStoredGoParityTest and the Go *_test.go vectors):
//
//   - direct/http/socks/shadowsocks from the first slice (no TLS);
//   - vmess (V2RayN base64 JSON and URL forms), vless, trojan: the full TLS
//     surface Tls.kt reads (SNI/ALPN/insecure/pins/ECH/REALITY/uTLS, min/max
//     version, cipher suites, curves, fragment/record_fragment, spoof and
//     tls_tricks), flow, encryption, packetEncoding, and the ws / http /
//     httpupgrade / grpc / quic / xhttp (with extra.xmux) / mkcp transports;
//   - hysteria/hysteria2/hy2: v1 auth+obfs+recv windows, v2 password,
//     salamander/gecko obfs with sizes, up/down bandwidth, port hopping,
//     pinSHA256, QUIC fields and realm in stored JSON;
//   - tuic and anytls: link/Clash/JSON forms with their TLS and QUIC fields.
//
// Remaining work (answered supported:false, never approximated):
//
//   - Xray full-config conversion corpus, mux details the stored exporter does
//     not model, and every protocol outside the list above (mieru, snell,
//     shadowtls, wireguard, …).
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
	nodes, err := profileImportBody(request.Text)
	if err != nil {
		var refused profileImportUnsupported
		if errors.As(err, &refused) {
			return profileImportReply{Supported: false, Reason: refused.Reason}, nil
		}
		return nil, err
	}
	return profileImportReply{Supported: true, Nodes: nodes}, nil
}
