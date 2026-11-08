package server

// Bearer-token authentication and the failed-auth rate limiter (FR-1, FR-8, NFR-5).

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"net"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"acpcode/gateway/internal/config"
)

var bearer = regexp.MustCompile(`(?i)^Bearer\s+([A-Za-z0-9._~+/=-]{16,512})\s*$`)

// HashToken is the SHA-256 of a token, as lowercase hex.
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func parseBearer(header string) (string, bool) {
	m := bearer.FindStringSubmatch(header)
	if m == nil {
		return "", false
	}
	return m[1], true
}

// findToken returns the entry whose hash matches. It compares against every entry in constant
// time and does not stop early, so timing does not reveal which entry matched.
func findToken(tokens []config.Token, header string) *config.Token {
	token, ok := parseBearer(header)
	if !ok {
		return nil
	}
	sum := sha256.Sum256([]byte(token))
	var found *config.Token
	for i := range tokens {
		expected, err := hex.DecodeString(tokens[i].SHA256)
		if err == nil && subtle.ConstantTimeCompare(expected, sum[:]) == 1 && found == nil {
			found = &tokens[i]
		}
	}
	return found
}

// clientKey is the address to rate-limit on. Behind Caddy every peer is loopback, so use the
// X-Forwarded-For header, but only when trustProxy is on and the peer is loopback. Use the LAST
// entry: the proxy appends the address it saw. Earlier entries come from the client.
func clientKey(r *http.Request, trustProxy bool) string {
	peer, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		peer = r.RemoteAddr
	}
	if trustProxy && config.IsLoopbackAddress(peer) {
		var last string
		for _, value := range r.Header.Values("X-Forwarded-For") {
			for _, part := range strings.Split(value, ",") {
				if p := strings.TrimSpace(part); p != "" {
					last = p
				}
			}
		}
		if last != "" {
			return last
		}
	}
	return peer
}

// failureLimiter counts failures per key in a sliding window and locks a key out once it reaches
// the limit.
type failureLimiter struct {
	mu          sync.Mutex
	maxFailures int
	window      time.Duration
	lockout     time.Duration
	now         func() time.Time
	failures    map[string][]time.Time
	lockedUntil map[string]time.Time
}

func newFailureLimiter(maxFailures int, window, lockout time.Duration) *failureLimiter {
	return &failureLimiter{
		maxFailures: maxFailures, window: window, lockout: lockout, now: time.Now,
		failures: map[string][]time.Time{}, lockedUntil: map[string]time.Time{},
	}
}

func (l *failureLimiter) isLocked(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	until, ok := l.lockedUntil[key]
	if !ok {
		return false
	}
	if l.now().Before(until) {
		return true
	}
	delete(l.lockedUntil, key)
	return false
}

func (l *failureLimiter) recordFailure(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	t := l.now()
	recent := l.failures[key][:0:0]
	for _, ts := range l.failures[key] {
		if t.Sub(ts) < l.window {
			recent = append(recent, ts)
		}
	}
	recent = append(recent, t)
	l.failures[key] = recent
	if len(recent) >= l.maxFailures {
		l.lockedUntil[key] = t.Add(l.lockout)
		delete(l.failures, key)
	}
	if len(l.failures) >= 10_000 {
		for k, list := range l.failures {
			if len(list) == 0 || t.Sub(list[len(list)-1]) >= l.window {
				delete(l.failures, k)
			}
		}
	}
}
