// The profile editor's document codec, as core actions.
//
// The configuration editor parses, validates and re-serialises a node document
// in Kotlin today (`parseOutbounds` + the model's `validate` + `ProfileJson`).
// Those three steps put the protocol model twice in the tree: Throne's Kotlin
// outbound classes and sing-box's own option types inside the kernel. These
// actions move the *document* half across without adding a third model: they
// use the pinned core's `option.Outbound` and the concrete
// `option.*OutboundOptions` structs, which are the same types the kernel loads a
// config with. Nothing can drift, because the kernel's own parser is the
// validator.
//
// Wire shapes (the Dart ActionMethod member IS the wire name):
//
//	profileValidate    {"json":"…"}       -> {"ok":true,"issues":[],"normalized":"…"}
//	                                         {"ok":false,"issues":[{"field","message","severity"}]}
//	                   {"json":"…","format":"stored"}
//	                                      -> {"ok":true,"supported":true,"issues":[],"normalized":"…"}
//	                                         {"ok":false,"supported":false,"issues":[…]} (caller falls back)
//	                                         {"ok":false,"supported":true,"issues":[…]}
//	profileNormalize   {"json":"…"}       -> {"json":"…"}
//	profileNewOutbound {"type":"socks"}   -> {"json":"…"}
//
// The `format` field is optional and defaults to "kernel", the original
// option.Outbound decoder path. "stored" validates Throne's own compact
// NodeRow.outbound_json against the parsed subset in profile_export_simple.go;
// that is the only path which adds the `supported` field to the reply.
//
// `json` is the caller's document, untouched: this file never rewrites the
// caller's string and never reads or writes profiles.json (these are pure
// functions over one string). Only profileValidate's `normalized` field carries
// a rewritten document.
//
// A refused document is a *successful* action answering ok:false; a non-zero
// action code means the action could not run at all (missing payload, a codec
// failure). The caller can therefore tell "your node is wrong" from "the kernel
// did not answer".
//
// Strictness: option.Outbound's UnmarshalJSONContext delegates to
// badjson.UnmarshallExcludedContext, which decodes the concrete options with
// DisallowUnknownFields. A key the pinned option struct does not declare is an
// error, at the envelope and inside the options object. Containers the core
// itself decodes leniently (TLS options, for one) stay lenient here: this action
// answers what the kernel would accept, not a stricter policy of its own.
//
// What validate cannot answer: the save gate's semantic checks — a required
// address or credential, a cipher this runtime really knows, a server that
// resolves. sing-box runs the last two in the outbound constructor, which needs
// a box context, a router and a dialer, and the required fields are not marked
// in the option structs at all. validate is a document check (syntax, field
// names, field types, the port range through uint16), so the Kotlin save path
// keeps its model validation until that half is addressed too.
package mobile

import (
	"context"
	stdjson "encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	singjson "github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"
)

// The Method constants live in their own block; the severity strings below are
// untyped because action_contract.py treats every string constant that inherits
// a `Method` line as a request method (the same reason profile_actions.go keeps
// its marker filename out of that block).
const (
	profileValidateMethod    Method = "profileValidate"
	profileNormalizeMethod   Method = "profileNormalize"
	profileNewOutboundMethod Method = "profileNewOutbound"
)

const (
	profileSeverityError   = "error"
	profileSeverityWarning = "warning"

	// profileUnknownTypePrefix is the one decoder message translated below: the
	// core's text is "unknown outbound type: <type>", which reads as a truncated
	// sentence when the type is empty.
	profileUnknownTypePrefix = "unknown outbound type:"
)

// profileNewOutboundSupported is the closed set of types profileNewOutbound will
// template. Deliberately small: a template is only useful when every value it
// leaves out is a value the kernel itself would treat as the default. A
// shadowsocks template would have to pick a cipher and VMess one a security
// mode; both are security choices, not defaults, so the caller's form supplies
// them and validate says whether the result is loadable.
var profileNewOutboundSupported = []string{"direct", "http", "socks"}

func init() {
	register(profileValidateMethod, handleProfileValidate)
	register(profileNormalizeMethod, handleProfileNormalize)
	register(profileNewOutboundMethod, handleProfileNewOutbound)
}

