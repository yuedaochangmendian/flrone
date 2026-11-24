// Polling test hub for the Kotlin host.
//
// The gomobile test entries took a Java handler object (URLTestHandler /
// IPTestHandler / SpeedTestHandler). The C ABI has no test callback slot, so
// this hub keeps the results in Go and the Kotlin side polls them:
//
//	start_url_test/start_ip_test/start_speed_test -> {"session": n}
//	poll_test {"session":n,"cursor":c} -> {"events":[...],"cursor":c2,"done":bool}
//	cancel_test -> StopTests()
//
// The events are the same fields the generated handlers carried, so the Kotlin
// runners only change transport. Sessions are removed once their done event has
// been drained.
package mobile

import (
	"encoding/json"
	"fmt"
	"sync"
)

type hostTestRequest struct {
	CoreConfig         string   `json:"coreConfig"`
	URL                string   `json:"url"`
	MaxConcurrency     int32    `json:"maxConcurrency"`
	TimeoutMs          int32    `json:"timeoutMs"`
	UseDefaultOutbound bool     `json:"useDefaultOutbound"`
	TestCurrent        bool     `json:"testCurrent"`
	TestDownload       bool     `json:"testDownload"`
	TestUpload         bool     `json:"testUpload"`
	SimpleDownload     bool     `json:"simpleDownload"`
	SimpleDownloadAddr string   `json:"simpleDownloadAddr"`
	OnlyCountry        bool     `json:"onlyCountry"`
	CountryConcurrency int32    `json:"countryConcurrency"`
	IPProvider         string   `json:"ipProvider"`
	ServiceChecks      string   `json:"serviceChecks"`
	SkipIPInfo         bool     `json:"skipIPInfo"`
	OutboundTags       []string `json:"outboundTags"`
	VPNEndpointTags    []string `json:"vpnEndpointTags"`
}

func (r hostTestRequest) build() *TestRequest {
	request := &TestRequest{
		CoreConfig:         r.CoreConfig,
		URL:                r.URL,
		MaxConcurrency:     r.MaxConcurrency,
		TimeoutMs:          r.TimeoutMs,
		UseDefaultOutbound: r.UseDefaultOutbound,
		TestCurrent:        r.TestCurrent,
		TestDownload:       r.TestDownload,
		TestUpload:         r.TestUpload,
		SimpleDownload:     r.SimpleDownload,
		SimpleDownloadAddr: r.SimpleDownloadAddr,
		OnlyCountry:        r.OnlyCountry,
		CountryConcurrency: r.CountryConcurrency,
		IPProvider:         r.IPProvider,
		ServiceChecks:      r.ServiceChecks,
		SkipIPInfo:         r.SkipIPInfo,
	}
	for _, tag := range r.OutboundTags {
		request.AddOutboundTag(tag)
	}
	for _, tag := range r.VPNEndpointTags {
		request.AddVPNEndpointTag(tag)
	}
	return request
}

type hostTestSession struct {
	mu     sync.Mutex
	events []map[string]any
	done   bool
}

func (s *hostTestSession) push(event map[string]any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, event)
}

func (s *hostTestSession) finish() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.done = true
}

var hostTestSessions = struct {
	sync.Mutex
	next int64
	m    map[int64]*hostTestSession
}{m: make(map[int64]*hostTestSession)}

func newHostTestSession() (int64, *hostTestSession) {
	hostTestSessions.Lock()
	defer hostTestSessions.Unlock()
	hostTestSessions.next++
	id := hostTestSessions.next
	session := &hostTestSession{}
	hostTestSessions.m[id] = session
	return id, session
}

func getHostTestSession(id int64) (*hostTestSession, error) {
	hostTestSessions.Lock()
	defer hostTestSessions.Unlock()
	session := hostTestSessions.m[id]
	if session == nil {
		return nil, fmt.Errorf("unknown test session %d", id)
	}
	return session, nil
}

