package push

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"sync"
	"time"
)

// RefreshAfter is how old a cached provider token may get before it is rebuilt (PLAN 3.11). Apple
// accepts a token for up to 60 minutes and rejects one made more often than every 20 minutes, so
// 50 minutes sits inside that window.
const RefreshAfter = 50 * time.Minute

// Signer builds and caches the ES256 provider token that APNs requires (token-based auth). It is
// safe for concurrent use.
type Signer struct {
	key    *ecdsa.PrivateKey
	keyID  string
	teamID string
	now    func() time.Time

	mu     sync.Mutex
	token  string
	issued time.Time
}

// NewSigner returns a signer for the key, key id and team id.
func NewSigner(key *ecdsa.PrivateKey, keyID, teamID string) *Signer {
	return &Signer{key: key, keyID: keyID, teamID: teamID, now: time.Now}
}

// Token returns the cached token, or a new one when it is older than RefreshAfter or force is set.
func (s *Signer) Token(force bool) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	if !force && s.token != "" && now.Sub(s.issued) < RefreshAfter {
		return s.token, nil
	}
	tok, err := BuildJWT(s.key, s.keyID, s.teamID, now)
	if err != nil {
		return "", err
	}
	s.token, s.issued = tok, now
	return tok, nil
}

type jwtHeader struct {
	Alg string `json:"alg"`
	Kid string `json:"kid"`
}

type jwtClaims struct {
	Iss string `json:"iss"`
	Iat int64  `json:"iat"`
}

// BuildJWT returns a signed ES256 token: header {alg, kid}, claims {iss, iat}. The signature is the
// raw 64-byte r||s form that JWS uses (RFC 7518, section 3.4), not ASN.1.
func BuildJWT(key *ecdsa.PrivateKey, keyID, teamID string, now time.Time) (string, error) {
	h, err := json.Marshal(jwtHeader{Alg: "ES256", Kid: keyID})
	if err != nil {
		return "", err
	}
	c, err := json.Marshal(jwtClaims{Iss: teamID, Iat: now.Unix()})
	if err != nil {
		return "", err
	}
	signing := b64(h) + "." + b64(c)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + b64(sig), nil
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }
