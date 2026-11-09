// Package connector is the remote connector: a second listener, public through Caddy without a
// client certificate, that lets Claude reach the gateway's projects and sessions over MCP (D-095).
//
// The listener serves only the routes below and answers every other path with 404. OAuth 2.1 with
// PKCE (S256) and resource indicators (RFC 8707) gates POST /mcp. A bearer grant is issued only
// after the owner approves a pairing on the phone (D-095 pairing), and each grant is scoped to
// projects and sessions. The phone's listener and its mutual TLS are never touched by this package.
//
//	GET  /.well-known/oauth-protected-resource       RFC 9728 metadata (root form)
//	GET  /.well-known/oauth-protected-resource/mcp   the same metadata, path-suffixed for /mcp (D-101)
//	GET  /.well-known/oauth-authorization-server RFC 8414 metadata
//	GET  /authorize                              pairing page; holds until the phone answers
//	POST /token                                  authorization code to grant token (PKCE)
//	POST /mcp                                    MCP Streamable HTTP, protocol 2025-11-25
package connector

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
)

// Options is what the connector needs from the rest of the gateway.
type Options struct {
	Config   config.Connector
	StateDir string
	Version  string // the gateway version, reported in MCP initialize
	Audit    *audit.Logger
	// Projects returns the ids of the registered projects.
	Projects func(ctx context.Context) ([]string, error)
	// SessionProject returns the project id of a session, or "" when the gateway does not know it.
	SessionProject func(ctx context.Context, sessionID string) (string, error)
	// Gateway is what the connector tools read and do on the gateway (D-096). The server implements it.
	Gateway Gateway
}

// Connector is one remote connector. A zero-config connector (Enabled false) starts no listener.
type Connector struct {
	opts   Options
	cfg    config.Connector
	audit  *audit.Logger
	grants *grantStore
	limits *limits
	turns  *turnRegistry // the turns send_prompt started, for get_turn (D-096)
	now    func() time.Time

	mu      sync.Mutex
	pending map[string]*pairing  // by pairing id; guarded by mu
	codes   map[string]*authCode // authorization codes not yet redeemed; guarded by mu

	ln   net.Listener
	http *http.Server
}

// New builds a connector. It binds nothing until Listen.
func New(opts Options) *Connector {
	c := &Connector{
		opts:    opts,
		cfg:     opts.Config,
		audit:   opts.Audit,
		grants:  newGrantStore(filepath.Join(opts.StateDir, "connector-grants.json")),
		limits:  newLimits(opts.Config.Limits),
		turns:   newTurnRegistry(),
		now:     time.Now,
		pending: map[string]*pairing{},
		codes:   map[string]*authCode{},
	}
	c.http = &http.Server{
		Handler:           c,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second, // the request is read in full well inside this; the held /authorize page only writes
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 * 1024,
	}
	return c
}

// Enabled reports whether the connector listens at all.
func (c *Connector) Enabled() bool { return c != nil && c.cfg.Enabled }

// Listen loads the grants file and binds 127.0.0.1 on the connector port. It is a no-op when the
// connector is off.
func (c *Connector) Listen() error {
	if !c.Enabled() {
		return nil
	}
	if err := c.grants.load(); err != nil {
		return err
	}
	ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(c.cfg.Port)))
	if err != nil {
		return fmt.Errorf("cannot listen on the connector port %d: %w", c.cfg.Port, err)
	}
	c.ln = ln
	c.audit.Log("connector_listening", audit.Fields{Reason: ln.Addr().String()})
	return nil
}

// Start serves the connector listener in the background. It is a no-op when Listen bound nothing.
func (c *Connector) Start() {
	if c == nil || c.ln == nil {
		return
	}
	go func() { _ = c.http.Serve(c.ln) }()
}

// Close stops the connector listener. Held pairing pages end when their connection closes.
func (c *Connector) Close() {
	if c == nil || c.ln == nil {
		return
	}
	_ = c.http.Close()
}

// The routes and the methods each one accepts (C4).
const (
	pathProtectedResource    = "/.well-known/oauth-protected-resource"
	pathProtectedResourceMCP = "/.well-known/oauth-protected-resource/mcp" // the form the spec derives for /mcp
	pathAuthorizationServer  = "/.well-known/oauth-authorization-server"
	pathAuthorize            = "/authorize"
	pathToken                = "/token"
	pathMCP                  = "/mcp"
)

