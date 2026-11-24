// Package testenv builds what a probe batch runs against: the running box, or a throwaway box.
package testenv

import (
	"ThroneCore/internal/probe"
)

type Env[B probe.Box] struct {
	Box   B
	Tags  []string
	close func()
}

func (e *Env[B]) Close() {
	e.close()
}

// Measures the running box, through "proxy" when it has one, and owns nothing.
func Current[B probe.Box](box B, tags []string, useDefaultOutbound bool) *Env[B] {
	outTags := tags
	if _, exists := box.Outbound().Outbound("proxy"); exists {
		outTags = []string{"proxy"}
	} else {
		useDefaultOutbound = true
	}
	if useDefaultOutbound {
		outTags = []string{box.Outbound().Default().Tag()}
	}
	return &Env[B]{Box: box, Tags: outTags, close: func() {}}
}

type Request struct {
	Tags               []string
	UseDefaultOutbound bool
}

func Prepare[B probe.Box](request Request, build func() (B, func(), error)) (*Env[B], error) {
	box, closeBox, err := build()
	if err != nil {
		return nil, err
	}
	outTags := request.Tags
	if request.UseDefaultOutbound {
		outTags = []string{box.Outbound().Default().Tag()}
	}
	return &Env[B]{Box: box, Tags: outTags, close: closeBox}, nil
}
