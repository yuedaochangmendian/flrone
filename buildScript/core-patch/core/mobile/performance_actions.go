// Bridge-performance actions on the Bettbox-style JSON bus.
//
// The new core pin exposes the primitives these handlers wrap:
//
//   - Instance.NewTrafficReader(tags) / TrafficReader.Read(): one locked read of
//     many outbound tags, draining the same counters QueryOutboundStats uses.
//   - mobile.SetScreenOff(off): tells every auto-selector to probe less often
//     while the screen is off (a process-wide setting, not an instance one).
//     The same handler pauses/wakes the running instance's pause manager, which
//     stops the core's periodic work while the TUN stays up (Bettbox's doze
//     semantics).
//   - the trafficcontrol manager's connection list, which the desktop RPC's
//     QueryConnectionCount counts by adapter network type.
//
// None of these need a new typed C export: Dart already has the single
// throne_invoke_action entry point, and Kotlin has Core.runAction. Keeping them
// on the bus means tools/diagnostics/action_contract.py can hold the Go/Dart
// wire names together, and symbol_audit.py's three-way export equality stays
// untouched.
//
// Wire shapes (the Dart ActionMethod member IS the wire name):
//
//	batchTraffic         {"tags":["a","b"]} -> {"tags":["a","b"],"counters":"<base64>"}
//	setScreenOff         {"off":true}       -> true
//	queryConnectionCount {}                 -> {"tcp":N,"udp":N}
//
// `counters` is 16 bytes per tag, in the request's order: little-endian int64
// uplink bytes then little-endian int64 downlink bytes, each a delta since the
// previous read of that tag. base64 keeps the JSON payload textual over the
// message port; Dart decodes it with ByteData + Endian.little.
//
// A tag is a single line: the reader takes a newline-separated string, so an
// embedded "\n" is rejected rather than silently creating extra tags. The tag
// count is bounded as well — the request comes from a UI isolate, but a
// malformed caller must not be able to allocate an unbounded byte slice.
package mobile

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/sagernet/sing-box/common/trafficcontrol"
	N "github.com/sagernet/sing/common/network"
)

const (
	batchTrafficMethod         Method = "batchTraffic"
	setScreenOffMethod         Method = "setScreenOff"
	queryConnectionCountMethod Method = "queryConnectionCount"
)

// maxBatchTrafficTags bounds one handler's allocation (16 bytes per tag) and
// keeps a malformed request from filling the action reply port.
const maxBatchTrafficTags = 1024

func init() {
	register(batchTrafficMethod, handleBatchTraffic)
	register(setScreenOffMethod, handleSetScreenOff)
	register(queryConnectionCountMethod, handleQueryConnectionCount)
}

// parseBatchTrafficRequest validates the tag list. It performs no I/O and
// touches no instance, so tests can pin every rejection branch deterministically.
func parseBatchTrafficRequest(raw json.RawMessage) ([]string, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, errors.New("batchTraffic: missing payload")
	}
	var request struct {
		Tags []string `json:"tags"`
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return nil, fmt.Errorf("batchTraffic: parse payload: %w", err)
	}
	if len(request.Tags) == 0 {
		return nil, errors.New("batchTraffic: tags is empty")
	}
	if len(request.Tags) > maxBatchTrafficTags {
		return nil, fmt.Errorf("batchTraffic: %d tags exceeds the %d tag limit", len(request.Tags), maxBatchTrafficTags)
	}
	for _, tag := range request.Tags {
		if tag == "" {
			return nil, errors.New("batchTraffic: empty tag")
		}
		if strings.ContainsAny(tag, "\r\n") {
			return nil, fmt.Errorf("batchTraffic: tag %q contains a newline", tag)
		}
	}
	return request.Tags, nil
}

// handleBatchTraffic reads every tag's counters in one locked pass. One reader
// per action is intentional: the core's reader holds a fixed tag list, and the
// action's whole point is to avoid one gobind crossing per tag. Because the
// reader drains the same pending map as QueryOutboundStats, the two can be
// mixed without losing or double-counting bytes.
func handleBatchTraffic(raw json.RawMessage) (any, error) {
	tags, err := parseBatchTrafficRequest(raw)
	if err != nil {
		return nil, err
	}
	instance, err := currentInstance()
	if err != nil {
		return nil, fmt.Errorf("batchTraffic: %w", err)
	}
	counters := instance.NewTrafficReader(strings.Join(tags, "\n")).Read()
	return map[string]any{
		"tags":     tags,
		"counters": base64.StdEncoding.EncodeToString(counters),
	}, nil
}

// applyScreenOff is the production seam: tests swap it for a recorder so the
// handler can be exercised without changing the process-wide auto-selector
// state. It is only assigned here and in tests; the bus never sends a function.
var applyScreenOff = SetScreenOff

// applyInstancePause connects the already-exported suspend capability
// (throne_suspend → Instance.Pause/Wake) to the same screen-off transition:
// the pause manager stops the core's periodic work (health checks, scheduled
// DNS/rule-set work) while the TUN keeps carrying traffic. Bettbox's doze mode
// does the same; without an instance this is a no-op.
var applyInstancePause = func(off bool) {
	instance, err := currentInstance()
	if err != nil || instance == nil {
		return
	}
	if off {
		instance.Pause()
	} else {
		instance.Wake()
	}
}

func handleSetScreenOff(raw json.RawMessage) (any, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, errors.New("setScreenOff: missing payload")
	}
	var request struct {
		Off *bool `json:"off"`
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return nil, fmt.Errorf("setScreenOff: parse payload: %w", err)
	}
	if request.Off == nil {
		return nil, errors.New("setScreenOff: off is required")
	}
	applyScreenOff(*request.Off)
	applyInstancePause(*request.Off)
	return true, nil
}

// countConnectionNetworks is the same count the desktop RPC's
// QueryConnectionCount reports: live connections only, grouped by the
// adapter's network string. Closed connections live in a separate ring and
// are deliberately not counted here.
func countConnectionNetworks(connections []*trafficcontrol.TrackerMetadata) map[string]any {
	var tcp, udp int
	for _, connection := range connections {
		if connection == nil {
			continue
		}
		switch connection.Metadata.Network {
		case N.NetworkTCP:
			tcp++
		case N.NetworkUDP:
			udp++
		}
	}
	return map[string]any{"tcp": tcp, "udp": udp}
}

func handleQueryConnectionCount(_ json.RawMessage) (any, error) {
	instance, err := currentInstance()
	if err != nil {
		return nil, fmt.Errorf("queryConnectionCount: %w", err)
	}
	if instance.traffic == nil {
		// A running instance without a traffic manager counts nothing; this is
		// the same answer the RPC gives when the manager is missing.
		return map[string]any{"tcp": 0, "udp": 0}, nil
	}
	return countConnectionNetworks(instance.traffic.Connections()), nil
}
