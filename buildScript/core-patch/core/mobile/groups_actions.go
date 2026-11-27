// The proxies screen's live selector switch, as a core action.
//
// A node tap used to leave Dart over the method channel, land in Kotlin's Clash
// API client (`PUT /proxies`) and come back as a boolean that said nothing about
// why a switch failed. The running box already owns those selector outbounds, so
// the switch belongs here: one action, no loopback HTTP, no `experimental.clash_api`
// dependency, and no Kotlin in the action path.
//
// Wire payload:
//
//	{"group":"Group A","tag":"Node B","nodeId":12}
//
// `group` and `tag` are the names the Dart/Kotlin layer already has. The reply is
// typed instead of a boolean because the caller has to choose between the live
// switch and the config rebuild:
//
//	switched        the running selector now points at `member`
//	not-found       no live outbound group or member matches the name
//	not-a-selector  the group resolves, but it is not a selector outbound
//	not-running     there is no live box, so there is nothing to switch
//
// Only `switched` may skip the reload. Every other status means the running config
// cannot express this choice in place, and the caller keeps the persistence +
// rebuild path it always had.
//
// Why most taps still rebuild: the generator emits ONE started chain per profile
// (`ConfigGenerator.build`), so a normal group has no selector outbound at all —
// its members are `config-N` hops of a single chain. The switchable groups are the
// ones the running config itself declares (`selector` outbounds, e.g. from a custom
// full config); the auto-selector is a different outbound type whose member state is
// the pin owned by `autoSelectorPin`, so it is deliberately NOT switched here.
package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/protocol/group"
)

const groupsSelectMethod Method = "groupsSelect"

// The status strings are untyped on purpose: action_contract.py treats every
// string constant that inherits a `Method` line as a request method, and a typed
// block would turn each status into a phantom action. They live in their own block
// for the same reason profile_actions.go keeps the marker filename out of its
// Method block.
const (
	groupsSelectSwitched     = "switched"
	groupsSelectNotFound     = "not-found"
	groupsSelectNotASelector = "not-a-selector"
	groupsSelectNotRunning   = "not-running"
)

// groupsSelectRequest is the action's payload. NodeID is optional diagnostics: the
// running config is addressed by tag, so an id alone cannot resolve a member — the
// reply says so instead of guessing.
type groupsSelectRequest struct {
	Group  string `json:"group"`
	Tag    string `json:"tag"`
	NodeID int64  `json:"nodeId"`
}

// groupsSelectReply is the typed answer. Group and Member echo the resolved
// outbound tags, which is what makes a "not-found" report useful.
type groupsSelectReply struct {
	Status string `json:"status"`
	Group  string `json:"group,omitempty"`
	Member string `json:"member,omitempty"`
	Reason string `json:"reason,omitempty"`
}

