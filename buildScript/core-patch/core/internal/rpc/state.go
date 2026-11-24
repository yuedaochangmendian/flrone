package rpc

import (
	"context"
	"errors"
	"sync"

	"ThroneCore/internal/boxmain"
	"ThroneCore/internal/process"

	"github.com/sagernet/sing-box/option"
)

// Serializes Start against Stop: the dispatcher gives every request its own goroutine.
var lifecycleMu sync.Mutex

// Guards the instance pointers; never held across a Create/Start, so pollers do not block behind a profile start.
var stateMu sync.RWMutex

var boxInstance *boxmain.Box

var instanceCancel context.CancelFunc

// Reached only from Start/Stop, i.e. always under lifecycleMu.
var extraProcess *process.Process

var stopEgressForwardingWatch func()

var errInstanceNotRunning = errors.New("Instance is not running")

func currentBox() *boxmain.Box {
	stateMu.RLock()
	defer stateMu.RUnlock()
	return boxInstance
}

func currentInstance() (*boxmain.Box, context.CancelFunc) {
	stateMu.RLock()
	defer stateMu.RUnlock()
	return boxInstance, instanceCancel
}

func setBoxInstance(box *boxmain.Box, cancel context.CancelFunc, routeRules []option.Rule) {
	stateMu.Lock()
	defer stateMu.Unlock()
	boxInstance, instanceCancel = box, cancel
	connRules.reset(box, routeRules)
}
