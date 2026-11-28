// Stored-form validation for the three Throne-only constructs the kernel does
// not own: chain, custom and autoselector.
//
// The link/kernel protocols share profile_validate_stored.go's reader, but
// these three documents never reach the core as a typed outbound: the config
// builder expands a chain, wraps custom JSON and plans an auto-selector. Their
// save gate therefore only needs the model checks the editor used to answer:
//
//   - chain: `list` must hold at least one hop;
//   - custom: `subtype` must be outbound or fullconfig, and `config` must be a
//     JSON object with a `type` string (outbound) or an `outbounds` array
//     (fullconfig), keys matched case-insensitively like custom.cpp;
//   - autoselector: `name_filter` must compile as a Go regexp (the regexp
//     dialect the core actually uses), `country_filter` entries are two ASCII
//     letters with an optional leading `!`, and the two URLs must be http(s)
//     with a host.
//
// The canonical document comes from the same normalizer profileNormalize uses;
// a field outside that normalizer's table is an error issue, not a half-saved
// row. Messages are stable English, like the rest of format:"stored".
package mobile

import (
	"net/url"
	"regexp"
	"strings"
)

// handleProfileValidateStoredConstruct answers the three stored-only types.
// The bool is false for every other type, so the caller keeps its existing
// dispatch. A hard normalizer error is an action error.
func handleProfileValidateStoredConstruct(object map[string]any, rawType string) (any, bool, error) {
	var normalizer profileStoredNormalizer
	switch rawType {
	case "chain":
		normalizer = profileStoredNormalizeChain
	case "custom":
		normalizer = profileStoredNormalizeCustom
	case "autoselector":
		normalizer = profileStoredNormalizeAutoSelector
	default:
		return nil, false, nil
	}

	canonical, reason, err := normalizer(object)
	if err != nil {
		return nil, true, err
	}
	issues := storedIssues{}
	if reason != "" {
		issues.addError("", reason)
	}
	switch rawType {
	case "chain":
		validateStoredChainConstruct(&issues, object)
	case "custom":
		validateStoredCustomConstruct(&issues, object)
	case "autoselector":
		validateStoredAutoSelectorConstruct(&issues, object)
	}
	result := profileValidateResult{
		Issues:    []profileIssue{},
		Supported: boolPointer(true),
	}
	return finishStoredValidation(result, issues, canonical), true, nil
}

func validateStoredChainConstruct(issues *storedIssues, object map[string]any) {
	list, _ := object["list"].([]any)
	if len(list) == 0 {
		issues.addError("list", "the chain needs at least one hop")
	}
}

func validateStoredCustomConstruct(issues *storedIssues, object map[string]any) {
	subtype := strings.TrimSpace(configJSONString(object, "subtype"))
	if subtype != "outbound" && subtype != "fullconfig" {
		if subtype == "" {
			issues.addError("subtype", "subtype is required")
		} else {
			issues.addError("subtype", "subtype must be outbound or fullconfig")
		}
		return
	}
	config := configJSONString(object, "config")
	if strings.TrimSpace(config) == "" {
		issues.addError("config", "config is required")
		return
	}
	document, ok := configDecodeJSONObject(config)
	if !ok {
		issues.addError("config", "config is not a JSON object")
		return
	}
	switch subtype {
	case "outbound":
		value, present := customValueNamed(document, "type")
		text, isString := value.(string)
		if !present || !isString || strings.TrimSpace(text) == "" {
			issues.addError("config", "the custom outbound config needs a type string")
		}
	case "fullconfig":
		value, present := customValueNamed(document, "outbounds")
		if _, isArray := value.([]any); !present || !isArray {
			issues.addError("config", "the custom full config needs an outbounds list")
		}
	}
}

func validateStoredAutoSelectorConstruct(issues *storedIssues, object map[string]any) {
	nameFilter := configJSONString(object, "name_filter")
	if nameFilter != "" {
		if _, err := regexp.Compile(nameFilter); err != nil {
			issues.addError("name_filter", "name_filter is not a valid regular expression")
		}
	}
	if countryFilter := configJSONString(object, "country_filter"); countryFilter != "" {
		if !validCountryFilter(countryFilter) {
			issues.addError("country_filter", "country_filter entries are two-letter country codes, optionally prefixed with !")
		}
	}
	for _, field := range []string{"test_url", "connectivity_url"} {
		value := strings.TrimSpace(configJSONString(object, field))
		if value != "" && !storedHTTPURL(value) {
			issues.addError(field, "the URL must be an http(s) URL with a host")
		}
	}
}

// validCountryFilter is AutoSelectorChecks.autoSelectorCountries: comma-list
// items of two ASCII letters, an optional leading `!` for an exclusion.
func validCountryFilter(text string) bool {
	for _, item := range strings.Split(text, ",") {
		code := strings.TrimSpace(item)
		if strings.HasPrefix(code, "!") {
			code = strings.TrimSpace(strings.TrimPrefix(code, "!"))
		}
		if len(code) != 2 || !isASCIIAlpha(code) {
			return false
		}
	}
	return true
}

func isASCIIAlpha(text string) bool {
	for _, r := range text {
		if (r < 'A' || r > 'Z') && (r < 'a' || r > 'z') {
			return false
		}
	}
	return true
}

func storedHTTPURL(text string) bool {
	parsed, err := url.Parse(text)
	if err != nil {
		return false
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return false
	}
	return parsed.Host != ""
}

// customValueNamed is custom.cpp customValueNamed: the core matches object keys
// case-insensitively, so any spelling of the key sets the same option.
func customValueNamed(object map[string]any, name string) (any, bool) {
	for key, value := range object {
		if strings.EqualFold(key, name) {
			return value, true
		}
	}
	return nil, false
}