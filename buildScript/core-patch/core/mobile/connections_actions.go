// The action-bus surface of the core-side connection feed.
//
// `connectionsWatch` is the demand signal: the connections page asks for rows
// while it is on screen, and the traffic ledger asks for attribution while
// traffic statistics are on. The two feeds are independent, so a page close
// cannot stop the ledger and a ledger toggle cannot blank the page.
//
// `connectionsClose` and `connectionsCloseAll` replace the old loopback HTTP
// calls to the Clash API. They act on the same tracker rows the feed reports,
// so the list and the close button cannot disagree about which session is live.
package mobile

import (
	"encoding/json"
	"reflect"
	"sync"
	"time"

	"github.com/gofrs/uuid/v5"
	E "github.com/sagernet/sing/common/exceptions"
)

const (
	connectionsWatchMethod    Method = "connectionsWatch"
	connectionsCloseMethod    Method = "connectionsClose"
	connectionsCloseAllMethod Method = "connectionsCloseAll"
)

func init() {
	register(connectionsWatchMethod, handleConnectionsWatch)
	register(connectionsCloseMethod, handleConnectionsClose)
	register(connectionsCloseAllMethod, handleConnectionsCloseAll)
}

type connectionsWatchRequest struct {
	Feed       string `json:"feed"`
	Enabled    bool   `json:"enabled"`
	IntervalMs int64  `json:"intervalMs"`
	Details    bool   `json:"details"`
}

type connectionsFeed struct {
	mu sync.Mutex

	rowsEnabled  bool
	rowsInterval time.Duration
	rowsRates    rateTracker
	lastRows     []map[string]any

	attrEnabled   bool
	attrInterval  time.Duration
	attrDetails   bool
	attrPrevious  map[string][2]int64
	attrEnabledAt time.Time
	attrSampledAt time.Time

	running bool
	stop    chan struct{}
	wake    chan struct{}
	current *Instance
}

var connectionFeed = &connectionsFeed{
	rowsInterval: connectionsRowsDefaultInterval,
	attrInterval: connectionsAttrDefaultInterval,
	wake:         make(chan struct{}, 1),
}

func handleConnectionsWatch(raw json.RawMessage) (any, error) {
	var request connectionsWatchRequest
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &request); err != nil {
			return nil, err
		}
	}
	return connectionFeed.update(request)
}

func (f *connectionsFeed) update(request connectionsWatchRequest) (any, error) {
	now := time.Now()
	f.mu.Lock()
	switch request.Feed {
	case "rows":
		if request.Enabled {
			// A (re)subscribe always gets a fresh snapshot: the new consumer has
			// no rows yet, and a UI engine restart must not inherit the previous
			// link's "unchanged, so not sent" state.
			f.rowsInterval = connectionInterval(request.IntervalMs, connectionsRowsDefaultInterval)
			f.rowsRates.reset()
			f.lastRows = nil
		} else {
			f.rowsRates.reset()
			f.lastRows = nil
		}
		f.rowsEnabled = request.Enabled
	case "attribution":
		if request.Enabled && !f.attrEnabled {
			f.attrPrevious = make(map[string][2]int64)
			f.attrEnabledAt = now
			f.attrSampledAt = time.Time{}
			f.attrInterval = connectionInterval(request.IntervalMs, connectionsAttrDefaultInterval)
			f.attrDetails = request.Details
		} else if request.Enabled {
			if request.IntervalMs > 0 {
				f.attrInterval = connectionInterval(request.IntervalMs, connectionsAttrDefaultInterval)
			}
			f.attrDetails = request.Details
		}
		f.attrEnabled = request.Enabled
		if !request.Enabled {
			f.attrPrevious = nil
			f.attrSampledAt = time.Time{}
		}
	default:
		f.mu.Unlock()
		return nil, E.New("connectionsWatch: unknown feed ", request.Feed)
	}
	running := f.rowsEnabled || f.attrEnabled
	if running && !f.running {
		f.running = true
		f.stop = make(chan struct{})
		go f.loop(f.stop)
	} else if !running && f.running {
		f.running = false
		close(f.stop)
		f.stop = nil
		f.current = nil
	}
	state := f.stateLocked()
	f.mu.Unlock()
	f.signal()
	return state, nil
}

func (f *connectionsFeed) stateLocked() map[string]any {
	return map[string]any{
		"rows":                  f.rowsEnabled,
		"rowsIntervalMs":        durationMillis(f.rowsInterval),
		"attribution":           f.attrEnabled,
		"attributionIntervalMs": durationMillis(f.attrInterval),
		"details":               f.attrDetails,
	}
}

func (f *connectionsFeed) signal() {
	select {
	case f.wake <- struct{}{}:
	default:
	}
}

