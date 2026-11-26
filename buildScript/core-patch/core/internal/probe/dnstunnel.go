package probe

import (
	"time"

	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
)

// Matches the GUI's StartupAllowanceMs: a DNS tunnel opens its session over many slow queries.
const (
	DNSTunnelStartupTimeout = 30 * time.Second
	MasterDNSStartupTimeout = 90 * time.Second
)

// Stacked tunnels start one after another, so their allowances add up.
func startupAllowance(i Box, tag string) time.Duration {
	var allowance time.Duration
	walkChain(i, tag, func(tag string, outbound adapter.Outbound) {
		switch outbound.Type() {
		case C.TypeDNSTT:
			allowance += DNSTunnelStartupTimeout
		case C.TypeMasterDNS:
			allowance += MasterDNSStartupTimeout
		}
	})
	return allowance
}
