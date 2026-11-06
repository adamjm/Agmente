package server

// Signed file URLs (FR-38, NFR-12, PLAN 5.3, ARCHITECTURE 2.5, D-061 to D-064).
//
// _agmente/files/url {projectId, path} returns https://<files.host>/f/<token>. The token is
// base64url(payload) "." base64url(HMAC-SHA256(key, payload)), where the payload is the JSON
// {p: projectId, r: relative path, e: expiry in Unix seconds}. GET and HEAD /f/<token> are answered
// only on the files host. Every serve verifies the token and resolves the path again: a symlink
// changed after signing is refused (D-063).

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/jsonv"
	"agmente/gateway/internal/store"
)

const (
	rpcFilesOff     = -32000
	fileTokenMaxLen = 2048
	fileMaxPathLen  = 1024
	filesPrefix     = "/f/"
	// htmlCSP is sent with every HTML file (D-062). No script runs from a served page.
	htmlCSP = "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:"
)

// servedTypes is the allow-list by extension (D-062). SVG is served as text, so it never runs.
var servedTypes = map[string]string{
	".png":  "image/png",
	".jpg":  "image/jpeg",
	".jpeg": "image/jpeg",
	".gif":  "image/gif",
	".webp": "image/webp",
	".heic": "image/heic",
	".html": "text/html; charset=utf-8",
	".css":  "text/css; charset=utf-8",
	".js":   "text/javascript; charset=utf-8",
	".json": "application/json",
	".txt":  "text/plain; charset=utf-8",
	".md":   "text/plain; charset=utf-8",
	".svg":  "text/plain; charset=utf-8",
}

// fileRefusalText is what the phone sees when a path is refused at signing (fixed set, D-063).
var fileRefusalText = map[string]string{
	"path":         "path must be relative to the project, with no \"..\", \".\" or empty part and no control characters",
	"outside_root": "path resolves outside the project folder",
	"not_found":    "file does not exist",
	"not_regular":  "path is not a regular file",
	"secret":       "file is on the secret deny-list",
	"type":         "file type is not served (png, jpg, jpeg, gif, webp, heic, html, css, js, json, txt, md, svg)",
	"too_large":    "file is larger than files.maxBytes",
}

// fileClaims is the signed payload of a file URL token.
type fileClaims struct {
	P string `json:"p"`
	R string `json:"r"`
	E int64  `json:"e"`
}

var enc = base64.RawURLEncoding

// signFileToken returns the token for a claim set.
func signFileToken(key []byte, c fileClaims) string {
	payload, _ := json.Marshal(c) // a string, a string and an integer cannot fail to encode
	mac := hmac.New(sha256.New, key)
	mac.Write(payload)
	return enc.EncodeToString(payload) + "." + enc.EncodeToString(mac.Sum(nil))
}

// verifyFileToken checks the signature in constant time and returns the claims. It does not check
// the expiry or the file: the caller does (D-063).
func verifyFileToken(key []byte, token string) (fileClaims, bool) {
	var c fileClaims
	if len(token) > fileTokenMaxLen {
		return c, false
	}
	dot := strings.IndexByte(token, '.')
	if dot < 0 || strings.IndexByte(token[dot+1:], '.') >= 0 {
		return c, false
	}
	payload, err := enc.DecodeString(token[:dot])
	if err != nil {
		return c, false
	}
	sig, err := enc.DecodeString(token[dot+1:])
	if err != nil {
		return c, false
	}
	mac := hmac.New(sha256.New, key)
	mac.Write(payload)
	if !hmac.Equal(sig, mac.Sum(nil)) {
		return c, false
	}
	if err := json.Unmarshal(payload, &c); err != nil || c.P == "" || c.R == "" {
		return fileClaims{}, false
	}
	return c, true
}

