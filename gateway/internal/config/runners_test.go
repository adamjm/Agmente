package config

import (
	"strings"
	"testing"

	"acpcode/gateway/internal/jsonv"
)

// runnersConfig validates a config whose agents are given as JSON text: `agents` is the body of the
// runners (or agent) member and `extra` is more members. The rest is a minimal valid config.
func runnersConfig(t *testing.T, members, extra string) (*Config, error) {
	t.Helper()
	block := `{
	  "listen": {"host": "127.0.0.1", "port": 8788},
	  "tokens": [{"id": "phone", "identity": "owner", "sha256": "` + strings.Repeat("a", 64) + `"}],
	  "projects": {"roots": ["/tmp/acp-test-root"]},
	  "stateDir": "/tmp/acp-test-state",
	  ` + members + extra + `
	}`
	raw, err := jsonv.Parse([]byte(block))
	if err != nil {
		t.Fatalf("parse test config: %v", err)
	}
	return Validate(raw)
}

const twoRunners = `
	  "runner": {"kind": "apple", "container": "/opt/homebrew/bin/container"},
	  "runners": {
	    "bob": {"command": ["bob", "acp"], "envPassthrough": ["PATH", "BOB_API_KEY"], "image": "acpcode-bob:2.0.9"},
	    "omp": {"name": "oh-my-pi", "command": ["omp", "acp"], "envPassthrough": ["PATH", "OMLX_API_KEY"], "image": "acpcode-omp:18.2.3"}
	  },
	  "defaultRunner": "bob"`

func TestRunnersTwoAgentsEachWithItsOwnCommandImageAndEnvironment(t *testing.T) {
	cfg, err := runnersConfig(t, twoRunners, "")
	if err != nil {
		t.Fatalf("valid two-runner config refused: %v", err)
	}
	if cfg.DefaultRunner != "bob" {
		t.Fatalf("default runner = %q, want bob", cfg.DefaultRunner)
	}
	def, ok := cfg.Agent("")
	if !ok || def.ID != "bob" || def.Image != "acpcode-bob:2.0.9" || strings.Join(def.Command, " ") != "bob acp" {
		t.Fatalf("default runner = %+v, want bob with its image and command", def)
	}
	omp, ok := cfg.Agent("omp")
	if !ok || omp.Name != "oh-my-pi" || omp.Image != "acpcode-omp:18.2.3" || strings.Join(omp.Command, " ") != "omp acp" {
		t.Fatalf("omp runner = %+v", omp)
	}
	if strings.Join(omp.EnvPassthrough, ",") != "PATH,OMLX_API_KEY" {
		t.Fatalf("omp env passthrough = %v: each runner keeps its own names", omp.EnvPassthrough)
	}
	if _, ok := cfg.Agent("missing"); ok {
		t.Fatal("an id that is not configured must not resolve")
	}
}

func TestRunnerNameDefaultsToTheIDAndOneRunnerNeedsNoDefault(t *testing.T) {
	cfg, err := runnersConfig(t, `
	  "runner": {"kind": "host", "allowHost": true},
	  "runners": {"solo": {"command": ["/bin/true"]}}`, "")
	if err != nil {
		t.Fatalf("one runner needs no defaultRunner: %v", err)
	}
	solo, _ := cfg.Agent("")
	if solo.ID != "solo" || solo.Name != "solo" || cfg.DefaultRunner != "solo" {
		t.Fatalf("one runner = %+v default %q", solo, cfg.DefaultRunner)
	}
}

func TestSingleAgentConfigBecomesOneRunnerWithIDDefault(t *testing.T) {
	cfg, err := runnersConfig(t, `
	  "agent": {"command": ["bob", "acp"], "envPassthrough": ["PATH", "BOB_API_KEY"]},
	  "runner": {"kind": "apple", "image": "acpcode-bob:2.0.9", "container": "/opt/homebrew/bin/container"}`, "")
	if err != nil {
		t.Fatalf("the single-agent form must still load: %v", err)
	}
	if len(cfg.Runners) != 1 || cfg.DefaultRunner != "default" {
		t.Fatalf("runners = %+v default %q, want one runner named default", cfg.Runners, cfg.DefaultRunner)
	}
	if cfg.Runners[0].Image != "acpcode-bob:2.0.9" || strings.Join(cfg.Runners[0].Command, " ") != "bob acp" {
		t.Fatalf("single runner = %+v", cfg.Runners[0])
	}
}

func TestRunnersConfigRefusesBadAgents(t *testing.T) {
	cases := []struct {
		name, members, extra, want string
	}{
		{"agent and runners together", `"runners": {"bob": {"command": ["bob", "acp"], "image": "i"}}, "agent": {"command": ["bob", "acp"]}, "runner": {"kind": "apple", "container": "/opt/homebrew/bin/container"}`, "", "use either runners or agent"},
		{"runner.image beside runners", `"runners": {"bob": {"command": ["bob", "acp"], "image": "i"}}, "runner": {"kind": "apple", "image": "i", "container": "/opt/homebrew/bin/container"}`, "", "runner.image moves into each runners entry"},
		{"more than one runner and no default", `"runners": {"bob": {"command": ["bob", "acp"], "image": "i"}, "omp": {"command": ["omp", "acp"], "image": "j"}}, "runner": {"kind": "apple", "container": "/opt/homebrew/bin/container"}`, "", "defaultRunner is required"},
		{"default names no runner", `"runners": {"bob": {"command": ["bob", "acp"], "image": "i"}}, "defaultRunner": "omp", "runner": {"kind": "apple", "container": "/opt/homebrew/bin/container"}`, "", "defaultRunner must be the id"},
		{"bad id", `"runners": {"Bob_1": {"command": ["bob", "acp"], "image": "i"}}, "runner": {"kind": "apple", "container": "/opt/homebrew/bin/container"}`, "", "must match"},
		{"image missing for a container runner", `"runners": {"bob": {"command": ["bob", "acp"], "image": "i"}, "omp": {"command": ["omp", "acp"]}}, "defaultRunner": "bob", "runner": {"kind": "apple", "container": "/opt/homebrew/bin/container"}`, "", "runners.omp.image must name the project image"},
		{"shell string command", `"runners": {"bob": {"command": "bob acp", "image": "i"}}, "runner": {"kind": "apple", "container": "/opt/homebrew/bin/container"}`, "", "runners.bob.command must be a non-empty array"},
		{"secrets file inside a runner", `"runners": {"bob": {"command": ["bob", "acp"], "image": "i", "secretsFile": "/tmp/x.env"}}, "runner": {"kind": "apple", "container": "/opt/homebrew/bin/container"}`, "", "secretsFile is not supported with runners"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := runnersConfig(t, c.members, c.extra)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("error = %v, want it to name %q", err, c.want)
			}
		})
	}
}
