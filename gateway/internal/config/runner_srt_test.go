package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const srtAgent = `"agent": {"command": ["bob", "acp"], "envPassthrough": ["PATH", "HOME"]},`

func srtRunnerBlock(body string) string {
	return srtAgent + `"runner": {"kind": "srt", ` + body + `}`
}

func TestSRTRunnerBlockIsRead(t *testing.T) {
	cfg, err := runnersConfig(t, srtRunnerBlock(`"srt": "/opt/homebrew/bin/srt", "allowedDomains": ["*.example.com", "api.example.com:443", "*.example.com"], "allowRead": ["/opt/homebrew"], "weakerNetworkIsolation": true`), "")
	if err != nil {
		t.Fatalf("valid srt config refused: %v", err)
	}
	r := cfg.Runner
	if r.Kind != "srt" || r.SRT != "/opt/homebrew/bin/srt" || !r.WeakerNetworkIsolation {
		t.Fatalf("runner = %+v", r)
	}
	if strings.Join(r.AllowedDomains, " ") != "*.example.com api.example.com:443" {
		t.Fatalf("allowedDomains = %v, want the duplicate dropped", r.AllowedDomains)
	}
	if strings.Join(r.AllowRead, " ") != "/opt/homebrew" {
		t.Fatalf("allowRead = %v", r.AllowRead)
	}
	if cfg.Runners[0].Image != "" {
		t.Fatalf("an srt runner has no image: %q", cfg.Runners[0].Image)
	}
}

func TestSRTWeakerNetworkIsolationIsOffByDefault(t *testing.T) {
	cfg, err := runnersConfig(t, srtRunnerBlock(`"srt": "/opt/homebrew/bin/srt", "allowedDomains": ["example.com"]`), "")
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Runner.WeakerNetworkIsolation {
		t.Fatal("weaker network isolation must be opt-in")
	}
}

func TestSRTAllowLocalBindingIsOffByDefaultAndParsed(t *testing.T) {
	cfg, err := runnersConfig(t, srtRunnerBlock(`"srt": "/opt/homebrew/bin/srt", "allowedDomains": ["example.com"]`), "")
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Runner.AllowLocalBinding {
		t.Fatal("local binding must be opt-in")
	}
	cfg, err = runnersConfig(t, srtRunnerBlock(`"srt": "/opt/homebrew/bin/srt", "allowedDomains": ["example.com"], "allowLocalBinding": true`), "")
	if err != nil || !cfg.Runner.AllowLocalBinding {
		t.Fatalf("allowLocalBinding true: %v %+v", err, cfg.Runner)
	}
}

func TestSRTRunnerBlockRefusesBadValues(t *testing.T) {
	cases := []struct{ name, body, want string }{
		{"no srt path", `"allowedDomains": ["example.com"]`, "runner.srt must be an absolute path"},
		{"relative srt path", `"srt": "srt", "allowedDomains": ["example.com"]`, "runner.srt must be an absolute path"},
		{"srt inside the state folder", `"srt": "/tmp/acp-test-state/bin/srt", "allowedDomains": ["example.com"]`, "outside the project roots and the state folder"},
		{"srt inside a project root", `"srt": "/tmp/acp-test-root/node_modules/.bin/srt", "allowedDomains": ["example.com"]`, "outside the project roots and the state folder"},
		{"no domains", `"srt": "/opt/homebrew/bin/srt"`, "runner.allowedDomains must list"},
		{"empty domains", `"srt": "/opt/homebrew/bin/srt", "allowedDomains": []`, "runner.allowedDomains must list"},
		{"bare star", `"srt": "/opt/homebrew/bin/srt", "allowedDomains": ["*"]`, "allowedDomains[0]"},
		{"ip literal", `"srt": "/opt/homebrew/bin/srt", "allowedDomains": ["10.0.0.1"]`, "allowedDomains[0]"},
		{"scheme", `"srt": "/opt/homebrew/bin/srt", "allowedDomains": ["https://example.com"]`, "allowedDomains[0]"},
		{"uppercase", `"srt": "/opt/homebrew/bin/srt", "allowedDomains": ["Example.com"]`, "allowedDomains[0]"},
		{"relative allowRead", `"srt": "/opt/homebrew/bin/srt", "allowedDomains": ["example.com"], "allowRead": ["lib"]`, "allowRead[0]"},
		{"root allowRead", `"srt": "/opt/homebrew/bin/srt", "allowedDomains": ["example.com"], "allowRead": ["/"]`, "allowRead[0]"},
		{"glob allowRead", `"srt": "/opt/homebrew/bin/srt", "allowedDomains": ["example.com"], "allowRead": ["/opt/*"]`, "allowRead[0]"},
		{"unknown key", `"srt": "/opt/homebrew/bin/srt", "allowedDomains": ["example.com"], "image": "x"`, "runner.image is not a known key"},
		{"local binding not a bool", `"srt": "/opt/homebrew/bin/srt", "allowedDomains": ["example.com"], "allowLocalBinding": "yes"`, "allowLocalBinding must be true or false"},
		{"weaker not a bool", `"srt": "/opt/homebrew/bin/srt", "allowedDomains": ["example.com"], "weakerNetworkIsolation": "yes"`, "weakerNetworkIsolation must be true or false"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := runnersConfig(t, srtRunnerBlock(c.body), "")
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("error = %v, want it to contain %q", err, c.want)
			}
		})
	}
}

func TestSRTPathThroughASymlinkIntoTheStateFolderIsRefused(t *testing.T) {
	state := t.TempDir()
	link := filepath.Join(t.TempDir(), "srt")
	if err := os.MkdirAll(filepath.Join(state, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(state, "bin", "srt")
	if err := os.WriteFile(target, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	cfg := `"agent": {"command": ["bob", "acp"], "envPassthrough": ["PATH"]},
	  "runner": {"kind": "srt", "srt": "` + link + `", "allowedDomains": ["example.com"]}`
	_, err := runnersConfigIn(t, cfg, state)
	if err == nil || !strings.Contains(err.Error(), "outside the project roots and the state folder") {
		t.Fatalf("a link into the state folder: %v", err)
	}
}

func TestWithin(t *testing.T) {
	for _, c := range []struct {
		path, dir string
		want      bool
	}{
		{"/a/b", "/a", true}, {"/a", "/a", true}, {"/ab", "/a", false}, {"/a/../b", "/a", false}, {"/b/a", "/a", false},
	} {
		if got := Within(c.path, c.dir); got != c.want {
			t.Errorf("Within(%q, %q) = %v, want %v", c.path, c.dir, got, c.want)
		}
	}
}
