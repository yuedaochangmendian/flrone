package rpc

import (
	"log"
	"time"

	"ThroneCore/internal/boxmain"
	"ThroneCore/internal/probe"
	"ThroneCore/internal/testenv"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

// `current` measures the running instance instead of building one, and owns nothing.
func prepareTestEnv(current bool, coreConfig string, tags []string, useDefaultOutbound bool) (*testenv.Env[*boxmain.Box], error) {
	if current {
		box := currentBox()
		if box == nil {
			return nil, errInstanceNotRunning
		}
		return testenv.Current(box, tags, useDefaultOutbound), nil
	}

	request := testenv.Request{
		Tags:               tags,
		UseDefaultOutbound: useDefaultOutbound,
	}
	return testenv.Prepare(request, func() (*boxmain.Box, func(), error) {
		box, cancel, err := boxmain.Create([]byte(coreConfig), func(options *option.Options) {
			applyAutoRedirectMark(options, autoRedirectMark.Load())
			probe.LimitWireGuardWorkers(options)
		})
		if err != nil {
			return nil, nil, err
		}
		return box, func() {
			box.CloseWithTimeout(cancel, 2*time.Second, log.Println, false)
		}, nil
	})
}

// A probe box has no tun to mark its sockets, so the running Tun's auto_redirect nftables rules would capture them.
func applyAutoRedirectMark(options *option.Options, mark uint32) {
	if mark == 0 {
		return
	}
	for _, inbound := range options.Inbounds {
		// sing-box refuses route.default_mark next to its own tun auto_redirect.
		if inbound.Type == C.TypeTun {
			return
		}
	}
	if options.Route == nil {
		options.Route = &option.RouteOptions{}
	}
	if options.Route.DefaultMark == 0 {
		options.Route.DefaultMark = option.FwMark(mark)
	}
}
