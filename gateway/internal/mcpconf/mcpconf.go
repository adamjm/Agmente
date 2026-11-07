// Package mcpconf reads and writes Bob's MCP config file (F-16, FR-41, D-084 to D-086). It parses
// the file, lists its servers, sets a server's `disabled` flag, and writes the file back
// atomically. It runs no program and knows nothing of the gateway's types. The caller checks
// the path (symlinks, containment); this package refuses a symlink at the final component.
//
// The file is a JSON object. `mcpServers` maps a server name to an object. Keys the gateway does
// not use are kept unchanged, at every level. Only `disabled` is ever written, and `alwaysAllow`
// when the phone sends one (D-089).
package mcpconf

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"syscall"
)

// MaxBytes is the largest config file the gateway reads or writes (SPEC, D-085).
const MaxBytes = 256 * 1024

var (
	ErrNotFound    = errors.New("no server with that name")
	ErrTooLarge    = errors.New("file is larger than 256 KiB")
	ErrSymlink     = errors.New("path is a symbolic link")
	ErrNotRegular  = errors.New("path is not a regular file")
	ErrInvalidJSON = errors.New("file is not valid JSON")
	ErrInvalid     = errors.New("file does not have the shape Bob reads")
)

// Server is one entry as the phone may see it: no headers, no URLs, no arguments.
type Server struct {
	Name        string
	Disabled    bool
	AlwaysAllow int    // the number of entries only; the names are not sent
	Transport   string // "stdio", "http", "sse" or "unknown" (verify against Bob's keys)
}

// File is a parsed config. Keys the gateway does not read are kept in raw form.
type File struct {
	top     map[string]json.RawMessage
	servers map[string]map[string]json.RawMessage
}