// profileDocumentRequest is the payload of profileValidate and
// profileNormalize. The pointer separates "no json field" (a caller bug, an
// action error) from "the field is empty" (an empty editor, a validation
// finding).
type profileDocumentRequest struct {
	JSON *string `json:"json"`
	// Format selects the validation path. Empty means "kernel" (the original
	// option.Outbound decoder). "stored" validates the compact form Throne keeps
	// in NodeRow.outbound_json. An unknown value is an action error rather than
	// silently falling back, so a caller cannot mistake a typo for a kernel
	// verdict.
	Format *string `json:"format,omitempty"`
}

// profileNewOutboundRequest is the payload of profileNewOutbound.
type profileNewOutboundRequest struct {
	Type string `json:"type"`
}

// profileIssue is one readable finding about a document. Field is the JSON path
// the core's decoder reported ("" for a whole-document problem, e.g. a syntax
// error). The kernel path emits "error" only; the stored path also emits
// "warning" for findings that do not block saving.
//
// Message is the core's decoder text (encoding/json's `json: ` prefix stripped)
// rather than a paraphrase, so it stays accurate across a pin bump. The only
// exceptions are the two messages this file writes itself, where the core's text
// names nothing: an empty document, and a bare "unknown outbound type:". Field
// carries the location the UI highlights either way.
type profileIssue struct {
	Field    string `json:"field"`
	Message  string `json:"message"`
	Severity string `json:"severity"`
}

type profileValidateResult struct {
	OK     bool           `json:"ok"`
	Issues []profileIssue `json:"issues"`
	// Normalized is the canonical document, present only when the document
	// passed. It is the one place the input is allowed to come back rewritten.
	Normalized string `json:"normalized,omitempty"`
	// Supported is non-nil only for format:"stored". False tells the caller the
	// document belongs to an outbound type or carries a field this slice does
	// not model, so it should fall back to the Kotlin validator/exporter. The
	// pointer keeps the kernel path's reply shape byte-for-byte unchanged.
	Supported *bool `json:"supported,omitempty"`
}

type profileJSONResult struct {
	JSON string `json:"json"`
}

// handleProfileValidate parses one outbound document and reports what the
// parser objected to. The default "kernel" format uses the kernel's own option
// types; "stored" uses the parsed subset of Throne's NodeRow.outbound_json.
func handleProfileValidate(raw stdjson.RawMessage) (any, error) {
	document, format, err := parseProfileValidateRequest(raw)
	if err != nil {
		return nil, err
	}
	switch format {
	case profileFormatStored:
		return handleProfileValidateStored(document)
	case profileFormatKernel, "":
		// The original path, unchanged below.
	default:
		return nil, fmt.Errorf("profile.validate: unknown format %q (want %q or %q)",
			format, profileFormatKernel, profileFormatStored)
	}
	result := profileValidateResult{Issues: []profileIssue{}}
	if strings.TrimSpace(document) == "" {
		result.Issues = append(result.Issues, profileIssue{
			Message:  "the document is empty; expected one sing-box outbound object",
			Severity: profileSeverityError,
		})
		return result, nil
	}
	ctx := profileCodecContext()
	outbound, err := decodeProfileOutbound(ctx, document)
	if err != nil {
		result.Issues = append(result.Issues, profileIssueFromDecodeError(err))
		return result, nil
	}
	normalized, err := encodeProfileOutbound(ctx, &outbound)
	if err != nil {
		// The document decoded, so failing to re-encode is a codec defect, not a
		// defect in the caller's node. Report it as an action error.
		return nil, fmt.Errorf("profile.validate: re-encode the outbound: %w", err)
	}
	result.OK = true
	result.Normalized = normalized
	return result, nil
}

