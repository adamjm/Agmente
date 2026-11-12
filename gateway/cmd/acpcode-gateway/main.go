// Command acpcode-gateway is the authenticated ACP gateway (SPEC 6.4).
//
//	acpcode-gateway --config <file> [--dry-run]
//	acpcode-gateway new-token <device-id> <identity> [--scope full|intent|connector]
//	acpcode-gateway --config <file> revoke-token <device-id>
//	acpcode-gateway --config <file> mcp-server list|put|delete [id]   (the gateway's MCP list, D-107)
package main

import (
	"context"
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
	"slices"
	"strconv"
	"strings"
	"syscall"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/push"
	"acpcode/gateway/internal/server"
	"acpcode/gateway/internal/store"
)

const usage = "Usage: acpcode-gateway --config <file> [--dry-run]\n       acpcode-gateway new-token <device-id> <identity> [--scope full|intent|connector]\n       acpcode-gateway --config <file> revoke-token <device-id>\n"

// pidFileName is the running gateway's process id, in the state directory. revoke-token signals it.
const pidFileName = "gateway.pid"

func main() {
	if len(os.Args) > 1 && os.Args[1] == "new-token" {
		os.Exit(newToken(os.Args[2:], os.Stdout, os.Stderr))
	}
	if len(os.Args) > 3 && os.Args[1] == "--config" && os.Args[3] == "revoke-token" {
		os.Exit(revokeTokenCommand(os.Args[2], os.Args[4:], os.Stdout, os.Stderr))
	}
	if len(os.Args) > 1 && os.Args[1] == "--config" && len(os.Args) > 3 && os.Args[3] == "mcp-server" {
		os.Exit(mcpServerCommand(append(os.Args[1:3:3], os.Args[4:]...), os.Stdin, os.Stdout, os.Stderr))
	}
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	fs := flag.NewFlagSet("acpcode-gateway", flag.ContinueOnError)
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
	var pushClient *push.Client
	if cfg.Push != nil {
		// Refuse to start on a key that is readable by others or cannot be parsed (PLAN 3.11).
		pushClient, err = push.NewClient(pushOptions(cfg.Push))
		if err != nil {
			fmt.Fprintf(os.Stderr, "push: %v\n", err)
			return 1
		}
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
	// A damaged revoked-token list stops the start: a revocation must never be lost silently.
	if err := srv.LoadRevoked(); err != nil {
		fmt.Fprintf(os.Stderr, "cannot read the revoked-token list: %v\n", err)
		return 1
	}
	// The default working directory is made and registered before the gateway listens (working_dir.go).
	if err := srv.EnsureWorkingDir(context.Background()); err != nil {
		fmt.Fprintf(os.Stderr, "cannot prepare the working_dir folder: %v\n", err)
		return 1
	}
	ln, err := srv.Listen()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot listen: %v\n", err)
		return 1
	}
	if pushClient != nil {
		srv.SetPush(pushClient)
		logger.Log("push_enabled", audit.Fields{})
	}
	logger.Log("listening", audit.Fields{Reason: ln.Addr().String()})

	pidPath := filepath.Join(cfg.StateDir, pidFileName)
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600); err != nil {
		logger.Log("pid_file_failed", audit.Fields{Reason: err.Error()})
	} else {
		defer os.Remove(pidPath)
	}

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	// SIGHUP reloads the revoked-token list (token_revoke.go); it does not stop the gateway.
	reloads := make(chan os.Signal, 1)
	signal.Notify(reloads, syscall.SIGHUP)
	go srv.ReloadOnSIGHUP(reloads)
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

// pushOptions maps the config's push block to the APNs client (D-053).
func pushOptions(p *config.Push) push.Options {
	return push.Options{
		KeyFile: p.KeyFile, KeyID: p.KeyID, TeamID: p.TeamID, Topic: p.Topic,
		SandboxURL: p.SandboxURL, ProductionURL: p.ProductionURL, CAFile: p.CAFile,
	}
}

// pushSummary shows the APNs settings with ids and paths only; "off" when the block is absent.
func pushSummary(p *config.Push) any {
	if p == nil {
		return "off"
	}
	o := pushOptions(p)
	sandbox, production := o.SandboxURL, o.ProductionURL
	if sandbox == "" {
		sandbox = push.DefaultSandboxURL
	}
	if production == "" {
		production = push.DefaultProductionURL
	}
	return map[string]any{
		"keyFile": p.KeyFile, "keyId": p.KeyID, "teamId": p.TeamID, "topic": p.Topic,
		"sandboxURL": sandbox, "productionURL": production, "caFile": p.CAFile,
	}
}

