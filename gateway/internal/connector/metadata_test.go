package connector

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
)

// The protected-resource metadata is served at the root and at the path-suffixed form for /mcp (MCP
// 2025-11-25 Authorization, Well-Known URI). Both return the same body, for the resource
// publicOrigin plus /mcp, and the challenge on /mcp names the path-suffixed form (owner decision 44).
func TestProtectedResourceMetadataIsServedAtBothURLs(t *testing.T) {
	c := metadataConnector(t)
	const want = `{"authorization_servers":["https://name.example:8443"],"bearer_methods_supported":["header"],"resource":"https://name.example:8443/mcp"}`
	root := serve(c, http.MethodGet, "/.well-known/oauth-protected-resource")
	suffixed := serve(c, http.MethodGet, "/.well-known/oauth-protected-resource/mcp")
	for name, rec := range map[string]*httptest.ResponseRecorder{"root": root, "path-suffixed": suffixed} {
		if rec.Code != http.StatusOK {
			t.Fatalf("%s metadata: status %d", name, rec.Code)
		}
		if got := trimNL(rec.Body.String()); got != want {
			t.Fatalf("%s metadata body:\n got %s\nwant %s", name, got, want)
		}
	}
}

// The 401 on /mcp points to the path-suffixed metadata, the form the spec derives for /mcp.
func TestMCPChallengeNamesThePathSuffixedMetadata(t *testing.T) {
	c := metadataConnector(t)
	rec := serve(c, http.MethodPost, "/mcp")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("no token: status %d", rec.Code)
	}
	const want = `Bearer resource_metadata="https://name.example:8443/.well-known/oauth-protected-resource/mcp"`
	if got := rec.Header().Get("WWW-Authenticate"); got != want {
		t.Fatalf("WWW-Authenticate:\n got %s\nwant %s", got, want)
	}
}

// Every other path, and a wrong method on a known path, stay as they were.
func TestUnknownMetadataPathsAreNotFound(t *testing.T) {
	c := metadataConnector(t)
	for _, p := range []string{
		"/.well-known/oauth-protected-resource/other",
		"/.well-known/oauth-protected-resource/mcp/extra",
		"/.well-known/oauth-protected-resource/",
		"/mcp/.well-known/oauth-protected-resource",
	} {
		if rec := serve(c, http.MethodGet, p); rec.Code != http.StatusNotFound {
			t.Errorf("GET %s: status %d, want 404", p, rec.Code)
		}
	}
	if rec := serve(c, http.MethodPost, "/.well-known/oauth-protected-resource/mcp"); rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST the suffixed metadata: status %d, want 405", rec.Code)
	}
}

func metadataConnector(t *testing.T) *Connector {
	t.Helper()
	return New(Options{
		Config:   config.Connector{Enabled: true, Port: 8789, PublicOrigin: "https://name.example:8443", Limits: defaultLimits()},
		StateDir: t.TempDir(),
		Version:  "test",
		Audit:    audit.New(&bytes.Buffer{}),
	})
}

func serve(c *Connector, method, path string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, nil)
	rec := httptest.NewRecorder()
	c.ServeHTTP(rec, req)
	return rec
}

func trimNL(s string) string {
	for len(s) > 0 && (s[len(s)-1] == '\n' || s[len(s)-1] == '\r') {
		s = s[:len(s)-1]
	}
	return s
}
