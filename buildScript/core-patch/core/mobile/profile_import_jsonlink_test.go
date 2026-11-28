package mobile

import (
	"strings"
	"testing"
)

func TestProfileImportJSONLinks(t *testing.T) {
	vless := `{"server":"example.com","server_port":443,"tag":"Node A","type":"vless","uuid":"u"}`
	standard := profileBase64Encode([]byte(vless), false, true)
	urlSafe := profileBase64Encode([]byte(vless), true, false)
	for _, testCase := range []struct {
		name string
		link string
	}{
		{"throne standard base64", "throne://add/" + standard},
		{"throne url-safe fallback", "throne://add/" + urlSafe},
		{"json url-safe fragment", "json://#" + urlSafe},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			nodes, err := profileImportBody(testCase.link)
			if err != nil {
				t.Fatalf("import: %v", err)
			}
			if len(nodes) != 1 {
				t.Fatalf("nodes = %+v, want one", nodes)
			}
			node := nodes[0]
			if node.Type != "vless" || node.Name != "Node A" {
				t.Fatalf("node = %+v", node)
			}
			if !strings.Contains(node.JSON, `"encryption":"none"`) ||
				!strings.Contains(node.JSON, `"packet_encoding":"xudp"`) {
				t.Fatalf("the canonical document is missing vless defaults: %s", node.JSON)
			}
			if !strings.HasPrefix(node.DedupKey, "throne://add/") {
				t.Fatalf("dedup key = %q", node.DedupKey)
			}
		})
	}
}

func TestProfileImportJSONLinkCustomName(t *testing.T) {
	custom := `{"config":"{}","name":"inner","subtype":"outbound","type":"custom"}`
	link := "json://#" + profileBase64Encode([]byte(custom), true, false)
	nodes, err := profileImportBody(link)
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	if len(nodes) != 1 || nodes[0].Type != "custom" || nodes[0].Name != "inner" {
		t.Fatalf("nodes = %+v", nodes)
	}
}

func TestProfileImportJSONLinkRefusals(t *testing.T) {
	for _, testCase := range []struct{ name, link string }{
		{"throne without add", "throne://other/abcd"},
		{"json without fragment", "json://abcd"},
		{"bad base64", "throne://add/!!!!"},
		{"not an object", "json://#" + profileBase64Encode([]byte(`[1]`), true, false)},
		{"unknown stored field", "json://#" + profileBase64Encode([]byte(`{"future":1,"type":"direct"}`), true, false)},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			if _, err := profileImportBody(testCase.link); err == nil {
				t.Fatalf("accepted %s", testCase.link)
			}
		})
	}
}
