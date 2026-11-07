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

// projectRoots answers `_agmente/projects/roots` (D-091): the configured roots that exist, as
// realpaths. The phone takes its parent folder for a new project from this list. Roots are only
// listed, never changed, and only an authenticated identity can ask.
func (s *Server) projectRoots() map[string]any {
	out := make([]string, 0, len(s.roots))
	out = append(out, s.roots...)
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
// a symbolic link anywhere in it is refused. The folder is created with mode 0755. Registration
// is the same as for an existing folder (registerProject). If registration fails, the folder this
// call created is removed again.
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
	target := filepath.Join(real, name)
	if _, err := os.Lstat(target); err == nil {
		return nil, invalidParams("a folder with that name already exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot check the folder"}
	}
	if existing, err := s.store.ProjectByPath(ctx, target); err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read projects"}
	} else if existing != nil {
		return nil, &rpcError{Code: rpcInvalidParams, Message: store.ErrDuplicatePath.Error(), Data: map[string]string{"projectId": existing.ID}}
	}
	if err := os.Mkdir(target, 0o755); err != nil {
		if errors.Is(err, os.ErrExist) {
			return nil, invalidParams("a folder with that name already exists")
		}
		return nil, &rpcError{Code: rpcInternal, Message: "cannot create the folder"}
	}
	// The folder now exists and this call made it: every refusal below removes it again.
	// Mkdir applies the umask, so the mode is set explicitly.
	if err := os.Chmod(target, 0o755); err != nil {
		_ = os.Remove(target)
		return nil, &rpcError{Code: rpcInternal, Message: "cannot set the folder mode"}
	}
	// Check the new folder as it now is: a race that put a link in its place is refused.
	if got, err := realpath(target); err != nil || got != target || !isInsideRoots(got, s.roots) {
		_ = os.Remove(target)
		return nil, invalidParams("path is outside the allowed project roots")
	}
	p, rerr := s.registerProject(ctx, name, target, mode, deny, skip)
	if rerr != nil {
		_ = os.Remove(target)
		return nil, rerr
	}
	return p, nil
}
