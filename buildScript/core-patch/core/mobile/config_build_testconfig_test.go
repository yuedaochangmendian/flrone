package mobile

import (
	"strings"
	"testing"
)

// TestConfigTestResultPayloadShape pins the JSON keys the Kotlin TestConfigBuilder
// reads from `build_test_config`; a rename on either side would otherwise leave
// the test session with an empty GeneratedConfig instead of a failure.
func TestConfigTestResultPayloadShape(t *testing.T) {
	cidr := "172.19.0.1/30"
	failure := ""
	result := configTestBuildResult{
		coreConfig:         `{"log":{}}`,
		outboundTags:       []string{"proxy-7-0"},
		tagToProfileID:     []configTestTagBucket{{tag: "proxy-7-0", profileID: 7}},
		fullConfigs:        []configTestFullConfig{{profileID: 8, config: `{"log":{}}`}},
		skipped:            []configTestSkip{{profileID: 9, reason: "Skipping Tailscale conf"}},
		tunIPv4Cidr:        &cidr,
		involvedProfileIDs: []int64{7},
		failure:            &failure,
	}
	payload := configTestResultPayload(result)
	for _, key := range []string{
		"coreConfig", "outboundTags", "tagToProfileId", "fullConfigs", "skipped",
		"tunIPv4Cidr", "involvedProfileIds", "error",
	} {
		if _, present := payload[key]; !present {
			t.Fatalf("payload is missing %q: %#v", key, payload)
		}
	}
	if tags, _ := payload["tagToProfileId"].(map[string]int64); tags["proxy-7-0"] != 7 {
		t.Fatalf("tagToProfileId = %#v", payload["tagToProfileId"])
	}
	if skipped, _ := payload["skipped"].(map[string]string); skipped["9"] != "Skipping Tailscale conf" {
		t.Fatalf("skipped = %#v", payload["skipped"])
	}
}

func TestBuildTestConfigHostCall(t *testing.T) {
	base := withConfigInputBase(t)
	writeDocumentFixture(t, base, profilesDocumentName, `{
  "version": 1,
  "nextProfileId": 2,
  "nextGroupId": 1,
  "profiles": [
    {"id": 1, "type": "shadowsocks", "name": "Host SS", "gid": 0, "user_order": 0,
     "outbound_json": "{\"type\":\"shadowsocks\",\"server\":\"198.51.100.44\",\"server_port\":8388,\"method\":\"aes-256-gcm\",\"password\":\"pw\"}"}
  ],
  "groups": []
}`)
	writeSettingsFixture(t, base, baseSettingsJSON(t, "1", nil))
	writeGlobalRulesFixture(t, base, `[]`)

	data, err := dispatchHostCall("build_test_config", []byte(`{"profileIds":[1]}`))
	if err != nil {
		t.Fatal(err)
	}
	payload, ok := data.(map[string]any)
	if !ok {
		t.Fatalf("data = %#v", data)
	}
	core, _ := payload["coreConfig"].(string)
	if !strings.Contains(core, `"tag":"proxy-1-0"`) {
		t.Fatalf("test config lacks the candidate tag: %s", core)
	}
	tags, _ := payload["tagToProfileId"].(map[string]int64)
	if tags["proxy-1-0"] != 1 {
		t.Fatalf("tagToProfileId = %#v", payload["tagToProfileId"])
	}
	if payload["error"] != nil {
		t.Fatalf("error = %#v", payload["error"])
	}
}

func TestBuildTestConfigHostCallWithoutProfiles(t *testing.T) {
	base := withConfigInputBase(t)
	writeDocumentFixture(t, base, profilesDocumentName, `{"version":1,"profiles":[],"groups":[]}`)
	writeSettingsFixture(t, base, baseSettingsJSON(t, "1", nil))
	writeGlobalRulesFixture(t, base, `[]`)

	data, err := dispatchHostCall("build_test_config", []byte(`{"profileIds":[]}`))
	if err != nil {
		t.Fatalf("an empty candidate list must not require a selected profile: %v", err)
	}
	payload, _ := data.(map[string]any)
	core, _ := payload["coreConfig"].(string)
	if core == "" {
		t.Fatalf("empty test config: %#v", payload)
	}
}

func TestBuildTestSkipsKotlinOnlyTypes(t *testing.T) {
	inputs := &simpleConfigInputs{
		Settings: simpleConfigSettings{DirectDNS: "223.5.5.5", DNSCacheCapacity: 65536, DNSQueryTimeout: "5s"},
		Profiles: []simpleConfigProfile{
			{ID: 1, Type: "openvpn-unported-test", OutboundJSON: `{"type":"openvpn-unported-test"}`},
		},
	}
	result := buildTestCoreConfig(inputs, []configTestCandidate{{id: 1, landingProxyID: -1, frontProxyID: -1}})
	if result.failure != nil {
		t.Fatalf("a Kotlin-only candidate must not fail the batch: %s", *result.failure)
	}
	if len(result.skipped) != 1 || result.skipped[0].reason != "Unsupported profile type: openvpn-unported-test" {
		t.Fatalf("skipped = %#v", result.skipped)
	}
}
