// Non-destructive status read for the host's own meters.
//
// Instance.Status() reports Uplink/Downlink as the bytes moved since the
// previous Status() call and moves the baseline on every read. The Dart
// heartbeat (throne_status_snapshot) relies on that delta for the speed card,
// but the Kotlin traffic recorder only needs memory and connection counts — and
// its second read every second consumed the heartbeat's delta, so the speed card
// alternated between the real rate and zero.
//
// MetricsSnapshot answers the same fields without touching statusSampled. The
// two rate fields stay zero: rates belong to the delta reader alone.
package mobile

import (
	"runtime"

	"github.com/sagernet/sing/common/memory"
)

// MetricsSnapshot is Status() without the rate accounting: memory, goroutines,
// connections and the cumulative totals, safe to poll from a second reader.
func (i *Instance) MetricsSnapshot() *StatusMessage {
	status := &StatusMessage{
		Memory:     int64(memory.Total()),
		Goroutines: int32(runtime.NumGoroutine()),
	}
	if status.Memory == 0 {
		status.Memory = int64(memory.Inuse())
	}
	if !i.running() {
		return status
	}
	if i.connections != nil {
		status.ConnectionsOut = int32(i.connections.Count())
	}
	if i.traffic != nil {
		status.TrafficAvailable = true
		status.UplinkTotal, status.DownlinkTotal = i.traffic.Total()
		status.ConnectionsIn = int32(i.traffic.ConnectionsLen())
	}
	return status
}
