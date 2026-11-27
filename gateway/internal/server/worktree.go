package server

// `_acpcode/projects/createWorktree {projectId, runner?}` (D-125). Makes a git worktree of a
// project in a sibling folder, on a new branch, and registers it as a child project. The caller then
// opens a session in the child's path. Every git command goes through the gateway's git runner
// (runGit), so the protections against a hostile repository apply (gitexec.go); nothing here runs
// git directly.
//
// The worktree is a sibling of the parent (<parent>-<runner>-<8 hex>), so it lies in the same
// project root, and its branch is acpcode/<runner>/<8 hex>, from the parent's current HEAD. The
// srt runner is the only one that can work in it: the worktree's git folder is in the parent's
// .git, outside the child's folder, and the container runners mount only the project folder
// (worktree_srt.go gives the srt sandbox exactly the git folders the child needs).

import (
	"context"
	"errors"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

// worktreeAddLimit is the time limit of `git worktree add`: it checks out the whole tree, which
// does not fit in a status call's 5 s on a large repository.
const worktreeAddLimit = 60 * time.Second

// worktreeTotalBudget bounds the whole call, rollback included.
const worktreeTotalBudget = 3 * time.Minute

// worktreeFailedMessage is the generic answer when the folder cannot be made. It names no path.
const worktreeFailedMessage = "cannot create the worktree"

// serveCreateWorktree answers _acpcode/projects/createWorktree. It runs in its own goroutine,
// because a checkout can take a while.
func (s *Server) serveCreateWorktree(who audit.Who, id, params *jsonv.Value, reply func(*jsonv.Value, any, *rpcError)) {
	const method = "_acpcode/projects/createWorktree"
	defer s.recoverCall(who, method, id, reply)
	base := s.pushCtx
	if base == nil {
		base = context.Background()
	}
	ctx, cancel := context.WithTimeout(base, worktreeTotalBudget)
	defer cancel()
	out, rerr := s.createWorktree(ctx, who, params)
	if rerr != nil {
		reply(id, nil, rerr)
		return
	}
	reply(id, out, nil)
}

// createWorktree is the work of serveCreateWorktree. On a failure after the worktree exists it
// removes the worktree and the branch again.
func (s *Server) createWorktree(ctx context.Context, who audit.Who, params *jsonv.Value) (map[string]any, *rpcError) {
	parentID, ok := params.Get("projectId").StringValue()
	if !ok || parentID == "" {
		return nil, invalidParams("projectId is required")
	}
	if kind := s.cfg.Runner.Kind; kind == "apple" || kind == "podman" {
		return nil, invalidParams("separate worktrees need the srt runner")
	}
	parent, err := s.store.ProjectByID(ctx, parentID)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read projects"}
	}
	if parent == nil {
		return nil, invalidParams("unknown project")
	}
	if parent.ParentID != "" {
		return nil, invalidParams("a worktree project cannot have a worktree of its own")
	}
	runnerID := parent.Runner
	if runnerID == "" {
		runnerID = s.cfg.DefaultRunner
	}
	if v := params.Get("runner"); !v.IsNull() {
		r, ok := v.StringValue()
		if !ok {
			return nil, invalidParams("runner must be the id of one of the gateway's runners")
		}
		runnerID = r
	}
	agent, found := s.cfg.Agent(runnerID)
	if !found || runnerID == "" {
		return nil, invalidParams("runner must be the id of one of the gateway's runners")
	}
	if rerr := s.checkWorktreeSource(ctx, *parent); rerr != nil {
		return nil, rerr
	}

	suffix, err := randomHex(4)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: worktreeFailedMessage}
	}
	childPath := parent.Path + "-" + runnerID + "-" + suffix
	branch := "acpcode/" + runnerID + "/" + suffix
	if !isInsideRoots(childPath, s.roots) {
		return nil, invalidParams("the worktree would be outside the allowed project roots")
	}
	if _, err := os.Lstat(childPath); err == nil {
		return nil, invalidParams("the worktree folder already exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, &rpcError{Code: rpcInternal, Message: worktreeFailedMessage}
	}

	// The srt sandbox of the parent's git command may write the new folder, and only for this call.
	release := allowPendingWorktree(parent.Path, childPath)
	defer release()

	if _, err := s.runGit(withGitLimit(ctx, worktreeAddLimit), *parent, nil, nil, "worktree", "add", "-q", "-b", branch, childPath); err != nil {
		s.removeWorktree(*parent, childPath, branch)
		return nil, &rpcError{Code: rpcInternal, Message: worktreeFailedMessage}
	}
	child, rerr := s.registerWorktree(ctx, *parent, agent.ID, agent.Name, childPath, branch)
	if rerr != nil {
		s.removeWorktree(*parent, childPath, branch)
		return nil, rerr
	}
	s.audit.Log("worktree_create", with(who, audit.Fields{Project: child.ID, Reason: "parent:" + parent.ID}))
	var mode any
	if child.DefaultMode != "" {
		mode = child.DefaultMode
	}
	return map[string]any{
		"id":          child.ID,
		"name":        child.Name,
		"path":        child.Path,
		"defaultMode": mode,
		"runner":      child.Runner,
		"autoApprove": child.AutoApprove,
		"parentId":    child.ParentID,
		"branch":      child.Branch,
	}, nil
}

