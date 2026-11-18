// Host-call dispatcher: the stateless half of the C ABI as one JSON entry.
//
// The gomobile AAR exposed Mobile.version(), checkConfig(), genQuicSignature(),
// resolveDomains(), warpRegister() and captureDiagnostics() as Java methods with
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
// (resolveDomains up to 5 s per lookup, warpRegister up to 10 s per API host,
// captureDiagnostics for the requested window).
package mobile

import (
	"encoding/json"
	"fmt"
	"os"
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

func hostCall(raw string) string {
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
	case "xray_version":
		return XrayVersion(), nil
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
	case "check_xray_config":
		var request struct {
			Config string `json:"config"`
		}
		if err := decodeHostParams(params, &request); err != nil {
			return nil, err
		}
		return nil, CheckXrayConfig(request.Config)
	case "gen_quic_signature":
		var request struct {
			Domain string `json:"domain"`
		}
		if err := decodeHostParams(params, &request); err != nil {
			return nil, err
		}
		iterator, err := GenQuicSignature(request.Domain)
		if err != nil {
			return nil, err
		}
		packets := make([]string, 0, 5)
		if iterator != nil {
			for iterator.HasNext() {
				packets = append(packets, iterator.Next())
			}
		}
		return map[string]any{"packets": packets}, nil
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
	case "warp_register":
		var request struct {
			TunnelType               string   `json:"tunnelType"`
			Proxy                    string   `json:"proxy"`
			TLSFragment              bool     `json:"tlsFragment"`
			TLSRecordFragment        bool     `json:"tlsRecordFragment"`
			TLSFragmentFallbackDelay string   `json:"tlsFragmentFallbackDelay"`
			APIHosts                 []string `json:"apiHosts"`
		}
		if err := decodeHostParams(params, &request); err != nil {
			return nil, err
		}
		warpRequest := &WarpRegisterRequest{
			TunnelType:               request.TunnelType,
			Proxy:                    request.Proxy,
			TLSFragment:              request.TLSFragment,
			TLSRecordFragment:        request.TLSRecordFragment,
			TLSFragmentFallbackDelay: request.TLSFragmentFallbackDelay,
		}
		for _, host := range request.APIHosts {
			warpRequest.AddAPIHost(host)
		}
		identity, err := WarpRegister(warpRequest)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"device_id":       identity.DeviceID,
			"token":           identity.Token,
			"license":         identity.License,
			"ipv4":            identity.IPv4,
			"ipv6":            identity.IPv6,
			"private_key":     identity.PrivateKey,
			"peer_public_key": identity.PeerPublicKey,
			"endpoint":        identity.Endpoint,
			"reserved":        identity.Reserved,
		}, nil
	case "capture_diagnostics":
		var request struct {
			DurationMs      int32    `json:"durationMs"`
			Contention      bool     `json:"contention"`
			Trace           bool     `json:"trace"`
			AttachmentPaths []string `json:"attachmentPaths"`
			OutputPath      string   `json:"outputPath"`
		}
		if err := decodeHostParams(params, &request); err != nil {
			return nil, err
		}
		diagnosticsRequest := &DiagnosticsRequest{
			DurationMs: request.DurationMs,
			Contention: request.Contention,
			Trace:      request.Trace,
		}
		for _, path := range request.AttachmentPaths {
			data, err := os.ReadFile(path)
			if err != nil {
				return nil, fmt.Errorf("read attachment %s: %w", path, err)
			}
			diagnosticsRequest.AddAttachment(hostBaseName(path), data)
		}
		return nil, CaptureDiagnostics(diagnosticsRequest, request.OutputPath)
	case "stop_diagnostics":
		StopDiagnostics()
		return nil, nil
	case "new_instance":
		var request struct {
			CoreConfig              string   `json:"coreConfig"`
			NeedXray                bool     `json:"needXray"`
			XrayConfig              string   `json:"xrayConfig"`
			XrayOutboundDNSStrategy string   `json:"xrayOutboundDNSStrategy"`
			XrayLazyStart           bool     `json:"xrayLazyStart"`
			XrayIdleSeconds         int32    `json:"xrayIdleSeconds"`
			XrayFullIdleSeconds     int32    `json:"xrayFullIdleSeconds"`
			XrayFullConfigs         []string `json:"xrayFullConfigs"`
		}
		if err := decodeHostParams(params, &request); err != nil {
			return nil, err
		}
		options := &StartOptions{
			CoreConfig:              request.CoreConfig,
			NeedXray:                request.NeedXray,
			XrayConfig:              request.XrayConfig,
			XrayOutboundDNSStrategy: request.XrayOutboundDNSStrategy,
			XrayLazyStart:           request.XrayLazyStart,
			XrayIdleSeconds:         request.XrayIdleSeconds,
			XrayFullIdleSeconds:     request.XrayFullIdleSeconds,
		}
		for _, config := range request.XrayFullConfigs {
			options.AddXrayFullConfig(config)
		}
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
	case "instance_pause":
		instance, err := hostInstanceParam(params)
		if err != nil {
			return nil, err
		}
		instance.Pause()
		return nil, nil
	case "instance_wake":
		instance, err := hostInstanceParam(params)
		if err != nil {
			return nil, err
		}
		instance.Wake()
		return nil, nil
	case "instance_reset_network":
		instance, err := hostInstanceParam(params)
		if err != nil {
			return nil, err
		}
		instance.ResetNetwork()
		return nil, nil
	case "instance_need_wifi_state":
		instance, err := hostInstanceParam(params)
		if err != nil {
			return nil, err
		}
		return instance.NeedWIFIState(), nil
	case "instance_update_wifi_state":
		instance, err := hostInstanceParam(params)
		if err != nil {
			return nil, err
		}
		instance.UpdateWIFIState()
		return nil, nil
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
	case "instance_status":
		instance, err := hostInstanceParam(params)
		if err != nil {
			return nil, err
		}
		status := instance.Status()
		return map[string]any{
			"memory":           status.Memory,
			"goroutines":       status.Goroutines,
			"connectionsIn":    status.ConnectionsIn,
			"connectionsOut":   status.ConnectionsOut,
			"trafficAvailable": status.TrafficAvailable,
			"uplink":           status.Uplink,
			"downlink":         status.Downlink,
			"uplinkTotal":      status.UplinkTotal,
			"downlinkTotal":    status.DownlinkTotal,
		}, nil
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
	case "instance_query_auto_selectors":
		instance, err := hostInstanceParam(params)
		if err != nil {
			return nil, err
		}
		iterator := instance.QueryAutoSelectors()
		statuses := make([]map[string]any, 0)
		if iterator != nil {
			for iterator.HasNext() {
				status := iterator.Next()
				if status == nil {
					continue
				}
				members := make([]map[string]any, 0)
				if memberIterator := status.Members(); memberIterator != nil {
					for memberIterator.HasNext() {
						member := memberIterator.Next()
						if member == nil {
							continue
						}
						members = append(members, map[string]any{
							"tag": member.Tag, "rank": member.Rank, "state": member.State,
							"selected": member.Selected, "selectedUdp": member.SelectedUDP,
							"qualified": member.Qualified, "active": member.Active,
							"averageMs": member.AverageMs, "deviationMs": member.DeviationMs,
							"minMs": member.MinMs, "maxMs": member.MaxMs, "samples": member.Samples,
							"failures": member.Failures, "probes": member.Probes,
							"dialTotal": member.DialTotal, "dialFail": member.DialFail,
							"lastOkMs": member.LastOkMs, "lastProbeMs": member.LastProbeMs,
							"cooldownUntilMs": member.CooldownUntilMs, "lastError": member.LastError,
						})
					}
				}
				statuses = append(statuses, map[string]any{
					"tag": status.Tag, "phase": status.Phase,
					"selected": status.Selected, "selectedUdp": status.SelectedUDP,
					"pinned": status.Pinned, "balance": status.Balance,
					"balanceMode": status.BalanceMode, "suspended": status.Suspended,
					"suspendedSinceMs": status.SuspendedSinceMs,
					"membersTotal":     status.MembersTotal, "membersProbed": status.MembersProbed,
					"membersAlive": status.MembersAlive, "membersQualified": status.MembersQualified,
					"membersCooldown": status.MembersCooldown, "probesInFlight": status.ProbesInFlight,
					"roundsCompleted": status.RoundsCompleted, "lastRoundMs": status.LastRoundMs,
					"nextRoundMs": status.NextRoundMs, "lastSwitchMs": status.LastSwitchMs,
					"lastSwitchReason": status.LastSwitchReason, "members": members,
				})
			}
		}
		return map[string]any{"selectors": statuses}, nil
	case "instance_auto_selector_action":
		var request struct {
			Handle int64  `json:"handle"`
			Tag    string `json:"tag"`
			Action string `json:"action"`
			Member string `json:"member"`
		}
		if err := decodeHostParams(params, &request); err != nil {
			return nil, err
		}
		instance, err := hostInstance(request.Handle)
		if err != nil {
			return nil, err
		}
		return nil, instance.AutoSelectorAction(request.Tag, request.Action, request.Member)
	case "instance_alive":
		instance, err := hostInstanceParam(params)
		if err != nil {
			return nil, err
		}
		return instance.running(), nil
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

// hostBaseName is filepath.Base without importing path/filepath for one call;
// diagnostics attachments are zipped under their base name.
func hostBaseName(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' || path[i] == '\\' {
			return path[i+1:]
		}
	}
	return path
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
