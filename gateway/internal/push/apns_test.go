package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func newKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

// writeP8 writes a PKCS#8 PEM key with the given mode and returns its path.
func writeP8(t *testing.T, key *ecdsa.PrivateKey, mode os.FileMode) string {
	t.Helper()
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "AuthKey_TESTKEY123.p8")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestBuildJWTHeaderClaimsAndSignature(t *testing.T) {
	key := newKey(t)
	now := time.Unix(1_800_000_000, 0)
	tok, err := BuildJWT(key, "TESTKEY123", "TEAM123456", now)
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		t.Fatalf("want 3 parts, got %d", len(parts))
	}
	var h jwtHeader
	var c jwtClaims
	mustDecode(t, parts[0], &h)
	mustDecode(t, parts[1], &c)
	if h.Alg != "ES256" || h.Kid != "TESTKEY123" {
		t.Errorf("header = %+v", h)
	}
	if c.Iss != "TEAM123456" || c.Iat != now.Unix() {
		t.Errorf("claims = %+v", c)
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		t.Fatalf("signature must be 64 raw bytes (r||s), got %d (%v)", len(sig), err)
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r := new(big.Int).SetBytes(sig[:32])
	s := new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Fatal("signature does not verify against the public key")
	}
	// A different key must not verify it.
	other := newKey(t)
	if ecdsa.Verify(&other.PublicKey, digest[:], r, s) {
		t.Fatal("signature verified with the wrong key")
	}
}

func mustDecode(t *testing.T, part string, v any) {
	t.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(part)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, v); err != nil {
		t.Fatal(err)
	}
}

func TestSignerCachesThenRefreshesAfterRefreshAfter(t *testing.T) {
	key := newKey(t)
	clock := time.Unix(1_800_000_000, 0)
	s := NewSigner(key, "TESTKEY123", "TEAM123456")
	s.now = func() time.Time { return clock }
	first, err := s.Token(false)
	if err != nil {
		t.Fatal(err)
	}
	clock = clock.Add(RefreshAfter - time.Minute)
	if again, _ := s.Token(false); again != first {
		t.Error("a token younger than RefreshAfter must be reused")
	}
	clock = clock.Add(2 * time.Minute)
	refreshed, _ := s.Token(false)
	if refreshed == first {
		t.Error("a token older than RefreshAfter must be rebuilt")
	}
	if forced, _ := s.Token(true); forced == refreshed {
		t.Error("force must rebuild the token even when it is young")
	}
	if RefreshAfter < 20*time.Minute || RefreshAfter > 55*time.Minute {
		t.Errorf("RefreshAfter %v is outside the 20 to 55 minute window", RefreshAfter)
	}
}

func TestLoadKeyRefusesGroupOrWorldReadable(t *testing.T) {
	key := newKey(t)
	for _, mode := range []os.FileMode{0o640, 0o604, 0o644} {
		path := writeP8(t, key, mode)
		_, err := LoadKey(path)
		if err == nil || !strings.Contains(err.Error(), "group or others") {
			t.Errorf("mode %o: want a refusal, got %v", mode, err)
		}
	}
	if _, err := LoadKey(writeP8(t, key, 0o600)); err != nil {
		t.Errorf("owner-only key must load: %v", err)
	}
}

func TestLoadKeyRefusesUnparsableAndWrongCurve(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bad.p8")
	if err := os.WriteFile(path, []byte("not a key"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadKey(path); err == nil || strings.Contains(err.Error(), "not a key") {
		t.Errorf("unparsable key: want a refusal without the file's bytes, got %v", err)
	}
	// A PKCS#8 PEM block whose body is not DER reaches the parse branch. (The wire test uses a
	// neutral PEM label, so this is the only test of "cannot be parsed".)
	bogus := filepath.Join(t.TempDir(), "bogus.p8")
	if err := os.WriteFile(bogus, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: []byte("not der")}), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadKey(bogus); err == nil || !strings.Contains(err.Error(), "cannot be parsed") || strings.Contains(err.Error(), "not der") {
		t.Errorf("PKCS#8 label with a non-DER body: want a parse refusal without the bytes, got %v", err)
	}
	if _, err := LoadKey(filepath.Join(t.TempDir(), "missing.p8")); err == nil {
		t.Error("a missing key must be refused")
	}
	p256, _ := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	if _, err := LoadKey(writeP8(t, p256, 0o600)); err == nil || !strings.Contains(err.Error(), "P-256") {
		t.Errorf("a P-384 key must be refused, got %v", err)
	}
}

func TestDecideCleanupAndRetryRules(t *testing.T) {
	cases := []struct {
		status int
		reason string
		want   Outcome
	}{
		{200, "", Sent},
		{410, "Unregistered", RemoveToken},
		{410, "none", RemoveToken},
		{400, "BadDeviceToken", RemoveToken},
		{400, "DeviceTokenNotForTopic", RemoveToken},
		{400, "Unregistered", RemoveToken},
		{403, "ExpiredProviderToken", RefreshToken},
		{403, "InvalidProviderToken", Failed},
		{429, "TooManyRequests", Retry},
		{500, "InternalServerError", Retry},
		{503, "ServiceUnavailable", Retry},
		{400, "PayloadTooLarge", Failed},
		{0, "transport", Failed},
	}
	for _, c := range cases {
		if got := Decide(c.status, c.reason); got != c.want {
			t.Errorf("Decide(%d, %q) = %v, want %v", c.status, c.reason, got, c.want)
		}
	}
}

// fakeAPNs answers each request from a script and records what it saw.
type fakeAPNs struct {
	mu       sync.Mutex
	script   []answer
	requests []seenRequest
}

type answer struct {
	status int
	reason string
}

type seenRequest struct {
	path, auth, topic, pushType string
}

func (f *fakeAPNs) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.requests = append(f.requests, seenRequest{r.URL.Path, r.Header.Get("authorization"), r.Header.Get("apns-topic"), r.Header.Get("apns-push-type")})
	a := answer{status: 200}
	if len(f.script) > 0 {
		a = f.script[0]
		f.script = f.script[1:]
	}
	w.WriteHeader(a.status)
	if a.reason != "" {
		_, _ = w.Write([]byte(`{"reason":"` + a.reason + `"}`))
	}
}

