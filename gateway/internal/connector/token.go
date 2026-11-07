package connector

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"net/http"
	"strings"
	"time"

	"agmente/gateway/internal/audit"
)

// serveToken exchanges an authorization code for the grant's bearer token (OAuth 2.1 section 4.1.3
// with PKCE, RFC 8707 resource). The code is single use: it is removed on the first attempt.
func (c *Connector) serveToken(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if err := r.ParseForm(); err != nil {
		tokenError(w, "invalid_request", "the request body is not a form")
		return
	}
	if r.PostForm.Get("grant_type") != "authorization_code" {
		tokenError(w, "unsupported_grant_type", "grant_type must be authorization_code")
		return
	}
	if r.PostForm.Has("resource") && !c.resourceMatches(r.PostForm.Get("resource")) {
		tokenError(w, "invalid_target", "resource must be "+c.resource())
		return
	}

	code := r.PostForm.Get("code")
	c.mu.Lock()
	ac := c.codes[code]
	delete(c.codes, code) // single use, even when the check below fails
	c.mu.Unlock()
	if ac == nil || c.now().After(ac.expiresAt) {
		tokenError(w, "invalid_grant", "the code is unknown, used or expired")
		return
	}
	if r.PostForm.Get("client_id") != ac.clientID || r.PostForm.Get("redirect_uri") != ac.redirectURI {
		tokenError(w, "invalid_grant", "client_id or redirect_uri does not match the authorization request")
		return
	}
	if !verifyPKCE(r.PostForm.Get("code_verifier"), ac.challenge) {
		tokenError(w, "invalid_grant", "code_verifier does not match the code_challenge")
		return
	}
	if c.grants.find(ac.grantID) == nil {
		tokenError(w, "invalid_grant", "the grant was revoked before the token was issued")
		return
	}

	token := randomString(32) // 256 bits; shown once, stored only as a hash (D-003)
	if err := c.grants.setToken(ac.grantID, hashToken(token)); err != nil {
		tokenError(w, "server_error", "cannot save the grant")
		return
	}
	c.audit.Log("connector_token", audit.Fields{Client: clientAddr(r), Reason: "grant:" + ac.grantID})
	writeJSON(w, http.StatusOK, map[string]string{"access_token": token, "token_type": "Bearer"})
}

// verifyPKCE checks an S256 code_verifier against the stored challenge in constant time (RFC 7636).
func verifyPKCE(verifier, challenge string) bool {
	if len(verifier) < 43 || len(verifier) > 128 {
		return false
	}
	for i := 0; i < len(verifier); i++ {
		if !strings.ContainsRune(unreserved, rune(verifier[i])) {
			return false
		}
	}
	sum := sha256.Sum256([]byte(verifier))
	want := base64.RawURLEncoding.EncodeToString(sum[:])
	return subtle.ConstantTimeCompare([]byte(want), []byte(challenge)) == 1
}

// unreserved is the RFC 7636 code_verifier alphabet: anything else is rejected.
const unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

func tokenError(w http.ResponseWriter, code, description string) {
	writeJSON(w, http.StatusBadRequest, map[string]string{"error": code, "error_description": description})
}

// expiredCodes drops codes past their lifetime. It runs under mu.
func (c *Connector) expiredCodes(now time.Time) {
	for k, ac := range c.codes {
		if now.After(ac.expiresAt) {
			delete(c.codes, k)
		}
	}
}
