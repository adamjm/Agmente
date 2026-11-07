package server

import (
	"testing"

	"agmente/gateway/internal/jsonv"
)

// 6C.2: the phone's answer to an elicitation is checked before it goes to the agent. An action
// must be accept, decline or cancel. Content, when sent, must be an object whose values are
// strings, numbers, booleans or arrays of strings; anything else is -32602.
func TestParseElicitationAnswer(t *testing.T) {
	cases := []struct {
		name, params, wantAction, wantContent string
		wantCode                              int
	}{
		{"accept with content", `{"elicitationId":"x","action":"accept","content":{"a":true,"b":1,"c":"s","d":["x","y"],"e":[]}}`, "accept", `{"a":true,"b":1,"c":"s","d":["x","y"],"e":[]}`, 0},
		{"accept without content", `{"action":"accept"}`, "accept", "", 0},
		{"decline", `{"action":"decline"}`, "decline", "", 0},
		{"cancel", `{"action":"cancel"}`, "cancel", "", 0},
		{"decline drops content", `{"action":"decline","content":{"a":1}}`, "decline", "", 0},
		{"missing action", `{}`, "", "", -32602},
		{"unknown action", `{"action":"Accept"}`, "", "", -32602},
		{"action not a string", `{"action":true}`, "", "", -32602},
		{"content is an array", `{"action":"accept","content":["a"]}`, "", "", -32602},
		{"content is a string", `{"action":"accept","content":"a"}`, "", "", -32602},
		{"content is null", `{"action":"accept","content":null}`, "", "", -32602},
		{"value is an object", `{"action":"accept","content":{"a":{"b":1}}}`, "", "", -32602},
		{"value is null", `{"action":"accept","content":{"a":null}}`, "", "", -32602},
		{"array of numbers", `{"action":"accept","content":{"a":[1]}}`, "", "", -32602},
		{"nested array", `{"action":"accept","content":{"a":[["x"]]}}`, "", "", -32602},
		{"bad value under decline", `{"action":"decline","content":{"a":{}}}`, "", "", -32602},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			params, err := jsonv.Parse([]byte(c.params))
			if err != nil {
				t.Fatal(err)
			}
			action, content, rerr := parseElicitationAnswer(params)
			if c.wantCode != 0 {
				if rerr == nil || rerr.Code != c.wantCode {
					t.Fatalf("want error %d, got %v", c.wantCode, rerr)
				}
				if action != "" || content != nil {
					t.Fatalf("a refused answer returned %q and %v", action, content)
				}
				return
			}
			if rerr != nil {
				t.Fatalf("unexpected error %+v", rerr)
			}
			if action != c.wantAction {
				t.Fatalf("action %q, want %q", action, c.wantAction)
			}
			got := ""
			if content != nil {
				got = string(content.Marshal())
			}
			if got != c.wantContent {
				t.Fatalf("content %q, want %q", got, c.wantContent)
			}
		})
	}
	if _, _, rerr := parseElicitationAnswer(nil); rerr == nil || rerr.Code != -32602 {
		t.Fatalf("nil params: want -32602, got %v", rerr)
	}
}
