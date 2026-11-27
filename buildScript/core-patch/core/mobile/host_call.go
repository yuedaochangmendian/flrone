// Host-call dispatcher: the stateless half of the C ABI as one JSON entry.
//
// The gomobile AAR exposed a series of helpers (Mobile.version(), checkConfig(),
// resolveDomains(), …) as Java methods with
// generated request/handle types. ADR 0004 replaces that surface with the plain
// c-shared ABI: this file gives the Kotlin host one stable JSON call instead of a
// JNI wrapper per helper, while every operation still runs through the same Go
// implementation the typed exports use.
//
// Wire shape (both directions JSON):
//
//	request  {"method":"check_config","params":{"config":"..."}}
//	response {"ok":true,"data":...} | {"ok":false,"error":"..."}
//
// The dispatcher is intentionally additive: no handler here changes the typed
// exports, and the async action bus remains the path for Dart. Callers on the
// Android main thread must move a host call to a worker; several handlers block
// (resolveDomains up to 5 s per lookup).
package mobile

import (
	"encoding/json"
	"fmt"
)

type hostCallEnvelope struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type hostCallResult struct {
	OK    bool   `json:"ok"`
	Data  any    `json:"data,omitempty"`
	Error string `json:"error,omitempty"`
}

func hostCall(raw string) (out string) {
	// Keep panics on the JSON path: exporting them through guardExport would
	// poison throne_last_error, which the Dart typed path reads after its own
	// calls, and would leave Kotlin with only "invalid JSON".
	defer func() {
		if r := recover(); r != nil {
			out = encodeHostResult(hostCallResult{Error: fmt.Sprintf("host call panic: %v", r)})
		}
	}()
	var envelope hostCallEnvelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		return encodeHostResult(hostCallResult{Error: "parse host call: " + err.Error()})
	}
	data, err := dispatchHostCall(envelope.Method, envelope.Params)
	if err != nil {
		return encodeHostResult(hostCallResult{Error: err.Error()})
	}
	return encodeHostResult(hostCallResult{OK: true, Data: data})
}

func encodeHostResult(result hostCallResult) string {
	encoded, err := json.Marshal(result)
	if err != nil {
		return `{"ok":false,"error":"encode host call result"}`
	}
	return string(encoded)
}

