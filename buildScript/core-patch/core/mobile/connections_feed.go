// Core-side connection feed (ADR 0004 P4 follow-up).
//
// The connections screen used to poll the core's Clash API over loopback HTTP
// every 1.5 s, and the traffic ledger polled it again every 5 s. Both consumers
// were reading the same trafficcontrol.Manager, which the box already owns; the
// HTTP hop only existed because that manager had no action-bus surface.
//
// This file gives the manager one: rows (live plus the core's closed ring) are
// shaped once, rates are computed from the same cumulative counters the page
// used to diff in Kotlin, and attribution deltas are produced every tick from
// the full tracker. The Go->Dart push is a JSON event, so the UI keeps its
// existing `connections` and `trafficDeltas` handlers.
//
// The feed is demand-driven: `connectionsWatch` turns the rows feed and/or the
// attribution feed on, and the loop stops when both are off. State is global
// rather than per-instance so a watch survives a core stop/start; a changed
// instance resets the rate and attribution baselines so a new session's ids
// cannot inherit the previous one's counters.
package mobile

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/trafficcontrol"
	C "github.com/sagernet/sing-box/constant"
	M "github.com/sagernet/sing/common/metadata"
)

const (
	connectionsRowsDefaultInterval = 1500 * time.Millisecond
	connectionsAttrDefaultInterval = 5 * time.Second
	connectionsMinInterval         = 250 * time.Millisecond
	connectionsMaxInterval         = time.Minute
	connectionsMaxClosedRows       = 200
	connectionsMaxAttrEntries      = 128
)

// connectionSample is one tracker's wire-neutral shape. Both the rows feed and
// the attribution feed read it, so the two can never disagree about a field.
type connectionSample struct {
	ID                 string
	CreatedAt          int64
	ClosedAt           int64
	Network            string
	Protocol           string
	Inbound            string
	Outbound           string
	Chain              []string
	Rule               string
	Source             string
	Destination        string
	Domain             string
	DisplayDestination string
	ProcessPath        string
	ProcessName        string
	UploadTotal        int64
	DownloadTotal      int64
}

func (s connectionSample) closed() bool { return s.ClosedAt > 0 }

// sampleConnections turns the tracker snapshot into samples. DNS connections
// are internal lookups, not user requests: the Clash API filtered them and the
// page's counts have always excluded them.
func sampleConnections(metadata []*trafficcontrol.TrackerMetadata) []connectionSample {
	samples := make([]connectionSample, 0, len(metadata))
	for _, item := range metadata {
		if item == nil || item.OutboundType == C.TypeDNS {
			continue
		}
		samples = append(samples, sampleConnection(item))
	}
	return samples
}

func sampleConnection(item *trafficcontrol.TrackerMetadata) connectionSample {
	inbound := item.Metadata.InboundType
	if item.Metadata.Inbound != "" {
		inbound = item.Metadata.InboundType + "/" + item.Metadata.Inbound
	}
	destination := socksaddrString(item.Metadata.Destination)
	domain := item.Metadata.Domain
	if domain == "" {
		domain = item.Metadata.Destination.Fqdn
	}
	display := domain
	if display == "" {
		display = destination
	}
	processPath, processName := connectionProcess(item.Metadata.ProcessInfo)
	outbound := item.Outbound
	if len(item.Chain) > 0 {
		outbound = item.Chain[len(item.Chain)-1]
	}
	return connectionSample{
		ID:                 item.ID.String(),
		CreatedAt:          unixMilli(item.CreatedAt),
		ClosedAt:           unixMilli(item.ClosedAt),
		Network:            item.Metadata.Network,
		Protocol:           item.Metadata.InboundType,
		Inbound:            inbound,
		Outbound:           outbound,
		Chain:              append([]string(nil), item.Chain...),
		Rule:               connectionRule(item.Rule),
		Source:             socksaddrString(item.Metadata.Source),
		Destination:        destination,
		Domain:             domain,
		DisplayDestination: display,
		ProcessPath:        processPath,
		ProcessName:        processName,
		UploadTotal:        atomicTotal(item.Upload),
		DownloadTotal:      atomicTotal(item.Download),
	}
}

func socksaddrString(address M.Socksaddr) string {
	if !address.Addr.IsValid() {
		return ""
	}
	return address.Addr.String() + ":" + strconv.Itoa(int(address.Port))
}

func connectionProcess(owner *adapter.ConnectionOwner) (path, name string) {
	if owner == nil {
		return "", ""
	}
	if len(owner.ProcessPaths) > 0 {
		path = owner.ProcessPaths[0]
	} else if len(owner.PackageNames) > 0 {
		path = owner.PackageNames[0]
	}
	if len(owner.PackageNames) > 0 {
		name = owner.PackageNames[0]
	}
	if name == "" && path != "" {
		name = packageFromAPKPath(path)
		if name == "" {
			if index := strings.LastIndexByte(path, '/'); index >= 0 && index+1 < len(path) {
				name = path[index+1:]
			} else {
				name = path
			}
		}
	}
	return path, name
}

