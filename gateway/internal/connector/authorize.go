package connector

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"html"
	"math/big"
	"net/http"
	"net/url"
	"regexp"
	"time"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/jsonv"
)

// maxPendingPairings bounds the pairing pages a public client can hold open at once.
const maxPendingPairings = 5

// maxWrongCodes is how many wrong codes the phone may send for one pairing before the pairing is
// removed the way deny removes it (D-097).
const maxWrongCodes = 5

// codeNeededMessage is the refusal for an approve with no six-digit code. It is not a wrong attempt.
const codeNeededMessage = "approve needs the six-digit code shown on the client's page"

// wrongCodeMessage is the refusal for a six-digit code that is not the pairing's code.
const wrongCodeMessage = "the code does not match the one on the client's page"

// authCode is an authorization code issued after an approval. It is single use and short lived.
type authCode struct {
	grantID     string
	clientID    string
	redirectURI string
	challenge   string
	expiresAt   time.Time
}

const authCodeTTL = 60 * time.Second

// pairing is one client waiting for the phone (C5). decision receives exactly one value.
type pairing struct {
	ID          string
	Code        string
	ClientName  string
	RequestedAt time.Time
	ExpiresAt   time.Time
	clientID    string
	redirectURI string
	state       string
	challenge   string
	resource    string
	decision    chan decision
	wrongCodes  int // wrong codes the phone sent for this pairing; guarded by Connector.mu
}

type decision struct {
	code   string // the authorization code, when approved
	denied bool
	reason string // access_denied detail for the client
}

var (
	clientIDPattern    = regexp.MustCompile(`^[\x21-\x7e]{1,512}$`)
	codeChallengeRegex = regexp.MustCompile(`^[A-Za-z0-9_-]{43,128}$`)
)

