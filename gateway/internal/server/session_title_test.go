package server

import (
	"strings"
	"testing"

	"acpcode/gateway/internal/jsonv"
)

func textPrompt(t *testing.T, raw string) *jsonv.Value {
	t.Helper()
	v, err := jsonv.Parse([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestPromptTitle(t *testing.T) {
	long := strings.Repeat("a", 80)
	cases := []struct{ name, prompt, want string }{
		{"plain text", `[{"type":"text","text":"fix the login page"}]`, "fix the login page"},
		{"first non-empty line", `[{"type":"text","text":"\n\n  fix   the\tbug \nsecond line"}]`, "fix the bug"},
		{"text blocks only", `[{"type":"image","data":"x"},{"type":"text","text":"hello"}]`, "hello"},
		{"cut with an ellipsis", `[{"type":"text","text":"` + long + `"}]`, strings.Repeat("a", 50) + "…"},
		{"cut on a character", `[{"type":"text","text":"` + strings.Repeat("日", 60) + `"}]`, strings.Repeat("日", 50) + "…"},
		{"white space only", `[{"type":"text","text":"  \n "}]`, ""},
		{"no text block", `[{"type":"image","data":"x"}]`, ""},
		{"not an array", `"hello"`, ""},
	}
	for _, c := range cases {
		if got := promptTitle(textPrompt(t, c.prompt)); got != c.want {
			t.Errorf("%s: promptTitle = %q, want %q", c.name, got, c.want)
		}
	}
	if got := promptTitle(nil); got != "" {
		t.Errorf("nil prompt: %q", got)
	}
}
