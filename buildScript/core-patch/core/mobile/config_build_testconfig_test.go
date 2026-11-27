package mobile

import "testing"

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