// handleGroupsSelect switches one running selector group in place. It never
// mutates persisted state: the caller writes its own selection after a `switched`
// answer, and the next start reads it.
func handleGroupsSelect(raw json.RawMessage) (any, error) {
	request, err := parseGroupsSelectRequest(raw)
	if err != nil {
		return nil, err
	}
	instance, err := currentInstance()
	if err != nil {
		if errors.Is(err, errInstanceNotRunning) {
			return groupsSelectReply{Status: groupsSelectNotRunning, Reason: err.Error()}, nil
		}
		return nil, err
	}
	if instance.outbounds == nil {
		return nil, errors.New("groups.select: the running box exposes no outbound manager")
	}
	if request.Tag == "" {
		// A node id alone is not addressable: the core names outbounds by tag, and
		// nothing in the running config maps a profile id to one.
		return groupsSelectReply{
			Status: groupsSelectNotFound,
			Group:  request.Group,
			Reason: "a member tag is required; the running config is addressed by tag",
		}, nil
	}

	type groupCandidate struct {
		tag      string
		typ      string
		outbound adapter.OutboundGroup
	}
	groups := make([]groupCandidate, 0, 8)
	groupTags := make([]string, 0, 8)
	outboundTags := make([]string, 0, 16)
	for _, outbound := range instance.outbounds.Outbounds() {
		adapterGroup, isGroup := outbound.(adapter.OutboundGroup)
		if !isGroup {
			outboundTags = append(outboundTags, outbound.Tag())
			continue
		}
		groups = append(groups, groupCandidate{tag: adapterGroup.Tag(), typ: adapterGroup.Type(), outbound: adapterGroup})
		groupTags = append(groupTags, adapterGroup.Tag())
	}

	groupTag, ambiguous := matchOutboundName(groupTags, request.Group)
	if ambiguous {
		return groupsSelectReply{
			Status: groupsSelectNotFound,
			Group:  request.Group,
			Reason: fmt.Sprintf("more than one outbound group matches %q", request.Group),
		}, nil
	}
	if groupTag == "" {
		if outboundTag, ambiguousOutbound := matchOutboundName(outboundTags, request.Group); ambiguousOutbound {
			return groupsSelectReply{
				Status: groupsSelectNotFound,
				Group:  request.Group,
				Reason: fmt.Sprintf("more than one outbound matches %q", request.Group),
			}, nil
		} else if outboundTag != "" {
			// A plain outbound carries the name: it exists, but it cannot be
			// switched as a group. The caller's fallback is the same either way;
			// the honest status makes a bug report readable.
			return groupsSelectReply{
				Status: groupsSelectNotASelector,
				Group:  outboundTag,
				Reason: fmt.Sprintf("outbound %q is not a group", outboundTag),
			}, nil
		}
		return groupsSelectReply{
			Status: groupsSelectNotFound,
			Group:  request.Group,
			Reason: fmt.Sprintf("no outbound group matches %q", request.Group),
		}, nil
	}

	var resolved groupCandidate
	for _, candidate := range groups {
		if candidate.tag == groupTag {
			resolved = candidate
			break
		}
	}
	selector, isSelector := resolved.outbound.(*group.Selector)
	if !isSelector {
		return groupsSelectReply{
			Status: groupsSelectNotASelector,
			Group:  groupTag,
			Reason: fmt.Sprintf("outbound group %q is %q, not a selector", groupTag, resolved.typ),
		}, nil
	}

	memberTag, ambiguousMember := matchOutboundName(selector.All(), request.Tag)
	if ambiguousMember {
		return groupsSelectReply{
			Status: groupsSelectNotFound,
			Group:  groupTag,
			Reason: fmt.Sprintf("more than one member of %q matches %q", groupTag, request.Tag),
		}, nil
	}
	if memberTag == "" {
		return groupsSelectReply{
			Status: groupsSelectNotFound,
			Group:  groupTag,
			Reason: fmt.Sprintf("no member of %q matches %q", groupTag, request.Tag),
		}, nil
	}
	if !selector.SelectOutbound(memberTag) {
		return groupsSelectReply{
			Status: groupsSelectNotFound,
			Group:  groupTag,
			Member: memberTag,
			Reason: fmt.Sprintf("the selector %q refused member %q", groupTag, memberTag),
		}, nil
	}
	// The kernel log records the switch; the lifecycle log records the persistence half the
	// caller runs next. Two surfaces, so a report can tell "switched but not remembered" from
	// "not switched".
	pump.push(int32(LogLevelInfo), "select: live switch "+request.Group+" -> "+request.Tag+" (no reload)")
	return groupsSelectReply{Status: groupsSelectSwitched, Group: groupTag, Member: memberTag}, nil
}

// parseGroupsSelectRequest validates the payload before any box lookup, so a
// malformed request is a refusal rather than a silent "not found".
func parseGroupsSelectRequest(raw json.RawMessage) (groupsSelectRequest, error) {
	var request groupsSelectRequest
	if len(raw) == 0 || string(raw) == "null" {
		return request, errors.New("groups.select: missing payload")
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return request, fmt.Errorf("groups.select: parse payload: %w", err)
	}
	request.Group = strings.TrimSpace(request.Group)
	request.Tag = strings.TrimSpace(request.Tag)
	if request.Group == "" && request.Tag == "" {
		return request, errors.New("groups.select: group and tag are both empty")
	}
	if request.Group == "" {
		return request, errors.New("groups.select: group is empty")
	}
	return request, nil
}

// matchOutboundName resolves one display name to at most one outbound tag. The
// removed Kotlin client accepted an exact tag or a single `<prefix>/<name>` suffix
// (the route/chain builder prefixes its outbound tags), and the same rule lives
// here so a caller that worked against the API keeps working against the core.
// Two prefix hits are ambiguous and are refused instead of guessed; an exact hit
// always wins, even when prefixes also match.
func matchOutboundName(tags []string, want string) (match string, ambiguous bool) {
	if want == "" {
		return "", false
	}
	for _, tag := range tags {
		if tag == want {
			return tag, false
		}
	}
	var candidate string
	for _, tag := range tags {
		if !strings.HasSuffix(tag, "/"+want) {
			continue
		}
		if candidate != "" {
			return "", true
		}
		candidate = tag
	}
	return candidate, false
}
