package server

import (
	"context"
	"fmt"
	"strings"

	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/store"
)

// PrepareRunners makes the stored projects agree with the config, once, when the gateway starts.
// A project with no runner (made before multi-runner) gets the config's default, and keeps it. A
// project whose runner is no longer in the config stops the start with an error that names it:
// the gateway never moves a project to another agent.
func PrepareRunners(ctx context.Context, cfg *config.Config, db *store.Store) error {
	if _, err := db.AssignUnsetRunners(ctx, cfg.DefaultRunner); err != nil {
		return fmt.Errorf("assign runners: %w", err)
	}
	ps, err := db.Projects(ctx)
	if err != nil {
		return fmt.Errorf("read projects: %w", err)
	}
	var missing []string
	for _, p := range ps {
		if _, ok := cfg.Agent(p.Runner); !ok {
			missing = append(missing, fmt.Sprintf("%s (runner %q)", p.ID, p.Runner))
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("projects use a runner that is not in the config: %s. Add the runner back to runners, or remove the project", strings.Join(missing, ", "))
	}
	return nil
}