// Parse reads one config document. It refuses anything over MaxBytes, anything that is not one
// JSON object, and any server entry or value of the wrong type for a key the gateway reads.
func Parse(data []byte) (*File, error) {
	if len(data) > MaxBytes {
		return nil, ErrTooLarge
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(data, &top); err != nil || top == nil {
		return nil, ErrInvalidJSON
	}
	f := &File{top: top, servers: map[string]map[string]json.RawMessage{}}
	raw, ok := top["mcpServers"]
	if !ok || isNull(raw) {
		return f, nil
	}
	var servers map[string]json.RawMessage
	if err := json.Unmarshal(raw, &servers); err != nil || servers == nil {
		return nil, ErrInvalid
	}
	for name, rawEntry := range servers {
		var entry map[string]json.RawMessage
		if err := json.Unmarshal(rawEntry, &entry); err != nil || entry == nil {
			return nil, ErrInvalid
		}
		if d, ok := entry["disabled"]; ok && !isNull(d) {
			var b bool
			if err := json.Unmarshal(d, &b); err != nil {
				return nil, ErrInvalid
			}
		}
		if a, ok := entry["alwaysAllow"]; ok && !isNull(a) {
			var list []json.RawMessage
			if err := json.Unmarshal(a, &list); err != nil {
				return nil, ErrInvalid
			}
		}
		f.servers[name] = entry
	}
	return f, nil
}

func isNull(raw json.RawMessage) bool { return string(raw) == "null" }

// Servers lists the servers sorted by name.
func (f *File) Servers() []Server {
	out := make([]Server, 0, len(f.servers))
	for name, entry := range f.servers {
		s := Server{Name: name, Transport: transportOf(entry)}
		if d, ok := entry["disabled"]; ok && !isNull(d) {
			_ = json.Unmarshal(d, &s.Disabled)
		}
		if a, ok := entry["alwaysAllow"]; ok && !isNull(a) {
			var list []json.RawMessage
			_ = json.Unmarshal(a, &list)
			s.AlwaysAllow = len(list)
		}
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// Has reports whether a server with this name is in the file.
func (f *File) Has(name string) bool {
	_, ok := f.servers[name]
	return ok
}

// SetDisabled sets the `disabled` flag of a server that is already in the file. It never adds a
// server (D-084) and never touches another key.
func (f *File) SetDisabled(name string, disabled bool) error {
	entry, ok := f.servers[name]
	if !ok {
		return ErrNotFound
	}
	value, err := json.Marshal(disabled)
	if err != nil {
		return err
	}
	entry["disabled"] = value
	return nil
}

// SetAlwaysAllow replaces the `alwaysAllow` list of a server that is already in the file (D-089).
// It never adds a server (D-084) and never touches another key. A nil list is written as [].
func (f *File) SetAlwaysAllow(name string, names []string) error {
	entry, ok := f.servers[name]
	if !ok {
		return ErrNotFound
	}
	if names == nil {
		names = []string{}
	}
	value, err := json.Marshal(names)
	if err != nil {
		return err
	}
	entry["alwaysAllow"] = value
	return nil
}

// Marshal returns the file as JSON with a trailing newline. It refuses output over MaxBytes.
func (f *File) Marshal() ([]byte, error) {
	servers, err := json.Marshal(f.servers)
	if err != nil {
		return nil, err
	}
	top := make(map[string]json.RawMessage, len(f.top)+1)
	for k, v := range f.top {
		top[k] = v
	}
	if _, ok := f.top["mcpServers"]; ok || len(f.servers) > 0 {
		top["mcpServers"] = servers
	}
	out, err := json.MarshalIndent(top, "", "  ")
	if err != nil {
		return nil, err
	}
	out = append(out, '\n')
	if len(out) > MaxBytes {
		return nil, ErrTooLarge
	}
	return out, nil
}

// transportOf names how a server runs: a command is stdio, a URL is http. The `type` key wins
// when it names one of the three transports Bob has used.
func transportOf(entry map[string]json.RawMessage) string {
	if raw, ok := entry["type"]; ok {
		var t string
		if json.Unmarshal(raw, &t) == nil {
			switch t {
			case "stdio", "http", "sse":
				return t
			}
		}
	}
	if _, ok := entry["command"]; ok {
		return "stdio"
	}
	if _, ok := entry["url"]; ok {
		return "http"
	}
	if _, ok := entry["httpUrl"]; ok {
		return "http"
	}
	return "unknown"
}

// Read returns the bytes of the file at path. It opens the final component without following a
// link (O_NOFOLLOW), refuses anything that is not a regular file, and reads at most MaxBytes.
// A missing file gives an error that is os.ErrNotExist.
func Read(path string) ([]byte, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0) // O_NONBLOCK: a FIFO must not block the open
	if err != nil {
		if errors.Is(err, syscall.ELOOP) {
			return nil, ErrSymlink
		}
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, ErrNotRegular
	}
	if info.Size() > MaxBytes {
		return nil, ErrTooLarge
	}
	data, err := io.ReadAll(io.LimitReader(f, MaxBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > MaxBytes {
		return nil, ErrTooLarge
	}
	return data, nil
}

// Hooks for the write path, replaced by tests to make a step fail.
var (
	rename   = os.Rename
	syncFile = func(f *os.File) error { return f.Sync() }
)

// Write replaces the file at path with data, atomically: it writes a temp file in the same folder
// (created with O_EXCL, mode 0600), fsyncs it, and renames it over the target. Any missing parent
// folder is created with mode 0700. A symlink at path is refused, and nothing is left behind on
// an error.
func Write(path string, data []byte) error {
	if len(data) > MaxBytes {
		return ErrTooLarge
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			return ErrSymlink
		}
		if !info.Mode().IsRegular() {
			return ErrNotRegular
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	suffix := make([]byte, 8)
	if _, err := rand.Read(suffix); err != nil {
		return err
	}
	tmp := filepath.Join(dir, fmt.Sprintf(".%s.%s.tmp", filepath.Base(path), hex.EncodeToString(suffix)))
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	done := false
	defer func() {
		if !done {
			_ = f.Close()
			_ = os.Remove(tmp)
		}
	}()
	if err := f.Chmod(0o600); err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		return err
	}
	if err := syncFile(f); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := rename(tmp, path); err != nil {
		return err
	}
	done = true
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}
