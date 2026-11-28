package mobile

import (
	"strings"
	"testing"
)

// TestProfileValidateStoredConstructs pins the save gate for the three
// Throne-only stored constructs: the normalizer supplies the canonical
// document, and the validator adds exactly the checks the deleted Kotlin
// models answered.
func TestProfileValidateStoredConstructs(t *testing.T) {
	cases := []struct {
		name       string
		document   string
		ok         bool
		field      string
		normalized bool
	}{
		{
			name:     "chain with no hops is rejected",
			document: `{"list":[],"name":"c","type":"chain"}`,
			ok:       false, field: "list", normalized: true,
		},
		{
			name:     "chain with a hop is accepted",
			document: `{"list":[1,2],"name":"c","type":"chain"}`,
			ok:       true, normalized: true,
		},
		{
			name:     "chain missing list is rejected",
			document: `{"name":"c","type":"chain"}`,
			ok:       false, field: "list", normalized: true,
		},
		{
			name:     "custom outbound with a type is accepted",
			document: `{"config":"{\"server\":\"x\",\"type\":\"vless\"}","name":"n","subtype":"outbound","type":"custom"}`,
			ok:       true, normalized: true,
		},
		{
			name:     "custom outbound case-insensitive type is accepted",
			document: `{"config":"{\"TYPE\":\"vless\"}","name":"n","subtype":"outbound","type":"custom"}`,
			ok:       true, normalized: true,
		},
		{
			name:     "custom outbound without a type is rejected",
			document: `{"config":"{\"server\":\"x\"}","name":"n","subtype":"outbound","type":"custom"}`,
			ok:       false, field: "config", normalized: true,
		},
		{
			name:     "custom full config with outbounds is accepted",
			document: `{"config":"{\"outbounds\":[]}","name":"n","subtype":"fullconfig","type":"custom"}`,
			ok:       true, normalized: true,
		},
		{
			name:     "custom full config without outbounds is rejected",
			document: `{"config":"{\"log\":{}}","name":"n","subtype":"fullconfig","type":"custom"}`,
			ok:       false, field: "config", normalized: true,
		},
		{
			name:     "custom missing subtype is rejected",
			document: `{"config":"{}","name":"n","subtype":"","type":"custom"}`,
			ok:       false, field: "subtype", normalized: true,
		},
		{
			name:     "custom unknown subtype is rejected",
			document: `{"config":"{}","name":"n","subtype":"future","type":"custom"}`,
			ok:       false, field: "subtype", normalized: true,
		},
		{
			name:     "custom config that is not JSON is rejected",
			document: `{"config":"not json","name":"n","subtype":"outbound","type":"custom"}`,
			ok:       false, field: "config", normalized: true,
		},
		{
			name:     "custom unknown stored field is a normalizer issue",
			document: `{"config":"{}","future":1,"subtype":"outbound","type":"custom"}`,
			ok:       false, normalized: false,
		},
		{
			name:     "autoselector defaults are accepted",
			document: `{"type":"autoselector"}`,
			ok:       true, normalized: true,
		},
		{
			name:     "autoselector valid filters and urls are accepted",
			document: `{"country_filter":"!RU,US","name_filter":"HK|TW","test_url":"https://example.com","type":"autoselector"}`,
			ok:       true, normalized: true,
		},
		{
			name:     "autoselector invalid regex is rejected",
			document: `{"name_filter":"(","type":"autoselector"}`,
			ok:       false, field: "name_filter", normalized: true,
		},
		{
			name:     "autoselector three-letter country is rejected",
			document: `{"country_filter":"CHN","type":"autoselector"}`,
			ok:       false, field: "country_filter", normalized: true,
		},
		{
			name:     "autoselector bare exclusion marker is rejected",
			document: `{"country_filter":"!","type":"autoselector"}`,
			ok:       false, field: "country_filter", normalized: true,
		},
		{
			name:     "autoselector non-http url is rejected",
			document: `{"test_url":"ftp://example.com","type":"autoselector"}`,
			ok:       false, field: "test_url", normalized: true,
		},
		{
			name:     "autoselector hostless url is rejected",
			document: `{"connectivity_url":"https://","type":"autoselector"}`,
			ok:       false, field: "connectivity_url", normalized: true,
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			answer, err := handleProfileValidateStored(testCase.document)
			if err != nil {
				t.Fatalf("validate %s: %v", testCase.document, err)
			}
			result, ok := answer.(profileValidateResult)
			if !ok {
				t.Fatalf("answer type = %T", answer)
			}
			if result.Supported == nil || !*result.Supported {
				t.Fatalf("the construct must be supported, got %+v", result)
			}
			if result.OK != testCase.ok {
				t.Fatalf("ok = %v, want %v (issues %+v)", result.OK, testCase.ok, result.Issues)
			}
			if testCase.field != "" {
				found := false
				for _, issue := range result.Issues {
					if issue.Field == testCase.field && issue.Severity == profileSeverityError {
						found = true
					}
				}
				if !found {
					t.Fatalf("no %q error in %+v", testCase.field, result.Issues)
				}
			}
			if testCase.normalized && result.Normalized == "" {
				t.Fatalf("a supported document must carry its canonical form")
			}
			if !testCase.normalized && result.Normalized != "" {
				t.Fatalf("a document the normalizer refuses must not carry a half-canonical form: %s", result.Normalized)
			}
		})
	}
}

// TestProfileValidateStoredConstructCanonical pins that the validator and the
// normalizer answer the same bytes for the three constructs.
func TestProfileValidateStoredConstructCanonical(t *testing.T) {
	for _, document := range []string{
		`{"list":[3],"name":"c","type":"chain"}`,
		`{"config":"{\"server\":\"x\",\"type\":\"vless\"}","name":"n","subtype":"outbound","type":"custom"}`,
		`{"type":"autoselector"}`,
	} {
		normalized, err := handleProfileNormalizeStored(document)
		if err != nil {
			t.Fatalf("normalize %s: %v", document, err)
		}
		normalizedReply := normalized.(profileStoredNormalizeResult)
		if !normalizedReply.Supported {
			t.Fatalf("normalizer refused %s: %s", document, normalizedReply.Reason)
		}
		answer, err := handleProfileValidateStored(document)
		if err != nil {
			t.Fatalf("validate %s: %v", document, err)
		}
		result := answer.(profileValidateResult)
		if !result.OK {
			t.Fatalf("validator refused %s: %+v", document, result.Issues)
		}
		if result.Normalized != normalizedReply.JSON {
			t.Fatalf("validate canonical = %s\nnormalize canonical = %s", result.Normalized, normalizedReply.JSON)
		}
		if !strings.Contains(result.Normalized, `"type"`) {
			t.Fatalf("canonical document lost its type: %s", result.Normalized)
		}
	}
}