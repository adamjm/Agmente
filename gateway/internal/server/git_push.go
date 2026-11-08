package server

// `_acpcode/git/push {projectId, credentialId, branch?, confirm: true, allowSecretFiles?}` (D-105,
// v2). The push runs in one-off containers, never the agent's. Four steps, each its own container:
//
//  1. config (no network): neutralize the repository's config keys that can run programs or
//     redirect a push, read the branch and the remotes, and record a hash of .git/config.
//  2. names (no network): every path in the pushed history, to refuse the secret names.
//  3. content (no network): the pushed tree, to refuse a private key header.
//  4. push (default network): the config hash is checked again, then one push of the commit that
//     steps 1 to 3 looked at, to the origin URL that step 1 validated. The token reaches this
//     container only as an environment variable, through a one-shot askpass helper.
//
// Nothing here forces a push: the refspec is a fast-forward or a new branch, and the remote decides.

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

// tokenEnv is the environment name that carries the token into the push container (-e NAME).
const tokenEnv = "ACPCODE_GIT_TOKEN"

// askpassScript answers git's prompts from the environment. The token is never written to a file:
// the script reads it from ACPCODE_GIT_TOKEN.
const askpassScript = `#!/bin/sh
case "$1" in
  Username*) printf '%s\n' 'x-access-token' ;;
  *) printf '%s\n' "$ACPCODE_GIT_TOKEN" ;;
esac
`

// pushNeutralize is run first in every push-path command. It unsets the repository config keys
// that can run a program or send a push somewhere else: credential helpers, ssh and askpass
// commands, git proxies, rewriting of URLs (insteadOf, pushInsteadOf), push URLs, HTTP proxies and
// extra headers, and includes. The repository's config is the one Bob can write (F-20).
const pushNeutralize = `
pattern='^(credential\..*helper|core\.sshcommand|core\.askpass|core\.gitproxy|url\..*\.(push)?insteadof|remote\..*\.pushurl|http\..*(proxy|extraheader)|include(if)?\..*)$'
keys=$(git config --local --name-only --get-regexp "$pattern" 2>/dev/null || true)
printf '%s\n' "$keys" | while IFS= read -r k; do
  if [ -n "$k" ]; then git config --local --unset-all "$k" || exit 3; fi
done
`

// pushConfigScript (step 1) prints, one per line: the hash of .git/config after neutralizing,
// HEAD's branch ref, the commit of HEAD, the commit of refs/heads/$1, and every remote key.
const pushConfigScript = `set -eu` + pushNeutralize + `
echo "hash $(git hash-object .git/config)"
echo "head $(git symbolic-ref -q HEAD || true)"
echo "headcommit $(git rev-parse --verify -q HEAD || true)"
echo "branchcommit $(git rev-parse --verify -q "refs/heads/$1" || true)"
git config --local --get-regexp '^remote\.' || true
`

// pushNamesScript (step 2) prints every path in the commit's tree and in its history, each ended by
// NUL (-z: no quoting, so a name is exactly the bytes git stored).
const pushNamesScript = `set -eu
git ls-tree -r -z --name-only "$1"
git log -m -z --format= --name-only "$1"
`

// pushContentScript (step 3) prints the paths of the tree that hold a private key header. git grep
// exits 1 when nothing matches; any other failure stops the push.
const pushContentScript = `set -eu
rc=0
git grep -I -l -z -e "$2" "$1" -- || rc=$?
[ "$rc" -le 1 ] || exit "$rc"
`

// pushScript (step 4) checks the config hash again, then pushes the commit to the origin URL. Its
// arguments: $1 config hash, $2 URL, $3 commit, $4 branch, $5 project folder.
const pushScript = `set -eu` + pushNeutralize + `
[ "$(git hash-object .git/config)" = "$1" ] || { echo 'the repository config changed during the push' >&2; exit 3; }
exec git --no-pager --no-optional-locks -c core.fsmonitor=false -c core.hooksPath=/dev/null -c "safe.directory=$5" -c credential.helper= push "$2" "$3:refs/heads/$4"
`

// privateKeyHeader is the pattern step 3 searches for.
const privateKeyHeader = `-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----`

