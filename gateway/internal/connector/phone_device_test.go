package connector

import (
	"bytes"
	"context"
	"encoding/json"
	"net/url"
	"strings"
	"testing"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/jsonv"
)

// An enabled connector answers the phone's methods. A call with no device id is refused before any
// pairing is touched (D-097: only a phone approves).
func TestPhoneRefusesEmptyDevice(t *testing.T) {
	c := New(Options{
		Config:   config.Connector{Enabled: true, PublicOrigin: "https://connector.test.example", PairingTimeoutSeconds: 60},
		StateDir: t.TempDir(),
		Version:  "test",
		Audit:    audit.New(&bytes.Buffer{}),
		Projects: func(context.Context) ([]string, error) { return nil, nil },
	})
	for _, method := range []string{"_acpcode/connector/approve", "_acpcode/connector/revoke", "_acpcode/connector/pending"} {
		_, rerr := c.Phone(context.Background(), audit.Who{Identity: "owner"}, method, nil)
		if rerr == nil || rerr.Code != -32003 {
			t.Fatalf("%s with no device: %+v, want -32003", method, rerr)
		}
	}
	if _, rerr := c.Phone(context.Background(), audit.Who{Identity: "owner", Device: "phone"}, "_acpcode/connector/pending", nil); rerr != nil {
		t.Fatalf("a phone with a device was refused: %+v", rerr)
	}
}

// approveConnector is an enabled connector with one registered project and a buffer for its audit
// lines (D-097: approve needs the six-digit code).
func approveConnector(t *testing.T) (*Connector, *bytes.Buffer) {
	t.Helper()
	buf := &bytes.Buffer{}
	c := New(Options{
		Config:   config.Connector{Enabled: true, PublicOrigin: "https://connector.test.example", PairingTimeoutSeconds: 60},
		StateDir: t.TempDir(),
		Version:  "test",
		Audit:    audit.New(buf),
		Projects: func(context.Context) ([]string, error) { return []string{"p1"}, nil },
	})
	return c, buf
}