// serveAuthorize opens a pairing and holds the page until the phone answers, the pairing times out,
// or the client goes away. The page is streamed: the code shows at once, and the redirect is
// appended when the decision arrives.
func (c *Connector) serveAuthorize(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if msg := c.checkAuthorizeQuery(q); msg != "" {
		http.Error(w, msg, http.StatusBadRequest)
		return
	}
	p, err := c.newPairing(q, clientAddr(r))
	if err != nil {
		http.Error(w, err.Error(), http.StatusTooManyRequests)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Connect to ACP Code</title></head>`+
		`<body style="font-family:-apple-system,system-ui,sans-serif;padding:24px;max-width:480px;line-height:1.4">`+
		`<h1 style="font-size:22px">Approve on your phone</h1>`+
		`<p>Check that this code matches the code on your ACP Code phone:</p>`+
		`<p style="font-size:40px;letter-spacing:4px;font-weight:600">%s %s</p>`+
		`<p>Connecting: <code>%s</code>. This page finishes when your phone answers. Keep it open.</p>`,
		p.Code[:3], p.Code[3:], html.EscapeString(p.ClientName))
	flush(w)

	timer := time.NewTimer(time.Until(p.ExpiresAt))
	defer timer.Stop()
	select {
	case d := <-p.decision:
		c.finish(w, p, d)
	case <-timer.C:
		d := c.expire(p)
		c.finish(w, p, d)
	case <-r.Context().Done():
		c.cancel(p)
	}
}

// checkAuthorizeQuery returns a plain reason when the request is not a PKCE authorization request
// for the MCP server. These errors are shown on the page, not sent to a redirect, because the
// redirect URI itself may be the problem.
func (c *Connector) checkAuthorizeQuery(q url.Values) string {
	switch {
	case q.Get("response_type") != "code":
		return "response_type must be code"
	case !clientIDPattern.MatchString(q.Get("client_id")):
		return "client_id is required"
	case !validRedirectURI(q.Get("redirect_uri")):
		return "redirect_uri must be https, or http on localhost"
	case q.Get("code_challenge_method") != "S256":
		return "code_challenge_method must be S256 (PKCE is required)"
	case !codeChallengeRegex.MatchString(q.Get("code_challenge")):
		return "code_challenge is required"
	case len(q.Get("state")) > 512:
		return "state is too long"
	case q.Has("resource") && !c.resourceMatches(q.Get("resource")):
		return "resource must be " + c.resource()
	}
	return ""
}

// validRedirectURI: https, or http to a loopback host (MCP 2025-11-25 Open Redirection). The
// redirect is not checked against a pre-registered list, because no registration exists (D-095).
func validRedirectURI(raw string) bool {
	if raw == "" || len(raw) > 2048 {
		return false
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.Fragment != "" || u.User != nil {
		return false
	}
	switch u.Scheme {
	case "https":
		return true
	case "http":
		h := u.Hostname()
		return h == "localhost" || h == "127.0.0.1" || h == "::1"
	}
	return false
}

// newPairing records a pending pairing with a fresh six-digit code. It fails when too many are open.
func (c *Connector) newPairing(q url.Values, client string) (*pairing, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		panic(fmt.Sprintf("crypto/rand: %v", err))
	}
	now := c.now()
	name := q.Get("client_id")
	if len(name) > 120 {
		name = name[:120]
	}
	p := &pairing{
		ID:          randomString(12),
		Code:        fmt.Sprintf("%06d", n.Int64()),
		ClientName:  name,
		RequestedAt: now,
		ExpiresAt:   now.Add(time.Duration(c.cfg.PairingTimeoutSeconds) * time.Second),
		clientID:    q.Get("client_id"),
		redirectURI: q.Get("redirect_uri"),
		state:       q.Get("state"),
		challenge:   q.Get("code_challenge"),
		resource:    c.resource(),
		decision:    make(chan decision, 1),
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.pending) >= maxPendingPairings {
		return nil, fmt.Errorf("too many pairings are waiting for the phone (limit %d); try again later", maxPendingPairings)
	}
	c.pending[p.ID] = p
	c.audit.Log("connector_pairing", audit.Fields{Client: client, Reason: "requested"})
	return p, nil
}

// expire removes a pairing whose time ran out and returns its decision: denied, unless the phone
// answered at the same moment, in which case that answer stands.
func (c *Connector) expire(p *pairing) decision {
	c.mu.Lock()
	if _, open := c.pending[p.ID]; open {
		delete(c.pending, p.ID)
		c.mu.Unlock()
		c.audit.Log("connector_pairing", audit.Fields{Reason: "timeout"})
		return decision{denied: true, reason: "the pairing timed out"}
	}
	c.mu.Unlock()
	return <-p.decision // the phone answered first; its decision is already in the channel
}

// cancel drops a pairing whose client went away.
func (c *Connector) cancel(p *pairing) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, open := c.pending[p.ID]; open {
		delete(c.pending, p.ID)
		c.audit.Log("connector_pairing", audit.Fields{Reason: "cancelled"})
	}
}

// finish ends the held page with a redirect to the client's redirect URI: the code on approval,
// access_denied otherwise. The redirect is a script, so a browser follows it; a link is the fallback.
func (c *Connector) finish(w http.ResponseWriter, p *pairing, d decision) {
	target, _ := url.Parse(p.redirectURI)
	q := target.Query()
	if d.denied {
		q.Set("error", "access_denied")
		q.Set("error_description", d.reason)
	} else {
		q.Set("code", d.code)
	}
	if p.state != "" {
		q.Set("state", p.state)
	}
	target.RawQuery = q.Encode()
	location := target.String()
	js, _ := json.Marshal(location) // escapes < > & for use inside a script element
	fmt.Fprintf(w, `<p><a href="%s">Continue</a></p><script>location.replace(%s);</script></body></html>`,
		html.EscapeString(location), js)
	flush(w)
}

func flush(w http.ResponseWriter) {
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}

// Phone answers the phone's _acpcode/connector/* methods (C5). It is nil-safe: a disabled connector
// has no methods, so each one is method-not-found.
func (c *Connector) Phone(ctx context.Context, who audit.Who, method string, params *jsonv.Value) (any, *RPCError) {
	if !c.Enabled() {
		return nil, &RPCError{Code: rpcMethodNotFound, Message: "Method not found"}
	}
	// Only a phone token (which has a device id) may pair or manage grants (D-097). A call with no
	// device is a gateway's own call, and the gateway never makes one of these.
	if who.Device == "" {
		return nil, &RPCError{Code: rpcForbidden, Message: "only a phone may call " + method}
	}
	raw := json.RawMessage("null")
	if params != nil {
		raw = params.Marshal()
	}
	switch method {
	case "_acpcode/connector/pending":
		return c.pendingList(), nil
	case "_acpcode/connector/approve":
		return c.approve(ctx, who, raw)
	case "_acpcode/connector/deny":
		return c.deny(who, raw)
	case "_acpcode/connector/grants":
		return c.grantList(), nil
	case "_acpcode/connector/revoke":
		return c.revoke(who, raw)
	}
	return nil, &RPCError{Code: rpcMethodNotFound, Message: "Method not found"}
}

func (c *Connector) pendingList() map[string]any {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]map[string]any, 0, len(c.pending))
	for _, p := range c.pending {
		// redirectHost is an addition to C5: the phone shows where the code would be sent, so the
		// owner can refuse a pairing that redirects to an unexpected host.
		out = append(out, map[string]any{
			"pairingId":    p.ID,
			"code":         p.Code,
			"clientName":   p.ClientName,
			"redirectHost": redirectHost(p.redirectURI),
			"requestedAt":  rfc3339(p.RequestedAt),
			"expiresAt":    rfc3339(p.ExpiresAt),
		})
	}
	return map[string]any{"pairings": out}
}

type pairingParams struct {
	PairingID string `json:"pairingId"`
	Scope     *Scope `json:"scope"`
}

// approveParams is what the phone sends on approve. Code is typed any so that a missing or
// non-string code is refused with the code message, not as a malformed request.
type approveParams struct {
	PairingID string `json:"pairingId"`
	Scope     *Scope `json:"scope"`
	Code      any    `json:"code"`
}

func (c *Connector) approve(ctx context.Context, who audit.Who, params json.RawMessage) (any, *RPCError) {
	var in approveParams
	if err := json.Unmarshal(params, &in); err != nil || in.PairingID == "" {
		return nil, invalidParams("approve needs pairingId and scope")
	}
	// The code is checked before the scope and before anything is created (D-097).
	sent, isString := in.Code.(string)
	if !isString || !isSixDigits(sent) {
		return nil, invalidParams(codeNeededMessage)
	}
	p, rerr := c.checkCode(who, in.PairingID, sent)
	if rerr != nil {
		return nil, rerr
	}
	if in.Scope == nil {
		return nil, invalidParams("approve needs scope")
	}
	if rerr := c.checkScope(ctx, *in.Scope); rerr != nil {
		return nil, rerr
	}
	g := &Grant{
		ID:        randomString(12),
		Label:     p.ClientName,
		Scope:     *in.Scope,
		CreatedAt: c.now(),
		ClientID:  p.clientID,
		Resource:  p.resource,
	}
	if err := c.grants.add(g); err != nil {
		return nil, &RPCError{Code: rpcInternal, Message: "cannot save the grant"}
	}
	c.mu.Lock()
	if _, still := c.pending[p.ID]; !still {
		c.mu.Unlock()
		_, _ = c.grants.remove(g.ID)
		return nil, invalidParams("no pending pairing with that pairingId (it may have timed out)")
	}
	code := randomString(32)
	c.expiredCodes(c.now())
	c.codes[code] = &authCode{grantID: g.ID, clientID: p.clientID, redirectURI: p.redirectURI, challenge: p.challenge, expiresAt: c.now().Add(authCodeTTL)}
	delete(c.pending, p.ID)
	p.decision <- decision{code: code} // buffered, and only one send ever happens (the pending entry is gone)
	c.mu.Unlock()
	c.audit.Log("connector_pairing", audit.Fields{Identity: who.Identity, Device: who.Device, Reason: "approved grant:" + g.ID})
	return map[string]any{"grantId": g.ID}, nil
}

// checkCode finds the pending pairing and compares the phone's code with the pairing's code in
// constant time. A match returns the pairing. A wrong code is counted under the lock; the
// maxWrongCodes-th removes the pairing the way deny does, so the client gets the same denial.
func (c *Connector) checkCode(who audit.Who, pairingID, code string) (*pairing, *RPCError) {
	c.mu.Lock()
	p, open := c.pending[pairingID]
	if !open {
		c.mu.Unlock()
		return nil, invalidParams("no pending pairing with that pairingId (it may have timed out)")
	}
	if subtle.ConstantTimeCompare([]byte(code), []byte(p.Code)) == 1 {
		c.mu.Unlock()
		return p, nil
	}
	p.wrongCodes++
	removed := p.wrongCodes >= maxWrongCodes
	if removed {
		delete(c.pending, p.ID)
		p.decision <- decision{denied: true, reason: "the owner denied the pairing"} // buffered; the pending entry is gone, so this is the only send
	}
	c.mu.Unlock()
	c.audit.Log("connector_pairing", audit.Fields{Identity: who.Identity, Device: who.Device, Reason: "wrong code"})
	if removed {
		c.audit.Log("connector_pairing", audit.Fields{Identity: who.Identity, Device: who.Device, Reason: "too many wrong codes"})
	}
	return nil, invalidParams(wrongCodeMessage)
}

// isSixDigits reports whether s is exactly six ASCII digits.
func isSixDigits(s string) bool {
	if len(s) != 6 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// checkScope validates a scope the phone sends: projects must be registered, and sessions must be
// known and inside the listed projects (C5).
func (c *Connector) checkScope(ctx context.Context, s Scope) *RPCError {
	projects, err := c.opts.Projects(ctx)
	if err != nil {
		return &RPCError{Code: rpcInternal, Message: "cannot read projects"}
	}
	if !s.AllProjects {
		if len(s.Projects) == 0 {
			return invalidParams("scope.projects must name at least one project or be \"all\"")
		}
		for _, id := range s.Projects {
			if !contains(projects, id) {
				return invalidParams("scope names a project that is not registered: " + id)
			}
		}
	}
	if s.HasSessions {
		if len(s.Sessions) == 0 {
			return invalidParams("scope.sessions must name at least one session or be left out")
		}
		for _, sid := range s.Sessions {
			pid, err := c.opts.SessionProject(ctx, sid)
			if err != nil {
				return &RPCError{Code: rpcInternal, Message: "cannot read sessions"}
			}
			if pid == "" || !s.Allows(pid, "") {
				return invalidParams("scope names a session that is not in the listed projects: " + sid)
			}
		}
	}
	return nil
}

func (c *Connector) deny(who audit.Who, params json.RawMessage) (any, *RPCError) {
	var in pairingParams
	if err := json.Unmarshal(params, &in); err != nil || in.PairingID == "" {
		return nil, invalidParams("deny needs pairingId")
	}
	c.mu.Lock()
	p, open := c.pending[in.PairingID]
	if open {
		delete(c.pending, p.ID)
		p.decision <- decision{denied: true, reason: "the owner denied the pairing"}
	}
	c.mu.Unlock()
	if !open {
		return nil, invalidParams("no pending pairing with that pairingId (it may have timed out)")
	}
	c.audit.Log("connector_pairing", audit.Fields{Identity: who.Identity, Device: who.Device, Reason: "denied"})
	return map[string]any{}, nil
}

func (c *Connector) grantList() map[string]any {
	grants := c.grants.list()
	out := make([]map[string]any, 0, len(grants))
	for _, g := range grants {
		item := map[string]any{
			"grantId":   g.ID,
			"label":     g.Label,
			"scope":     g.Scope,
			"createdAt": rfc3339(g.CreatedAt),
		}
		if g.LastUsedAt != nil {
			item["lastUsedAt"] = rfc3339(*g.LastUsedAt)
		}
		out = append(out, item)
	}
	return map[string]any{"grants": out}
}

func (c *Connector) revoke(who audit.Who, params json.RawMessage) (any, *RPCError) {
	var in struct {
		GrantID string `json:"grantId"`
	}
	if err := json.Unmarshal(params, &in); err != nil || in.GrantID == "" {
		return nil, invalidParams("revoke needs grantId")
	}
	if _, err := c.grants.remove(in.GrantID); err != nil {
		if err == errNotFound {
			return nil, invalidParams("no such grant")
		}
		return nil, &RPCError{Code: rpcInternal, Message: "cannot save the grants"}
	}
	c.audit.Log("connector_revoke", audit.Fields{Identity: who.Identity, Device: who.Device, Reason: "grant:" + in.GrantID})
	return map[string]any{}, nil
}

// redirectHost is the host of a redirect URI, for the phone's pairing prompt.
func redirectHost(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	return u.Host
}

func rfc3339(t time.Time) string { return t.UTC().Format(time.RFC3339) }
