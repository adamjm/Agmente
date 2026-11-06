// Command agmente-gateway is the authenticated ACP gateway (SPEC 6.4).
//
//	agmente-gateway --config <file> [--dry-run]
//	agmente-gateway new-token <device-id> <identity>
package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/config"
	"agmente/gateway/internal/server"
	"agmente/gateway/internal/store"
)

const usage = "Usage: agmente-gateway --config <file> [--dry-run]\n       agmente-gateway new-token <device-id> <identity>\n"

func main() {
	if len(os.Args) > 1 && os.Args[1] == "new-token" {
		os.Exit(newToken(os.Args[2:], os.Stdout, os.Stderr))
	}
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	fs := flag.NewFlagSet("agmente-gateway", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	configPath := fs.String("config", "", "config file")
	dryRun := fs.Bool("dry-run", false, "validate the config, print a summary and exit")
	if err := fs.Parse(args); err != nil || *configPath == "" || fs.NArg() > 0 {
		fmt.Fprint(os.Stderr, usage)
		return 2
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		return 1
	}
	if *dryRun {
		return printSummary(cfg)
	}

	db, err := store.Open(filepath.Join(cfg.StateDir, "gateway.db"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot open the database in %s: %v\n", cfg.StateDir, err)
		return 1
	}
	defer db.Close()

	logger := audit.New(os.Stderr)
	srv := server.New(cfg, logger, db)
	ln, err := srv.Listen()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot listen: %v\n", err)
		return 1
	}
	logger.Log("listening", audit.Fields{Reason: ln.Addr().String()})

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	served := make(chan error, 1)
	go func() { served <- srv.Serve(ln) }()
	select {
	case sig := <-signals:
		name := "SIGTERM"
		if sig == syscall.SIGINT {
			name = "SIGINT"
		}
		logger.Log("shutdown", audit.Fields{Signal: name})
		srv.Shutdown()
		return 0
	case err := <-served:
		fmt.Fprintf(os.Stderr, "server stopped: %v\n", err)
		return 1
	}
}

// printSummary prints the config without token hashes.
func printSummary(cfg *config.Config) int {
	tokens := make([]string, 0, len(cfg.Tokens))
	for _, t := range cfg.Tokens {
		tokens = append(tokens, fmt.Sprintf("%s (%s)", t.ID, t.Identity))
	}
	roots := make([]string, 0, len(cfg.Roots))
	for _, r := range cfg.Roots {
		if _, err := os.Stat(r); errors.Is(err, os.ErrNotExist) {
			r += " (missing: no cwd will be allowed)"
		}
		roots = append(roots, r)
	}
	summary := struct {
		Listen         string        `json:"listen"`
		Runner         config.Runner `json:"runner"`
		TrustProxy     bool          `json:"trustProxy"`
		Tokens         []string      `json:"tokens"`
		AgentCommand   string        `json:"agentCommand"`
		EnvPassthrough []string      `json:"envPassthrough"`
		Roots          []string      `json:"roots"`
		StateDir       string        `json:"stateDir"`
		Limits         config.Limits `json:"limits"`
	}{
		Listen:         fmt.Sprintf("%s:%d", cfg.ListenHost, cfg.ListenPort),
		Runner:         cfg.Runner,
		TrustProxy:     cfg.TrustProxy,
		Tokens:         tokens,
		AgentCommand:   strings.Join(cfg.AgentCommand, " "),
		EnvPassthrough: append([]string{}, cfg.EnvPassthrough...),
		Roots:          roots,
		StateDir:       cfg.StateDir,
		Limits:         cfg.Limits,
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(summary); err != nil {
		return 1
	}
	fmt.Fprintln(os.Stdout, "Config OK (dry run).")
	return 0
}

// newToken prints a new random token once, and the config entry that holds only its hash.
func newToken(args []string, stdout, stderr io.Writer) int {
	if len(args) != 2 || args[0] == "" || args[1] == "" {
		fmt.Fprint(stderr, "Usage: agmente-gateway new-token <device-id> <identity>\n")
		return 2
	}
	raw := make([]byte, 32) // 256 bits
	if _, err := rand.Read(raw); err != nil {
		fmt.Fprintf(stderr, "cannot read random bytes: %v\n", err)
		return 1
	}
	token := base64.RawURLEncoding.EncodeToString(raw)
	entry, _ := json.Marshal(struct {
		ID       string `json:"id"`
		Identity string `json:"identity"`
		SHA256   string `json:"sha256"`
	}{args[0], args[1], server.HashToken(token)})
	fmt.Fprintln(stderr, "Copy the token into the app now. It is not stored anywhere and is shown once.")
	fmt.Fprintf(stdout, "token: %s\n", token)
	fmt.Fprintf(stdout, "config entry: %s\n", entry)
	return 0
}
