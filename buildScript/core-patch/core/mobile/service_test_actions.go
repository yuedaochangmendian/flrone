// The service availability check: a synchronous action over the JSON bus.
//
// The pinned core already owns the probe (`probe.BatchServiceTest`), the
// definitions parser (`servicecheck.ParseOrDefault`) and the JSON shape
// (`serviceResultString`). StartServiceTest is the async, per-tag streaming
// handler the gobind/desktop side uses; the action bus has no streaming reply
// port, so this handler runs the same batch synchronously against the CURRENT
// running instance and returns the finished result in one ActionResult.
//
// It deliberately does not build a stripped config: `prepareTestEnv(current,
// true, ...)` adopts the live box, and `probe.LiveInstance` marks the batch so
// the probe reuses the tunnel's DNS/cache instead of cold-starting a box.

package mobile

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"ThroneCore/internal/probe"
	"ThroneCore/internal/servicecheck"

	E "github.com/sagernet/sing/common/exceptions"
)

const serviceTestMethod Method = "serviceTest"

func init() {
	register(serviceTestMethod, handleServiceTest)
}

const (
	defaultServiceTimeoutMs     = 15000
	defaultServiceMaxConcurrent = 4
	// The action is synchronous on the worker: the batch must never outlive the
	// caller's wait. A single per-tag budget of serviceTestBudget (3m) would hang
	// the worker, so cap the whole batch with an independent wall-clock deadline.
	maxServiceActionDuration = 90 * time.Second
)

type serviceTestRequest struct {
	ServiceChecks  string   `json:"serviceChecks"`
	SkipIPInfo     bool     `json:"skipIpInfo"`
	Only           []string `json:"only"`
	TimeoutMs      int      `json:"timeoutMs"`
	MaxConcurrency int      `json:"maxConcurrency"`
}

type serviceTestTagResult struct {
	Tag    string `json:"tag"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

type serviceTestResponse struct {
	Results []serviceTestTagResult `json:"results"`
}

func handleServiceTest(data json.RawMessage) (any, error) {
	var request serviceTestRequest
	if len(data) > 0 {
		if err := json.Unmarshal(data, &request); err != nil {
			return nil, E.Cause(err, "serviceTest request")
		}
	}

	current, err := currentInstance()
	if err != nil {
		return nil, err
	}
	// Running against the box already carrying the subscription: no config is
	// parsed and no box is started. UseDefaultOutbound lets testenv pick the
	// proxy tag (or the default outbound when there is no proxy).
	probeRequest := &TestRequest{UseDefaultOutbound: true}
	env, err := prepareTestEnv(current, true, nil, probeRequest)
	if err != nil {
		return nil, err
	}
	defer env.Close()

	defs, err := servicecheck.ParseOrDefault(request.ServiceChecks)
	if err != nil {
		return nil, E.Cause(err, "service checks")
	}
	options := servicecheck.Options{SkipIPInfo: request.SkipIPInfo}
	if len(request.Only) > 0 {
		options.Only = make(map[string]bool, len(request.Only))
		for _, id := range request.Only {
			options.Only[id] = true
		}
	}

	timeoutMs := request.TimeoutMs
	if timeoutMs <= 0 {
		timeoutMs = defaultServiceTimeoutMs
	}
	concurrency := request.MaxConcurrency
	if concurrency <= 0 {
		concurrency = defaultServiceMaxConcurrent
	}

	// A bounded context so this action can never hang the worker: the probe
	// treats a deadline as partial results (failed checks get a "timeout" note)
	// rather than aborting the whole batch.
	ctx, cancel := context.WithTimeout(probe.LiveInstance(probe.TestContext()), maxServiceActionDuration)
	defer cancel()

	raw := probe.BatchServiceTest(
		ctx, env.Box, env.Tags, concurrency, false, defs,
		time.Duration(timeoutMs)*time.Millisecond, options,
	)

	response := serviceTestResponse{Results: make([]serviceTestTagResult, 0, len(raw))}
	for _, item := range raw {
		if item == nil {
			continue
		}
		entry := serviceTestTagResult{Tag: item.Tag}
		if item.Error != nil {
			entry.Error = item.Error.Error()
		} else {
			// serviceResultString returns the same checks/ip_info JSON the
			// streaming handler emits; decode it into an object for the bus.
			var decoded any
			if err := json.Unmarshal([]byte(serviceResultString(item.Result)), &decoded); err != nil {
				entry.Error = fmt.Sprintf("decode result: %v", err)
			} else {
				entry.Result = decoded
			}
		}
		response.Results = append(response.Results, entry)
	}
	return response, nil
}
