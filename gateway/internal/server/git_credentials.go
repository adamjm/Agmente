package server

// Git credential profiles (D-105, v2). The phone can write a token and read only metadata back:
// no response, log line or audit line holds a token. Each token is a 0600 file in
// <stateDir>/credentials (a 0700 folder) named by the profile id; SQLite holds the metadata only.
// A token is used only by the push container (git_push.go), never by the agent's container.

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

const (
	maxCredentialName  = 64
	maxCredentialToken = 4096
	rpcServerError     = -32000 // a refusal that is not a bad parameter (the server's own error range)
)

// credentialIDPattern is a profile id: 12 lowercase hex characters, safe as a file name.
var credentialIDPattern = regexp.MustCompile(`^[0-9a-f]{12}$`)

// errNoSecret means a profile has no token file (or it is not private).
var errNoSecret = errors.New("the credential has no secret stored")

func (s *Server) credentialsDir() string { return filepath.Join(s.cfg.StateDir, "credentials") }

func (s *Server) credentialPath(id string) string { return filepath.Join(s.credentialsDir(), id) }

// connectionSecure says whether a connection may carry a credential (D-105). The gateway listens
// on loopback only (FR-2), so a direct connection is loopback-only. Behind Caddy, when trustProxy
// is on and the peer is loopback, the proxy's X-Forwarded-Proto says how the phone connected: a
// connection the proxy reports as plain is refused.
func connectionSecure(r *http.Request, trustProxy bool) bool {
	if !trustProxy {
		return true
	}
	peer, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		peer = r.RemoteAddr
	}
	if !config.IsLoopbackAddress(peer) {
		return true
	}
	values := r.Header.Values("X-Forwarded-Proto")
	if len(values) == 0 {
		return true
	}
	last := ""
	for _, v := range values {
		for _, part := range strings.Split(v, ",") {
			if p := strings.TrimSpace(part); p != "" {
				last = p
			}
		}
	}
	return strings.EqualFold(last, "https")
}

// gitCredentialJSON is a profile as the phone sees it. It never has the token.
type gitCredentialJSON struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Host      string `json:"host"`
	CreatedAt string `json:"createdAt"`
	HasSecret bool   `json:"hasSecret"`
}

// listGitCredentials answers `_acpcode/git/credentials/list`: metadata only.
func (s *Server) listGitCredentials(ctx context.Context) (any, *rpcError) {
	creds, err := s.store.GitCredentials(ctx)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read the credentials"}
	}
	out := make([]gitCredentialJSON, 0, len(creds))
	for _, c := range creds {
		out = append(out, gitCredentialJSON{ID: c.ID, Name: c.Name, Host: c.Host, CreatedAt: c.Created, HasSecret: s.hasSecret(c.ID)})
	}
	return map[string]any{"credentials": out}, nil
}

// hasSecret reports whether the profile's token file exists and is not empty.
func (s *Server) hasSecret(id string) bool {
	info, err := os.Lstat(s.credentialPath(id))
	return err == nil && info.Mode().IsRegular() && info.Size() > 0
}