func newTestClient(t *testing.T, srv *httptest.Server, key *ecdsa.PrivateKey) *Client {
	t.Helper()
	return &Client{
		topic:   "com.example.acpcode",
		urls:    map[string]string{"sandbox": srv.URL, "production": srv.URL},
		signer:  NewSigner(key, "TESTKEY123", "TEAM123456"),
		http:    srv.Client(),
		backoff: []time.Duration{0, 0},
	}
}

func TestDeliverRetriesThenSucceeds(t *testing.T) {
	f := &fakeAPNs{script: []answer{{429, "TooManyRequests"}, {503, "ServiceUnavailable"}}}
	srv := httptest.NewUnstartedServer(f)
	srv.EnableHTTP2 = true
	srv.StartTLS()
	defer srv.Close()
	c := newTestClient(t, srv, newKey(t))
	res, err := c.Deliver(context.Background(), "ab", "sandbox", []byte(`{}`))
	if err != nil || res.Status != 200 {
		t.Fatalf("want success after two retries, got %+v %v", res, err)
	}
	if len(f.requests) != 3 {
		t.Errorf("want 3 requests (1 + 2 retries), got %d", len(f.requests))
	}
	for _, r := range f.requests {
		if r.topic != "com.example.acpcode" || r.pushType != "alert" || !strings.HasPrefix(r.auth, "bearer ") {
			t.Errorf("headers wrong: %+v", r)
		}
	}
}

func TestDeliverStopsAfterTwoRetries(t *testing.T) {
	f := &fakeAPNs{script: []answer{{500, "InternalServerError"}, {500, "InternalServerError"}, {500, "InternalServerError"}, {200, ""}}}
	srv := httptest.NewUnstartedServer(f)
	srv.EnableHTTP2 = true
	srv.StartTLS()
	defer srv.Close()
	c := newTestClient(t, srv, newKey(t))
	res, _ := c.Deliver(context.Background(), "ab", "sandbox", []byte(`{}`))
	if res.Status != 500 || len(f.requests) != 3 {
		t.Errorf("want 3 attempts and the last 500, got %d attempts and %+v", len(f.requests), res)
	}
}

func TestDeliverRefreshesJWTOnceOnExpiredProviderToken(t *testing.T) {
	f := &fakeAPNs{script: []answer{{403, "ExpiredProviderToken"}, {200, ""}}}
	srv := httptest.NewUnstartedServer(f)
	srv.EnableHTTP2 = true
	srv.StartTLS()
	defer srv.Close()
	c := newTestClient(t, srv, newKey(t))
	res, _ := c.Deliver(context.Background(), "ab", "sandbox", []byte(`{}`))
	if res.Status != 200 || len(f.requests) != 2 {
		t.Fatalf("want success on the second attempt, got %d attempts and %+v", len(f.requests), res)
	}
	if f.requests[0].auth == f.requests[1].auth {
		t.Error("the retry must carry a new provider token")
	}

	f2 := &fakeAPNs{script: []answer{{403, "ExpiredProviderToken"}, {403, "ExpiredProviderToken"}, {200, ""}}}
	srv2 := httptest.NewUnstartedServer(f2)
	srv2.EnableHTTP2 = true
	srv2.StartTLS()
	defer srv2.Close()
	c2 := newTestClient(t, srv2, newKey(t))
	res, _ = c2.Deliver(context.Background(), "ab", "sandbox", []byte(`{}`))
	if len(f2.requests) != 2 || res.Status != 403 {
		t.Errorf("the JWT is refreshed once only: got %d attempts and %+v", len(f2.requests), res)
	}
}

func TestDeliverRejectsUnknownEnvironment(t *testing.T) {
	c := &Client{urls: map[string]string{"sandbox": "https://x"}}
	if _, err := c.Deliver(context.Background(), "ab", "staging", nil); err == nil {
		t.Error("an unknown environment must be an error")
	}
}
