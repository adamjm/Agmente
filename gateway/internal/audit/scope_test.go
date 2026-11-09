package audit

import (
	"bytes"
	"strings"
	"testing"
)

// The token's scope rides on every line of its connection, so an owner can see what a line's
// token was allowed to do.
func TestAuditLineCarriesScope(t *testing.T) {
	var buf bytes.Buffer
	New(&buf).Log("rpc", Who{Identity: "owner", Device: "shortcut", Scope: "intent"}.Fields())
	if !strings.Contains(buf.String(), `"scope":"intent"`) {
		t.Fatalf("no scope on the line: %s", buf.String())
	}
	buf.Reset()
	New(&buf).Log("connect", Fields{Identity: "owner"})
	if strings.Contains(buf.String(), `"scope"`) {
		t.Fatalf("a line with no token carries a scope: %s", buf.String())
	}
}
