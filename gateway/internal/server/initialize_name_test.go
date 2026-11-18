package server

import (
	"testing"

	"acpcode/gateway/internal/config"
)

// Before a runner has started, initialize answers from the built-in result. That result is Bob's, so
// the gateway must not name Bob for another default runner (the app showed "Bob v2.0.9" for omp).
func TestInitializeNamesDefaultRunnerBeforeFirstStart(t *testing.T) {
	cases := []struct {
		name      string
		runnerID  string
		runnerNm  string
		wantTitle string
	}{
		{"other agent", "omp", "Oh My Pi", "Oh My Pi"},
		{"bob keeps its title", "bob", "Bob", "Bob"},
		{"no configured name falls back to the id", "custom", "", "custom"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := &Server{
				cfg: &config.Config{
					DefaultRunner: c.runnerID,
					Runners:       []config.AgentRunner{{ID: c.runnerID, Name: c.runnerNm}},
				},
				caps: map[string][]byte{},
			}
			info := s.initializeResult().Get("agentInfo")
			if info == nil {
				t.Fatal("initialize result has no agentInfo")
			}
			title, _ := info.Get("title").StringValue()
			name, _ := info.Get("name").StringValue()
			version, _ := info.Get("version").StringValue()
			if title != c.wantTitle {
				t.Errorf("title = %q, want %q", title, c.wantTitle)
			}
			if name != c.runnerID {
				t.Errorf("name = %q, want %q", name, c.runnerID)
			}
			if version != "" {
				t.Errorf("version = %q, want empty before the agent has started", version)
			}
		})
	}
}
