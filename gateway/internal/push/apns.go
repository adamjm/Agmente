// Package push delivers APNs notifications (PLAN 3.11, FR-23, D-053). The payload comes from Build
// (D-038); this package adds token-based auth, the HTTP/2 POST, the retry rules and the answer
// handling. It uses only the standard library.
package push

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

// Options is the APNs configuration (SPEC 6.3, push block). The key is read from KeyFile.
type Options struct {
	KeyFile       string
	KeyID         string
	TeamID        string
	Topic         string
	SandboxURL    string // default DefaultSandboxURL
	ProductionURL string // default DefaultProductionURL
	CAFile        string // test only: PEM CA that trusts a fake APNs server (D-055)
	// Backoff is the wait before each retry of a 429 or 5xx answer. Nil means 500 ms, then 1 s:
	// at most two retries (FR-23 cleanup rules, PLAN 3.11).
	Backoff []time.Duration
}

const (
	DefaultSandboxURL    = "https://api.sandbox.push.apple.com"
	DefaultProductionURL = "https://api.push.apple.com"
)

var defaultBackoff = []time.Duration{500 * time.Millisecond, time.Second}

// Client sends notifications to APNs. It is safe for concurrent use.
type Client struct {
	topic   string
	urls    map[string]string
	signer  *Signer
	http    *http.Client
	backoff []time.Duration
}

// NewClient loads the key (refusing a readable or unparsable file) and builds the client.
func NewClient(o Options) (*Client, error) {
	key, err := LoadKey(o.KeyFile)
	if err != nil {
		return nil, err
	}
	tr := &http.Transport{
		ForceAttemptHTTP2: true,
		TLSClientConfig:   &tls.Config{MinVersion: tls.VersionTLS12},
	}
	if o.CAFile != "" {
		pem, err := os.ReadFile(o.CAFile)
		if err != nil {
			return nil, fmt.Errorf("push caFile %s cannot be read", o.CAFile)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("push caFile %s holds no certificate", o.CAFile)
		}
		tr.TLSClientConfig.RootCAs = pool
	}
	c := &Client{
		topic:   o.Topic,
		urls:    map[string]string{"sandbox": orDefault(o.SandboxURL, DefaultSandboxURL), "production": orDefault(o.ProductionURL, DefaultProductionURL)},
		signer:  NewSigner(key, o.KeyID, o.TeamID),
		http:    &http.Client{Transport: tr, Timeout: 15 * time.Second},
		backoff: o.Backoff,
	}
	if c.backoff == nil {
		c.backoff = defaultBackoff
	}
	return c, nil
}

func orDefault(v, d string) string {
	if v == "" {
		return d
	}
	return v
}

// Result is APNs' answer: the HTTP status and the reason in its JSON body. Status is 0 and Reason
// "transport" when the request never got an answer. The transport error text is never kept: it
// holds the URL, which holds the device token.
type Result struct {
	Status int
	Reason string
}

// Outcome is what the gateway does with an answer.
type Outcome int

const (
	Sent         Outcome = iota
	RemoveToken          // the device token is gone or never matched this app: delete it
	Retry                // 429 or 5xx: try again after the backoff
	RefreshToken         // 403 ExpiredProviderToken: rebuild the JWT and try once more
	Failed               // anything else: audit and move on
)

// Decide maps an APNs answer to an outcome (PLAN 3.11). It is the whole cleanup and retry policy.
func Decide(status int, reason string) Outcome {
	switch {
	case status == http.StatusOK:
		return Sent
	case status == http.StatusGone, reason == "Unregistered", reason == "BadDeviceToken", reason == "DeviceTokenNotForTopic":
		return RemoveToken
	case status == http.StatusForbidden && reason == "ExpiredProviderToken":
		return RefreshToken
	case status == http.StatusTooManyRequests, status >= 500:
		return Retry
	}
	return Failed
}

// Deliver sends one notification to a device token. environment picks the APNs host: "sandbox" or
// "production" (D-052). It retries 429 and 5xx at most len(backoff) times, and rebuilds the provider
// token once on ExpiredProviderToken.
func (c *Client) Deliver(ctx context.Context, token, environment string, payload []byte) (Result, error) {
	base, ok := c.urls[environment]
	if !ok {
		return Result{}, errors.New("unknown push environment")
	}
	refreshed := false
	force := false
	retries := 0
	for {
		jwt, err := c.signer.Token(force)
		if err != nil {
			return Result{Reason: "jwt"}, err
		}
		force = false
		res := c.post(ctx, base, token, jwt, payload)
		switch Decide(res.Status, res.Reason) {
		case RefreshToken:
			if refreshed {
				return res, nil
			}
			refreshed, force = true, true
		case Retry:
			if retries >= len(c.backoff) {
				return res, nil
			}
			select {
			case <-ctx.Done():
				return res, ctx.Err()
			case <-time.After(c.backoff[retries]):
			}
			retries++
		default:
			return res, nil
		}
	}
}

func (c *Client) post(ctx context.Context, base, token, jwt string, payload []byte) Result {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/3/device/"+token, bytes.NewReader(payload))
	if err != nil {
		return Result{Reason: "transport"}
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", c.topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")
	req.Header.Set("content-type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return Result{Reason: "transport"}
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	var parsed struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(body, &parsed)
	if parsed.Reason == "" {
		parsed.Reason = "none"
	}
	return Result{Status: resp.StatusCode, Reason: parsed.Reason}
}
