package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"testing"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/protocol/group"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/service"
)

// fakeOutbound is a selector member: only the identity and dialer shape a
// selector start resolves are needed, so the dial methods are never exercised.
type fakeOutbound struct {
	*outbound.Adapter
}

func newFakeOutbound(tag string) *fakeOutbound {
	adapter := outbound.NewAdapter(C.TypeShadowsocks, tag, []string{N.NetworkTCP, N.NetworkUDP}, nil)
	return &fakeOutbound{Adapter: &adapter}
}

func (f *fakeOutbound) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	return nil, errors.New("the fake outbound dials nothing")
}

func (f *fakeOutbound) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, errors.New("the fake outbound listens on nothing")
}

// fakeOutboundManager is the slice of adapter.OutboundManager a selector start
// reads. Create answers with an error no test reaches.
type fakeOutboundManager struct {
	outbounds []adapter.Outbound
}

func (f *fakeOutboundManager) Start(adapter.StartStage, *adapter.Scope) error { return nil }

func (f *fakeOutboundManager) Outbounds() []adapter.Outbound { return f.outbounds }

func (f *fakeOutboundManager) Outbound(tag string) (adapter.Outbound, bool) {
	for _, outbound := range f.outbounds {
		if outbound.Tag() == tag {
			return outbound, true
		}
	}
	return nil, false
}

func (f *fakeOutboundManager) Default() adapter.Outbound { return nil }

func (f *fakeOutboundManager) Create(context.Context, adapter.Router, log.ContextLogger, string, string, any) error {
	return errors.New("the fake manager creates nothing")
}

// newTestSelector builds and starts a real *group.Selector over fake members, so
// the handler's type assertion and SelectOutbound call run against the same
// implementation the running core uses.
func newTestSelector(t *testing.T, tag string, memberTags []string) *group.Selector {
	t.Helper()
	logger := log.NewNOPFactory().Logger()
	manager := &fakeOutboundManager{}
	for _, memberTag := range memberTags {
		manager.outbounds = append(manager.outbounds, newFakeOutbound(memberTag))
	}
	ctx := service.ContextWith[adapter.OutboundManager](context.Background(), manager)
	created, err := group.NewSelector(ctx, nil, logger, tag, option.SelectorOutboundOptions{Outbounds: memberTags})
	if err != nil {
		t.Fatalf("new selector %q: %v", tag, err)
	}
	selector, isSelector := created.(*group.Selector)
	if !isSelector {
		t.Fatalf("new selector %q answered %T", tag, created)
	}
	if err := selector.Start(adapter.StartStateStart, adapter.NewScope(ctx, logger)); err != nil {
		t.Fatalf("start selector %q: %v", tag, err)
	}
	return selector
}

// testInstance is a started box around the fake manager: running() only reads
// started/closed, so no platform interface or config parse is needed.
func testInstance(outbounds adapter.OutboundManager) *Instance {
	return &Instance{outbounds: outbounds, started: true}
}

// withLastInstance publishes the box the way an FFI start does, and restores the
// registry afterwards so the test cannot leak a fake into another case.
func withLastInstance(t *testing.T, instance *Instance) {
	t.Helper()
	lastInstance.mu.Lock()
	previous := lastInstance.inst
	lastInstance.inst = instance
	lastInstance.mu.Unlock()
	t.Cleanup(func() {
		lastInstance.mu.Lock()
		lastInstance.inst = previous
		lastInstance.mu.Unlock()
	})
}

