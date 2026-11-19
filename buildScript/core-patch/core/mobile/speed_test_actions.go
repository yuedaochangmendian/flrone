// Speed-test metadata on the JSON action bus (ADR 0004, P4 first slice).
//
// The two methods here answer the *metadata* the speed screen reads before a run
// starts. The long-running session itself is now on the bus too, in
// test_session_actions.go: Go relays those controls to the Kotlin host, while
// the pushed `testSession` progress feed stays on the EventChannel. Moving the
// reads here gives the speed screen one control plane for everything the kernel
// owns, while Kotlin keeps only the Android platform duties listed in ADR 0004.
//
// Wire shapes are deliberately the same ones the old `speedTest.outbounds` and
// `groups.nodes` channel arms produced, so the Dart facade only changes its
// transport, not the shape it normalizes:
//
//   speedTestOutbounds -> {"outbounds": ["tag", ...]}        (running box)
//   groupNodes         -> {"nodes": [{"id","tag","type","isSelector"}, ...]}
//
// `speedTestServers` is NOT revived here. Its producer (the latency-ranked
// speedtest.net server list) lived in the 1680-line Bettbox `speedtest.go` that
// was deleted with the channel arm; the pinned core's probe package only exposes
// a single best-server pick internally, so there is no Go producer for that
// shape. There is no Dart caller either — the current screen prints the provider
// server from the finished run. See the P4 report.

package mobile

import (
	"encoding/json"
)

const (
	speedTestOutboundsMethod Method = "speedTestOutbounds"
	groupNodesMethod         Method = "groupNodes"
)

func init() {
	register(speedTestOutboundsMethod, handleSpeedTestOutbounds)
	register(groupNodesMethod, handleGroupNodes)
}

// handleSpeedTestOutbounds lists the running box's outbound tags, the picker the
// speed test narrows a run to. It needs a live instance: the result is the hop the
// test would actually dial through, and with the core down there is no honest
// answer. currentInstance() reports errInstanceNotRunning in that case, which the
// Dart facade turns into the screen's "start the VPN first" message.
func handleSpeedTestOutbounds(_ json.RawMessage) (any, error) {
	instance, err := currentInstance()
	if err != nil {
		return nil, err
	}
	outbounds := instance.outbounds
	if outbounds == nil {
		return map[string]any{"outbounds": []string{}}, nil
	}
	all := outbounds.Outbounds()
	tags := make([]string, 0, len(all))
	for _, outbound := range all {
		if outbound == nil {
			continue
		}
		tags = append(tags, outbound.Tag())
	}
	return map[string]any{"outbounds": tags}, nil
}

// handleGroupNodes answers the outbound-picker catalog: every node of every
// group, id and tag first. This is the read the speed screen actually uses to
// resolve a chosen tag to a ProxyEntity id — the old `speedTest.outbounds` tags
// alone could not start a session, so the current screen reads this catalog
// instead. It is identical to BboxGroupsWire.nodes:
//
//	{"nodes": [{"id": 7, "tag": "Node A", "type": "shadowsocks", "isSelector": false}, ...]}
//
// Room is the authority for profiles and groups (ADR 0002 amended), so Go reads
// it directly — the same `readRoomProfiles`/`readRoomGroups` helpers the profile
// actions use. Unlike speedTestOutbounds this needs no running core, which is why
// the Dart facade keeps a channel fallback for screens that render before the
// VPN starts. `type` is the stored column, the same value BboxCatalog falls back
// to when its outbound-JSON parse fails; the speed screen only reads id and tag.
func handleGroupNodes(_ json.RawMessage) (any, error) {
	groups, err := readRoomGroups()
	if err != nil {
		return nil, err
	}
	profiles, err := readRoomProfiles()
	if err != nil {
		return nil, err
	}
	nodes := make([]map[string]any, 0, len(profiles))
	for _, group := range groups {
		for _, profile := range profilesOfGroup(profiles, group.id) {
			// BboxCatalog.node falls back to displayName() for an empty name; Go
			// has no Kotlin outbound model, so an empty label is left empty rather
			// than guessed from a config it does not parse.
			tag := rowString(profile, "name")
			typeName := rowString(profile, "type")
			nodes = append(nodes, map[string]any{
				"id":         rowInt64(profile, "id"),
				"tag":        tag,
				"type":       typeName,
				"isSelector": typeName == "autoselector",
			})
		}
	}
	return map[string]any{"nodes": nodes}, nil
}
