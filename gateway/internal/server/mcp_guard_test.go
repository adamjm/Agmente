package server

// The phone's mcpServers list (D-084, D-086). Each case is one refusal rule or one accepted shape.

import (
	"fmt"
	"strings"
	"testing"

	"agmente/gateway/internal/jsonv"
)

func parseMCP(t *testing.T, s string) *jsonv.Value {
	t.Helper()
	v, err := jsonv.Parse([]byte(s))
	if err != nil {
		t.Fatalf("bad test JSON: %v", err)
	}
	return v
}

func TestCheckMCPServersAccepts(t *testing.T) {
	stdio := `{"name":"local","command":"/usr/bin/tool","args":["--x"],"env":[{"name":"K","value":"V"}]}`
	cases := map[string]struct {
		in   string // "" means the list is absent (nil)
		want mcpCounts
	}{
		"absent":                     {"", mcpCounts{}},
		"null":                       {"null", mcpCounts{}},
		"empty array":                {"[]", mcpCounts{}},
		"stdio":                      {"[" + stdio + "]", mcpCounts{Stdio: 1}},
		"stdio with type":            {`[{"type":"stdio","name":"a","command":"c","args":[],"env":[]}]`, mcpCounts{Stdio: 1}},
		"http https":                 {`[{"type":"http","name":"h","url":"https://mcp.example.com/mcp","headers":[{"name":"Authorization","value":"Bearer x"}]}]`, mcpCounts{HTTP: 1}},
		"http loopback 127":          {`[{"type":"http","name":"h","url":"http://127.0.0.1:8941/mcp","headers":[]}]`, mcpCounts{HTTP: 1}},
		"http localhost":             {`[{"type":"http","name":"h","url":"http://localhost:8080/mcp","headers":[]}]`, mcpCounts{HTTP: 1}},
		"http loopback v6":           {`[{"type":"http","name":"h","url":"http://[::1]:8080/mcp","headers":[]}]`, mcpCounts{HTTP: 1}},
		"mixed":                      {"[" + stdio + `,{"type":"http","name":"h","url":"https://x.example/mcp","headers":[]}]`, mcpCounts{Stdio: 1, HTTP: 1}},
		"32 entries (limit)":         {manyStdio(32), mcpCounts{Stdio: 32}},
		"alwaysAllow stdio":          {stdioWithAllow(`["t"]`), mcpCounts{Stdio: 1, AlwaysAllow: 1}},
		"alwaysAllow http":           {`[{"type":"http","name":"h","url":"https://x.example/mcp","headers":[],"alwaysAllow":["search","fetch"]}]`, mcpCounts{HTTP: 1, AlwaysAllow: 2}},
		"alwaysAllow empty array":    {stdioWithAllow(`[]`), mcpCounts{Stdio: 1}},
		"alwaysAllow 64 names":       {stdioWithAllow(toolNames(64, 4)), mcpCounts{Stdio: 1, AlwaysAllow: 64}},
		"alwaysAllow 128 characters": {stdioWithAllow(toolNames(1, 128)), mcpCounts{Stdio: 1, AlwaysAllow: 1}},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			var in *jsonv.Value
			if c.in != "" {
				in = parseMCP(t, c.in)
			}
			got, refusal := checkMCPServers(in)
			if refusal != nil {
				t.Fatalf("refused: %s: %s", refusal.Code, refusal.Message)
			}
			if got != c.want {
				t.Fatalf("counts %+v, want %+v", got, c.want)
			}
		})
	}
}

func manyStdio(n int) string {
	parts := make([]string, n)
	for i := range parts {
		parts[i] = fmt.Sprintf(`{"name":"s%d","command":"c","args":[],"env":[]}`, i)
	}
	return "[" + strings.Join(parts, ",") + "]"
}

// toolNames is a JSON array of n tool names, each length characters long.
func toolNames(n, length int) string {
	names := make([]string, n)
	for i := range names {
		names[i] = `"` + strings.Repeat("t", length) + `"`
	}
	return "[" + strings.Join(names, ",") + "]"
}

// stdioWithAllow is a list of one stdio entry whose alwaysAllow is the JSON value list.
func stdioWithAllow(list string) string {
	return `[{"name":"a","command":"c","args":[],"env":[],"alwaysAllow":` + list + `}]`
}