// printSummary prints the config without token hashes or key material (SPEC 6.4).
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
		Push           any           `json:"push"`
		Files          any           `json:"files"`
	}{
		Files:          filesSummary(cfg.Files),
		Listen:         fmt.Sprintf("%s:%d", cfg.ListenHost, cfg.ListenPort),
		Runner:         cfg.Runner,
		TrustProxy:     cfg.TrustProxy,
		Tokens:         tokens,
		AgentCommand:   strings.Join(cfg.AgentCommand, " "),
		EnvPassthrough: append([]string{}, cfg.EnvPassthrough...),
		Roots:          roots,
		StateDir:       cfg.StateDir,
		Limits:         cfg.Limits,
		Push:           pushSummary(cfg.Push),
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

// filesSummary describes the files block without its key. Nil when the feature is off.
func filesSummary(f *config.Files) any {
	if f == nil {
		return nil
	}
	out := map[string]any{"host": f.Host, "ttlSeconds": f.TTLSeconds, "maxBytes": f.MaxBytes}
	if f.SecretFile != "" {
		out["keyFile"] = f.SecretFile
	} else {
		out["key"] = "random per process"
	}
	return out
}

// newToken prints a new random token once, and the config entry that holds only its hash. The
// entry names the token's scope; full is the default.
func newToken(args []string, stdout, stderr io.Writer) int {
	const usageLine = "Usage: acpcode-gateway new-token <device-id> <identity> [--scope full|intent|connector]\n"
	scope := config.ScopeFull
	var positional []string
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--scope" && i+1 < len(args):
			scope = args[i+1]
			i++
		case strings.HasPrefix(a, "--scope="):
			scope = strings.TrimPrefix(a, "--scope=")
		case strings.HasPrefix(a, "-"):
			fmt.Fprint(stderr, usageLine)
			return 2
		default:
			positional = append(positional, a)
		}
	}
	if len(positional) != 2 || positional[0] == "" || positional[1] == "" {
		fmt.Fprint(stderr, usageLine)
		return 2
	}
	if !slices.Contains(config.TokenScopes, scope) {
		fmt.Fprintf(stderr, "--scope must be full, intent or connector (got %q)\n", scope)
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
		Scope    string `json:"scope"`
	}{positional[0], positional[1], server.HashToken(token), scope})
	fmt.Fprintln(stderr, "Copy the token into the app now. It is not stored anywhere and is shown once.")
	fmt.Fprintf(stdout, "token: %s\n", token)
	fmt.Fprintf(stdout, "config entry: %s\n", entry)
	return 0
}

// revokeTokenCommand adds a token id to the revoked-token list in the state directory, then signals
// a running gateway to reload it (SIGHUP). The token's open connections close, and its next request
// is refused. With no running gateway the list is read at the next start.
func revokeTokenCommand(configPath string, args []string, stdout, stderr io.Writer) int {
	if len(args) != 1 || args[0] == "" {
		fmt.Fprint(stderr, "Usage: acpcode-gateway --config <file> revoke-token <device-id>\n")
		return 2
	}
	id := args[0]
	cfg, err := config.Load(configPath)
	if err != nil {
		fmt.Fprintln(stderr, err.Error())
		return 1
	}
	known := false
	for _, t := range cfg.Tokens {
		known = known || t.ID == id
	}
	if !known {
		fmt.Fprintf(stderr, "no token with id %q in %s\n", id, configPath)
		return 1
	}
	ids, err := server.ReadRevokedTokens(cfg.StateDir)
	if err != nil {
		fmt.Fprintf(stderr, "cannot read the revoked-token list: %v\n", err)
		return 1
	}
	if !slices.Contains(ids, id) {
		ids = append(ids, id)
	}
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		fmt.Fprintf(stderr, "cannot create the state directory: %v\n", err)
		return 1
	}
	if err := server.WriteRevokedTokens(cfg.StateDir, ids); err != nil {
		fmt.Fprintf(stderr, "cannot write the revoked-token list: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "Revoked token %q. Its open connections close and its next request is refused.\n", id)
	if pid, ok := runningGateway(cfg.StateDir); ok {
		if err := syscall.Kill(pid, syscall.SIGHUP); err == nil {
			fmt.Fprintf(stdout, "Told the running gateway (pid %d) to reload the list.\n", pid)
			return 0
		}
	}
	fmt.Fprintln(stdout, "No running gateway was told. It reads the list at its next start, or on SIGHUP.")
	return 0
}

// runningGateway reads the pid file and reports the pid when that process is alive.
func runningGateway(stateDir string) (int, bool) {
	data, err := os.ReadFile(filepath.Join(stateDir, pidFileName))
	if err != nil {
		return 0, false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 1 {
		return 0, false
	}
	return pid, syscall.Kill(pid, 0) == nil
}
