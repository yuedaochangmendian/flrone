// The Dart-owned profiles/groups document (ADR 0005 final stage).
//
// Dart writes `<basePath>/documents/profiles.json` through `ProfileStore`; Kotlin
// reads the same file synchronously (`DartProfileStore.kt`) to build the core
// config. Go needs one read: the outbound picker's node catalog
// (`groupNodes`). Room's `profiles`/`groups` tables are no longer written once
// the document exists, so reading them here would answer rows frozen at
// migration time — a node added yesterday would be missing from the picker.
//
// The document carries the row shape with Room's column names, exactly like the
// route documents, so [row] and its readers work unchanged. Unlike the route
// documents (written by this package), the envelope also carries the next-id
// counters; they are not needed for a read and are intentionally ignored.
package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

const profilesDocumentName = "profiles.json"

type profilesDocument struct {
	Version  int   `json:"version"`
	Profiles []row `json:"profiles"`
	Groups   []row `json:"groups"`
}

// readProfilesDocument loads the document Dart owns. A missing file answers an
// empty document rather than an error: a fresh install has no file until the
// one-time migration runs, and "no nodes yet" is a legitimate answer for the
// picker.
func readProfilesDocument() (*profilesDocument, error) {
	dir, err := documentsDir()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(filepath.Join(dir, profilesDocumentName))
	if errors.Is(err, os.ErrNotExist) {
		return &profilesDocument{}, nil
	}
	if err != nil {
		return nil, err
	}
	var doc profilesDocument
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("read %s: %w", profilesDocumentName, err)
	}
	return &doc, nil
}

// groupsInTabOrder returns the groups the way GroupRepo.all does: display_order,
// then id. Dart writes the array in tab order already, but a hand-edited or
// older document must not reorder the picker.
func (d *profilesDocument) groupsInTabOrder() []row {
	groups := append([]row(nil), d.Groups...)
	sort.SliceStable(groups, func(a, b int) bool {
		left, right := rowInt64(groups[a], "display_order"), rowInt64(groups[b], "display_order")
		if left != right {
			return left < right
		}
		return rowInt64(groups[a], "id") < rowInt64(groups[b], "id")
	})
	return groups
}