func groupsSelectWire(t *testing.T, payload string) (groupsSelectReply, int) {
	t.Helper()
	encoded := RunAction(`{"id":"select-1","method":"groupsSelect","data":` + payload + `}`)
	var answer struct {
		ID   string          `json:"id"`
		Code int             `json:"code"`
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal([]byte(encoded), &answer); err != nil {
		t.Fatalf("decode action result: %v (%s)", err, encoded)
	}
	if answer.ID != "select-1" {
		t.Fatalf("action result id = %q, want select-1", answer.ID)
	}
	var reply groupsSelectReply
	if err := json.Unmarshal(answer.Data, &reply); err != nil {
		t.Fatalf("decode groupsSelect reply: %v (%s)", err, answer.Data)
	}
	return reply, answer.Code
}

func TestMatchOutboundName(t *testing.T) {
	tags := []string{"proxy", "auto/proxy", "auto/config-0", "a/dup", "b/dup"}
	for _, test := range []struct {
		name      string
		want      string
		match     string
		ambiguous bool
	}{
		{name: "exact wins over prefixes", want: "proxy", match: "proxy"},
		{name: "one prefixed hit is accepted", want: "config-0", match: "auto/config-0"},
		{name: "two prefixed hits are ambiguous", want: "dup", ambiguous: true},
		{name: "nothing matches", want: "missing"},
		{name: "an empty name matches nothing, not a trailing slash", want: ""},
	} {
		match, ambiguous := matchOutboundName(tags, test.want)
		if match != test.match || ambiguous != test.ambiguous {
			t.Fatalf("%s: match=%q ambiguous=%v, want %q/%v", test.name, match, ambiguous, test.match, test.ambiguous)
		}
	}
	// The same name must not be ambiguous merely because one tag is a prefix of
	// another: suffix matching is anchored on the slash.
	if match, ambiguous := matchOutboundName([]string{"a/x", "b/x/y"}, "x"); match != "a/x" || ambiguous {
		t.Fatalf("prefix-of-prefix: match=%q ambiguous=%v, want a/x/false", match, ambiguous)
	}
}

func TestGroupsSelectSwitchesASelectorInPlace(t *testing.T) {
	selector := newTestSelector(t, "proxy", []string{"pool-0", "pool-1"})
	withLastInstance(t, testInstance(&fakeOutboundManager{outbounds: []adapter.Outbound{selector}}))

	reply, code := groupsSelectWire(t, `{"group":"proxy","tag":"pool-1","nodeId":12}`)
	if code != actionCodeSuccess {
		t.Fatalf("action code = %d, want %d", code, actionCodeSuccess)
	}
	if reply.Status != groupsSelectSwitched {
		t.Fatalf("status = %q (%s), want %q", reply.Status, reply.Reason, groupsSelectSwitched)
	}
	if reply.Group != "proxy" || reply.Member != "pool-1" {
		t.Fatalf("resolved group/member = %q/%q, want proxy/pool-1", reply.Group, reply.Member)
	}
	if selected := selector.Selected(N.NetworkTCP); selected == nil || selected.Tag() != "pool-1" {
		t.Fatalf("selector now points at %v, want pool-1", selected)
	}

	// A prefixed member tag resolves the way the removed client accepted it.
	if match, ambiguous := matchOutboundName(selector.All(), "pool-0"); match != "pool-0" || ambiguous {
		t.Fatalf("member resolution = %q/%v, want pool-0/false", match, ambiguous)
	}
}

func TestGroupsSelectResolvesPrefixedTags(t *testing.T) {
	selector := newTestSelector(t, "custom/proxy", []string{"custom/pool-0"})
	withLastInstance(t, testInstance(&fakeOutboundManager{outbounds: []adapter.Outbound{selector}}))

	reply, code := groupsSelectWire(t, `{"group":"proxy","tag":"pool-0"}`)
	if code != actionCodeSuccess {
		t.Fatalf("action code = %d, want %d", code, actionCodeSuccess)
	}
	if reply.Status != groupsSelectSwitched {
		t.Fatalf("status = %q (%s), want %q", reply.Status, reply.Reason, groupsSelectSwitched)
	}
	if reply.Group != "custom/proxy" || reply.Member != "custom/pool-0" {
		t.Fatalf("resolved group/member = %q/%q, want custom/proxy/custom/pool-0", reply.Group, reply.Member)
	}
}

func TestGroupsSelectRefusesNonSelectorGroups(t *testing.T) {
	manager := &fakeOutboundManager{outbounds: []adapter.Outbound{newFakeOutbound("group-a")}}
	withLastInstance(t, testInstance(manager))

	reply, _ := groupsSelectWire(t, `{"group":"group-a","tag":"node"}`)
	if reply.Status != groupsSelectNotASelector {
		t.Fatalf("status = %q (%s), want %q", reply.Status, reply.Reason, groupsSelectNotASelector)
	}
	if reply.Group != "group-a" {
		t.Fatalf("group = %q, want group-a", reply.Group)
	}
}

func TestGroupsSelectReportsNotFound(t *testing.T) {
	selector := newTestSelector(t, "proxy", []string{"pool-0"})
	manager := &fakeOutboundManager{outbounds: []adapter.Outbound{selector}}
	withLastInstance(t, testInstance(manager))

	for _, test := range []struct{ name, payload string }{
		{name: "unknown group", payload: `{"group":"missing","tag":"pool-0"}`},
		{name: "unknown member", payload: `{"group":"proxy","tag":"missing"}`},
		{name: "id without a tag", payload: `{"group":"proxy","nodeId":12}`},
	} {
		reply, code := groupsSelectWire(t, test.payload)
		if code != actionCodeSuccess {
			t.Fatalf("%s: action code = %d, want %d", test.name, code, actionCodeSuccess)
		}
		if reply.Status != groupsSelectNotFound {
			t.Fatalf("%s: status = %q (%s), want %q", test.name, reply.Status, reply.Reason, groupsSelectNotFound)
		}
		if reply.Reason == "" {
			t.Fatalf("%s: not-found must name the reason", test.name)
		}
	}
}

func TestGroupsSelectRejectsAmbiguousGroupNames(t *testing.T) {
	first := newTestSelector(t, "a/proxy", []string{"pool-0"})
	second := newTestSelector(t, "b/proxy", []string{"pool-0"})
	withLastInstance(t, testInstance(&fakeOutboundManager{outbounds: []adapter.Outbound{first, second}}))

	reply, _ := groupsSelectWire(t, `{"group":"proxy","tag":"pool-0"}`)
	if reply.Status != groupsSelectNotFound {
		t.Fatalf("status = %q (%s), want %q", reply.Status, reply.Reason, groupsSelectNotFound)
	}
	if reply.Reason == "" {
		t.Fatalf("ambiguous group must name the reason")
	}
}

func TestGroupsSelectReportsNotRunning(t *testing.T) {
	lastInstance.mu.Lock()
	previous := lastInstance.inst
	lastInstance.inst = nil
	lastInstance.mu.Unlock()
	t.Cleanup(func() {
		lastInstance.mu.Lock()
		lastInstance.inst = previous
		lastInstance.mu.Unlock()
	})

	reply, code := groupsSelectWire(t, `{"group":"proxy","tag":"pool-0"}`)
	if code != actionCodeSuccess {
		t.Fatalf("action code = %d, want %d", code, actionCodeSuccess)
	}
	if reply.Status != groupsSelectNotRunning {
		t.Fatalf("status = %q (%s), want %q", reply.Status, reply.Reason, groupsSelectNotRunning)
	}
}

func TestGroupsSelectRejectsMalformedPayload(t *testing.T) {
	for _, payload := range []string{`null`, `{}`, `{"tag":"node"}`, `{"group":" ","tag":""}`} {
		if _, err := handleGroupsSelect(json.RawMessage(payload)); err == nil {
			t.Fatalf("payload %s was accepted, want a parse error", payload)
		}
	}
}