// validRelPath is true for a clean path relative to the project root: no leading "/", no empty,
// "." or ".." component, no control character, no backslash, at most 1024 bytes.
func validRelPath(rel string) bool {
	if rel == "" || len(rel) > fileMaxPathLen || !utf8.ValidString(rel) || strings.HasPrefix(rel, "/") {
		return false
	}
	for _, r := range rel {
		if unicode.IsControl(r) || r == '\\' {
			return false
		}
	}
	for _, part := range strings.Split(rel, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}

// projectFile resolves rel inside the project and returns its realpath and file info, or the
// refusal reason from the fixed set. It is used at signing and again at every serve (D-063).
func (s *Server) projectFile(p *store.Project, rel string) (string, os.FileInfo, string) {
	if !validRelPath(rel) {
		return "", nil, "path"
	}
	if isSecretFor(p.DenyPaths, rel) {
		return "", nil, "secret"
	}
	root, err := realpath(p.Path)
	if err != nil {
		return "", nil, "not_found"
	}
	real, err := realpath(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		return "", nil, "not_found"
	}
	if !isInsideRoots(real, []string{root}) {
		return "", nil, "outside_root"
	}
	// The file may be a link into the project that names a secret: check where it really is too.
	if inner, err := filepath.Rel(root, real); err == nil && isSecretFor(p.DenyPaths, filepath.ToSlash(inner)) {
		return "", nil, "secret"
	}
	info, err := os.Stat(real)
	if err != nil {
		return "", nil, "not_found"
	}
	if !info.Mode().IsRegular() {
		return "", nil, "not_regular"
	}
	if _, ok := servedTypes[strings.ToLower(filepath.Ext(rel))]; !ok {
		return "", nil, "type"
	}
	return real, info, ""
}

// fileURL answers _agmente/files/url (FR-38). The phone may name any file that passes projectFile.
func (s *Server) fileURL(ctx context.Context, who audit.Who, params *jsonv.Value) (any, *rpcError) {
	if s.cfg.Files == nil {
		return nil, &rpcError{Code: rpcFilesOff, Message: "file URLs are not enabled (config files)"}
	}
	pid, ok := params.Get("projectId").StringValue()
	if !ok || pid == "" {
		return nil, invalidParams("projectId is required")
	}
	p, err := s.store.ProjectByID(ctx, pid)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read projects"}
	}
	if p == nil {
		return nil, invalidParams("unknown project")
	}
	rel, ok := params.Get("path").StringValue()
	if !ok {
		return nil, invalidParams("path must be a string")
	}
	refuse := func(reason string) (any, *rpcError) {
		f := audit.Fields{Project: p.ID, Reason: reason}
		if validRelPath(rel) {
			f.Path = rel
		}
		s.audit.Log("file_refused", with(who, f))
		return nil, invalidParams("%s", fileRefusalText[reason])
	}
	if _, info, reason := s.projectFile(p, rel); reason != "" {
		return refuse(reason)
	} else if info.Size() > s.cfg.Files.MaxBytes {
		return refuse("too_large")
	}

	ttl := s.cfg.Files.TTLSeconds
	expires := time.Now().Unix() + ttl // NFR-12: at most 300 s
	token := signFileToken(s.cfg.Files.Key, fileClaims{P: p.ID, R: rel, E: expires})
	s.audit.Log("file_url_issued", with(who, audit.Fields{Project: p.ID, Path: rel}))
	return map[string]any{
		"url":       "https://" + s.cfg.Files.Host + filesPrefix + token,
		"expiresAt": time.Unix(expires, 0).UTC().Format("2006-01-02T15:04:05.000Z"),
	}, nil
}

// isFilesHost is true when the request's Host names the files host (D-061). The port is ignored.
func (s *Server) isFilesHost(r *http.Request) bool {
	if s.cfg.Files == nil {
		return false
	}
	host := r.Host
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	return strings.EqualFold(host, s.cfg.Files.Host)
}

// serveFile answers GET and HEAD for /f/<token> on the files host (D-062). It sets no cookie and
// reads no request header that carries state.
func (s *Server) serveFile(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Cache-Control", "no-store")
	client := clientKey(r, s.cfg.TrustProxy)
	refuse := func(status int, reason, project, rel string) {
		f := audit.Fields{Client: client, Status: status, Reason: reason, Project: project}
		if validRelPath(rel) {
			f.Path = rel
		}
		s.audit.Log("file_refused", f)
		http.Error(w, http.StatusText(status), status)
	}

	token, ok := strings.CutPrefix(r.URL.Path, filesPrefix)
	if !ok || token == "" || strings.Contains(token, "/") {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		h.Set("Allow", "GET, HEAD")
		refuse(http.StatusMethodNotAllowed, "method", "", "")
		return
	}
	claims, ok := verifyFileToken(s.cfg.Files.Key, token)
	if !ok {
		refuse(http.StatusForbidden, "token", "", "")
		return
	}
	if time.Now().Unix() >= claims.E {
		refuse(http.StatusForbidden, "expired", claims.P, claims.R)
		return
	}
	p, err := s.store.ProjectByID(r.Context(), claims.P)
	if err != nil || p == nil {
		refuse(http.StatusForbidden, "project", claims.P, claims.R)
		return
	}
	real, info, reason := s.projectFile(p, claims.R)
	if reason != "" {
		refuse(fileReasonStatus(reason), reason, p.ID, claims.R)
		return
	}
	if info.Size() > s.cfg.Files.MaxBytes {
		refuse(http.StatusRequestEntityTooLarge, "too_large", p.ID, claims.R)
		return
	}
	f, err := os.Open(real)
	if err != nil {
		refuse(http.StatusNotFound, "not_found", p.ID, claims.R)
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		refuse(http.StatusForbidden, "not_regular", p.ID, claims.R)
		return
	}
	// The path may have changed since the first check (D-063). Resolve it again: it must still be
	// inside the project and not secret, and it must name the file that is open.
	_, again, reason := s.projectFile(p, claims.R)
	if reason != "" {
		refuse(fileReasonStatus(reason), reason, p.ID, claims.R)
		return
	}
	if !os.SameFile(fi, again) {
		refuse(http.StatusForbidden, "changed", p.ID, claims.R)
		return
	}
	if fi.Size() > s.cfg.Files.MaxBytes {
		refuse(http.StatusRequestEntityTooLarge, "too_large", p.ID, claims.R)
		return
	}

	ext := strings.ToLower(filepath.Ext(claims.R))
	h.Set("Content-Type", servedTypes[ext])
	h.Set("Content-Length", strconv.FormatInt(fi.Size(), 10))
	h.Set("Content-Disposition", "inline")
	if ext == ".html" {
		h.Set("Content-Security-Policy", htmlCSP)
	}
	w.WriteHeader(http.StatusOK)
	s.audit.Log("file_served", audit.Fields{Client: client, Project: p.ID, Path: claims.R})
	if r.Method == http.MethodHead {
		return
	}
	_, _ = io.CopyN(w, f, fi.Size()) // a write error means the phone went away
}

// fileReasonStatus is the HTTP status for a refusal reason.
func fileReasonStatus(reason string) int {
	switch reason {
	case "not_found":
		return http.StatusNotFound
	case "too_large":
		return http.StatusRequestEntityTooLarge
	}
	return http.StatusForbidden
}