// openTestPairing records a pending pairing the way /authorize does.
func openTestPairing(t *testing.T, c *Connector) *pairing {
	t.Helper()
	q := url.Values{
		"client_id":      {"claude"},
		"redirect_uri":   {"https://claude.example/callback"},
		"code_challenge": {strings.Repeat("a", 43)},
	}
	p, err := c.newPairing(q, "203.0.113.5")
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// wrongCodeFor returns a six-digit code that is not code.
func wrongCodeFor(code string) string {
	if code == "000000" {
		return "000001"
	}
	return "000000"
}

// approveBody builds the approve params. A nil code leaves the key out, so "missing" and "null"
// are both sent on purpose.
func approveBody(t *testing.T, pairingID string, code any, omitCode bool) *jsonv.Value {
	t.Helper()
	m := map[string]any{"pairingId": pairingID, "scope": map[string]any{"projects": "all"}}
	if !omitCode {
		m["code"] = code
	}
	raw, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	v, err := jsonv.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

var phoneWho = audit.Who{Identity: "owner", Device: "phone-1"}

func TestApproveWithRightCodeSucceeds(t *testing.T) {
	c, buf := approveConnector(t)
	p := openTestPairing(t, c)
	res, rerr := c.Phone(context.Background(), phoneWho, "_acpcode/connector/approve", approveBody(t, p.ID, p.Code, false))
	if rerr != nil {
		t.Fatalf("approve with the right code refused: %+v", rerr)
	}
	grantID, _ := res.(map[string]any)["grantId"].(string)
	if grantID == "" {
		t.Fatalf("no grantId in %+v", res)
	}
	if n := len(c.grants.list()); n != 1 {
		t.Fatalf("grants = %d, want 1", n)
	}
	c.mu.Lock()
	_, still := c.pending[p.ID]
	c.mu.Unlock()
	if still {
		t.Fatal("an approved pairing must leave the pending list")
	}
	select {
	case d := <-p.decision:
		if d.denied || d.code == "" {
			t.Fatalf("decision = %+v, want an authorization code", d)
		}
	default:
		t.Fatal("the held page was not given a decision")
	}
	if strings.Contains(buf.String(), `"`+p.Code+`"`) {
		t.Fatal("the audit log holds the pairing code")
	}
}

func TestApproveWithWrongCodeIsRefusedAndCreatesNothing(t *testing.T) {
	c, buf := approveConnector(t)
	p := openTestPairing(t, c)
	_, rerr := c.Phone(context.Background(), phoneWho, "_acpcode/connector/approve", approveBody(t, p.ID, wrongCodeFor(p.Code), false))
	if rerr == nil || rerr.Code != rpcInvalidParams || rerr.Message != wrongCodeMessage {
		t.Fatalf("wrong code: %+v, want -32602 %q", rerr, wrongCodeMessage)
	}
	if n := len(c.grants.list()); n != 0 {
		t.Fatalf("a wrong code created %d grant(s)", n)
	}
	c.mu.Lock()
	_, open := c.pending[p.ID]
	codes := len(c.codes)
	c.mu.Unlock()
	if !open {
		t.Fatal("a wrong code must leave the pairing pending")
	}
	if codes != 0 {
		t.Fatalf("a wrong code created %d authorization code(s)", codes)
	}
	if !strings.Contains(buf.String(), `"reason":"wrong code"`) {
		t.Fatalf("no wrong code audit line: %s", buf.String())
	}
	if !strings.Contains(buf.String(), `"identity":"owner"`) || !strings.Contains(buf.String(), `"device":"phone-1"`) {
		t.Fatalf("the wrong code line does not name the caller: %s", buf.String())
	}
	if strings.Contains(buf.String(), `"`+p.Code+`"`) {
		t.Fatal("the audit log holds the pairing code")
	}
}

func TestApproveWithMissingCodeIsRefused(t *testing.T) {
	c, _ := approveConnector(t)
	p := openTestPairing(t, c)
	for name, body := range map[string]*jsonv.Value{
		"missing": approveBody(t, p.ID, nil, true),
		"null":    approveBody(t, p.ID, nil, false),
	} {
		_, rerr := c.Phone(context.Background(), phoneWho, "_acpcode/connector/approve", body)
		if rerr == nil || rerr.Code != rpcInvalidParams || rerr.Message != codeNeededMessage {
			t.Fatalf("%s code: %+v, want -32602 %q", name, rerr, codeNeededMessage)
		}
	}
	if n := len(c.grants.list()); n != 0 {
		t.Fatalf("a missing code created %d grant(s)", n)
	}
	c.mu.Lock()
	wrong := p.wrongCodes
	c.mu.Unlock()
	if wrong != 0 {
		t.Fatalf("a missing code counted as %d wrong attempt(s), want 0", wrong)
	}
}

func TestApproveWithNonSixDigitCodeIsRefused(t *testing.T) {
	c, _ := approveConnector(t)
	p := openTestPairing(t, c)
	bad := []any{"", "12345", "1234567", "12345a", " 123456", "12 456", "١٢٣٤٥٦", "-12345", 123456, true}
	for _, code := range bad {
		_, rerr := c.Phone(context.Background(), phoneWho, "_acpcode/connector/approve", approveBody(t, p.ID, code, false))
		if rerr == nil || rerr.Code != rpcInvalidParams || rerr.Message != codeNeededMessage {
			t.Fatalf("code %#v: %+v, want -32602 %q", code, rerr, codeNeededMessage)
		}
	}
	c.mu.Lock()
	wrong := p.wrongCodes
	c.mu.Unlock()
	if wrong != 0 {
		t.Fatalf("malformed codes counted as %d wrong attempt(s), want 0", wrong)
	}
}

func TestFiveWrongCodesRemovePairing(t *testing.T) {
	c, buf := approveConnector(t)
	p := openTestPairing(t, c)
	wrong := wrongCodeFor(p.Code)
	for i := 1; i <= maxWrongCodes; i++ {
		_, rerr := c.Phone(context.Background(), phoneWho, "_acpcode/connector/approve", approveBody(t, p.ID, wrong, false))
		if rerr == nil || rerr.Message != wrongCodeMessage {
			t.Fatalf("attempt %d: %+v, want the wrong code refusal", i, rerr)
		}
		c.mu.Lock()
		_, open := c.pending[p.ID]
		c.mu.Unlock()
		if i < maxWrongCodes && !open {
			t.Fatalf("attempt %d removed the pairing early", i)
		}
		if i == maxWrongCodes && open {
			t.Fatal("the fifth wrong code must remove the pairing")
		}
	}
	select {
	case d := <-p.decision:
		if !d.denied || d.reason != "the owner denied the pairing" {
			t.Fatalf("decision = %+v, want the denial deny gives", d)
		}
	default:
		t.Fatal("the held page was not told of the denial")
	}
	if !strings.Contains(buf.String(), `"reason":"too many wrong codes"`) {
		t.Fatalf("no too-many-wrong-codes audit line: %s", buf.String())
	}
	// The right code no longer works: the pairing is gone.
	_, rerr := c.Phone(context.Background(), phoneWho, "_acpcode/connector/approve", approveBody(t, p.ID, p.Code, false))
	if rerr == nil || rerr.Code != rpcInvalidParams || !strings.Contains(rerr.Message, "no pending pairing") {
		t.Fatalf("approve after removal: %+v, want no pending pairing", rerr)
	}
	if n := len(c.grants.list()); n != 0 {
		t.Fatalf("a removed pairing created %d grant(s)", n)
	}
}

func TestDenyNeedsNoCode(t *testing.T) {
	c, _ := approveConnector(t)
	p := openTestPairing(t, c)
	raw, _ := json.Marshal(map[string]any{"pairingId": p.ID})
	v, err := jsonv.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if _, rerr := c.Phone(context.Background(), phoneWho, "_acpcode/connector/deny", v); rerr != nil {
		t.Fatalf("deny without a code refused: %+v", rerr)
	}
	select {
	case d := <-p.decision:
		if !d.denied {
			t.Fatalf("decision = %+v, want denied", d)
		}
	default:
		t.Fatal("deny gave the held page no decision")
	}
}
