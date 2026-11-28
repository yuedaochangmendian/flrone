package mobile

import "testing"

func TestProfileImportPartialBody(t *testing.T) {
	body := "vless://u@example.com:443?security=tls#Good\nfoo://bar\n"
	result, err := profileImportBodyPartial(body)
	if err != nil {
		t.Fatalf("partial import: %v", err)
	}
	if len(result.Nodes) != 1 || result.Nodes[0].Name != "Good" {
		t.Fatalf("nodes = %+v", result.Nodes)
	}
	if result.Skipped != 1 || len(result.Messages) != 1 {
		t.Fatalf("skipped = %d messages = %+v", result.Skipped, result.Messages)
	}
}

func TestProfileImportPartialBase64(t *testing.T) {
	body := "vless://u@example.com:443?security=tls#Good\nfoo://bar\n"
	encoded := profileBase64Encode([]byte(body), false, true)
	result, err := profileImportBodyPartial(encoded)
	if err != nil {
		t.Fatalf("partial import: %v", err)
	}
	if len(result.Nodes) != 1 || result.Skipped != 1 {
		t.Fatalf("nodes = %+v skipped = %d", result.Nodes, result.Skipped)
	}
}

func TestProfileImportPartialSingleLinkStaysStrict(t *testing.T) {
	if _, err := profileImportBodyPartial("foo://bar"); err == nil {
		t.Fatal("a single unsupported link must stay a refusal")
	}
	allBad := "foo://bar\nbaz://qux\n"
	if _, err := profileImportBodyPartial(allBad); err == nil {
		t.Fatal("a body with no supported entry must stay a refusal")
	}
}
