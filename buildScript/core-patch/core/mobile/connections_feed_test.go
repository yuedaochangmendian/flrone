package mobile

import (
	"net/netip"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gofrs/uuid/v5"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/trafficcontrol"
	M "github.com/sagernet/sing/common/metadata"
)

func newAtomic(value int64) *atomic.Int64 {
	counter := new(atomic.Int64)
	counter.Store(value)
	return counter
}

func testUUID(t *testing.T) uuid.UUID {
	t.Helper()
	value, err := uuid.NewV4()
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func testSample(id string, upload, download int64) connectionSample {
	return connectionSample{
		ID:                 id,
		CreatedAt:          time.Now().Add(-time.Minute).UnixMilli(),
		Network:            "tcp",
		Protocol:           "tun",
		Inbound:            "tun/tun-in",
		Outbound:           "proxy",
		Chain:              []string{"proxy"},
		Rule:               "final",
		Source:             "10.0.0.2:1234",
		Destination:        "1.1.1.1:443",
		Domain:             "example.com",
		DisplayDestination: "example.com",
		ProcessPath:        "/data/app/~~abc/com.example-xyz/base.apk",
		ProcessName:        "com.example",
		UploadTotal:        upload,
		DownloadTotal:      download,
	}
}

func TestConnectionRowsRatesAndClosedRing(t *testing.T) {
	tracker := rateTracker{}
	first := testSample("a", 100, 200)
	rates := tracker.rates([]connectionSample{first}, time.Unix(100, 0))
	if got := rates["a"]; got != [2]int64{} {
		t.Fatalf("first sighting rate = %v, want zero", got)
	}

	second := testSample("a", 300, 600)
	rates = tracker.rates([]connectionSample{second}, time.Unix(102, 0))
	if got := rates["a"]; got != [2]int64{100, 200} {
		t.Fatalf("second tick rate = %v, want [100 200]", got)
	}

	closed := testSample("b", 50, 60)
	closed.ClosedAt = time.Unix(103, 0).UnixMilli()
	rows := connectionRows([]connectionSample{second}, []connectionSample{closed}, rates)
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2", len(rows))
	}
	if rows[1]["upload"] != int64(0) || rows[1]["download"] != int64(0) {
		t.Fatalf("closed row rates = %v/%v, want zero", rows[1]["upload"], rows[1]["download"])
	}
	if rows[1]["uploadTotal"] != int64(50) || rows[1]["closedAt"] != closed.ClosedAt {
		t.Fatalf("closed row lost its totals/stamp: %+v", rows[1])
	}
}

func TestConnectionRowsCapClosedRing(t *testing.T) {
	closed := make([]connectionSample, connectionsMaxClosedRows+10)
	for i := range closed {
		closed[i] = testSample("c"+strconv.Itoa(i), 1, 1)
	}
	rows := connectionRows(nil, closed, nil)
	if len(rows) != connectionsMaxClosedRows {
		t.Fatalf("closed rows = %d, want %d", len(rows), connectionsMaxClosedRows)
	}
}

func TestConnectionAttributionBaselineAndShortLived(t *testing.T) {
	start := time.Unix(100, 0)
	live := testSample("live", 1000, 2000)
	previous := map[string][2]int64{}
	payload, previous := connectionAttribution([]connectionSample{live}, nil, previous, start, true)
	if payload != nil {
		t.Fatalf("first sighting produced a delta: %+v", payload)
	}

	live.UploadTotal += 30
	live.DownloadTotal += 40
	payload, previous = connectionAttribution([]connectionSample{live}, nil, previous, start, true)
	if got := payload["totalUp"]; got != int64(30) {
		t.Fatalf("totalUp = %v, want 30 (payload %+v)", got, payload)
	}
	if got := payload["totalDown"]; got != int64(40) {
		t.Fatalf("totalDown = %v, want 40", got)
	}

	shortLived := testSample("short", 7, 9)
	shortLived.CreatedAt = start.Add(time.Second).UnixMilli()
	shortLived.ClosedAt = start.Add(2 * time.Second).UnixMilli()
	payload, previous = connectionAttribution(nil, []connectionSample{shortLived}, previous, start, false)
	if got := payload["totalUp"]; got != int64(7) {
		t.Fatalf("short-lived totalUp = %v, want 7 (payload %+v)", got, payload)
	}
	if _, ok := previous["live"]; ok {
		t.Fatal("a connection that disappeared from live+closed kept its baseline")
	}
}

func TestConnectionAttributionDetailsTopN(t *testing.T) {
	start := time.Unix(100, 0)
	sample := testSample("a", 100, 200)
	sample.CreatedAt = start.Add(time.Second).UnixMilli()
	sample.ClosedAt = start.Add(2 * time.Second).UnixMilli()
	payload, _ := connectionAttribution(nil, []connectionSample{sample}, map[string][2]int64{}, start, true)
	if payload == nil {
		t.Fatal("missing payload")
	}
	hosts := payload["hosts"].(map[string][]int64)
	if got := hosts["example.com"]; got[0] != 100 || got[1] != 200 {
		t.Fatalf("host slice = %v", got)
	}
	nodes := payload["nodes"].(map[string][]int64)
	if got := nodes["proxy"]; got[0] != 100 {
		t.Fatalf("node slice = %v", got)
	}
	processes := payload["processes"].(map[string][]int64)
	if got := processes["com.example"]; got[0] != 100 {
		t.Fatalf("process slice = %v", got)
	}
}

