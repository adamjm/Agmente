package server

import "acpcode/gateway/internal/config"

// withRunner gives cfg one runner with id "default", which is its default. The tests written before
// multi-runner use it to keep their single agent.
func withRunner(cfg *config.Config, command, env []string, image string) *config.Config {
	cfg.Runners = []config.AgentRunner{{ID: "default", Name: "default", Command: command, EnvPassthrough: env, Image: image}}
	cfg.DefaultRunner = "default"
	return cfg
}

// withImage sets the image of cfg's default runner.
func withImage(cfg *config.Config, image string) {
	cfg.Runners[0].Image = image
}