// ServeHTTP routes a request. Unknown paths are 404; a known path with another method is 405.
func (c *Connector) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var method string
	var handle func(http.ResponseWriter, *http.Request)
	switch r.URL.Path {
	case pathProtectedResource, pathProtectedResourceMCP:
		method, handle = http.MethodGet, c.serveProtectedResource
	case pathAuthorizationServer:
		method, handle = http.MethodGet, c.serveAuthorizationServer
	case pathAuthorize:
		method, handle = http.MethodGet, c.serveAuthorize
	case pathToken:
		method, handle = http.MethodPost, c.serveToken
	case pathMCP:
		method, handle = http.MethodPost, c.serveMCP
	default:
		http.NotFound(w, r)
		return
	}
	if r.Method != method {
		w.Header().Set("Allow", method)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	// The Origin check applies to every route the connector serves (MCP transport, DNS rebinding).
	if !c.originAllowed(r) {
		c.audit.Log("connector_reject", audit.Fields{Client: clientAddr(r), Status: http.StatusForbidden, Reason: "origin"})
		http.Error(w, "origin not allowed", http.StatusForbidden)
		return
	}
	handle(w, r)
}

// originAllowed: a request with no Origin is allowed; one with an Origin must be in allowedOrigins.
func (c *Connector) originAllowed(r *http.Request) bool {
	values, present := r.Header["Origin"]
	if !present {
		return true
	}
	if len(values) != 1 {
		return false
	}
	for _, allowed := range c.cfg.AllowedOrigins {
		if strings.EqualFold(values[0], allowed) {
			return true
		}
	}
	return false
}

// resource is the canonical URI of the MCP server (RFC 8707, MCP 2025-11-25 Canonical Server URI).
func (c *Connector) resource() string { return c.cfg.PublicOrigin + pathMCP }

// resourceMatches accepts the canonical URI, with or without one trailing slash.
func (c *Connector) resourceMatches(value string) bool {
	return strings.TrimSuffix(value, "/") == c.resource()
}

func (c *Connector) serveProtectedResource(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"resource":                 c.resource(),
		"authorization_servers":    []string{c.cfg.PublicOrigin},
		"bearer_methods_supported": []string{"header"},
	})
}

func (c *Connector) serveAuthorizationServer(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"issuer":                                c.cfg.PublicOrigin,
		"authorization_endpoint":                c.cfg.PublicOrigin + pathAuthorize,
		"token_endpoint":                        c.cfg.PublicOrigin + pathToken,
		"response_types_supported":              []string{"code"},
		"grant_types_supported":                 []string{"authorization_code"},
		"code_challenge_methods_supported":      []string{"S256"},
		"token_endpoint_auth_methods_supported": []string{"none"},
	})
}

// authenticate checks the bearer grant token on /mcp. It writes the 401 and returns nil when the
// token is missing, malformed, unknown or revoked.
func (c *Connector) authenticate(w http.ResponseWriter, r *http.Request) *Grant {
	// The challenge names the path-suffixed form: the spec derives that URL for a resource at /mcp (D-101).
	challenge := `Bearer resource_metadata="` + c.cfg.PublicOrigin + pathProtectedResourceMCP + `"`
	token, ok := bearerToken(r.Header.Get("Authorization"))
	if !ok {
		w.Header().Set("WWW-Authenticate", challenge)
		c.audit.Log("connector_reject", audit.Fields{Client: clientAddr(r), Status: http.StatusUnauthorized, Reason: "no_token"})
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return nil
	}
	g := c.grants.byToken(token)
	if g == nil {
		w.Header().Set("WWW-Authenticate", challenge+`, error="invalid_token"`)
		c.audit.Log("connector_reject", audit.Fields{Client: clientAddr(r), Status: http.StatusUnauthorized, Reason: "invalid_token"})
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return nil
	}
	c.grants.touch(g.ID, c.now())
	return g
}

// bearerToken returns the token of an "Authorization: Bearer <token>" header.
func bearerToken(header string) (string, bool) {
	scheme, token, found := strings.Cut(header, " ")
	token = strings.TrimSpace(token)
	if !found || !strings.EqualFold(scheme, "Bearer") || token == "" {
		return "", false
	}
	return token, true
}

func clientAddr(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// writeJSON writes a JSON body with no caching (tokens and codes must never be cached).
func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

// randomString returns n random bytes, base64url without padding.
func randomString(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(fmt.Sprintf("crypto/rand: %v", err)) // the gateway cannot run without randomness
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

// hashToken is the SHA-256 of a token as lowercase hex: the form the grants file stores (D-003).
func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// invalidParams is a JSON-RPC invalid-params error for the phone.
func invalidParams(msg string) *RPCError { return &RPCError{Code: rpcInvalidParams, Message: msg} }

// RPCError is a JSON-RPC error the server returns to the phone.
type RPCError struct {
	Code    int
	Message string
}

const (
	rpcMethodNotFound = -32601
	rpcInvalidParams  = -32602
	rpcInternal       = -32603
	rpcForbidden      = -32003 // the caller may not make this call (a token's scope, or no device)
)

var errNotFound = errors.New("not found")