func TestCheckMCPServersRefuses(t *testing.T) {
	cases := map[string]struct {
		in   string
		code string // the audit reason
	}{
		"not an array":               {`{"name":"a"}`, "shape"},
		"entry not an object":        {`["x"]`, "shape"},
		"33 entries":                 {manyStdio(33), "too_many"},
		"unknown type":               {`[{"type":"sse","name":"a","url":"https://x.example/sse","headers":[]}]`, "type"},
		"type not a string":          {`[{"type":5,"name":"a"}]`, "type"},
		"empty name":                 {`[{"name":"","command":"c","args":[],"env":[]}]`, "name"},
		"blank name":                 {`[{"name":"   ","command":"c","args":[],"env":[]}]`, "name"},
		"missing name":               {`[{"command":"c","args":[],"env":[]}]`, "name"},
		"duplicate name":             {`[{"name":"a","command":"c","args":[],"env":[]},{"name":"a","command":"d","args":[],"env":[]}]`, "duplicate"},
		"alwaysAllow null":           {`[{"name":"a","command":"c","args":[],"env":[],"alwaysAllow":null}]`, "alwaysAllow"},
		"alwaysAllow not array":      {stdioWithAllow(`"search"`), "alwaysAllow"},
		"alwaysAllow object":         {stdioWithAllow(`{"t":1}`), "alwaysAllow"},
		"alwaysAllow non-string":     {stdioWithAllow(`["t",1]`), "alwaysAllow"},
		"alwaysAllow bool in http":   {`[{"type":"http","name":"a","url":"https://x.example/mcp","headers":[],"alwaysAllow":[true]}]`, "alwaysAllow"},
		"alwaysAllow null entry":     {stdioWithAllow(`[null]`), "alwaysAllow"},
		"alwaysAllow empty name":     {stdioWithAllow(`[""]`), "alwaysAllow"},
		"alwaysAllow blank name":     {stdioWithAllow(`["  "]`), "alwaysAllow"},
		"alwaysAllow 65 names":       {stdioWithAllow(toolNames(65, 4)), "alwaysAllow"},
		"alwaysAllow 129 characters": {stdioWithAllow(toolNames(1, 129)), "alwaysAllow"},
		"stdio no command":           {`[{"name":"a","args":[],"env":[]}]`, "command"},
		"stdio empty command":        {`[{"name":"a","command":"","args":[],"env":[]}]`, "command"},
		"args not strings":           {`[{"name":"a","command":"c","args":[1],"env":[]}]`, "args"},
		"args not array":             {`[{"name":"a","command":"c","args":"x","env":[]}]`, "args"},
		"env no value":               {`[{"name":"a","command":"c","args":[],"env":[{"name":"K"}]}]`, "env"},
		"env value not string":       {`[{"name":"a","command":"c","args":[],"env":[{"name":"K","value":1}]}]`, "env"},
		"env empty name":             {`[{"name":"a","command":"c","args":[],"env":[{"name":"","value":"v"}]}]`, "env"},
		"env not array":              {`[{"name":"a","command":"c","args":[],"env":{}}]`, "env"},
		"http no url":                {`[{"type":"http","name":"a","headers":[]}]`, "url"},
		"http ftp url":               {`[{"type":"http","name":"a","url":"ftp://x.example/mcp","headers":[]}]`, "url"},
		"http plain to lan":          {`[{"type":"http","name":"a","url":"http://192.168.1.5:8080/mcp","headers":[]}]`, "url"},
		"http plain to name":         {`[{"type":"http","name":"a","url":"http://mcp.example.com/mcp","headers":[]}]`, "url"},
		"http no host":               {`[{"type":"http","name":"a","url":"https:///mcp","headers":[]}]`, "url"},
		"headers not array":          {`[{"type":"http","name":"a","url":"https://x.example/mcp","headers":{}}]`, "headers"},
		"header empty name":          {`[{"type":"http","name":"a","url":"https://x.example/mcp","headers":[{"name":"","value":"v"}]}]`, "headers"},
		"unknown key stdio":          {`[{"name":"a","command":"c","args":[],"env":[],"cwd":"/"}]`, "field"},
		"unknown key http":           {`[{"type":"http","name":"a","url":"https://x.example/mcp","headers":[],"command":"c"}]`, "field"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			_, refusal := checkMCPServers(parseMCP(t, c.in))
			if refusal == nil {
				t.Fatalf("accepted %s", c.in)
			}
			if refusal.Code != c.code {
				t.Fatalf("code %q (%s), want %q", refusal.Code, refusal.Message, c.code)
			}
		})
	}
}

// D-089: a refused alwaysAllow entry names the position and the rule, never the tool name.
func TestCheckMCPServersAlwaysAllowRefusalHoldsNoName(t *testing.T) {
	long := "TOOLSECRET" + strings.Repeat("x", 128)
	_, refusal := checkMCPServers(parseMCP(t, stdioWithAllow(`["`+long+`"]`)))
	if refusal == nil || refusal.Code != "alwaysAllow" {
		t.Fatalf("an over-long name must be refused under alwaysAllow: %+v", refusal)
	}
	if strings.Contains(refusal.Message, "TOOLSECRET") || !strings.Contains(refusal.Message, "alwaysAllow[0]") {
		t.Fatalf("refusal message: %q", refusal.Message)
	}
}

// A refusal names the entry and the field, never a value (D-086: no args, env or header values in logs).
func TestCheckMCPServersRefusalHoldsNoValue(t *testing.T) {
	in := `[{"name":"a","command":"SECRETCMD","args":["SECRETARG"],"env":[{"name":"K","value":"SECRETENV"}],"headers":[{"name":"X","value":"SECRETHDR"}],"cwd":"/"}]`
	_, refusal := checkMCPServers(parseMCP(t, in))
	if refusal == nil {
		t.Fatal("an unknown key must be refused")
	}
	if strings.Contains(refusal.Message, "SECRET") || strings.Contains(refusal.Code, "SECRET") {
		t.Fatalf("refusal leaks a value: %q", refusal.Message)
	}
}

func TestMCPKeptDefaultsToEmptyArray(t *testing.T) {
	if got := string(mcpKept(parseMCP(t, `{"sessionId":"s"}`)).Marshal()); got != "[]" {
		t.Fatalf("no list sent: kept %s, want []", got)
	}
	list := `[{"name":"a","command":"c","args":[],"env":[]}]`
	if got := string(mcpKept(parseMCP(t, `{"mcpServers":`+list+`}`)).Marshal()); got != list {
		t.Fatalf("kept %s, want the list as sent", got)
	}
}