func (f *connectionsFeed) nextInterval() time.Duration {
	f.mu.Lock()
	defer f.mu.Unlock()
	var interval time.Duration
	if f.rowsEnabled {
		interval = f.rowsInterval
	}
	if f.attrEnabled && (interval == 0 || f.attrInterval < interval) {
		interval = f.attrInterval
	}
	return interval
}

func (f *connectionsFeed) loop(stop <-chan struct{}) {
	immediate := true
	for {
		interval := f.nextInterval()
		fireNow := immediate
		immediate = false
		if interval <= 0 && !fireNow {
			// Both feeds were turned off between the wake and this read; the
			// update that did it closes stop, so this branch is only the
			// narrow race window. Wait for either signal instead of spinning.
			select {
			case <-stop:
				return
			case <-f.wake:
				immediate = true
			}
			continue
		}
		if fireNow {
			interval = 0
		}
		timer := time.NewTimer(interval)
		select {
		case <-stop:
			timer.Stop()
			return
		case <-f.wake:
			timer.Stop()
			immediate = true
		case <-timer.C:
			f.tick(time.Now())
		}
	}
}

func (f *connectionsFeed) tick(now time.Time) {
	defer func() { _ = recover() }()
	instance, err := currentInstance()
	if err != nil || instance == nil || instance.traffic == nil {
		f.mu.Lock()
		if f.current != nil {
			f.current = nil
			f.rowsRates.reset()
			f.attrPrevious = nil
			f.attrSampledAt = time.Time{}
		}
		f.mu.Unlock()
		return
	}

	f.mu.Lock()
	if instance != f.current {
		f.current = instance
		f.rowsRates.reset()
		f.lastRows = nil
		f.attrPrevious = make(map[string][2]int64)
		f.attrSampledAt = time.Time{}
		f.attrEnabledAt = now
	}
	rowsDue := f.rowsEnabled && (f.rowsRates.at.IsZero() || now.Sub(f.rowsRates.at)+50*time.Millisecond >= f.rowsInterval)
	attrDue := f.attrEnabled && (f.attrSampledAt.IsZero() || now.Sub(f.attrSampledAt)+50*time.Millisecond >= f.attrInterval)
	details := f.attrDetails
	attrEnabledAt := f.attrEnabledAt
	f.mu.Unlock()

	if !rowsDue && !attrDue {
		return
	}
	live := sampleConnections(instance.traffic.Connections())
	closed := sampleConnections(instance.traffic.ClosedConnections())

	if rowsDue {
		f.publishRows(live, closed, now)
	}
	if attrDue {
		f.mu.Lock()
		payload, previous := connectionAttribution(live, closed, f.attrPrevious, attrEnabledAt, details)
		f.attrPrevious = previous
		f.attrSampledAt = now
		f.mu.Unlock()
		if payload != nil {
			sendEvent("trafficDeltas", payload)
		}
	}
}

// emitConnectionsRows is the seam a test swaps to observe the unchanged-row
// suppression without a message port.
var emitConnectionsRows = func(rows []map[string]any) {
	sendEvent("connections", rows)
}

func (f *connectionsFeed) publishRows(live, closed []connectionSample, now time.Time) {
	f.mu.Lock()
	if !f.rowsEnabled {
		f.mu.Unlock()
		return
	}
	rates := f.rowsRates.rates(live, now)
	rows := connectionRows(live, closed, rates)
	// An idle tunnel's rows are identical tick after tick; the page should not
	// be rebuilt (nor the IPC payload sent) until something moved.
	changed := !reflect.DeepEqual(rows, f.lastRows)
	if changed {
		f.lastRows = rows
	}
	f.mu.Unlock()
	if changed {
		emitConnectionsRows(rows)
	}
}

func handleConnectionsClose(raw json.RawMessage) (any, error) {
	var request struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return nil, err
	}
	if request.ID == "" {
		return nil, E.New("connectionsClose: missing id")
	}
	instance, err := currentInstance()
	if err != nil {
		return nil, err
	}
	if instance.traffic == nil {
		return nil, E.New("connectionsClose: connection tracking is not available")
	}
	id, err := uuid.FromString(request.ID)
	if err != nil {
		return nil, E.New("connectionsClose: invalid id: ", err)
	}
	if tracker := instance.traffic.Connection(id); tracker != nil {
		if err := tracker.Close(); err != nil {
			return nil, err
		}
	}
	return true, nil
}

func handleConnectionsCloseAll(_ json.RawMessage) (any, error) {
	instance, err := currentInstance()
	if err != nil {
		return nil, err
	}
	if instance.traffic == nil {
		return nil, E.New("connectionsCloseAll: connection tracking is not available")
	}
	instance.traffic.CloseAllConnections()
	// The Clash API's DELETE /connections also resets the network manager; the
	// page's "close all" has always meant both, so keep that behaviour.
	instance.ResetNetwork()
	return true, nil
}