// checkWorktreeSource refuses a project that is not the top folder of a git repository with a
// commit. Both questions go through the git runner.
func (s *Server) checkWorktreeSource(ctx context.Context, p store.Project) *rpcError {
	notRepo := invalidParams("the project is not a git repository with at least one commit")
	top, err := s.runGit(ctx, p, nil, nil, "rev-parse", "--show-toplevel")
	if err != nil {
		return notRepo
	}
	if real, err := realpath(strings.TrimSpace(string(top.Out))); err != nil || real != p.Path {
		return notRepo
	}
	if _, err := s.runGit(ctx, p, nil, nil, "rev-parse", "--verify", "-q", "HEAD^{commit}"); err != nil {
		return notRepo
	}
	return nil
}

// registerWorktree stores the new folder as a child project with its own home. It makes nothing
// the caller has to undo except the worktree itself.
func (s *Server) registerWorktree(ctx context.Context, parent store.Project, runnerID, runnerName, path, branch string) (*store.Project, *rpcError) {
	fail := &rpcError{Code: rpcInternal, Message: worktreeFailedMessage}
	real, err := realpath(path)
	if err != nil || !isInsideRoots(real, s.roots) {
		return nil, fail
	}
	id, err := newProjectID()
	if err != nil {
		return nil, fail
	}
	home := s.projectHome(id)
	if err := prepareHome(home, real); err != nil {
		_ = os.RemoveAll(home)
		return nil, fail
	}
	if runnerName == "" {
		runnerName = runnerID
	}
	p := store.Project{
		ID:          id,
		Name:        worktreeName(parent.Name, runnerName),
		Path:        real,
		DefaultMode: parent.DefaultMode,
		Created:     time.Now().UTC().Format("2006-01-02T15:04:05.000Z"),
		DenyPaths:   parent.DenyPaths,
		WatchSkip:   parent.WatchSkip,
		Runner:      runnerID,
		ParentID:    parent.ID,
		Branch:      branch,
	}
	if err := s.store.CreateProject(ctx, p); err != nil {
		_ = os.RemoveAll(home)
		return nil, fail
	}
	return &p, nil
}

// worktreeName is "<parent name> (<runner name>)", with the parent's name cut so the whole fits
// maxProjectName.
func worktreeName(parent, runner string) string {
	suffix := " (" + runner + ")"
	if room := maxProjectName - utf8.RuneCountInString(suffix); utf8.RuneCountInString(parent) > room {
		if room < 1 {
			room = 1
		}
		parent = string([]rune(parent)[:room])
	}
	return parent + suffix
}

// removeWorktree undoes `git worktree add`: the worktree, its branch and the folder. It uses a
// context of its own, so a cancelled request still cleans up. Failures are ignored: the caller
// reports a generic error either way.
func (s *Server) removeWorktree(parent store.Project, path, branch string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	_, _ = s.runGit(ctx, parent, nil, nil, "worktree", "remove", "--force", path)
	_, _ = s.runGit(ctx, parent, nil, nil, "branch", "-D", branch)
	if _, err := os.Lstat(path); err == nil {
		_ = os.RemoveAll(path) // a folder this call made: its name had no entry before
	}
	_, _ = s.runGit(ctx, parent, nil, nil, "worktree", "prune")
}