// setGitCredential answers `_acpcode/git/credentials/set {id?, name, host, token}` and returns only
// {id}. It is refused unless the connection is secure (connectionSecure). The host must be on the
// allow-list, and an existing profile keeps its host. The token is written first, then the metadata,
// so a failure never leaves metadata for a token that was not stored.
func (s *Server) setGitCredential(ctx context.Context, who audit.Who, params *jsonv.Value) (any, *rpcError) {
	if !who.Secure {
		return nil, &rpcError{Code: rpcServerError, Message: "credentials can be set only over a secure connection (wss://)"}
	}
	id := ""
	if v := params.Get("id"); !v.IsNull() {
		str, ok := v.StringValue()
		if !ok || !credentialIDPattern.MatchString(str) {
			return nil, invalidParams("id is not a credential id")
		}
		id = str
	}
	rawName, ok := params.Get("name").StringValue()
	name := strings.TrimSpace(rawName)
	if !ok || name == "" || utf8.RuneCountInString(name) > maxCredentialName || strings.IndexFunc(name, unicode.IsControl) >= 0 {
		return nil, invalidParams("name must be 1 to %d characters with no control characters", maxCredentialName)
	}
	host, ok := params.Get("host").StringValue()
	if !ok || !s.gitHostAllowed(host) {
		return nil, invalidParams("host must be on the gateway's git allow-list")
	}
	token, ok := params.Get("token").StringValue()
	// The message never includes the token or any part of it.
	if !ok || token == "" || len(token) > maxCredentialToken || strings.IndexFunc(token, badTokenByte) >= 0 {
		return nil, invalidParams("token must be 1 to %d characters with no spaces or control characters", maxCredentialToken)
	}
	existing, err := s.getCredential(ctx, id)
	if err != nil {
		return nil, err
	}
	if id != "" && existing == nil {
		return nil, invalidParams("unknown credential")
	}
	if existing != nil && existing.Host != host {
		return nil, invalidParams("a credential keeps its host; delete it and add it again to change the host")
	}
	reason := "created"
	created := existing
	if existing == nil {
		newID, err := newCredentialID()
		if err != nil {
			return nil, &rpcError{Code: rpcInternal, Message: "cannot create a credential id"}
		}
		id = newID
	} else {
		reason = "updated"
	}
	if err := s.ensureCredentialsDir(); err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot store the credential"}
	}
	if err := writeFileAtomic(s.credentialPath(id), []byte(token)); err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot store the credential"}
	}
	createdAt := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	if created != nil {
		createdAt = created.Created
	}
	if err := s.store.SetGitCredential(ctx, store.GitCredential{ID: id, Name: name, Host: host, Created: createdAt}); err != nil {
		if created == nil {
			_ = os.Remove(s.credentialPath(id)) // no metadata for this token: remove it
		}
		return nil, &rpcError{Code: rpcInternal, Message: "cannot save the credential"}
	}
	s.audit.Log("git_credential_set", with(who, audit.Fields{Credential: id, Host: host, Reason: reason}))
	return map[string]any{"id": id}, nil
}

// deleteGitCredential answers `_acpcode/git/credentials/delete {id}` with {}. The token file goes
// first: if the metadata delete then fails, the profile shows hasSecret false and can be deleted again.
func (s *Server) deleteGitCredential(ctx context.Context, who audit.Who, params *jsonv.Value) (any, *rpcError) {
	id, ok := params.Get("id").StringValue()
	if !ok || !credentialIDPattern.MatchString(id) {
		return nil, invalidParams("id is not a credential id")
	}
	existing, rerr := s.getCredential(ctx, id)
	if rerr != nil {
		return nil, rerr
	}
	if existing == nil {
		return nil, invalidParams("unknown credential")
	}
	if err := os.Remove(s.credentialPath(id)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot remove the credential"}
	}
	if _, err := s.store.DeleteGitCredential(ctx, id); err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot remove the credential"}
	}
	s.audit.Log("git_credential_deleted", with(who, audit.Fields{Credential: id, Host: existing.Host}))
	return map[string]any{}, nil
}

// readCredentialToken returns the token of a profile for the push container. The file must be
// private (no group or other bits), as the APNs key file is (D-055).
func (s *Server) readCredentialToken(id string) (string, error) {
	path := s.credentialPath(id)
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 || info.Size() == 0 || info.Size() > maxCredentialToken {
		return "", errNoSecret
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", errNoSecret
	}
	return strings.TrimRight(string(data), "\r\n"), nil
}

func (s *Server) getCredential(ctx context.Context, id string) (*store.GitCredential, *rpcError) {
	if id == "" {
		return nil, nil
	}
	c, err := s.store.GitCredentialByID(ctx, id)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read the credentials"}
	}
	return c, nil
}

func (s *Server) ensureCredentialsDir() error {
	dir := s.credentialsDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	return os.Chmod(dir, 0o700)
}

func (s *Server) gitHostAllowed(host string) bool {
	for _, h := range s.gitHosts() {
		if h == host {
			return true
		}
	}
	return false
}

func newCredentialID() (string, error) { return newProjectID() }

// badTokenByte is true for a space, a control character or a non-ASCII rune: none is in a token.
func badTokenByte(r rune) bool { return r > 0x7e || r <= ' ' || r == 0x7f }