func TestConnectionSampleShape(t *testing.T) {
	uuid := testUUID(t)
	upload := newAtomic(120)
	download := newAtomic(240)
	metadata := &trafficcontrol.TrackerMetadata{
		ID:        uuid,
		CreatedAt: time.Unix(100, 0),
		Upload:    upload,
		Download:  download,
		Metadata: adapter.InboundContext{
			Network:     "tcp",
			InboundType: "tun",
			Inbound:     "tun-in",
			Source:      M.SocksaddrFrom(netip.MustParseAddr("10.0.0.2"), 1234),
			Destination: M.SocksaddrFrom(netip.MustParseAddr("1.1.1.1"), 443),
			Domain:      "example.com",
			ProcessInfo: &adapter.ConnectionOwner{
				PackageNames: []string{"com.example"},
				ProcessPaths: []string{"/data/app/~~abc/com.example-xyz/base.apk"},
			},
		},
		Chain:    []string{"proxy"},
		Outbound: "proxy",
	}
	sample := sampleConnection(metadata)
	if sample.Protocol != "tun" || sample.Inbound != "tun/tun-in" {
		t.Fatalf("protocol/inbound = %q/%q", sample.Protocol, sample.Inbound)
	}
	if sample.Source != "10.0.0.2:1234" || sample.Destination != "1.1.1.1:443" {
		t.Fatalf("source/destination = %q/%q", sample.Source, sample.Destination)
	}
	if sample.DisplayDestination != "example.com" || sample.Outbound != "proxy" {
		t.Fatalf("display/outbound = %q/%q", sample.DisplayDestination, sample.Outbound)
	}
	if sample.UploadTotal != 120 || sample.DownloadTotal != 240 {
		t.Fatalf("totals = %d/%d", sample.UploadTotal, sample.DownloadTotal)
	}
	if sample.ProcessName != "com.example" {
		t.Fatalf("process name = %q", sample.ProcessName)
	}
}

func TestConnectionIntervalClamp(t *testing.T) {
	if got := connectionInterval(0, time.Second); got != time.Second {
		t.Fatalf("zero did not take the default: %v", got)
	}
	if got := connectionInterval(1, time.Second); got != connectionsMinInterval {
		t.Fatalf("tiny interval = %v, want %v", got, connectionsMinInterval)
	}
	if got := connectionInterval(3_600_000, time.Second); got != connectionsMaxInterval {
		t.Fatalf("huge interval = %v, want %v", got, connectionsMaxInterval)
	}
}

func TestConnectionsActionsAreRegistered(t *testing.T) {
	for _, method := range []Method{
		connectionsWatchMethod,
		connectionsCloseMethod,
		connectionsCloseAllMethod,
	} {
		if _, ok := actionHandlers[method]; !ok {
			t.Fatalf("%s is not registered", method)
		}
	}
}

func TestConnectionRowsSkipUnchanged(t *testing.T) {
	original := emitConnectionsRows
	var sent [][]map[string]any
	emitConnectionsRows = func(rows []map[string]any) { sent = append(sent, rows) }
	t.Cleanup(func() { emitConnectionsRows = original })

	feed := &connectionsFeed{}
	feed.rowsEnabled = true
	feed.rowsRates = rateTracker{}
	sample := testSample("a", 1, 2)
	sample.CreatedAt = 1000
	feed.publishRows([]connectionSample{sample}, nil, time.Unix(100, 0))
	feed.publishRows([]connectionSample{sample}, nil, time.Unix(101, 0))
	if len(sent) != 1 {
		t.Fatalf("unchanged rows produced %d sends, want 1", len(sent))
	}
	sample.UploadTotal = 3
	sample.DownloadTotal = 4
	feed.publishRows([]connectionSample{sample}, nil, time.Unix(102, 0))
	if len(sent) != 2 {
		t.Fatalf("changed rows produced %d sends, want 2", len(sent))
	}
}

func TestConnectionsWatchState(t *testing.T) {
	state, err := connectionFeed.update(connectionsWatchRequest{
		Feed:       "rows",
		Enabled:    true,
		IntervalMs: 900,
	})
	if err != nil {
		t.Fatal(err)
	}
	if state.(map[string]any)["rows"] != true {
		t.Fatalf("rows not enabled: %+v", state)
	}
	if got := state.(map[string]any)["rowsIntervalMs"]; got != int64(900) {
		t.Fatalf("rows interval = %v", got)
	}
	state, err = connectionFeed.update(connectionsWatchRequest{Feed: "rows", Enabled: false})
	if err != nil {
		t.Fatal(err)
	}
	if state.(map[string]any)["rows"] != false {
		t.Fatalf("rows still enabled: %+v", state)
	}
}
