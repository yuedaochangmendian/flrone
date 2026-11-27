// The fixture-facing half of the buildTest config builder: load one
// app/src/test/resources/config-test-golden/<case>/ directory, ask the builder
// for its result and render the exact envelope ConfigTestGoldenTest commits.
//
// The fixture documents sit side by side (the Kotlin oracle points its two
// stores at the case directory):
//
//	profiles.json    Dart-owned profile document (groups give each candidate its
//	                 landing / front proxy, CoreConfigs.buildTest)
//	settings.json    Kotlin-owned settings document
//	build_test.json  the call: profileIds (candidates, in order) and an optional
//	                 goStage marker reserving the case for a later builder stage
//	expected.json    the oracle envelope; never written from this side
//
// The envelope shape is pinned by ConfigTestGoldenTest.envelope: coreConfig and
// its SHA-256, the ordered outboundTags / tagToProfileId arrays, the ordered
// fullConfigs / skipped arrays (profile id order of the candidate list), the
// tun IPv4 CIDR (null for a test build), the sorted involved ids (empty for a
// test build) and the error (null on success). The builder itself is test-only
// (config_build_test.go) until a production consumer exists, so this file takes
// it as a function: the harness installs the seam (config_test_golden_test.go).
package mobile

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// configTestCandidate is TestCandidate: one profile to probe plus the landing /
// front proxy of its group (0 or negative when the group has none).
// configTestBuilderFunc is the builder entry the harness installs: the test-only
// buildTest port in config_build_test.go.
type configTestBuilderFunc func(inputs *simpleConfigInputs, candidates []configTestCandidate) configTestBuildResult

// configTestFixtureBuildFile is build_test.json; the optional goStage marker is
// read by the harness, which decides whether this builder may run the case.
type configTestFixtureBuildFile struct {
	ProfileIDs []int64 `json:"profileIds"`
}

// buildTestEnvelopeFromFixtureDir loads one case directory, runs build over it
// and returns the exact expected.json text.
func buildTestEnvelopeFromFixtureDir(caseDir string, build configTestBuilderFunc) (string, error) {
	if build == nil {
		return "", fmt.Errorf("buildTest fixture loader has no builder")
	}
	inputs, candidates, err := loadConfigTestFixture(caseDir)
	if err != nil {
		return "", err
	}
	return configTestEnvelope(build(inputs, candidates))
}

// loadConfigTestFixture reads one case directory into the builder's inputs. The
// candidate's group is resolved the way CoreConfigs.buildTest does it: the
// candidate row's gid names a group whose landing / front proxy it carries,
// and a missing group is "none" (-1).
func loadConfigTestFixture(caseDir string) (*simpleConfigInputs, []configTestCandidate, error) {
	buildFile, err := readConfigTestBuildFile(caseDir)
	if err != nil {
		return nil, nil, err
	}
	profiles, err := readProfilesDocumentAt(caseDir)
	if err != nil {
		return nil, nil, err
	}
	settingsRows, _, err := readDocumentAt(caseDir, settingsDocumentName)
	if err != nil {
		return nil, nil, fmt.Errorf("read %s.json: %w", settingsDocumentName, err)
	}
	settingsValues := settingsRowsByKey(settingsRows)
	if err := configTestValidateSettingsValues(settingsValues); err != nil {
		return nil, nil, err
	}
	settings := loadSimpleConfigSettingsFromValues(settingsValues)

	allProfiles, err := simpleConfigProfilesFromDocument(profiles)
	if err != nil {
		return nil, nil, err
	}
	groups := make(map[int64]simpleConfigGroup, len(profiles.Groups))
	for _, groupRow := range profiles.Groups {
		group := simpleConfigGroupFromRow(groupRow)
		if group.ID > 0 {
			groups[group.ID] = group
		}
	}

	candidates := make([]configTestCandidate, 0, len(buildFile.ProfileIDs))
	seen := make(map[int64]bool, len(buildFile.ProfileIDs))
	for index, id := range buildFile.ProfileIDs {
		if id <= 0 {
			return nil, nil, fmt.Errorf("build_test.json profileIds[%d] must be a positive profile id, not %d", index, id)
		}
		if seen[id] {
			return nil, nil, fmt.Errorf("build_test.json profileIds must not repeat id %d "+
				"(buildTest collapses repeats silently, so the fixture would not test what it looks like)", id)
		}
		seen[id] = true
		candidate := configTestCandidate{id: id, landingProxyID: -1, frontProxyID: -1}
		if row := configFindProfile(allProfiles, id); row != nil && row.GroupID > 0 {
			if group, ok := groups[row.GroupID]; ok {
				if group.LandingProxyID > 0 {
					candidate.landingProxyID = group.LandingProxyID
				}
				if group.FrontProxyID > 0 {
					candidate.frontProxyID = group.FrontProxyID
				}
				candidate.groupName = group.Name
			}
		}
		candidates = append(candidates, candidate)
	}

	mode := serviceMode(configSettingStringValue(settingsValues, "serviceMode"))
	if mode != serviceModeVPN && mode != serviceModeProxy {
		mode = serviceModeVPN
	}
	outbound := outboundMode(configSettingStringValue(settingsValues, "bbox_outbound_mode"))
	if outbound != outboundModeRule && outbound != outboundModeGlobal && outbound != outboundModeDirect {
		outbound = outboundModeRule
	}
	inputs := &simpleConfigInputs{
		Profiles:       allProfiles,
		Settings:       settings,
		Mode:           mode,
		OutboundMode:   outbound,
		DeferRuleSets:  false,
		RouteRules:     []simpleConfigRouteRule{},
		RuleSetCatalog: simpleRuleSetCatalog{Entries: []simpleRuleSetEntry{}, index: map[string]string{}},
	}
	return inputs, candidates, nil
}

