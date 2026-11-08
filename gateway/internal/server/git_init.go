package server

// Git at project creation (D-105, v1): `_acpcode/projects/create` with createFolder true may run
// `git init` in the new folder and add an https origin. Nothing is fetched or pushed here. Every
// check runs before the folder is made; a failure after that removes the folder and any .git.

import (
	"context"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"unicode"

	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

const maxGitRemote = 2048

// gitOptions are the optional git fields of a create request.
type gitOptions struct {
	init         bool
	remote       string // "" when none
	credentialID string // "" when none
}

// any reports whether the request asked for anything git.
func (g gitOptions) any() bool { return g.init || g.remote != "" || g.credentialID != "" }

// gitInitResult is the `git` field of the create result. Branch is "" while the repository has no
// commits (unborn), and Unborn says so; a detached HEAD is not reported as unborn.
type gitInitResult struct {
	Initialized bool    `json:"initialized"`
	Remote      *string `json:"remote"`
	Branch      string  `json:"branch"`
	Unborn      bool    `json:"unborn"`
}

// parseGitOptions reads gitInit, gitRemote and credentialId. Their combinations are checked by the
// caller, which knows whether the request makes a new folder.
func parseGitOptions(params *jsonv.Value) (gitOptions, *rpcError) {
	var g gitOptions
	if v := params.Get("gitInit"); !v.IsNull() {
		if v.Kind != jsonv.Bool {
			return g, invalidParams("gitInit must be true or false")
		}
		g.init = v.B
	}
	if v := params.Get("gitRemote"); !v.IsNull() {
		s, ok := v.StringValue()
		if !ok || s == "" {
			return g, invalidParams("gitRemote must be a non-empty string, or left out")
		}
		g.remote = s
	}
	if v := params.Get("credentialId"); !v.IsNull() {
		s, ok := v.StringValue()
		if !ok || !credentialIDPattern.MatchString(s) {
			return g, invalidParams("credentialId must be a credential id from git/credentials/list")
		}
		g.credentialID = s
	}
	return g, nil
}

// checkGitRemote applies the remote rules (D-105) and returns the host. Only https, no user name
// or password, no port, no query or fragment, a repository path, and a host on the allow-list.
// The message names the rule and never echoes the URL.
func checkGitRemote(raw string, hosts []string) (string, *rpcError) {
	bad := func(msg string) (string, *rpcError) { return "", invalidParams("gitRemote %s", msg) }
	if len(raw) > maxGitRemote {
		return bad("must be at most 2048 characters")
	}
	for _, r := range raw {
		if r > 0x7f || r <= ' ' || r == 0x7f || unicode.IsSpace(r) {
			return bad("must be ASCII with no spaces or control characters")
		}
	}
	if !strings.HasPrefix(raw, "https://") {
		return bad("must be an https:// URL")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Opaque != "" || u.Host == "" {
		return bad("must be a valid https:// URL with a host")
	}
	if u.User != nil || strings.Contains(u.Host, "@") {
		return bad("must not contain a user name or password; choose a credential instead")
	}
	if u.Port() != "" || strings.Contains(u.Host, ":") {
		return bad("must not name a port")
	}
	if u.RawQuery != "" || u.Fragment != "" || strings.Contains(raw, "#") || strings.Contains(raw, "?") {
		return bad("must not have a query or a fragment")
	}
	if u.Path == "" || u.Path == "/" || strings.HasSuffix(u.Path, "/") || strings.Contains(raw, "..") {
		return bad("must name a repository path, such as https://github.com/owner/repo.git")
	}
	host := strings.ToLower(u.Hostname())
	for _, h := range hosts {
		if h == host {
			return host, nil
		}
	}
	return bad("host is not on the gateway's allow-list (git.hosts)")
}

// gitHosts is the allow-list in use: the configured one, or the default when none is set.
func (s *Server) gitHosts() []string {
	if len(s.cfg.GitHosts) == 0 {
		return append([]string(nil), defaultGitHosts...)
	}
	return s.cfg.GitHosts
}

var defaultGitHosts = []string{"github.com"}

// checkGitOptions applies the rules that depend on each other and on stored state. It runs before
// any folder is made. It returns the remote's host ("" without a remote).
func (s *Server) checkGitOptions(ctx context.Context, g gitOptions, createFolder bool) (string, *rpcError) {
	if !createFolder {
		if g.any() {
			return "", invalidParams("gitInit, gitRemote and credentialId need createFolder: true (D-105)")
		}
		return "", nil
	}
	if g.remote != "" && !g.init {
		return "", invalidParams("gitRemote needs gitInit: true")
	}
	if g.credentialID != "" && g.remote == "" {
		return "", invalidParams("credentialId needs gitRemote")
	}
	if g.remote == "" {
		return "", nil
	}
	host, rerr := checkGitRemote(g.remote, s.gitHosts())
	if rerr != nil {
		return "", rerr
	}
	if g.credentialID != "" {
		cred, err := s.store.GitCredentialByID(ctx, g.credentialID)
		if err != nil {
			return "", &rpcError{Code: rpcInternal, Message: "cannot read the credentials"}
		}
		if cred == nil {
			return "", invalidParams("unknown credential")
		}
		if cred.Host != host {
			return "", invalidParams("the credential is for %s, not %s", cred.Host, host)
		}
	}
	return host, nil
}

// gitInitFolder runs `git init -b main` and, with a remote, `git remote add origin` in the new
// folder, through the runner (one-off, --network none, D-034). It does not fetch or push.
func (s *Server) gitInitFolder(ctx context.Context, p store.Project, g gitOptions) (*gitInitResult, *rpcError) {
	steps := [][]string{{"init", "-q", "-b", "main"}}
	if g.remote != "" {
		steps = append(steps, []string{"remote", "add", "origin", g.remote})
	}
	for _, args := range steps {
		if _, err := s.runGit(ctx, p, nil, nil, args...); err != nil {
			return nil, &rpcError{Code: rpcInternal, Message: "cannot create the Git repository; nothing was created"}
		}
	}
	res := &gitInitResult{Initialized: true, Branch: "", Unborn: true}
	if g.remote != "" {
		remote := g.remote
		res.Remote = &remote
	}
	return res, nil
}

// rollbackNewFolder undoes a folder creation that failed after the folder was made: the .git this
// call made (when gitMade), the folder if it is still empty, and the project home if one was
// started. A file or link at the name is never removed (D-099).
func rollbackNewFolder(dir *os.Root, name, home string, gitMade bool) {
	if gitMade {
		_ = dir.RemoveAll(filepath.Join(name, ".git"))
	}
	removeOwnFolder(dir, name)
	_ = os.RemoveAll(home)
}
