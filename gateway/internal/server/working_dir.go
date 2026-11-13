package server

// The default working directory (working_dir). A gateway connection whose working directory is blank
// starts its sessions in this folder. The gateway makes and owns <stateDir>/working_dir (mode 0700)
// and registers it as the project "working_dir" when it starts. No request removes it: there is no
// delete method, and a folder is never registered or made over its path. It is an allowed cwd, but it
// is not offered as a root for new projects.

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const (
	workingDirName    = "working_dir" // the folder, under stateDir
	workingDirProject = "working_dir" // the project name the phone sees
)

// EnsureWorkingDir makes the default folder when it is missing and registers it as a project when no
// project has its path. It runs once at start, before the gateway listens. An entry at the path that
// is not a folder (a file, or a link) stops the start, and nothing there is changed.
func (s *Server) EnsureWorkingDir(ctx context.Context) error {
	dir := filepath.Join(s.cfg.StateDir, workingDirName)
	info, err := os.Lstat(dir)
	switch {
	case errors.Is(err, os.ErrNotExist):
		if err := os.Mkdir(dir, 0o700); err != nil {
			return fmt.Errorf("cannot make %s: %w", dir, err)
		}
		// Mkdir applies the umask, so the mode is set explicitly.
		if err := os.Chmod(dir, 0o700); err != nil {
			return fmt.Errorf("cannot set the mode of %s: %w", dir, err)
		}
	case err != nil:
		return fmt.Errorf("cannot check %s: %w", dir, err)
	case !info.IsDir():
		return fmt.Errorf("%s is not a folder (a file or a link); move it aside and start the gateway again", dir)
	}
	real, err := realpath(dir)
	if err != nil {
		return fmt.Errorf("cannot resolve %s: %w", dir, err)
	}
	existing, err := s.store.ProjectByPath(ctx, real)
	if err != nil {
		return fmt.Errorf("cannot read projects: %w", err)
	}
	if existing == nil {
		if _, rerr := s.registerProject(ctx, workingDirProject, real, "", nil, nil, s.cfg.DefaultRunner); rerr != nil {
			return fmt.Errorf("cannot register %s: %s", workingDirProject, rerr.Message)
		}
	}
	s.workingDir = real
	return nil
}

// allowedCwdRoots are the folders a request's cwd may be in: the configured roots and, once
// EnsureWorkingDir has run, the default folder. Project creation still uses s.roots alone.
func (s *Server) allowedCwdRoots() []string {
	if s.workingDir == "" {
		return s.roots
	}
	out := make([]string, 0, len(s.roots)+1)
	out = append(out, s.roots...)
	return append(out, s.workingDir)
}
