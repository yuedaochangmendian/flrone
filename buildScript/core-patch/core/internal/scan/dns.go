package scan

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"sync"
	"time"

	"github.com/sagernet/sing-box/include"
	M "github.com/sagernet/sing/common/metadata"
)

const (
	DNSProtocolDNSTT     = "dnstt"
	DNSProtocolMasterDNS = "masterdns"

	DNSLevelPoll      = "poll"
	DNSLevelQName     = "qname"
	DNSLevelHandshake = "handshake"
	DNSLevelQuick     = "quick"
	DNSLevelFull      = "full"
)

const (
	dnsDefaultPort    = 53
	defaultDNSTimeout = 5 * time.Second
	maxDNSTimeout     = 5 * time.Minute
)

type DNSOptions struct {
	Enabled    bool
	Protocol   string
	ConfigJSON string
	Level      string
	Timeout    time.Duration
}

type dnsProbe func(ctx context.Context, egress Egress, server netip.AddrPort, result *Result) error

type dnsPlan struct {
	timeout time.Duration
	probe   dnsProbe
}

func newDNSPlan(options DNSOptions) (*dnsPlan, error) {
	plan := &dnsPlan{timeout: defaultDNSTimeout}
	if options.Timeout > 0 {
		plan.timeout = min(max(options.Timeout, minPhaseTimeout), maxDNSTimeout)
	}
	return nil, fmt.Errorf("unsupported DNS tunnel protocol %q", options.Protocol)
}

func (r *probeRun) dnsTarget(ctx context.Context, target Target) Result {
	result := Result{Addr: target.Addr, Port: target.Port}
	port := target.Port
	if port == 0 {
		port = dnsDefaultPort
	}
	result.ProbePort = port
	display := DisplayTarget(target.Addr, port)
	r.session.emit(EventStart, PhaseDNS, display, 0, "")
	probeCtx, cancel := context.WithTimeout(ctx, r.plan.dns.timeout)
	defer cancel()
	if err := r.plan.dns.probe(probeCtx, r.egress, netip.AddrPortFrom(target.Addr.Unmap(), port), &result); err != nil {
		if result.DNSStage != "" {
			err = &dnsStageError{stage: result.DNSStage, err: err}
		}
		return r.fail(ctx, &result, PhaseDNS, display, err)
	}
	r.session.emit(EventOK, PhaseDNS, display, time.Duration(result.DNSMs)*time.Millisecond, "")
	result.Passed = true
	return result
}

type dnsStageError struct {
	stage string
	err   error
}

func (e *dnsStageError) Error() string {
	return e.stage + ": " + e.err.Error()
}

func (e *dnsStageError) Unwrap() error {
	return e.err
}

// DNSMs 0 means the resolver never answered, so an answer faster than the clock resolution still counts.
func answeredMs(latency time.Duration) int32 {
	return int32(min(max(latency.Milliseconds(), 1), int64(maxDNSTimeout/time.Millisecond)))
}

func listenUDP(ctx context.Context, egress Egress, destination netip.Addr) (net.PacketConn, error) {
	controlFunc, err := egress.Control()
	if err != nil {
		return nil, err
	}
	network := "udp4"
	if destination.Unmap().Is6() {
		network = "udp6"
	}
	return (&net.ListenConfig{Control: controlFunc}).ListenPacket(ctx, network, "")
}

type egressDialer struct {
	egress Egress
}

func (d egressDialer) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	if !destination.IsIP() {
		return nil, fmt.Errorf("unexpected destination %s", destination)
	}
	controlFunc, err := d.egress.Control()
	if err != nil {
		return nil, err
	}
	return (&net.Dialer{Control: controlFunc}).DialContext(ctx, network, destination.Unwrap().String())
}

func (d egressDialer) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	return listenUDP(ctx, d.egress, destination.Addr)
}

var errDryRun = errors.New("dry run")

type dryRunDialer struct{}

func (dryRunDialer) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	return nil, errDryRun
}

func (dryRunDialer) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, errDryRun
}

var boxContext = sync.OnceValue(func() context.Context {
	return include.Context(context.Background())
})
