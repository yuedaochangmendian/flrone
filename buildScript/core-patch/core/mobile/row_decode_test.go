// Row decoding and ordering for the JSON documents (ADR 0005 final stage).
//
// The row helpers grew up on JSON documents, where a number is a float64, and
// then grew a text arm for Room's sqlite3_get_table cells. With the profile
// actions deleted (and Room closed to this package), the documents are the only
// source again — but the text arm stays, because a hand-edited document may
// store "70" as a string and a 0 from rowInt64 would silently drop the row from
// every picker.
//
// These tests pin the decode itself, the group tab order and the member order.
package mobile

import (
	"reflect"
	"testing"
)

func TestRowInt64ReadsTextCells(t *testing.T) {
	if got := rowInt64(row{"id": "70"}, "id"); got != 70 {
		t.Fatalf("a text cell must decode to its number, got %d", got)
	}
	if got := rowInt64(row{"id": "-7"}, "id"); got != -7 {
		t.Fatalf("a negative text cell must keep its sign, got %d", got)
	}
	// Larger than a 32-bit int: the decode must not narrow.
	const large = int64(1) << 40
	if got := rowInt64(row{"id": "1099511627776"}, "id"); got != large {
		t.Fatalf("a wide text cell must survive intact, got %d", got)
	}
}

func TestRowInt64LeavesNonNumbersAtZero(t *testing.T) {
	if got := rowInt64(row{"id": "nope"}, "id"); got != 0 {
		t.Fatalf("an unparseable cell reads as 0, got %d", got)
	}
	if got := rowInt64(row{"id": ""}, "id"); got != 0 {
		t.Fatalf("an empty cell reads as 0, got %d", got)
	}
	if got := rowInt64(row{"id": nil}, "id"); got != 0 {
		t.Fatalf("a NULL cell reads as 0, got %d", got)
	}
}

func TestRowIntDecodesLikeRowInt64(t *testing.T) {
	if got := rowInt(row{"type": "3"}, "type"); got != 3 {
		t.Fatalf("rowInt must agree with rowInt64 on text cells, got %d", got)
	}
}

// The document store stores JSON numbers, so the text arm must not have cost
// the original branches anything.
func TestRowInt64KeepsJSONNumbers(t *testing.T) {
	if got := rowInt64(row{"id": float64(70)}, "id"); got != 70 {
		t.Fatalf("a JSON float64 must decode, got %d", got)
	}
	if got := rowInt64(row{"id": int64(70)}, "id"); got != 70 {
		t.Fatalf("a re-encoded int64 must decode, got %d", got)
	}
	if got := rowInt64(row{"id": 70}, "id"); got != 70 {
		t.Fatalf("an int must decode, got %d", got)
	}
}

func TestProfilesOfGroupOrdersByUserOrderThenID(t *testing.T) {
	rows := []row{
		{"id": "70", "gid": "3", "user_order": "1"},
		{"id": "71", "gid": "3", "user_order": "0"},
		{"id": "69", "gid": "3", "user_order": "1"},
		{"id": "72", "gid": "4", "user_order": "0"},
	}
	got := profilesOfGroup(rows, 3)
	ids := make([]int64, 0, len(got))
	for _, r := range got {
		ids = append(ids, rowInt64(r, "id"))
	}
	// Filtered by gid, then user_order, with the id breaking a tie: a stable sort
	// alone would keep the document's array order for equal orders.
	if !reflect.DeepEqual(ids, []int64{71, 69, 70}) {
		t.Fatalf("want [71 69 70], got %v", ids)
	}
}

func TestGroupsInTabOrder(t *testing.T) {
	doc := profilesDocument{Groups: []row{
		{"id": 2, "display_order": 5},
		{"id": 1, "display_order": 1},
		{"id": 3, "display_order": 5},
	}}
	got := doc.groupsInTabOrder()
	ids := make([]int64, 0, len(got))
	for _, r := range got {
		ids = append(ids, rowInt64(r, "id"))
	}
	if !reflect.DeepEqual(ids, []int64{1, 2, 3}) {
		t.Fatalf("want [1 2 3], got %v", ids)
	}
}