func dispatchHostCall(method string, params json.RawMessage) (any, error) {
	switch method {
	case "version":
		return Version(), nil
	case "go_version":
		return GoVersion(), nil
	case "setup":
		var request struct {
			BasePath    string `json:"basePath"`
			WorkingPath string `json:"workingPath"`
			TempPath    string `json:"tempPath"`
			LogMaxLines int32  `json:"logMaxLines"`
			Debug       bool   `json:"debug"`
		}
		if err := decodeHostParams(params, &request); err != nil {
			return nil, err
		}
		return nil, Setup(&SetupOptions{
			BasePath:    request.BasePath,
			WorkingPath: request.WorkingPath,
			TempPath:    request.TempPath,
			LogMaxLines: request.LogMaxLines,
			Debug:       request.Debug,
		})
	case "check_config":
		var request struct {
			Config string `json:"config"`
		}
		if err := decodeHostParams(params, &request); err != nil {
			return nil, err
		}
		return nil, CheckConfig(request.Config)
	case "build_test_config":
		var request struct {
			ProfileIDs []int64 `json:"profileIds"`
		}
		if err := decodeHostParams(params, &request); err != nil {
			return nil, err
		}
		inputs, err := loadSimpleConfigInputs()
		if err != nil {
			return nil, fmt.Errorf("build_test_config: %w", err)
		}
		candidates := make([]configTestCandidate, 0, len(request.ProfileIDs))
		for _, id := range request.ProfileIDs {
			// TestSession passes plain ids; CoreConfigs.buildTest filled the
			// group's landing / front proxy. The profiles document carries the
			// group id on every row, so resolve those here instead of asking the
			// caller.
			candidates = append(candidates, configTestCandidate{
				id:             id,
				landingProxyID: -1,
				frontProxyID:   -1,
			})
		}
		for index := range candidates {
			row := configFindProfile(inputs.Profiles, candidates[index].id)
			if row == nil || row.GroupID <= 0 {
				continue
			}
			for _, groupRow := range inputs.Groups {
				if rowInt64(groupRow, "id") != row.GroupID {
					continue
				}
				group := simpleConfigGroupFromRow(groupRow)
				candidates[index].landingProxyID = group.LandingProxyID
				candidates[index].frontProxyID = group.FrontProxyID
				candidates[index].groupName = group.Name
				break
			}
		}
		return configTestResultPayload(buildTestCoreConfig(inputs, candidates)), nil
	case "resolve_domains":
		var request struct {
			CoreConfig string   `json:"coreConfig"`
			Domains    []string `json:"domains"`
		}
		if err := decodeHostParams(params, &request); err != nil {
			return nil, err
		}
		resolveRequest := &ResolveRequest{CoreConfig: request.CoreConfig}
		for _, domain := range request.Domains {
			resolveRequest.AddDomain(domain)
		}
		iterator, err := ResolveDomains(nil, bridgePlatform, resolveRequest)
		if err != nil {
			return nil, err
		}
		results := make([]map[string]any, 0)
		if iterator != nil {
			for iterator.HasNext() {
				resolved := iterator.Next()
				if resolved == nil {
					continue
				}
				addresses := make([]string, 0)
				if values := resolved.Addresses(); values != nil {
					for values.HasNext() {
						addresses = append(addresses, values.Next())
					}
				}
				results = append(results, map[string]any{
					"domain":    resolved.Domain,
					"error":     resolved.Error,
					"addresses": addresses,
				})
			}
		}
		return map[string]any{"results": results}, nil
	case "new_instance":
		var request struct {
			CoreConfig string `json:"coreConfig"`
		}
		if err := decodeHostParams(params, &request); err != nil {
			return nil, err
		}
		options := &StartOptions{CoreConfig: request.CoreConfig}
		instance, err := NewInstance(bridgePlatform, options)
		if err != nil {
			return nil, err
		}
		registerInstance(instance)
		return map[string]any{"handle": marshal_handle(instance)}, nil
	case "instance_start":
		instance, err := hostInstanceParam(params)
		if err != nil {
			return nil, err
		}
		return nil, instance.Start()
	case "instance_close":
		instance, handle, err := hostInstanceHandleParam(params)
		if err != nil {
			return nil, err
		}
		closeErr := instance.Close()
		clearInstance(instance)
		hostReleaseHandle(handle)
		return nil, closeErr
	case "instance_update_rule_sets":
		instance, err := hostInstanceParam(params)
		if err != nil {
			return nil, err
		}
		update, err := instance.UpdateRuleSets()
		if err != nil {
			return nil, err
		}
		return map[string]any{"updated": update.Updated, "error": update.Error}, nil
	case "instance_local_dns_failure":
		instance, err := hostInstanceParam(params)
		if err != nil {
			return nil, err
		}
		failure := instance.LocalDNSFailure()
		if failure == nil {
			return nil, nil
		}
		return map[string]any{"servers": failure.Servers}, nil
	case "instance_outbound_stats":
		var request struct {
			Handle    int64  `json:"handle"`
			Tag       string `json:"tag"`
			Direction string `json:"direction"`
		}
		if err := decodeHostParams(params, &request); err != nil {
			return nil, err
		}
		instance, err := hostInstance(request.Handle)
		if err != nil {
			return nil, err
		}
		return instance.QueryOutboundStats(request.Tag, request.Direction), nil
	case "query_speed_test":
		result := QuerySpeedTest()
		if result == nil {
			return nil, nil
		}
		return map[string]any{
			"tag": result.Tag, "dlSpeed": result.DlSpeed, "ulSpeed": result.UlSpeed,
			"latency": result.Latency, "serverName": result.ServerName,
			"serverCountry": result.ServerCountry, "error": result.Error,
			"cancelled": result.Cancelled, "dlBytes": result.DlBytes,
			"ulBytes": result.UlBytes, "running": result.Running,
		}, nil
	case "stop_tests":
		StopTests()
		return nil, nil
	case "start_url_test":
		return startHostTest("url", params)
	case "start_ip_test":
		return startHostTest("ip", params)
	case "start_speed_test":
		return startHostTest("speed", params)
	case "poll_test":
		return pollHostTest(params)
	case "cancel_test":
		StopTests()
		return nil, nil
	case "set_log_sink":
		SetLogSink(hostLogSink{})
		return nil, nil
	default:
		return nil, fmt.Errorf("unknown host call method: %s", method)
	}
}

func decodeHostParams(raw json.RawMessage, target any) error {
	if len(raw) == 0 || string(raw) == "null" {
		raw = []byte("{}")
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return fmt.Errorf("parse host call params: %w", err)
	}
	return nil
}

func hostInstance(handle int64) (*Instance, error) {
	value := handleGet(handle)
	if value == nil {
		return nil, fmt.Errorf("unknown instance handle %d", handle)
	}
	instance, ok := value.(*Instance)
	if !ok {
		return nil, fmt.Errorf("handle %d is not an instance", handle)
	}
	return instance, nil
}

func hostInstanceParam(params json.RawMessage) (*Instance, error) {
	var request struct {
		Handle int64 `json:"handle"`
	}
	if err := decodeHostParams(params, &request); err != nil {
		return nil, err
	}
	return hostInstance(request.Handle)
}

func hostInstanceHandleParam(params json.RawMessage) (*Instance, int64, error) {
	var request struct {
		Handle int64 `json:"handle"`
	}
	if err := decodeHostParams(params, &request); err != nil {
		return nil, 0, err
	}
	instance, err := hostInstance(request.Handle)
	return instance, request.Handle, err
}

// hostReleaseHandle drops the handle registry entry after a close, mirroring
// throne_Instance_close (which also calls throne_handle_release).
func hostReleaseHandle(handle int64) {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	if _, ok := handles[handle]; ok {
		delete(handles, handle)
		handleReleased++
	}
}

// hostLogSink forwards the kernel's formatted log lines over the same JSON
// platform facade, so the Kotlin host keeps its log table without a gobind
// LogSink object. The Kotlin router applies the configured level filter.
type hostLogSink struct{}

func (hostLogSink) Write(level int32, message string) {
	platformRequest("log", map[string]any{"level": level, "message": message})
}
