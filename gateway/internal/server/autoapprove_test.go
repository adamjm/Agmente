package server

import (
	"testing"

	"acpcode/gateway/internal/jsonv"
)

func parseOptions(t *testing.T, src string) *jsonv.Value {
	t.Helper()
	v, err := jsonv.Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	return v
}

// D-124: the gateway's allow answer prefers allow_once, falls back to allow_always, and is nil when
// the request offers neither, so the phone is asked.
func TestAllowOutcomePrefersOnceThenAlwaysThenNothing(t *testing.T) {
	for _, tc := range []struct {
		name, options, want string
	}{
		{"once first", `[{"optionId":"a","kind":"allow_always"},{"optionId":"b","kind":"allow_once"},{"optionId":"c","kind":"reject_once"}]`, "b"},
		{"always only", `[{"optionId":"a","kind":"allow_always"},{"optionId":"c","kind":"reject_once"}]`, "a"},
		{"reject only", `[{"optionId":"c","kind":"reject_once"},{"optionId":"d","kind":"reject_always"}]`, ""},
		{"empty list", `[]`, ""},
		{"not a list", `{"optionId":"a","kind":"allow_once"}`, ""},
		{"empty id", `[{"optionId":"","kind":"allow_once"}]`, ""},
	} {
		got := allowOutcome(parseOptions(t, tc.options))
		if tc.want == "" {
			if got != nil {
				t.Errorf("%s: got an outcome, want nil", tc.name)
			}
			continue
		}
		if got == nil {
			t.Errorf("%s: got nil, want %q", tc.name, tc.want)
			continue
		}
		if id, _ := got.Get("optionId").StringValue(); id != tc.want {
			t.Errorf("%s: optionId = %q, want %q", tc.name, id, tc.want)
		}
	}
	if allowOutcome(nil) != nil {
		t.Error("nil options must give nil")
	}
}
