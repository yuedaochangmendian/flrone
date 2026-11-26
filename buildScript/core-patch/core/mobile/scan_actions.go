// Network-scan actions on the Bettbox-style JSON bus (ADR 0002).
//
// The pinned core (Throne bdc8be00) ships mobile/scan.go with five entry points:
// ScanProbe, QueryScan, StopScan, ScanURLTest and ScanCheckNetwork. Only
// ScanCheckNetwork is wired here. The rest are deliberately deferred — see the
// "deferred" note below — because the fork's Xray-removal overlay does not
// carry the dependency chain those entry points need to compile. Wiring a
// handler whose Go file cannot be built into the AAR would be worse than not
// exposing it: the whole mobile package would fail to compile.
//
// What IS wired:
//
//	scanCheckNetwork  {"targets":["1.1.1.1:53","host:443"],"timeoutMs":3000,"dns":false,"systemResolvers":[]}
//	               -> {"up":true,"error":"","systemResolvers":[]}
//
// The request/response are the core's own ScanCheckNetworkRequest/Response JSON
// verbatim: this handler only validates the envelope and delegates to
// ScanCheckNetwork, which owns the dials (through the Xray-free protectDial
// shim in xray_compat_shim.go) and the up/error verdict. No new typed C export
// is added — Dart reaches it through the existing `throne_invoke_action`.
//
// Deferred entry points and the exact reason (all verified against the pinned
// checkout and this overlay):
//
//   - ScanProbe / QueryScan / StopScan: upstream ScanProbe needs the full
//     internal/scan session+engine chain (session.go, engine.go, targets.go,
//     egress.go, netcheck.go, warp.go) plus internal/warpprobe. Our overlay
//     ships only internal/scan/dns.go, and that file's newDNSProbe is an
//     always-error stub (no Xray DNS tunnel prober exists in the fork). Adding
//     the rest without the Xray DNS/WARP helpers would make ScanProbe produce
//     nothing but errors, i.e. a fake "scan" the UI cannot honestly show.
//   - ScanURLTest: takes PlatformInterface + *TestRequest + a probe box built
//     by prepareTestEnv and calls probe.BatchURLTestTo; it is the desktop's
//     URL test, not a standalone JSON API, and wiring it through the bus would
//     need a new typed payload shape and a live test environment. The existing
//     URL-test action surface already covers this use case.
//
// The scan session lifecycle (an action that starts a chunk, a polling action
// for events, a stop action) is therefore NOT exposed yet. If the plan is to
// add it later, the whole internal/scan tree and its WARP/DNS dependencies must
// first be ported Xray-free; this file is where those handlers would go.
package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
)

const scanCheckNetworkMethod Method = "scanCheckNetwork"

// limits mirror the UI's needs: a check never needs more than a handful of
// targets/resolvers, and a malformed caller must not make the core dial an
// unbounded list.
const (
	maxCheckTargets   = 64
	maxCheckResolvers = 16
)

func init() {
	register(scanCheckNetworkMethod, handleScanCheckNetwork)
}

// The request/response types are declared by upstream mobile/scan.go as
// scanCheckNetworkRequest / scanCheckNetworkResponse. Reuse them instead of
// redeclaring: the whole mobile package (including the c-shared ABI) compiles
// both files together, and duplicate declarations are a build failure.
// A "dns":true check asks the supplied system resolvers on port 53 instead of
// dialing "targets"; the response reports which resolvers were actually asked.

// decodeScanCheckRequest parses and bounds the JSON envelope. Pure so tests
// can pin every rejection branch without touching the network or the core.
func decodeScanCheckRequest(raw json.RawMessage) (scanCheckNetworkRequest, error) {
	var request scanCheckNetworkRequest
	if len(raw) == 0 || string(raw) == "null" {
		return request, errors.New("scanCheckNetwork: missing payload")
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return request, fmt.Errorf("scanCheckNetwork: parse payload: %w", err)
	}
	entries := request.Targets
	if request.DNS {
		entries = request.SystemResolvers
	}
	if len(entries) == 0 {
		field := "targets"
		if request.DNS {
			field = "system_resolvers"
		}
		return request, fmt.Errorf("scanCheckNetwork: %s is empty", field)
	}
	limit := maxCheckTargets
	if request.DNS {
		limit = maxCheckResolvers
	}
	if len(entries) > limit {
		return request, fmt.Errorf("scanCheckNetwork: %d entries exceeds the %d limit", len(entries), limit)
	}
	validate := func(kind string, values []string) error {
		for _, value := range values {
			if strings.TrimSpace(value) == "" {
				return fmt.Errorf("scanCheckNetwork: empty %s", kind)
			}
			if request.DNS {
				// The core parses these as IP literals; a hostname here would be
				// silently dropped, leaving the caller thinking it was checked.
				if net.ParseIP(value) == nil {
					return fmt.Errorf("scanCheckNetwork: resolver %q is not an IP literal", value)
				}
			} else if _, _, err := net.SplitHostPort(value); err != nil {
				return fmt.Errorf("scanCheckNetwork: target %q is not host:port", value)
			}
		}
		return nil
	}
	if err := validate("target", request.Targets); err != nil {
		return request, err
	}
	if err := validate("resolver", request.SystemResolvers); err != nil {
		return request, err
	}
	return request, nil
}

// invokeScanCheckNetwork is the seam tests swap for a recorder: the handler's
// validation and response folding stay testable without opening sockets.
var invokeScanCheckNetwork = ScanCheckNetwork

func handleScanCheckNetwork(raw json.RawMessage) (any, error) {
	request, err := decodeScanCheckRequest(raw)
	if err != nil {
		return nil, err
	}
	// Re-encode the validated request: the core's own ScanCheckNetwork decodes
	// the same JSON keys, so there is a single source of truth for the wire
	// shape and no duplicate struct mapping to drift.
	encoded, err := json.Marshal(request)
	if err != nil {
		return nil, fmt.Errorf("scanCheckNetwork: encode request: %w", err)
	}
	var response scanCheckNetworkResponse
	if err := json.Unmarshal([]byte(invokeScanCheckNetwork(string(encoded))), &response); err != nil {
		return nil, fmt.Errorf("scanCheckNetwork: decode core response: %w", err)
	}
	// The core answers its errors inside the JSON (not as a Go error), so the
	// action stays a success with the raw verdict — exactly what the Dart
	// facade decodes. A missing system_resolvers array is normalized to [] so
	// callers can rely on a list shape.
	if response.SystemResolvers == nil {
		response.SystemResolvers = []string{}
	}
	return response, nil
}