// packageFromAPKPath mirrors the host's ProcessPaths.packageFromApkPath. The
// core's ProcessInfo usually carries PackageNames directly on Android, so this
// is only the path-shaped fallback for an owner that has a path but no package.
func packageFromAPKPath(path string) string {
	segments := strings.FieldsFunc(path, func(r rune) bool { return r == '/' })
	if len(segments) == 0 {
		return ""
	}
	file := segments[len(segments)-1]
	if !strings.HasSuffix(strings.ToLower(file), ".apk") {
		return ""
	}
	if len(segments) >= 3 && segments[0] == "data" && segments[1] == "app" {
		dir := segments[2]
		if strings.HasPrefix(dir, "~~") {
			if len(segments) < 4 {
				return ""
			}
			dir = segments[3]
		}
		return stripInstallSuffix(dir)
	}
	if len(segments) >= 4 && isSystemPartition(segments[0]) &&
		(segments[1] == "app" || segments[1] == "priv-app" || segments[1] == "privapp") {
		return segments[2]
	}
	return ""
}

func stripInstallSuffix(value string) string {
	// A package name cannot contain '-'; the suffix after it is the install id
	// (base64url, which may itself contain a dash).
	if index := strings.IndexByte(value, '-'); index > 0 {
		return value[:index]
	}
	return value
}

func isSystemPartition(value string) bool {
	switch value {
	case "system", "product", "vendor", "odm", "system_ext", "apex":
		return true
	default:
		return false
	}
}

func connectionRule(rule adapter.Rule) string {
	if rule == nil {
		return "final"
	}
	return fmt.Sprint(rule, " => ", rule.Action())
}

func atomicTotal(value *atomic.Int64) int64 {
	if value == nil {
		return 0
	}
	return value.Load()
}

func unixMilli(value time.Time) int64 {
	if value.IsZero() {
		return 0
	}
	return value.UnixMilli()
}

// connectionRow is the map shape the connections page has always consumed. The
// upload/download fields are per-second rates; uploadTotal/downloadTotal stay
// cumulative. A closed row reports zero rates and its final totals.
func connectionRow(sample connectionSample, uploadRate, downloadRate int64) map[string]any {
	var process any
	if sample.ProcessPath != "" {
		process = map[string]any{"path": sample.ProcessPath}
	}
	return map[string]any{
		"id":                 sample.ID,
		"createdAt":          sample.CreatedAt,
		"closedAt":           sample.ClosedAt,
		"network":            sample.Network,
		"protocol":           sample.Protocol,
		"inbound":            nilIfEmpty(sample.Inbound),
		"outbound":           sample.Outbound,
		"chain":              sample.Chain,
		"rule":               sample.Rule,
		"source":             sample.Source,
		"destination":        sample.Destination,
		"domain":             sample.Domain,
		"displayDestination": sample.DisplayDestination,
		"process":            process,
		"upload":             uploadRate,
		"download":           downloadRate,
		"uploadTotal":        sample.UploadTotal,
		"downloadTotal":      sample.DownloadTotal,
	}
}

func nilIfEmpty(value string) any {
	if value == "" {
		return nil
	}
	return value
}

// rateTracker diffs cumulative totals across one feed's emissions. A first
// sighting has no baseline and reports zero rather than its whole volume.
type rateTracker struct {
	totals map[string][2]int64
	at     time.Time
}

func (t *rateTracker) rates(samples []connectionSample, now time.Time) map[string][2]int64 {
	if t.totals == nil {
		t.totals = make(map[string][2]int64, len(samples))
	}
	var seconds float64
	if !t.at.IsZero() {
		seconds = now.Sub(t.at).Seconds()
		if seconds < 0.001 {
			seconds = 0.001
		}
	}
	rates := make(map[string][2]int64, len(samples))
	next := make(map[string][2]int64, len(samples))
	for _, sample := range samples {
		current := [2]int64{sample.UploadTotal, sample.DownloadTotal}
		previous, seen := t.totals[sample.ID]
		if seen && seconds > 0 {
			up := current[0] - previous[0]
			down := current[1] - previous[1]
			if up < 0 {
				up = 0
			}
			if down < 0 {
				down = 0
			}
			rates[sample.ID] = [2]int64{
				int64(float64(up) / seconds),
				int64(float64(down) / seconds),
			}
		}
		next[sample.ID] = current
	}
	t.totals = next
	t.at = now
	return rates
}

func (t *rateTracker) reset() {
	t.totals = nil
	t.at = time.Time{}
}