func readConfigTestBuildFile(caseDir string) (configTestFixtureBuildFile, error) {
	var buildFile configTestFixtureBuildFile
	data, err := os.ReadFile(filepath.Join(caseDir, "build_test.json"))
	if errors.Is(err, os.ErrNotExist) {
		return buildFile, fmt.Errorf("build_test.json is missing in %s", caseDir)
	}
	if err != nil {
		return buildFile, fmt.Errorf("read build_test.json: %w", err)
	}
	if err := json.Unmarshal(data, &buildFile); err != nil {
		return buildFile, fmt.Errorf("parse build_test.json: %w", err)
	}
	if buildFile.ProfileIDs == nil {
		return buildFile, fmt.Errorf("build_test.json needs a profileIds array")
	}
	return buildFile, nil
}

// configTestValidateSettingsValues applies the constraints ConfigTestGoldenTest
// asserts: the JVM oracle cannot derive DataStore's per-user ports, a random
// core_box_api_secret would change every envelope, and an empty duration error
// needs Android resources.
func configTestValidateSettingsValues(values map[string]string) error {
	if _, present := values["inbound_socks_port"]; !present {
		return fmt.Errorf("settings.json must spell out inbound_socks_port")
	}
	if configSettingStringValue(values, "core_box_api_secret") == "" {
		return fmt.Errorf("settings.json must set a non-empty core_box_api_secret")
	}
	if configSettingIntValue(values, "core_box_clash_api") > 0 &&
		configSettingStringValue(values, "core_box_clash_api_secret") == "" {
		return fmt.Errorf("settings.json enables the Clash API and must set core_box_clash_api_secret")
	}
	if configSettingStringValue(values, "dns_query_timeout") == "" {
		return fmt.Errorf("settings.json must set a non-empty dns_query_timeout")
	}
	if configSettingBoolValue(values, "dns_optimistic") &&
		configSettingStringValue(values, "dns_optimistic_timeout") == "" {
		return fmt.Errorf("dns_optimistic requires a non-empty dns_optimistic_timeout")
	}
	return nil
}

// configTestEnvelope is ConfigTestGoldenTest.envelope: the exact pretty-printed
// document the oracle commits, including its trailing newline.
func configTestEnvelope(result configTestBuildResult) (string, error) {
	var builder strings.Builder
	builder.WriteString("{\n")
	builder.WriteString("  \"version\": 1,\n")
	builder.WriteString("  \"generatedBy\": \"" + configTestGeneratedBy + "\",\n")
	builder.WriteString("  \"sha256\": \"" + configTestSHA256(result.coreConfig) + "\",\n")
	builder.WriteString("  \"coreConfig\": " + configTestQuote(result.coreConfig) + ",\n")

	tags := result.outboundTags
	records := make([]string, 0, len(tags))
	for _, bucket := range result.tagToProfileID {
		records = append(records, "{\"tag\": "+configTestQuote(bucket.tag)+
			", \"profileId\": "+strconv.FormatInt(bucket.profileID, 10)+"}")
	}
	builder.WriteString("  \"outboundTags\": " + configTestQuoteList(tags) + ",\n")
	builder.WriteString("  \"tagToProfileId\": " + configTestRecordList(records) + ",\n")

	records = records[:0]
	for _, full := range result.fullConfigs {
		records = append(records, "{\"profileId\": "+strconv.FormatInt(full.profileID, 10)+
			", \"config\": "+configTestQuote(full.config)+", \"sha256\": \""+configTestSHA256(full.config)+"\"}")
	}
	builder.WriteString("  \"fullConfigs\": " + configTestRecordList(records) + ",\n")

	records = records[:0]
	for _, skip := range result.skipped {
		records = append(records, "{\"profileId\": "+strconv.FormatInt(skip.profileID, 10)+
			", \"reason\": "+configTestQuote(skip.reason)+"}")
	}
	builder.WriteString("  \"skipped\": " + configTestRecordList(records) + ",\n")

	builder.WriteString("  \"tunIPv4Cidr\": ")
	if result.tunIPv4Cidr == nil {
		builder.WriteString("null")
	} else {
		builder.WriteString(configTestQuote(*result.tunIPv4Cidr))
	}
	builder.WriteString(",\n")

	// The oracle sorts the involved set inline, with no spaces.
	involved := append([]int64(nil), result.involvedProfileIDs...)
	sort.Slice(involved, func(a, b int) bool { return involved[a] < involved[b] })
	values := make([]string, 0, len(involved))
	for index, id := range involved {
		if index > 0 && involved[index-1] == id {
			continue
		}
		values = append(values, strconv.FormatInt(id, 10))
	}
	builder.WriteString("  \"involvedProfileIds\": [" + strings.Join(values, ",") + "],\n")

	builder.WriteString("  \"error\": ")
	if result.failure == nil {
		builder.WriteString("null")
	} else {
		builder.WriteString(configTestQuote(*result.failure))
	}
	builder.WriteString("\n}\n")
	return builder.String(), nil
}

