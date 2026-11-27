// The involved-profile record of one config build.
//
// The Kotlin generator wraps its profile provider in RecordingProfiles
// (ConfigGenerator.kt:1146-1151): every profile a build reads is added to a
// LinkedHashSet and handed back as GeneratedConfig.involvedProfileIds, which
// BoxInstance reports as `config.build`'s third key. The set is not decoration:
// `state.markRunning` persists it and ProfileManager.runningUses refuses to
// delete a node a running chain still uses.
//
// This file is the Go port of that wrapper. The builder reads profiles through
// configBuilder.readProfile and through configBuildChain, and both record the id
// on the same sites Kotlin's reads.get does:
//
//   - the selected profile, first (ConfigGenerator.build :52);
//   - every route outbound and its chain hops (:133, :149);
//   - the main chain's landing proxy, chain hops and front proxy (:522-529);
//   - a chain per route outbound group (:536-543);
//   - an auto-selector's every build member (:658 via rejectedMembers, :575) and
//     each member's own group landing / front proxies (:577-580).
//
// The WARP pseudo profile is deliberately absent on both sides: WarpHop.PROFILE_ID
// and configWarpProfileID are resolved from the settings before any provider read.
//
// For a successful build the recorded set must contain the selected profile
// first; a build that cannot reproduce that is an error, never an empty list.
package mobile

import (
	"errors"
	"fmt"
)

// errConfigInvolvedProfiles marks the typed failure returned when a successful
// build cannot report its involved profiles exactly. Callers can test it with
// errors.Is; the response must never carry a guessed or empty list instead.
var errConfigInvolvedProfiles = errors.New("involved profile ids are not reproducible")

// configInvolvedProfilesError is the typed failure: the reason names which
// invariant of RecordingProfiles the build did not satisfy.
type configInvolvedProfilesError struct {
	Reason string
}

func (err *configInvolvedProfilesError) Error() string {
	return "config.build: involved profile ids are not reproducible: " + err.Reason
}

// Unwrap exposes the sentinel so errors.Is works without type assertions.
func (err *configInvolvedProfilesError) Unwrap() error {
	return errConfigInvolvedProfiles
}

// configProfileReads is RecordingProfiles: the ids of the profiles a build read,
// in first-read order, without duplicates. A nil recorder records nothing, which
// is what the golden harness uses — it compares bytes and never reports ids.
type configProfileReads struct {
	ids  []int64
	seen map[int64]bool
}

func newConfigProfileReads() *configProfileReads {
	return &configProfileReads{seen: make(map[int64]bool)}
}

// record is RecordingProfiles.get's `.also { ids.add(id) }`: a profile that
// resolved (the caller found it) enters the set, a missing one never does.
func (reads *configProfileReads) record(id int64) {
	if reads == nil || reads.seen[id] {
		return
	}
	reads.seen[id] = true
	reads.ids = append(reads.ids, id)
}

// snapshot is GeneratedConfig.involvedProfileIds.toList(): insertion order, no
// duplicates. It refuses to answer when the build's first read was not the
// selected profile, since that means a read site bypassed the recorder and the
// list would be incomplete.
func (reads *configProfileReads) snapshot(selected int64) ([]int64, error) {
	if reads == nil {
		return nil, &configInvolvedProfilesError{Reason: "the build did not record profile reads"}
	}
	if len(reads.ids) == 0 {
		return nil, &configInvolvedProfilesError{Reason: "the build read no profile"}
	}
	if reads.ids[0] != selected {
		return nil, &configInvolvedProfilesError{
			Reason: fmt.Sprintf("the selected profile %d is not the first recorded read (%d)", selected, reads.ids[0]),
		}
	}
	return append([]int64(nil), reads.ids...), nil
}