var (
	pushBranchPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$`)
	objectIDPattern   = regexp.MustCompile(`^[0-9a-f]{40}([0-9a-f]{24})?$`)
)

const maxSecretNamesInError = 10

// validPushBranch applies the branch rules: a plain branch name, no "..", no "//", no trailing
// "/" or ".", no ".lock" ending.
func validPushBranch(b string) bool {
	return pushBranchPattern.MatchString(b) && !strings.Contains(b, "..") && !strings.Contains(b, "//") &&
		!strings.HasSuffix(b, "/") && !strings.HasSuffix(b, ".") && !strings.HasSuffix(b, ".lock")
}

// gitPush answers `_acpcode/git/push`. The reply is {branch, commit, remote}: never a token and
// never git's own text.
func (s *Server) gitPush(ctx context.Context, who audit.Who, params *jsonv.Value) (any, *rpcError) {
	if c := params.Get("confirm"); c.IsNull() || c.Kind != jsonv.Bool || !c.B {
		return nil, invalidParams("git/push needs confirm: true")
	}
	projectID, ok := params.Get("projectId").StringValue()
	if !ok || projectID == "" {
		return nil, invalidParams("projectId is required")
	}
	p, err := s.store.ProjectByID(ctx, projectID)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read projects"}
	}
	if p == nil {
		return nil, invalidParams("unknown project")
	}
	credID, ok := params.Get("credentialId").StringValue()
	if !ok || !credentialIDPattern.MatchString(credID) {
		return nil, invalidParams("credentialId is required")
	}
	branch := ""
	if v := params.Get("branch"); !v.IsNull() {
		b, ok := v.StringValue()
		if !ok || !validPushBranch(b) {
			return nil, invalidParams("branch is not a valid branch name")
		}
		branch = b
	}
	allowSecrets := false
	if v := params.Get("allowSecretFiles"); !v.IsNull() {
		if v.Kind != jsonv.Bool {
			return nil, invalidParams("allowSecretFiles must be true or false")
		}
		allowSecrets = v.B
	}
	cred, rerr := s.getCredential(ctx, credID)
	if rerr != nil {
		return nil, rerr
	}
	if cred == nil {
		return nil, invalidParams("unknown credential")
	}
	if !s.gitHostAllowed(cred.Host) {
		return nil, invalidParams("the credential's host is not on the gateway's git allow-list")
	}
	token, err := s.readCredentialToken(credID)
	if err != nil {
		return nil, &rpcError{Code: rpcServerError, Message: errNoSecret.Error()}
	}

	res, reason, rerr := s.runPush(ctx, *p, *cred, token, branch, allowSecrets)
	outcome := "pushed"
	switch {
	case rerr != nil && reason == "failed":
		outcome = "failed"
	case rerr != nil:
		outcome = "refused"
	}
	s.audit.Log("git_push", with(who, audit.Fields{Project: p.ID, Credential: cred.ID, Host: cred.Host, Reason: outcome + ":" + reason}))
	if rerr != nil {
		return nil, rerr
	}
	return res, nil
}

// pushResult is the reply of a push. Remote is the origin URL, which holds no user name or password.
type pushResult struct {
	Pushed bool   `json:"pushed"`
	Branch string `json:"branch"`
	Commit string `json:"commit"`
	Remote string `json:"remote"`
}

// runPush runs the four steps. It returns a short reason for the audit line and, on refusal or
// failure, the reply's error. The token is used only in step 4.
func (s *Server) runPush(ctx context.Context, p store.Project, cred store.GitCredential, token, branch string, allowSecrets bool) (*pushResult, string, *rpcError) {
	home := s.projectHome(p.ID)
	scratch, err := s.pushScratch()
	if err != nil {
		return nil, "failed", &rpcError{Code: rpcInternal, Message: "cannot prepare the push"}
	}
	defer os.RemoveAll(scratch)
	askpass := filepath.Join(scratch, "askpass.sh")
	if err := os.WriteFile(askpass, []byte(askpassScript), 0o700); err != nil {
		return nil, "failed", &rpcError{Code: rpcInternal, Message: "cannot prepare the push"}
	}
	plain := gitEnv(home, nil)
	// A refusal of what the request or the repository holds is -32602; a failure of the system is -32000.
	fail := func(reason string, msg string) (*pushResult, string, *rpcError) {
		code := rpcServerError
		if reason == "remote" || reason == "branch" {
			code = rpcInvalidParams
		}
		return nil, reason, &rpcError{Code: code, Message: msg}
	}
	// step 1
	out, err := s.runner.oneOff(ctx, p, home, oneOffCmd{argv: []string{"sh", "-c", pushConfigScript, "sh", branch}, vars: plain}, nil)
	if err != nil {
		return fail("failed", "cannot read the repository; nothing was pushed")
	}
	cfg := parsePushConfig(out.Out)
	if !objectIDPattern.MatchString(cfg.hash) {
		return fail("failed", "cannot read the repository; nothing was pushed")
	}
	sha := ""
	if branch == "" {
		if !strings.HasPrefix(cfg.head, "refs/heads/") {
			return fail("branch", "HEAD is detached or has no branch; name the branch to push")
		}
		branch = strings.TrimPrefix(cfg.head, "refs/heads/")
		if !validPushBranch(branch) {
			return fail("branch", "the current branch name cannot be pushed")
		}
		sha = cfg.headCommit
	} else {
		sha = cfg.branchCommit
	}
	if !objectIDPattern.MatchString(sha) {
		return fail("branch", "the branch has no commits or does not exist; nothing was pushed")
	}
	originURLs, ok := cfg.remotes["origin"]
	if !ok || len(originURLs) != 1 {
		return fail("remote", "the project needs exactly one origin URL")
	}
	origin := originURLs[0]
	hosts := s.gitHosts()
	for name, urls := range cfg.remotes {
		for _, url := range urls {
			host, rerr := checkGitRemote(url, hosts)
			if rerr != nil {
				return fail("remote", "remote "+name+" is refused: "+strings.TrimPrefix(rerr.Message, "gitRemote "))
			}
			if name == "origin" && host != cred.Host {
				return fail("remote", "origin is on a different host from the credential")
			}
		}
	}
	// step 2: every name in the pushed history
	out, err = s.runner.oneOff(ctx, p, home, oneOffCmd{argv: []string{"sh", "-c", pushNamesScript, "sh", sha}, vars: plain}, nil)
	if err != nil || out.Truncated {
		return fail("failed", "cannot list the files to push; nothing was pushed")
	}
	var hits []string
	for _, name := range nulRecords(out.Out) {
		if isSecretFor(p.DenyPaths, name) {
			hits = append(hits, name)
		}
	}
	// step 3: private key headers in the pushed tree
	out, err = s.runner.oneOff(ctx, p, home, oneOffCmd{argv: []string{"sh", "-c", pushContentScript, "sh", sha, privateKeyHeader}, vars: plain}, nil)
	if err != nil || out.Truncated {
		return fail("failed", "cannot scan the files to push; nothing was pushed")
	}
	for _, rec := range nulRecords(out.Out) {
		if _, path, ok := strings.Cut(rec, ":"); ok {
			hits = append(hits, path)
		}
	}
	hits = uniqueStrings(hits)
	if len(hits) > 0 && !allowSecrets {
		names := hits
		if len(names) > maxSecretNamesInError {
			names = names[:maxSecretNamesInError]
		}
		return nil, "secrets", &rpcError{
			Code:    rpcInvalidParams,
			Message: "refused: " + strconv.Itoa(len(hits)) + " file(s) in the push look like secrets; remove them from the history or pass allowSecretFiles: true",
			Data:    map[string]any{"files": names},
		}
	}
	if len(hits) > 0 {
		s.audit.Log("git_push_secret_override", audit.Fields{Project: p.ID, Credential: cred.ID, Reason: "allowSecretFiles", Code: len(hits)})
	}
	// step 4: the push itself, the only command with network access
	pushEnv := append(append([]string{}, plain...), "GIT_ASKPASS="+askpass)
	out, err = s.runner.oneOff(ctx, p, home, oneOffCmd{
		argv:    []string{"sh", "-c", pushScript, "sh", cfg.hash, origin, sha, branch, p.Path},
		vars:    pushEnv,
		secrets: []string{tokenEnv + "=" + token},
		mounts:  []string{scratch},
		network: true,
	}, nil)
	if err != nil {
		var ee *gitExitError
		if errors.As(err, &ee) && ee.Code == 3 {
			return fail("failed", "the repository config changed during the push; nothing was pushed")
		}
		return fail("failed", "git push failed")
	}
	return &pushResult{Pushed: true, Branch: branch, Commit: sha[:12], Remote: origin}, "pushed", nil
}

// pushScratch makes a private folder for the askpass helper, outside the project and outside the
// homes. It is removed when the push ends.
func (s *Server) pushScratch() (string, error) {
	root := filepath.Join(s.cfg.StateDir, "push-tmp")
	if err := os.MkdirAll(root, 0o700); err != nil {
		return "", err
	}
	if err := os.Chmod(root, 0o700); err != nil {
		return "", err
	}
	return os.MkdirTemp(root, "push-")
}

// pushConfig is what step 1 printed.
type pushConfig struct {
	hash, head, headCommit, branchCommit string
	remotes                              map[string][]string // remote name -> every URL it has
}

// parsePushConfig reads step 1's lines. Only the first occurrence of each header counts, and a
// remote is read only from a line that begins with remote. and ends in .url. A value that spans
// lines cannot add a remote that passes the URL rules.
func parsePushConfig(out []byte) pushConfig {
	cfg := pushConfig{remotes: map[string][]string{}}
	seen := map[string]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		key, value, _ := strings.Cut(line, " ")
		switch key {
		case "hash", "head", "headcommit", "branchcommit":
			if seen[key] {
				continue
			}
			seen[key] = true
			switch key {
			case "hash":
				cfg.hash = value
			case "head":
				cfg.head = value
			case "headcommit":
				cfg.headCommit = value
			case "branchcommit":
				cfg.branchCommit = value
			}
		default:
			// Every value of every remote's url is kept, so each is checked, not only the first.
			if strings.HasPrefix(key, "remote.") && strings.HasSuffix(key, ".url") {
				name := strings.TrimSuffix(strings.TrimPrefix(key, "remote."), ".url")
				cfg.remotes[name] = append(cfg.remotes[name], value)
			}
		}
	}
	return cfg
}

// nulRecords splits -z output into its non-empty records. A leading newline is dropped, so the
// name is the one the rules see.
func nulRecords(out []byte) []string {
	var recs []string
	for _, r := range strings.Split(string(out), "\x00") {
		r = strings.TrimLeft(r, "\n")
		if r != "" {
			recs = append(recs, r)
		}
	}
	return recs
}

func uniqueStrings(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}
