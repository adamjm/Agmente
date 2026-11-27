package server

// srt settings for a separate worktree (D-125). A worktree project's folder holds a `.git` FILE,
// "gitdir: <parent>/.git/worktrees/<name>", so git needs the parent repository's git folder, which
// lies outside the child's folder and inside the denied project root. worktreeAccess adds exactly
// what git needs there and nothing more:
//
//   - write: the worktree's own git folder (HEAD, index, its logs), and the shared objects, refs,
//     logs and packed-refs of the common git folder (new commits and branches).
//   - read: the common git folder.
//   - never write: <common>/hooks, and <common>/config for the agent (a hook or a config key is a
//     program the gateway's own git runs later). The gateway's own git commands (spec.gitConfig,
//     which sets AllowGitConfig) may write <common>/config, as they may write .git/config in an
//     ordinary project; the push neutralizer needs it. Nothing of the parent's working files is
//     readable.
//
// The folder names come from the child's `.git` file, which the agent can rewrite. The gitdir is
// used only when its own back-link file names this project's `.git`, which the agent cannot forge
// toward another repository: it would have to write inside that repository.

import (
	"os"
	"path/filepath"
	"strings"
	"sync"

	"acpcode/gateway/internal/store"
)

// pendingWorktrees holds the folder of a worktree that `git worktree add` is about to make, per
// parent project folder. The parent's git commands may write it for the length of the call only.
var pendingWorktrees = struct {
	mu sync.Mutex
	m  map[string][]string
}{m: map[string][]string{}}

// allowPendingWorktree lets the sandbox of the parent's git commands write child until release runs.
func allowPendingWorktree(parent, child string) (release func()) {
	pendingWorktrees.mu.Lock()
	pendingWorktrees.m[parent] = append(pendingWorktrees.m[parent], child)
	pendingWorktrees.mu.Unlock()
	return func() {
		pendingWorktrees.mu.Lock()
		defer pendingWorktrees.mu.Unlock()
		list := pendingWorktrees.m[parent]
		for i, c := range list {
			if c == child {
				list = append(list[:i:i], list[i+1:]...)
				break
			}
		}
		if len(list) == 0 {
			delete(pendingWorktrees.m, parent)
		} else {
			pendingWorktrees.m[parent] = list
		}
	}
}

// linkedGitDirs returns the worktree's git folder and the common git folder of the project at path,
// or ok false when the folder is not a linked worktree or its git folders cannot be trusted.
func linkedGitDirs(path string) (gitDir, common string, ok bool) {
	dotGit := filepath.Join(path, ".git")
	info, err := os.Lstat(dotGit)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 4096 {
		return "", "", false
	}
	data, err := os.ReadFile(dotGit)
	if err != nil {
		return "", "", false
	}
	line, _, _ := strings.Cut(string(data), "\n")
	target, found := strings.CutPrefix(strings.TrimSpace(line), "gitdir:")
	if !found {
		return "", "", false
	}
	target = strings.TrimSpace(target)
	if !filepath.IsAbs(target) {
		target = filepath.Join(path, target)
	}
	gitDir, err = filepath.EvalSymlinks(target)
	if err != nil {
		return "", "", false
	}
	// <common>/worktrees/<name>
	worktrees := filepath.Dir(gitDir)
	if filepath.Base(worktrees) != "worktrees" || filepath.Base(gitDir) == "worktrees" {
		return "", "", false
	}
	common = filepath.Dir(worktrees)
	// The back-link: <gitdir>/gitdir names this project's .git.
	back, err := os.ReadFile(filepath.Join(gitDir, "gitdir"))
	if err != nil {
		return "", "", false
	}
	backPath := strings.TrimSpace(string(back))
	if !filepath.IsAbs(backPath) {
		backPath = filepath.Join(gitDir, backPath)
	}
	backReal, err1 := filepath.EvalSymlinks(backPath)
	dotGitReal, err2 := filepath.EvalSymlinks(dotGit)
	if err1 != nil || err2 != nil || backReal != dotGitReal {
		return "", "", false
	}
	return gitDir, common, true
}

// worktreeAccess widens the settings of a worktree project (see the file comment). It does nothing
// for an ordinary project, and nothing for a folder whose `.git` is not a trustworthy link.
func worktreeAccess(p store.Project, s *srtSettings) {
	pendingWorktrees.mu.Lock()
	pending := append([]string{}, pendingWorktrees.m[p.Path]...)
	pendingWorktrees.mu.Unlock()
	for _, child := range pending {
		for _, f := range pathForms(child) {
			s.Filesystem.AllowRead = append(s.Filesystem.AllowRead, f)
			s.Filesystem.AllowWrite = append(s.Filesystem.AllowWrite, f)
		}
	}
	if gitDir, common, ok := linkedGitDirs(p.Path); ok {
		s.Filesystem.AllowRead = append(s.Filesystem.AllowRead, pathForms(common)...)
		s.Filesystem.AllowWrite = append(s.Filesystem.AllowWrite, pathForms(gitDir)...)
		names := []string{"objects", "refs", "logs", "packed-refs", "packed-refs.lock"}
		if s.Filesystem.AllowGitConfig {
			// Only the gateway's own git commands (git init, the push neutralizer) may write the
			// shared config, as srt allows them <project>/.git/config in an ordinary project.
			names = append(names, "config", "config.lock")
		}
		for _, name := range names {
			s.Filesystem.AllowWrite = append(s.Filesystem.AllowWrite, pathForms(filepath.Join(common, name))...)
		}
	}
	s.Filesystem.AllowRead = uniq(s.Filesystem.AllowRead)
	s.Filesystem.AllowWrite = uniq(s.Filesystem.AllowWrite)
}