func dropHostTestSession(id int64) {
	hostTestSessions.Lock()
	defer hostTestSessions.Unlock()
	delete(hostTestSessions.m, id)
}

type hostURLSink struct{ session *hostTestSession }

func (s hostURLSink) OnResult(tag string, latencyMs int32, err string) {
	s.session.push(map[string]any{"kind": "result", "tag": tag, "latencyMs": latencyMs, "error": err})
}
func (s hostURLSink) OnVPNStatus(tag string, connected bool, state string, err string) {
	s.session.push(map[string]any{"kind": "vpn", "tag": tag, "connected": connected, "state": state, "error": err})
}
func (s hostURLSink) OnDone() { s.session.finish() }

type hostIPSink struct{ session *hostTestSession }

func (s hostIPSink) OnResult(tag string, ip string, countryCode string, err string) {
	s.session.push(map[string]any{"kind": "result", "tag": tag, "ip": ip, "country": countryCode, "error": err})
}
func (s hostIPSink) OnDone() { s.session.finish() }

type hostSpeedSink struct{ session *hostTestSession }

func (s hostSpeedSink) OnResult(result *SpeedTestResult) {
	if result == nil {
		return
	}
	s.session.push(map[string]any{
		"kind": "result", "tag": result.Tag, "dlSpeed": result.DlSpeed,
		"ulSpeed": result.UlSpeed, "latency": result.Latency,
		"serverName": result.ServerName, "serverCountry": result.ServerCountry,
		"error": result.Error, "cancelled": result.Cancelled,
		"dlBytes": result.DlBytes, "ulBytes": result.UlBytes, "running": result.Running,
	})
}
func (s hostSpeedSink) OnDone() { s.session.finish() }

func startHostTest(kind string, params json.RawMessage) (any, error) {
	var request struct {
		Session int64           `json:"session"`
		Request hostTestRequest `json:"request"`
	}
	if err := decodeHostParams(params, &request); err != nil {
		return nil, err
	}
	sessionID := request.Session
	created := sessionID == 0
	var session *hostTestSession
	if created {
		sessionID, session = newHostTestSession()
	} else {
		var err error
		session, err = getHostTestSession(sessionID)
		if err != nil {
			return nil, err
		}
	}
	testRequest := request.Request.build()
	var err error
	switch kind {
	case "url":
		err = StartURLTest(nil, bridgePlatform, testRequest, hostURLSink{session})
	case "ip":
		err = StartIPTest(bridgePlatform, testRequest, hostIPSink{session})
	case "speed":
		err = StartSpeedTest(nil, bridgePlatform, testRequest, hostSpeedSink{session})
	default:
		err = fmt.Errorf("unknown test kind %s", kind)
	}
	if err != nil {
		session.finish()
		// A session minted for a start that never ran has no poller: drop it
		// instead of leaking it until process death. A caller-supplied session
		// stays so its owner can still observe the done event.
		if created {
			dropHostTestSession(sessionID)
		}
		return nil, err
	}
	return map[string]any{"session": sessionID}, nil
}

func pollHostTest(params json.RawMessage) (any, error) {
	var request struct {
		Session int64 `json:"session"`
		Cursor  int   `json:"cursor"`
	}
	if err := decodeHostParams(params, &request); err != nil {
		return nil, err
	}
	session, err := getHostTestSession(request.Session)
	if err != nil {
		return nil, err
	}
	session.mu.Lock()
	cursor := request.Cursor
	if cursor < 0 {
		cursor = 0
	}
	if cursor > len(session.events) {
		cursor = len(session.events)
	}
	events := append([]map[string]any(nil), session.events[cursor:]...)
	next := cursor + len(events)
	done := session.done
	finished := done && next == len(session.events)
	session.mu.Unlock()
	if finished {
		dropHostTestSession(request.Session)
	}
	return map[string]any{"events": events, "cursor": next, "done": done}, nil
}
