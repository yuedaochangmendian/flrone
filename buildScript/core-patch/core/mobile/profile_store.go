// Profile row helpers shared by the JSON-document readers.
//
// ADR 0005 final stage: profiles and groups are Dart-owned data. The Go action
// handlers that used to read and write them over SQLite are gone; the one
// remaining consumer is the outbound picker (`groupNodes`), which reads the
// document through profiles_doc.go. This file keeps the ordering rule that read
// shares with the route-document readers.
package mobile

import "sort"

// profilesOfGroup filters by gid, preserving the user_order sort the DAO applied
// (user_order, then id — the order the Proxies screen shows).
func profilesOfGroup(rows []row, groupID int64) []row {
	kept := make([]row, 0, 16)
	for _, r := range rows {
		if rowInt64(r, "gid") == groupID {
			kept = append(kept, r)
		}
	}
	sort.SliceStable(kept, func(a, b int) bool {
		left, right := rowInt64(kept[a], "user_order"), rowInt64(kept[b], "user_order")
		if left != right {
			return left < right
		}
		return rowInt64(kept[a], "id") < rowInt64(kept[b], "id")
	})
	return kept
}