// handleProfileNormalize re-emits one outbound document in canonical compact
// form: one line, no trailing newline, keys in the core's own order.
//
// Limitation, and the reason the reply is a string rather than a promise of
// byte-stability: the output is deterministic for a given core pin (key order is
// the option structs' field order, the encoder is the core's own context-aware
// one, and the value shapes are the core's own: `udp_over_tcp` collapses to
// `true`, a null string becomes ""). It is NOT stable across a core bump — a
// renamed or added option field changes the bytes — and it is not Throne's
// Kotlin `ProfileJson` formatting, which has its own conventions. Normalization
// also drops what the decoder drops: comments, duplicate keys (the last one
// wins), and any field the option struct marks omitempty while it holds its zero
// value (`alter_id: 0`, for one, does not survive).
func handleProfileNormalize(raw stdjson.RawMessage) (any, error) {
	document, err := parseProfileDocumentRequest("profile.normalize", raw)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(document) == "" {
		// validate answers this as an issue (ok:false); normalize has nothing to
		// emit, so it refuses instead of answering the decoder's "unexpected end
		// of JSON input".
		return nil, errors.New("profile.normalize: the document is empty")
	}
	ctx := profileCodecContext()
	outbound, err := decodeProfileOutbound(ctx, document)
	if err != nil {
		return nil, fmt.Errorf("profile.normalize: %w", err)
	}
	normalized, err := encodeProfileOutbound(ctx, &outbound)
	if err != nil {
		return nil, fmt.Errorf("profile.normalize: re-encode the outbound: %w", err)
	}
	return profileJSONResult{JSON: normalized}, nil
}

// handleProfileNewOutbound answers a blank document for a type this action can
// construct without inventing defaults: the zero value of the core's own options
// struct, serialised by the core's own encoder. The caller's form fills in the
// server, the port and the credentials; validate answers whether the result is
// loadable.
func handleProfileNewOutbound(raw stdjson.RawMessage) (any, error) {
	var request profileNewOutboundRequest
	if len(raw) == 0 || string(raw) == "null" {
		return nil, errors.New("profile.newOutbound: missing payload")
	}
	if err := stdjson.Unmarshal(raw, &request); err != nil {
		return nil, fmt.Errorf("profile.newOutbound: parse payload: %w", err)
	}
	outboundType := strings.TrimSpace(request.Type)
	if outboundType == "" {
		return nil, fmt.Errorf("profile.newOutbound: the payload has no type (want %s)",
			strings.Join(profileNewOutboundSupported, ", "))
	}
	ctx := profileCodecContext()
	outbound, err := newProfileOutboundTemplate(ctx, outboundType)
	if err != nil {
		return nil, err
	}
	normalized, err := encodeProfileOutbound(ctx, &outbound)
	if err != nil {
		return nil, fmt.Errorf("profile.newOutbound: encode the template: %w", err)
	}
	return profileJSONResult{JSON: normalized}, nil
}

// parseProfileDocumentRequest validates the envelope before any parsing work, so
// a malformed request is a refusal rather than an "invalid document" answer.
func parseProfileDocumentRequest(action string, raw stdjson.RawMessage) (string, error) {
	request, err := decodeProfileDocumentRequest(action, raw)
	if err != nil {
		return "", err
	}
	return *request.JSON, nil
}

// decodeProfileDocumentRequest is the shared envelope decoder. Returning the
// whole request keeps the callers' existing (string, error) shape intact while
// giving profileValidate access to the optional format selector.
func decodeProfileDocumentRequest(action string, raw stdjson.RawMessage) (*profileDocumentRequest, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, fmt.Errorf("%s: missing payload", action)
	}
	var request profileDocumentRequest
	if err := stdjson.Unmarshal(raw, &request); err != nil {
		return nil, fmt.Errorf("%s: parse payload: %w", action, err)
	}
	if request.JSON == nil {
		return nil, fmt.Errorf(`%s: the payload has no "json" field`, action)
	}
	return &request, nil
}

// parseProfileValidateRequest reads the document plus the optional format
// selector for profileValidate. A null format means the kernel default.
func parseProfileValidateRequest(raw stdjson.RawMessage) (string, string, error) {
	request, err := decodeProfileDocumentRequest("profile.validate", raw)
	if err != nil {
		return "", "", err
	}
	format := ""
	if request.Format != nil {
		format = *request.Format
	}
	return *request.JSON, format, nil
}

// profileCodecContext builds the service registry option.Outbound needs: the
// outbound options registry, from the same include package the box itself is
// built with. That is the whole dependency — unmarshalling an outbound reads no
// router, no box and no file.
//
// The registry is rebuilt per call instead of cached: it is an in-memory table
// and this action is not on a hot path, while a package-level registry would be
// shared mutable state across action calls for no gain.
func profileCodecContext() context.Context {
	return service.ContextWith[option.OutboundOptionsRegistry](
		context.Background(), include.OutboundRegistry())
}

