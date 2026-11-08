package config

import (
	"strings"
	"testing"

	"acpcode/gateway/internal/jsonv"
)

// connectorBlock parses a connector block and runs the connector validation on it.
func connectorBlock(t *testing.T, block string) (Connector, []string) {
	t.Helper()
	v, err := jsonv.Parse([]byte(block))
	if err != nil {
		t.Fatalf("parse %s: %v", block, err)
	}
	return validateConnector(v)
}

// The public origin may carry a port; the resource identifier is publicOrigin plus /mcp (C4, D-101).
func TestConnectorPublicOriginWithPortIsAccepted(t *testing.T) {
	c, errs := connectorBlock(t, `{"enabled":true,"publicOrigin":"https://name.example:8443"}`)
	if len(errs) != 0 {
		t.Fatalf("a publicOrigin with a port is valid: %v", errs)
	}
	if c.PublicOrigin != "https://name.example:8443" {
		t.Fatalf("publicOrigin kept as written: %q", c.PublicOrigin)
	}
}

// A publicOrigin that is not an https origin with a host, an optional port, and no path, query or
// fragment is a config error. Each case names the field and gives the plain reason.
func TestConnectorPublicOriginRejectsBadValues(t *testing.T) {
	cases := map[string]string{
		"path":             `https://name.example/mcp`,
		"trailing slash":   `https://name.example/`,
		"query":            `https://name.example?x=1`,
		"fragment":         `https://name.example#top`,
		"http scheme":      `http://name.example`,
		"no host":          `https://:8443`,
		"port zero":        `https://name.example:0`,
		"port too large":   `https://name.example:65536`,
		"port not numeric": `https://name.example:https`,
		"empty port":       `https://name.example:`,
		"userinfo":         `https://user@name.example`,
	}
	for name, origin := range cases {
		block := `{"enabled":true,"publicOrigin":"` + origin + `"}`
		c, errs := connectorBlock(t, block)
		if c.PublicOrigin != "" {
			t.Errorf("%s: %q was kept as publicOrigin", name, origin)
		}
		if len(errs) == 0 || !strings.Contains(strings.Join(errs, "\n"), "connector.publicOrigin must be an https origin") {
			t.Errorf("%s: %q should report the publicOrigin error, got %v", name, origin, errs)
		}
	}
}
