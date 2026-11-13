package server

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/store"
)

// A project whose runner the config no longer lists stops the start, naming the project. The gateway
// never moves it to another agent.
func TestPrepareRunnersRefusesAProjectWhoseRunnerIsGone(t *testing.T) {
	db, err := store.Open(filepath.Join(t.TempDir(), "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	created := time.Now().UTC().Format(time.RFC3339)
	if err := db.CreateProject(ctx, store.Project{ID: "eeeeeeeeeeee", Name: "retired", Path: "/r/e", Created: created, Runner: "retired-agent"}); err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{Runners: []config.AgentRunner{{ID: "bob"}}, DefaultRunner: "bob"}
	err = PrepareRunners(ctx, cfg, db)
	if err == nil || !strings.Contains(err.Error(), "eeeeeeeeeeee") || !strings.Contains(err.Error(), "retired-agent") {
		t.Fatalf("PrepareRunners = %v, want an error naming the project and its runner", err)
	}
}

func TestPrepareRunnersGivesOldProjectsTheDefaultAndKeepsThem(t *testing.T) {
	db, err := store.Open(filepath.Join(t.TempDir(), "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	if err := db.CreateProject(ctx, store.Project{ID: "ffffffffffff", Name: "old", Path: "/r/f", Created: time.Now().UTC().Format(time.RFC3339)}); err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{Runners: []config.AgentRunner{{ID: "bob"}, {ID: "omp"}}, DefaultRunner: "bob"}
	if err := PrepareRunners(ctx, cfg, db); err != nil {
		t.Fatalf("PrepareRunners: %v", err)
	}
	// A later start with another default must not move the project: its runner was fixed at creation.
	cfg.DefaultRunner = "omp"
	if err := PrepareRunners(ctx, cfg, db); err != nil {
		t.Fatalf("second PrepareRunners: %v", err)
	}
	p, err := db.ProjectByID(ctx, "ffffffffffff")
	if err != nil || p == nil || p.Runner != "bob" {
		t.Fatalf("project runner = %+v, %v; want bob, kept across starts", p, err)
	}
}

func TestAgentForRefusesAnUnknownRunnerInsteadOfFallingBack(t *testing.T) {
	cfg := &config.Config{Runners: []config.AgentRunner{{ID: "bob", Command: []string{"bob", "acp"}}}, DefaultRunner: "bob"}
	if a, err := agentFor(cfg, store.Project{Runner: "gone"}); err == nil {
		t.Fatalf("agentFor returned %+v for an unknown runner; it must refuse", a)
	}
	if a, err := agentFor(cfg, store.Project{}); err != nil || a.ID != "bob" {
		t.Fatalf("a project with no runner gets the default: %+v, %v", a, err)
	}
}