// configTestGeneratedBy is the oracle that owns expected.json.
const configTestGeneratedBy = "ConfigTestGoldenTest"

// configTestSHA256 is the lowercase hex digest of the UTF-8 text.
func configTestSHA256(text string) string {
	digest := sha256.Sum256([]byte(text))
	return hex.EncodeToString(digest[:])
}

// configTestQuoteList is the oracle's quoteList: empty inline, else one quoted
// tag per line.
func configTestQuoteList(items []string) string {
	if len(items) == 0 {
		return "[]"
	}
	quoted := make([]string, 0, len(items))
	for _, item := range items {
		quoted = append(quoted, configTestQuote(item))
	}
	return "[\n    " + strings.Join(quoted, ",\n    ") + "\n  ]"
}

func configTestRecordList(items []string) string {
	if len(items) == 0 {
		return "[]"
	}
	return "[\n    " + strings.Join(items, ",\n    ") + "\n  ]"
}

// configTestQuote is org.json.JSONObject.quote: only `"` `\` and the C0/C1
// control characters are escaped, `</` is protected, everything else
// (non-ASCII included) stays literal. That is what expected.json contains, and
// it differs from JsonWriter's coreConfig escaping only for `/` and unpaired
// surrogates, neither of which the envelope strings carry.
func configTestQuote(text string) string {
	var builder strings.Builder
	builder.WriteByte('"')
	for index := 0; index < len(text); {
		character := text[index]
		if character < utf8.RuneSelf {
			switch character {
			case '"', '\\':
				builder.WriteByte('\\')
				builder.WriteByte(character)
			case '\b':
				builder.WriteString("\\b")
			case '\f':
				builder.WriteString("\\f")
			case '\n':
				builder.WriteString("\\n")
			case '\r':
				builder.WriteString("\\r")
			case '\t':
				builder.WriteString("\\t")
			case '/':
				if index > 0 && text[index-1] == '<' {
					builder.WriteByte('\\')
				}
				builder.WriteByte(character)
			default:
				if character < 0x20 || character == 0x7F {
					configTestWriteUnicodeEscape(&builder, rune(character))
				} else {
					builder.WriteByte(character)
				}
			}
			index++
			continue
		}
		codePoint, size := utf8.DecodeRuneInString(text[index:])
		if codePoint >= 0x80 && codePoint <= 0x9F {
			configTestWriteUnicodeEscape(&builder, codePoint)
		} else if codePoint == utf8.RuneError && size == 1 {
			// Not a valid UTF-8 sequence: org.json never sees one (Java strings
			// are UTF-16), so keep the byte rather than inventing a replacement.
			builder.WriteByte(character)
		} else {
			builder.WriteString(text[index : index+size])
		}
		index += size
	}
	builder.WriteByte('"')
	return builder.String()
}

func configTestWriteUnicodeEscape(builder *strings.Builder, codePoint rune) {
	builder.WriteString("\\u")
	builder.WriteByte(configTestHexDigit(byte(codePoint >> 12)))
	builder.WriteByte(configTestHexDigit(byte(codePoint >> 8)))
	builder.WriteByte(configTestHexDigit(byte(codePoint >> 4)))
	builder.WriteByte(configTestHexDigit(byte(codePoint)))
}

func configTestHexDigit(value byte) byte {
	const digits = "0123456789abcdef"
	return digits[value&0xF]
}
