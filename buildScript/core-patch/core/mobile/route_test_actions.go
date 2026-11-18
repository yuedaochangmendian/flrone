// The route test: one made-up connection walked through the running instance's
// route rules, without dialing anything.
//
// `core/mobile/routetest.go` (upstream, already in the pinned AAR) owns the
// walker; this handler exposes it through the JSON action bus so the Flutter
// diagnostics page needs no new C ABI export. The action returns the same
// TestRouteResponse JSON the desktop consumes, decoded into the action result.

package mobile

import "encoding/json"

const routeTestMethod Method = "routeTest"

func init() {
	register(routeTestMethod, handleRouteTest)
}

func handleRouteTest(data json.RawMessage) (any, error) {
	var request struct {
		Domain      string `json:"domain"`
		IP          string `json:"ip"`
		Port        int32  `json:"port"`
		Network     string `json:"network"`
		Protocol    string `json:"protocol"`
		PackageName string `json:"packageName"`
	}
	if len(data) > 0 {
		if err := json.Unmarshal(data, &request); err != nil {
			return nil, err
		}
	}
	instance, err := currentInstance()
	if err != nil {
		return nil, err
	}
	raw, err := instance.TestRoute(&RouteTestRequest{
		Domain:      request.Domain,
		IP:          request.IP,
		Port:        request.Port,
		Network:     request.Network,
		Protocol:    request.Protocol,
		PackageName: request.PackageName,
	})
	if err != nil {
		return nil, err
	}
	var result any
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		return nil, err
	}
	return result, nil
}
