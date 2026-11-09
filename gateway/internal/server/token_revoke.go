package server

// Live revocation of phone and intent tokens (config tokens). A revoked token id is kept in a deny
// list in the state directory. The gateway loads it at start, checks it on every upgrade and every
// request, and reloads it on SIGHUP (the revoke-token command sends that signal). A revoked token's
// open sockets are closed when the list is reloaded. The list only ever refuses: it cannot grant a
// token the config does not already hold.

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"

	"acpcode/gateway/internal/audit"
)

// revokedFileName is the deny list, in the state directory. Its content is {"revoked": [token ids]}.
const revokedFileName = "revoked-tokens.json"

// revokedClosedCode is the close code for a socket whose token was revoked (policy violation).
const revokedClosedCode = 1008

type revokedFile struct {
	Revoked []string `json:"revoked"`
}

// RevokedPath is the deny list's path under a state directory.
func RevokedPath(stateDir string) string { return filepath.Join(stateDir, revokedFileName) }

// ReadRevokedTokens reads the deny list. A missing file is an empty list. Any other read or parse
// error is returned, so a damaged list is never taken for an empty one.
func ReadRevokedTokens(stateDir string) ([]string, error) {
	data, err := os.ReadFile(RevokedPath(stateDir))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var f revokedFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("%s is not a revoked-token list: %w", RevokedPath(stateDir), err)
	}
	return f.Revoked, nil
}

// WriteRevokedTokens replaces the deny list atomically, with owner-only permissions.
func WriteRevokedTokens(stateDir string, ids []string) error {
	sorted := slices.Clone(ids)
	sort.Strings(sorted)
	data, err := json.MarshalIndent(revokedFile{Revoked: sorted}, "", "  ")
	if err != nil {
		return err
	}
	path := RevokedPath(stateDir)
	tmp := path + ".tmp"
	_ = os.Remove(tmp)
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(data, '\n')); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// LoadRevoked reads the deny list into memory. The gateway calls it before it listens. A damaged
// list stops the start (the caller exits), so a revocation is never silently lost.
func (s *Server) LoadRevoked() error {
	ids, err := ReadRevokedTokens(s.cfg.StateDir)
	if err != nil {
		return err
	}
	s.setRevoked(ids)
	return nil
}

// setRevoked replaces the in-memory set.
func (s *Server) setRevoked(ids []string) {
	set := make(map[string]bool, len(ids))
	for _, id := range ids {
		if id != "" {
			set[id] = true
		}
	}
	s.revokedMu.Lock()
	s.revoked = set
	s.revokedMu.Unlock()
}

// isRevoked is true when the token id is on the deny list. An empty id (a gateway's own call, which
// has no token) is never revoked.
func (s *Server) isRevoked(device string) bool {
	if device == "" {
		return false
	}
	s.revokedMu.Lock()
	defer s.revokedMu.Unlock()
	return s.revoked[device]
}

// reloadRevoked re-reads the deny list and closes the open sockets of every token on it. A failed
// read keeps the list in memory as it was, and is audited.
func (s *Server) reloadRevoked() error {
	ids, err := ReadRevokedTokens(s.cfg.StateDir)
	if err != nil {
		s.audit.Log("revoke_reload_failed", audit.Fields{Reason: err.Error()})
		return err
	}
	s.setRevoked(ids)
	s.mu.Lock()
	var closing []*client
	for c := range s.clients {
		if s.isRevoked(c.who.Device) {
			closing = append(closing, c)
		}
	}
	s.mu.Unlock()
	for _, c := range closing {
		c.closeWith(revokedClosedCode, "token revoked")
	}
	s.audit.Log("revoke_reload", audit.Fields{Reason: fmt.Sprintf("%d revoked", len(ids))})
	return nil
}

// ReloadOnSIGHUP reloads the deny list each time a SIGHUP arrives on sigs, until sigs is closed.
// The caller registers sigs with signal.Notify.
func (s *Server) ReloadOnSIGHUP(sigs <-chan os.Signal) {
	for range sigs {
		_ = s.reloadRevoked()
	}
}
