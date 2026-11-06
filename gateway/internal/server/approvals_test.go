package server

import (
	"testing"

	"agmente/gateway/internal/jsonv"
)

// D-009: the gateway's own answer is a reject option or cancelled, never an allow option.
func TestRejectOutcomeNeverAllows(t *testing.T) {
	cases := []struct{ options, want string }{
		{`[{"optionId":"a","kind":"allow_once"},{"optionId":"r","kind":"reject_once"}]`, `{"outcome":"selected","optionId":"r"}`},
		{`[{"optionId":"ra","kind":"reject_always"},{"optionId":"r","kind":"reject_once"}]`, `{"outcome":"selected","optionId":"r"}`},
		{`[{"optionId":"a","kind":"allow_always"},{"optionId":"ra","kind":"reject_always"}]`, `{"outcome":"selected","optionId":"ra"}`},
		{`[{"optionId":"a","kind":"allow_once"},{"optionId":"b","kind":"allow_always"}]`, `{"outcome":"cancelled"}`},
		{`[{"optionId":"","kind":"reject_once"},{"kind":"reject_once"},{"optionId":7,"kind":"reject_once"}]`, `{"outcome":"cancelled"}`},
		{`[{"optionId":"x","kind":"REJECT_ONCE"}]`, `{"outcome":"cancelled"}`},
		{`[]`, `{"outcome":"cancelled"}`},
		{`{"optionId":"r","kind":"reject_once"}`, `{"outcome":"cancelled"}`},
		{`null`, `{"outcome":"cancelled"}`},
	}
	for _, c := range cases {
		v, err := jsonv.Parse([]byte(c.options))
		if err != nil {
			t.Fatal(err)
		}
		if got := string(rejectOutcome(v).Marshal()); got != c.want {
			t.Errorf("%s: got %s, want %s", c.options, got, c.want)
		}
	}
	if got := string(rejectOutcome(nil).Marshal()); got != `{"outcome":"cancelled"}` {
		t.Errorf("nil options: got %s", got)
	}
}
