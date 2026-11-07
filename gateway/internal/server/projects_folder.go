package server

// Folder creation from the phone (D-091). `_agmente/projects/create` with `createFolder: true`
// makes <path>/<name> and registers it. Picking an existing folder is unchanged (D-024).

import (
	"context"
	"errors"
	"os"
	"path/filepath"

	"agmente/gateway/internal/jsonv"
	"agmente/gateway/internal/store"
)

const maxFolderName = 64

// folderHook is called at two points of a folder creation, for tests only: "before-mkdir" with the
// parent folder, and "after-mkdir" with the new folder. It plays the part of a process that swaps a
// path component inside the window (D-091). It is nil outside the tests.
var folderHook func(stage, path string)

// projectRoots answers `_agmente/projects/roots` (D-091): the configured roots that exist now, as
// realpaths, each once. The phone takes its parent folder for a new project from this list. Roots
// are only listed, never changed, and only an authenticated identity can ask.
func (s *Server) projectRoots() map[string]any {
	out := []string{}
	seen := map[string]bool{}
	for _, root := range s.roots {
		if seen[root] {
			continue
		}
		// A root removed after start, or one now reached through a link, is not offered: a folder
		// made in it would be refused (createFolderProject checks the same things).
		if real, err := realpath(root); err != nil || real != root {
			continue
		}
		if info, err := os.Stat(root); err != nil || !info.IsDir() {
			continue
		}
		seen[root] = true
		out = append(out, root)
	}
	return map[string]any{"roots": out}
}

// folderFlag reads createFolder. Absent or null is false; anything but a JSON boolean is refused.
func folderFlag(v *jsonv.Value) (bool, *rpcError) {
	if v.IsNull() {
		return false, nil
	}
	if v.Kind != jsonv.Bool {
		return false, invalidParams("createFolder must be true or false")
	}
	return v.B, nil
}

// checkFolderName applies the folder name rules (D-091). The name is used exactly as sent, so
// a space at either end is refused rather than trimmed. The name is one path component because
// a slash and a backslash are not in the allowed set.
func checkFolderName(name string) *rpcError {
	switch {
	case name == "":
		return invalidParams("folder name must not be empty")
	case len(name) > maxFolderName:
		return invalidParams("folder name must be at most %d characters", maxFolderName)
	case name[0] == '.':
		return invalidParams("folder name must not start with a dot")
	case name[0] == ' ' || name[len(name)-1] == ' ':
		return invalidParams("folder name must not start or end with a space")
	}
	for i := 0; i < len(name); i++ {
		if !folderNameByte(name[i]) {
			return invalidParams("folder name may contain only letters, digits, spaces, dots, hyphens and underscores")
		}
	}
	return nil
}

// folderNameByte is true for the ASCII letters, digits, space, dot, hyphen and underscore. ASCII
// only: a name that differs by Unicode normalisation would otherwise name two folders on macOS.
func folderNameByte(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
		c == ' ' || c == '.' || c == '-' || c == '_'
}

// createFolderProject makes <path>/<name> and registers it (D-091). `path` is the parent folder.
// Its realpath must be a root or inside one, and the path sent must already be that realpath, so
// a symbolic link anywhere in it is refused. The parent is then opened once and every step after
// that works through the open folder (os.Root), so a component swapped later cannot redirect the
// mkdir, the mode change or the rollback. The folder is created with mode 0755. Registration is the
// same as for an existing folder (registerProject). If it fails, the folder this call created is
// removed again, and only while it is still an empty folder.
func (s *Server) createFolderProject(ctx context.Context, params *jsonv.Value, name, mode string, deny, skip []string) (*store.Project, *rpcError) {
	parent, ok := params.Get("path").StringValue()
	if !ok || !filepath.IsAbs(parent) {
		return nil, invalidParams("path must be an absolute path")
	}
	if filepath.Clean(parent) != parent {
		return nil, invalidParams("path must be clean: no trailing slash, \".\" or \"..\"")
	}
	real, err := realpath(parent)
	if err != nil {
		return nil, invalidParams("path does not exist")
	}
	if real != parent {
		return nil, invalidParams("path must not contain a symbolic link")
	}
	if info, err := os.Stat(real); err != nil || !info.IsDir() {
		return nil, invalidParams("path must be a directory")
	}
	if !isInsideRoots(real, s.roots) {
		return nil, invalidParams("path is outside the allowed project roots")
	}
	dir, err := os.OpenRoot(real)
	if err != nil {
		return nil, invalidParams("path cannot be opened")
	}
	defer dir.Close()
	// The open may have followed a link swapped in after the check above. The path must still be
	// the same folder, or nothing is made.
	if got, err := realpath(real); err != nil || got != real {
		return nil, invalidParams("path must not contain a symbolic link")
	}
	target := filepath.Join(real, name)
	if _, err := dir.Lstat(name); err == nil {
		return nil, invalidParams("a folder with that name already exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot check the folder"}
	}
	if existing, err := s.store.ProjectByPath(ctx, target); err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read projects"}
	} else if existing != nil {
		return nil, &rpcError{Code: rpcInvalidParams, Message: store.ErrDuplicatePath.Error(), Data: map[string]string{"projectId": existing.ID}}
	}
	if folderHook != nil {
		folderHook("before-mkdir", real)
	}
	if err := dir.Mkdir(name, 0o755); err != nil {
		if errors.Is(err, os.ErrExist) {
			return nil, invalidParams("a folder with that name already exists")
		}
		return nil, &rpcError{Code: rpcInternal, Message: "cannot create the folder"}
	}
	// The folder now exists and this call made it. Anything that is not a folder at the name from
	// here on was put there by someone else, so it is left alone and never removed.
	if folderHook != nil {
		folderHook("after-mkdir", target)
	}
	if info, err := dir.Lstat(name); err != nil || !info.IsDir() {
		return nil, invalidParams("the new folder was replaced while it was made")
	}
	// Mkdir applies the umask, so the mode is set explicitly. Root.Chmod never follows a link out
	// of the parent.
	if err := dir.Chmod(name, 0o755); err != nil {
		removeOwnFolder(dir, name)
		return nil, &rpcError{Code: rpcInternal, Message: "cannot set the folder mode"}
	}
	// Check the new folder as it now is: its path must still resolve to itself inside a root.
	if got, err := realpath(target); err != nil || got != target || !isInsideRoots(got, s.roots) {
		removeOwnFolder(dir, name)
		return nil, invalidParams("path is outside the allowed project roots")
	}
	p, rerr := s.registerProject(ctx, name, target, mode, deny, skip)
	if rerr != nil {
		removeOwnFolder(dir, name)
		return nil, rerr
	}
	return p, nil
}

// removeOwnFolder removes the folder this call made, and only when it is still a folder and empty
// (Root.Remove removes an empty folder; a file or link at the name is never touched).
func removeOwnFolder(dir *os.Root, name string) {
	if info, err := dir.Lstat(name); err == nil && info.IsDir() {
		_ = dir.Remove(name)
	}
}