// connectionRows builds one whole page: every live row with its rate, then the
// core's closed ring (newest last, capped at the page's ring size).
func connectionRows(live, closed []connectionSample, rates map[string][2]int64) []map[string]any {
	rows := make([]map[string]any, 0, len(live)+minInt(len(closed), connectionsMaxClosedRows))
	for _, sample := range live {
		rate := rates[sample.ID]
		rows = append(rows, connectionRow(sample, rate[0], rate[1]))
	}
	if len(closed) > connectionsMaxClosedRows {
		closed = closed[len(closed)-connectionsMaxClosedRows:]
	}
	for _, sample := range closed {
		rows = append(rows, connectionRow(sample, 0, 0))
	}
	return rows
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// connectionAttribution accumulates one tick's per-key deltas. It is the Go
// counterpart of the retired Kotlin TrafficAttribution.tick: a first sighting
// only records a baseline, except for a connection that was created after the
// watch started and has already closed — its whole lifetime belongs to this
// feed, and the core's closed ring is the only place that lifetime survives.
func connectionAttribution(
	live []connectionSample,
	closed []connectionSample,
	previous map[string][2]int64,
	enabledAt time.Time,
	details bool,
) (map[string]any, map[string][2]int64) {
	if previous == nil {
		previous = make(map[string][2]int64, len(live)+len(closed))
	}
	seen := make(map[string]struct{}, len(live)+len(closed))
	var up, down, proxyUp, proxyDown, directUp, directDown int64
	hosts := map[string][2]int64{}
	nodes := map[string][2]int64{}
	rules := map[string][2]int64{}
	processes := map[string][2]int64{}

	apply := func(sample connectionSample) {
		seen[sample.ID] = struct{}{}
		current := [2]int64{sample.UploadTotal, sample.DownloadTotal}
		previousTotals, ok := previous[sample.ID]
		previous[sample.ID] = current
		if !ok {
			if !sample.closed() || sample.CreatedAt < enabledAt.UnixMilli() {
				return
			}
			// A short-lived connection that opened and closed between two
			// ticks: its whole lifetime is new to this feed.
			previousTotals = [2]int64{}
		}
		deltaUp := current[0] - previousTotals[0]
		deltaDown := current[1] - previousTotals[1]
		if deltaUp < 0 {
			deltaUp = 0
		}
		if deltaDown < 0 {
			deltaDown = 0
		}
		if deltaUp == 0 && deltaDown == 0 {
			return
		}
		up += deltaUp
		down += deltaDown
		direct := sample.Outbound == "" || strings.EqualFold(sample.Outbound, "DIRECT")
		if direct {
			directUp += deltaUp
			directDown += deltaDown
		} else {
			proxyUp += deltaUp
			proxyDown += deltaDown
		}
		if !details {
			return
		}
		if sample.DisplayDestination != "" {
			addAttribution(hosts, sample.DisplayDestination, deltaUp, deltaDown)
		}
		if !direct && sample.Outbound != "" {
			addAttribution(nodes, sample.Outbound, deltaUp, deltaDown)
		}
		if sample.Rule != "" {
			addAttribution(rules, sample.Rule, deltaUp, deltaDown)
		}
		if sample.ProcessName != "" {
			addAttribution(processes, sample.ProcessName, deltaUp, deltaDown)
		}
	}

	for _, sample := range live {
		apply(sample)
	}
	for _, sample := range closed {
		apply(sample)
	}
	for id := range previous {
		if _, ok := seen[id]; !ok {
			delete(previous, id)
		}
	}
	if up+down == 0 {
		return nil, previous
	}
	payload := map[string]any{
		"totalUp":    up,
		"totalDown":  down,
		"proxyUp":    proxyUp,
		"proxyDown":  proxyDown,
		"directUp":   directUp,
		"directDown": directDown,
	}
	if details {
		if len(hosts) > 0 {
			payload["hosts"] = topAttribution(hosts)
		}
		if len(nodes) > 0 {
			payload["nodes"] = topAttribution(nodes)
		}
		if len(rules) > 0 {
			payload["rules"] = topAttribution(rules)
		}
		if len(processes) > 0 {
			payload["processes"] = topAttribution(processes)
		}
	}
	return payload, previous
}

func addAttribution(target map[string][2]int64, key string, up, down int64) {
	value := target[key]
	value[0] += up
	value[1] += down
	target[key] = value
}

func topAttribution(source map[string][2]int64) map[string][]int64 {
	type entry struct {
		key   string
		value [2]int64
	}
	entries := make([]entry, 0, len(source))
	for key, value := range source {
		entries = append(entries, entry{key: key, value: value})
	}
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].value[0]+entries[i].value[1] > entries[j].value[0]+entries[j].value[1]
	})
	if len(entries) > connectionsMaxAttrEntries {
		entries = entries[:connectionsMaxAttrEntries]
	}
	result := make(map[string][]int64, len(entries))
	for _, item := range entries {
		result[item.key] = []int64{item.value[0], item.value[1]}
	}
	return result
}

// connectionInterval normalizes a requested interval. Zero means "the default
// for this feed"; anything else is clamped to a range the UI can survive.
func connectionInterval(requested int64, fallback time.Duration) time.Duration {
	if requested <= 0 {
		return fallback
	}
	interval := time.Duration(requested) * time.Millisecond
	if interval < connectionsMinInterval {
		return connectionsMinInterval
	}
	if interval > connectionsMaxInterval {
		return connectionsMaxInterval
	}
	return interval
}

// durationMillis keeps the action reply's numbers in the same unit the request
// used, so a caller can echo it back without a second conversion.
func durationMillis(interval time.Duration) int64 {
	return int64(interval / time.Millisecond)
}