func decodeProfileOutbound(ctx context.Context, document string) (option.Outbound, error) {
	return singjson.UnmarshalExtendedContext[option.Outbound](ctx, []byte(document))
}

// encodeProfileOutbound serialises one outbound the way the kernel itself would
// write it.
//
// The pointer argument is load-bearing: option.Outbound implements
// MarshalJSONContext on *Outbound so the concrete options object merges into the
// type/tag envelope. encoding/json only finds a pointer-receiver marshaler on an
// addressable value, so marshalling an option.Outbound *value* silently drops
// Options and answers {"type":"socks"}. Keep the pointer, or put the document in
// a slice (slice elements are addressable); never pass the value.
func encodeProfileOutbound(ctx context.Context, outbound *option.Outbound) (string, error) {
	encoded, err := singjson.MarshalContext(ctx, outbound)
	if err != nil {
		return "", err
	}
	return string(encoded), nil
}

// newProfileOutboundTemplate builds the zero-value document for one supported
// type. The registry is consulted as the authority on whether this kernel build
// carries the type at all: without the descriptor tag some outbounds are
// registered as stubs, and a template for a stub would look loadable while the
// kernel could never start it.
func newProfileOutboundTemplate(ctx context.Context, outboundType string) (option.Outbound, error) {
	var template option.Outbound
	switch outboundType {
	case "direct":
		template = option.Outbound{Type: outboundType, Options: &option.DirectOutboundOptions{}}
	case "http":
		template = option.Outbound{Type: outboundType, Options: &option.HTTPOutboundOptions{}}
	case "socks":
		template = option.Outbound{Type: outboundType, Options: &option.SOCKSOutboundOptions{}}
	default:
		return option.Outbound{}, fmt.Errorf("profile.newOutbound: unsupported type %q (want %s)",
			outboundType, strings.Join(profileNewOutboundSupported, ", "))
	}
	registry := service.FromContext[option.OutboundOptionsRegistry](ctx)
	if registry == nil {
		// include.OutboundRegistry() always provides one; a nil here means the
		// service-registry convention changed with a core bump.
		return option.Outbound{}, errors.New("profile.newOutbound: the kernel exposes no outbound options registry")
	}
	if _, loaded := registry.CreateOptions(outboundType); !loaded {
		return option.Outbound{}, fmt.Errorf("profile.newOutbound: this kernel build has no %q outbound", outboundType)
	}
	return template, nil
}

// profileIssueFromDecodeError turns one decoder error into a readable issue.
//
// The context decoder prefixes its messages with the JSON path it was decoding
// ("tls.enabled: json: cannot unmarshal …", "bogus: json: unknown field …"), so
// the path is recoverable without a second parse. Messages that are sentences
// have a space in them, which is what separates the two cases; the literal
// "json" prefix belongs to encoding/json itself and is not a field either.
func profileIssueFromDecodeError(err error) profileIssue {
	message := err.Error()
	field := ""
	if prefix, rest, found := strings.Cut(message, ": "); found {
		switch {
		case prefix == "json":
			message = rest
		case profileFieldPath(prefix):
			field = prefix
			message = strings.TrimPrefix(rest, "json: ")
		}
	}
	if outboundType, found := strings.CutPrefix(message, profileUnknownTypePrefix); found {
		outboundType = strings.TrimSpace(outboundType)
		if outboundType == "" {
			return profileIssue{
				Field:    "type",
				Message:  `the document has no "type" field naming a sing-box outbound`,
				Severity: profileSeverityError,
			}
		}
		return profileIssue{
			Field:    "type",
			Message:  fmt.Sprintf("unknown outbound type %q", outboundType),
			Severity: profileSeverityError,
		}
	}
	return profileIssue{Field: field, Message: message, Severity: profileSeverityError}
}

// profileFieldPath reports whether a message prefix is a JSON path. Anything
// with a space is a sentence, not a path.
func profileFieldPath(prefix string) bool {
	if prefix == "" {
		return false
	}
	for index, char := range prefix {
		switch {
		case char >= 'a' && char <= 'z',
			char >= 'A' && char <= 'Z',
			char == '_',
			char >= '0' && char <= '9' && index > 0,
			char == '.',
			char == '[',
			char == ']':
		default:
			return false
		}
	}
	return true
}
