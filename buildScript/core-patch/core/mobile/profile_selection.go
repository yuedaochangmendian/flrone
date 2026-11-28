// ADR 0008 P1-5: the Dart-owned selection document, read only by Go.
//
// Dart writes `<basePath>/documents/profile_selection.json` on every selection
// change:
//
//     {"version":1,"selectedProfileId":N,"currentGroupId":N,"updatedAt":epochMs}
//
// This package never writes it. During migration the file may be absent or
// malformed (an older install, a half-upgraded bundle, a hand edit); in that
// case the caller falls back to the settings-based selection (settings.json's
// `profileId` / `current_group`), which is the pre-P1-5 source of truth. A
// malformed file must never fail the build — config.build stays a pure read of
// documents with a documented fallback.
//
// MIGRATION SHIM: until profiles S4 lands, Kotlin is still a selection writer
// (widget, quick toggle, BaseService, subscription refresh, deletion fallback)
// and persists its choice to settings.json, not to this document. Go therefore
// uses the document only when it AGREES with settings, or when settings has no
// selection at all (an upgrade where settings was reset but the documents
// directory survived). A disagreement means the document is stale and settings
// wins. S4 drops the gate: config.build then reads only this document.

package mobile

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

const profileSelectionDocumentName = "profile_selection.json"

// profileSelection is the typed, validated form of the selection document.
// UpdatedAt is part of the wire contract and is validated as present (> 0);
// the current builder does not compare timestamps (the migration gate compares
// ids instead), but it is exposed so a future reader can.
type profileSelection struct {
	SelectedProfileID int64
	CurrentGroupID    int64
	UpdatedAt         int64
}

// readProfileSelection loads Dart's selection document from one documents
// directory. Three outcomes are distinguished by the caller:
//
//   - (nil, nil): the file is absent — fall back to settings;
//   - (nil, error): the file exists but is unreadable or parses to an invalid
//     shape — also fall back (the error is for diagnostics, not a hard failure);
//   - (selection, nil): a valid document, which the caller gates against
//     settings before using.
//
// Keeping "absent" and "invalid" distinct from a valid selection while never
// failing the build for either is deliberate: migration must be silent, but a
// corrupt file is still worth reporting.
func readProfileSelection(dir string) (*profileSelection, error) {
	path := filepath.Join(dir, profileSelectionDocumentName)
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		// An unreadable file (permissions, a directory in its place) is a
		// transient local problem, not a reason to fail config.build.
		return nil, err
	}
	return parseProfileSelection(data)
}

// parseProfileSelection validates the exact wire shape Dart writes. A wrong
// version, a non-positive selected id, a missing/invalid updatedAt or malformed
// JSON all return an error so the caller falls back. Unknown extra keys are
// tolerated (a newer Dart adding informational fields must not break an older
// Go); the four known keys and their types are the contract.
func parseProfileSelection(data []byte) (*profileSelection, error) {
	var wire struct {
		Version           int   `json:"version"`
		SelectedProfileID int64 `json:"selectedProfileId"`
		CurrentGroupID    int64 `json:"currentGroupId"`
		UpdatedAt         int64 `json:"updatedAt"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return nil, err
	}
	if wire.Version != 1 {
		return nil, errors.New("profile_selection.json has unsupported version")
	}
	if wire.SelectedProfileID <= 0 {
		return nil, errors.New("profile_selection.json has no selected profile")
	}
	if wire.CurrentGroupID < 0 {
		return nil, errors.New("profile_selection.json has an invalid current group")
	}
	if wire.UpdatedAt <= 0 {
		return nil, errors.New("profile_selection.json has no valid updatedAt")
	}
	return &profileSelection{
		SelectedProfileID: wire.SelectedProfileID,
		CurrentGroupID:    wire.CurrentGroupID,
		UpdatedAt:         wire.UpdatedAt,
	}, nil
}
